import BikeDashCore
import Foundation
import Observation
import os
import SpotifyiOS
import SwiftUI
import UIKit

private let log = Logger(subsystem: "com.jlmoh.bikedash", category: "spotify")

/// Now playing and playback controls through the Spotify app (App Remote).
///
/// Signing in once (Settings, or the music bar) gives a refresh token, kept in the Keychain, so
/// the access token is renewed through the home PC's token service whenever it's near its end.
/// Spotify still has to be running to connect: when it doesn't answer, Bike Dash tries again
/// after 2, 5 and 15 seconds, then every 30 seconds while it's in front, and after the quick
/// tries the music bar offers "Reconnect Spotify", which opens Spotify and starts the music.
@MainActor
@Observable
final class SpotifyController: NSObject {
    enum Status: Equatable {
        case notConfigured, disconnected, connecting, connected
    }

    struct NowPlaying: Equatable {
        var title: String
        var subtitle: String
        var isPaused: Bool
        /// Podcast episode: the arrows jump 15 s instead of skipping.
        var isEpisode: Bool
        var canSkipNext: Bool
        var canSkipPrevious: Bool
    }

    private(set) var status: Status = .disconnected
    private(set) var nowPlaying: NowPlaying?
    private(set) var artwork: UIImage?
    /// The music bar's colour, from the cover.
    private(set) var artworkTint: Color?
    private(set) var lastError: String?
    /// A refresh token is saved: Bike Dash stays signed in.
    private(set) var isSignedIn = false
    /// Spotify didn't answer the quick retries: offer to open it.
    private(set) var showsReconnectPrompt = false
    private(set) var signingIn = false

    static let redirectURL = URL(string: "bikedash://spotify-login-callback")!
    private static let refreshTokenAccount = "refreshToken"
    private static let accessTokenAccount = "accessToken"
    // Before the Keychain (1-hour tokens from Spotify's own app, kept in UserDefaults).
    private static let oldTokenKeys = ["spotifyToken", "spotifyTokenExpiry"]

    private let clientID: String
    private let appRemote: SPTAppRemote?
    private let tokenService = SpotifyTokenService.configured
    @ObservationIgnored private let signInSheet = SpotifySignInSheet()
    @ObservationIgnored private var artworkURI: String?
    @ObservationIgnored private var connectInFlight = false
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var backoff = ReconnectBackoff()
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    override init() {
        clientID = (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String) ?? ""
        if clientID.isEmpty || DemoMode.isOn {
            appRemote = nil
        } else {
            let configuration = SPTConfiguration(clientID: clientID, redirectURL: Self.redirectURL)
            appRemote = SPTAppRemote(configuration: configuration, logLevel: .error)
        }
        super.init()
        appRemote?.delegate = self
        if appRemote == nil && !DemoMode.isOn {
            status = .notConfigured
        }
        for key in Self.oldTokenKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        isSignedIn = refreshToken != nil
    }

    var isConfigured: Bool { appRemote != nil }
    /// Signing in needs the token service as well as the client ID.
    var canSignIn: Bool { isConfigured && tokenService != nil }

    // MARK: - Tokens

    private var refreshToken: String? {
        get { Keychain.string(Self.refreshTokenAccount) }
        set {
            Keychain.set(newValue, for: Self.refreshTokenAccount)
            isSignedIn = newValue != nil
        }
    }

    private var accessToken: SpotifyAccessToken? {
        get {
            Keychain.string(Self.accessTokenAccount)
                .flatMap { try? JSONDecoder().decode(SpotifyAccessToken.self, from: Data($0.utf8)) }
        }
        set {
            let json = newValue.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            Keychain.set(json, for: Self.accessTokenAccount)
        }
    }

    private func save(_ reply: SpotifyTokenResponse) -> SpotifyAccessToken {
        let token = reply.accessToken(receivedAt: Date())
        accessToken = token
        if let sealed = reply.refreshToken {
            refreshToken = sealed
        }
        return token
    }

    // MARK: - Signing in

