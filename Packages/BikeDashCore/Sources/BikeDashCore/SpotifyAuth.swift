import Foundation

// Staying connected to Spotify: a sign-in once, then access tokens refreshed through the home
// PC's token service (server/spotify-token-service.js, which holds the client secret), and App
// Remote retried with a backoff when Spotify doesn't answer.

/// An access token and when it runs out.
public struct SpotifyAccessToken: Codable, Equatable, Sendable {
    /// Refreshed this long before it runs out, so a connect never starts with a dying token.
    public static let refreshMargin: TimeInterval = 5 * 60

    public var value: String
    public var expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }

    public func isUsable(at now: Date) -> Bool {
        now < expiresAt
    }

    public func needsRefresh(at now: Date) -> Bool {
        now >= expiresAt.addingTimeInterval(-Self.refreshMargin)
    }
}

/// What to do before connecting.
public enum SpotifyTokenPlan: Equatable, Sendable {
    case use(SpotifyAccessToken)
    case refresh
    case signIn

    /// A fresh token is used as it is; one near its end is refreshed when there's a refresh
    /// token (and used to the last minute when there isn't); with nothing usable, sign in.
    public static func decide(access: SpotifyAccessToken?, hasRefreshToken: Bool, now: Date) -> SpotifyTokenPlan {
        if let access, !access.needsRefresh(at: now) { return .use(access) }
        if hasRefreshToken { return .refresh }
        if let access, access.isUsable(at: now) { return .use(access) }
        return .signIn
    }
}

/// The token service's reply to /swap and /refresh.
public struct SpotifyTokenResponse: Decodable, Equatable, Sendable {
    public var accessToken: String
    public var expiresIn: TimeInterval
    /// Sealed by the service; only on a swap, or a refresh when Spotify rotated it.
    public var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }

    public init(accessToken: String, expiresIn: TimeInterval, refreshToken: String?) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        // Spotify sends a number; its docs' examples show a string. Either works.
        if let seconds = try? c.decode(Double.self, forKey: .expiresIn) {
            expiresIn = seconds
        } else if let text = try? c.decode(String.self, forKey: .expiresIn), let seconds = Double(text) {
            expiresIn = seconds
        } else {
            expiresIn = 3600
        }
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func accessToken(receivedAt now: Date) -> SpotifyAccessToken {
        SpotifyAccessToken(value: accessToken, expiresAt: now.addingTimeInterval(max(expiresIn, 0)))
    }
}

/// Why a token call failed, and so what to do about it.
public enum SpotifyTokenFailure: Error, Equatable, Sendable {
    /// The refresh token is no good (revoked, or sealed with an old key): sign in again.
    case signInAgain
    /// The PC, the tunnel or Spotify didn't answer properly: keep the refresh token, try later.
    case tryLater

    /// `status` is nil when nothing came back at all (offline, PC off).
    public static func classify(status: Int?, body: Data?) -> SpotifyTokenFailure {
        guard let status, status == 400 || status == 401 else { return .tryLater }
        struct Reply: Decodable { var error: String? }
        let error = body.flatMap { try? JSONDecoder().decode(Reply.self, from: $0) }?.error
        return error == "invalid_grant" ? .signInAgain : .tryLater
    }
}

/// The one-time sign-in: Spotify's authorize page, and the code that comes back.
public enum SpotifySignIn {
    public static let scopes = ["app-remote-control"]

    public enum Failure: Error, Equatable, Sendable {
        case cancelled
        case denied(String)
        case stateMismatch
        case noCode
    }

    public static func authorizeURL(clientID: String, redirectURI: String, state: String) -> URL {
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        return c.url!
    }

    /// The code from Spotify's redirect, checking it answers our own request.
    public static func code(from callback: URL, expectedState: String) -> Result<String, Failure> {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = item("error") {
            return .failure(error == "access_denied" ? .cancelled : .denied(error))
        }
        guard item("state") == expectedState else { return .failure(.stateMismatch) }
        guard let code = item("code"), !code.isEmpty else { return .failure(.noCode) }
        return .success(code)
    }
}

/// application/x-www-form-urlencoded, for the token service.
public enum FormBody {
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        set.insert(charactersIn: "-._~")
        return set
    }()

    public static func encode(_ fields: [(String, String)]) -> Data {
        let text = fields.map { name, value in
            "\(escape(name))=\(escape(value))"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// How long to wait before trying App Remote again: 2 s, 5 s, 15 s, then every 30 s.
/// After the three quick tries fail, the music bar offers "Reconnect Spotify".
public struct ReconnectBackoff: Equatable, Sendable {
    public static let quickDelays: [TimeInterval] = [2, 5, 15]
    public static let steadyDelay: TimeInterval = 30

    /// Failed attempts since the last success (or since Bike Dash came to the front).
    public private(set) var failures = 0

    public init() {}

    /// A try failed: the wait before the next one.
    public mutating func nextDelay() -> TimeInterval {
        let delay = failures < Self.quickDelays.count ? Self.quickDelays[failures] : Self.steadyDelay
        failures += 1
        return delay
    }

    /// Connected, or starting afresh.
    public mutating func reset() {
        failures = 0
    }

    /// The quick tries are used up: worth asking Leon to open Spotify.
    public var showsReconnectPrompt: Bool {
        failures > Self.quickDelays.count
    }
}
