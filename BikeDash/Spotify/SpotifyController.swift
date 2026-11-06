import Foundation
import Observation
import os
import SpotifyiOS
import UIKit

private let log = Logger(subsystem: "com.jlmoh.bikedash", category: "spotify")

/// Now playing and playback controls through the Spotify app (App Remote).
///
/// Spotify has to be playing to connect. "Connect" opens Spotify, which starts
/// the music and comes back with a token that's good for an hour; within that
/// hour, coming back to Bike Dash reconnects by itself.
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
    private(set) var lastError: String?

    static let redirectURL = URL(string: "bikedash://spotify-login-callback")!
    private static let tokenKey = "spotifyToken"
    private static let tokenExpiryKey = "spotifyTokenExpiry"

    private let appRemote: SPTAppRemote?
    @ObservationIgnored private var artworkURI: String?
    @ObservationIgnored private var connectInFlight = false

    override init() {
        let clientID = (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String) ?? ""
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
    }

    var isConfigured: Bool { appRemote != nil }

    // MARK: - Connecting

    /// Opens Spotify, which starts playing and comes back with a token.
    func connectViaSpotifyApp() {
        guard let appRemote else { return }
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

    /// The redirect back from Spotify (bikedash://spotify-login-callback).
    func handle(_ url: URL) {
        guard let appRemote, let parameters = appRemote.authorizationParameters(from: url) else { return }
        if let token = parameters[SPTAppRemoteAccessTokenKey] {
            UserDefaults.standard.set(token, forKey: Self.tokenKey)
            UserDefaults.standard.set(Date().addingTimeInterval(55 * 60), forKey: Self.tokenExpiryKey)
            connect()
        } else {
            status = .disconnected
            lastError = parameters[SPTAppRemoteErrorDescriptionKey] ?? "Spotify sign-in failed"
        }
    }

    func appBecameActive() {
        connect()
    }

    /// Spotify asks apps to let go when they're in the background.
    func appWentToBackground() {
        if appRemote?.isConnected == true {
            appRemote?.disconnect()
        }
    }

    /// Settings > Disconnect: drops the connection and the saved token.
    func disconnect() {
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.tokenExpiryKey)
        if appRemote?.isConnected == true {
            appRemote?.disconnect()
        }
        status = isConfigured ? .disconnected : .notConfigured
        nowPlaying = nil
        artwork = nil
    }

    private var savedToken: String? {
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: Self.tokenKey),
              let expiry = defaults.object(forKey: Self.tokenExpiryKey) as? Date,
              expiry > Date() else { return nil }
        return token
    }

    private func connect() {
        guard let appRemote, !appRemote.isConnected, !connectInFlight, let token = savedToken else { return }
        appRemote.connectionParameters.accessToken = token
        connectInFlight = true
        status = .connecting
        appRemote.connect()
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
            self.artwork = result as? UIImage
        })
    }

    /// Demo mode (simulator screenshots).
    func loadDemo() {
        status = .connected
        nowPlaying = NowPlaying(
            title: "Midnight City",
            subtitle: "M83",
            isPaused: false,
            isEpisode: false,
            canSkipNext: true,
            canSkipPrevious: true
        )
    }
}

extension SpotifyController: @preconcurrency SPTAppRemoteDelegate {
    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        connectInFlight = false
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
        connectInFlight = false
        status = .disconnected
        lastError = "Couldn't reach Spotify. Tap Connect to open it."
        log.error("Connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        connectInFlight = false
        status = .disconnected
    }
}

extension SpotifyController: @preconcurrency SPTAppRemotePlayerStateDelegate {
    func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        update(with: playerState)
    }
}