    /// Spotify's sign-in page, once; afterwards Bike Dash stays signed in.
    func signIn() {
        guard canSignIn, let tokenService, !signingIn else { return }
        signingIn = true
        lastError = nil
        Task {
            defer { signingIn = false }
            switch await signInSheet.signIn(clientID: clientID, redirectURL: Self.redirectURL) {
            case .success(let code):
                do {
                    _ = save(try await tokenService.swap(code: code))
                    log.notice("Signed in to Spotify")
                    backoff.reset()
                    showsReconnectPrompt = false
                    connect()
                } catch {
                    lastError = "Couldn't finish signing in. Is the home PC on?"
                    log.error("Token swap failed: \(String(describing: error), privacy: .public)")
                }
            case .failure(.cancelled):
                break
            case .failure(let failure):
                lastError = "Spotify sign-in failed"
                log.error("Sign-in failed: \(String(describing: failure), privacy: .public)")
            }
        }
    }

    /// Opens Spotify, which starts playing and comes back with a token: the way to wake Spotify
    /// when it isn't running (the "Reconnect Spotify" prompt).
    func connectViaSpotifyApp() {
        guard let appRemote else { return }
        retryTask?.cancel()
        status = .connecting
        lastError = nil
        appRemote.authorizeAndPlayURI("", completionHandler: { [weak self] canOpen in
            guard !canOpen else { return }
            Task { @MainActor in
                self?.status = .disconnected
                self?.lastError = "The Spotify app isn't installed"
            }
        })
    }

    /// The redirect back from Spotify's app (bikedash://spotify-login-callback).
    func handle(_ url: URL) {
        guard let appRemote, let parameters = appRemote.authorizationParameters(from: url) else { return }
        if let token = parameters[SPTAppRemoteAccessTokenKey] {
            // Spotify's app gives an hour; the refresh token, if any, takes over after that.
            accessToken = SpotifyAccessToken(value: token, expiresAt: Date().addingTimeInterval(55 * 60))
            backoff.reset()
            showsReconnectPrompt = false
            connect()
        } else {
            status = .disconnected
            lastError = parameters[SPTAppRemoteErrorDescriptionKey] ?? "Spotify sign-in failed"
        }
    }

    // MARK: - Connecting

    func appBecameActive() {
        isActive = true
        guard isConfigured else { return }
        backoff.reset()
        showsReconnectPrompt = false
        connect()
    }

    /// Spotify asks apps to let go when they're in the background.
    func appWentToBackground() {
        isActive = false
        retryTask?.cancel()
        retryTask = nil
        if appRemote?.isConnected == true {
            appRemote?.disconnect()
        }
    }

    /// Settings > Sign out: drops the connection and every saved token.
    func disconnect() {
        retryTask?.cancel()
        refreshToken = nil
        accessToken = nil
        backoff.reset()
        showsReconnectPrompt = false
        if appRemote?.isConnected == true {
            appRemote?.disconnect()
        }
        status = isConfigured ? .disconnected : .notConfigured
        nowPlaying = nil
        artwork = nil
        artworkTint = nil
    }

    private func connect() {
        guard let appRemote, isActive, !appRemote.isConnected, !connectInFlight else { return }
        retryTask?.cancel()
        retryTask = nil
        let plan = SpotifyTokenPlan.decide(access: accessToken, hasRefreshToken: refreshToken != nil, now: Date())
        if case .signIn = plan {
            status = .disconnected
            return
        }
        connectInFlight = true
        status = .connecting
        Task { await connect(appRemote, plan) }
    }

    private func connect(_ appRemote: SPTAppRemote, _ plan: SpotifyTokenPlan) async {
        let token: SpotifyAccessToken
        switch plan {
        case .use(let saved):
            token = saved
        case .refresh:
            guard let refreshed = await refreshAccessToken() else { return }
            token = refreshed
        case .signIn:
            connectInFlight = false
            return
        }
        guard isActive else {
            connectInFlight = false
            status = .disconnected
            return
        }
        appRemote.connectionParameters.accessToken = token.value
        appRemote.connect()
    }

    /// A new access token from the token service, or nil after dealing with the failure.
    private func refreshAccessToken() async -> SpotifyAccessToken? {
        guard let tokenService, let sealed = refreshToken else {
            connectInFlight = false
            status = .disconnected
            return nil
        }
        do {
            return save(try await tokenService.refresh(sealed))
        } catch SpotifyTokenFailure.signInAgain {
            log.notice("Refresh token refused: signed out")
            refreshToken = nil
            connectInFlight = false
            status = .disconnected
            showsReconnectPrompt = false
            lastError = "Sign in to Spotify again"
            return nil
        } catch {
            // PC off, tunnel down, Spotify busy: an old token still has a few minutes, else retry.
            log.error("Token refresh failed; trying later")
            if let old = accessToken, old.isUsable(at: Date()) {
                return old
            }
            failedAttempt("Couldn't renew the Spotify sign-in")
            return nil
        }
    }

    private func failedAttempt(_ message: String) {
        connectInFlight = false
        status = .disconnected
        lastError = message
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard isActive, isConfigured else { return }
        let delay = backoff.nextDelay()
        showsReconnectPrompt = backoff.showsReconnectPrompt
        log.notice("Retrying Spotify in \(delay, privacy: .public) s (failure \(self.backoff.failures, privacy: .public))")
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    // MARK: - Controls

    func togglePlayPause() {
        guard let playerAPI = appRemote?.playerAPI, let nowPlaying else { return }
        if nowPlaying.isPaused {
            playerAPI.resume(nil)
        } else {
            playerAPI.pause(nil)
        }
    }

    func next() {
        guard let playerAPI = appRemote?.playerAPI else { return }
        if nowPlaying?.isEpisode == true {
            playerAPI.seekForward15Seconds(nil)
        } else {
            playerAPI.skip(toNext: nil)
        }
    }

    func previous() {
        guard let playerAPI = appRemote?.playerAPI else { return }
        if nowPlaying?.isEpisode == true {
            playerAPI.seekBackward15Seconds(nil)
        } else {
            playerAPI.skip(toPrevious: nil)
        }
    }

    // MARK: - Player state

    private func update(with state: SPTAppRemotePlayerState) {
        let track = state.track
        nowPlaying = NowPlaying(
            title: track.name,
            subtitle: track.artist.name,
            isPaused: state.isPaused,
            isEpisode: track.isEpisode || track.isPodcast,
            canSkipNext: state.playbackRestrictions.canSkipNext,
            canSkipPrevious: state.playbackRestrictions.canSkipPrevious
        )
        guard track.uri != artworkURI else { return }
        artworkURI = track.uri
        artwork = nil
        let uri = track.uri
        appRemote?.imageAPI?.fetchImage(forItem: track, with: CGSize(width: 600, height: 600), callback: { [weak self] result, _ in
            guard let self, self.artworkURI == uri else { return }
            let image = result as? UIImage
            self.artwork = image
            self.artworkTint = image.flatMap { ArtworkTint.color(for: $0) }
        })
    }

    /// Demo mode (simulator screenshots). `-spotifyDemo reconnect` shows the reconnect prompt.
    func loadDemo() {
        if UserDefaults.standard.string(forKey: "spotifyDemo") == "reconnect" {
            status = .disconnected
            isSignedIn = true
            showsReconnectPrompt = true
            return
        }
        status = .connected
        nowPlaying = NowPlaying(
            title: "Midnight City",
            subtitle: "M83",
            isPaused: false,
            isEpisode: false,
            canSkipNext: true,
            canSkipPrevious: true
        )
        let cover = ArtworkTint.demoCover()
        artwork = cover
        artworkTint = ArtworkTint.color(for: cover)
    }
}

extension SpotifyController: @preconcurrency SPTAppRemoteDelegate {
    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        connectInFlight = false
        retryTask?.cancel()
        backoff.reset()
        showsReconnectPrompt = false
        status = .connected
        lastError = nil
        appRemote.playerAPI?.delegate = self
        appRemote.playerAPI?.subscribe(toPlayerState: { _, error in
            if let error {
                log.error("Player subscription failed: \(error.localizedDescription, privacy: .public)")
            }
        })
        appRemote.playerAPI?.getPlayerState({ [weak self] result, _ in
            if let state = result as? SPTAppRemotePlayerState {
                self?.update(with: state)
            }
        })
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        log.error("Connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        failedAttempt("Spotify isn't answering")
    }

    /// Spotify closed, or Bike Dash let go in the background (no retry then).
    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        connectInFlight = false
        status = .disconnected
        if isActive {
            log.notice("Spotify disconnected: \(error?.localizedDescription ?? "no error", privacy: .public)")
            scheduleRetry()
        }
    }
}

extension SpotifyController: @preconcurrency SPTAppRemotePlayerStateDelegate {
    func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        update(with: playerState)
    }
}
