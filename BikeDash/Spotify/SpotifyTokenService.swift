import AuthenticationServices
import BikeDashCore
import Foundation
import UIKit

/// The home PC's token service (server/spotify-token-service.js) behind the Cloudflare Tunnel:
/// it swaps the sign-in code for tokens and refreshes them, holding Spotify's client secret.
struct SpotifyTokenService {
    let baseURL: URL

    /// Info.plist `SpotifyTokenServiceURL`.
    static var configured: SpotifyTokenService? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "SpotifyTokenServiceURL") as? String,
              let url = URL(string: text), !text.isEmpty else { return nil }
        return SpotifyTokenService(baseURL: url)
    }

    func swap(code: String) async throws -> SpotifyTokenResponse {
        try await post("swap", [("code", code)])
    }

    func refresh(_ sealedRefreshToken: String) async throws -> SpotifyTokenResponse {
        try await post("refresh", [("refresh_token", sealedRefreshToken)])
    }

    /// Throws `SpotifyTokenFailure`.
    private func post(_ path: String, _ fields: [(String, String)]) async throws -> SpotifyTokenResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = FormBody.encode(fields)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await NoRedirects.session.data(for: request)
        } catch {
            throw SpotifyTokenFailure.tryLater
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200, let reply = try? JSONDecoder().decode(SpotifyTokenResponse.self, from: data) else {
            throw SpotifyTokenFailure.classify(status: status, body: data)
        }
        return reply
    }
}

/// A Cloudflare Access login redirect is a failure to report, not a page to follow.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Spotify's sign-in page in a sheet; returns the authorization code.
@MainActor
final class SpotifySignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func signIn(clientID: String, redirectURL: URL) async -> Result<String, SpotifySignIn.Failure> {
        let state = UUID().uuidString
        let url = SpotifySignIn.authorizeURL(clientID: clientID, redirectURI: redirectURL.absoluteString, state: state)
        return await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: redirectURL.scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: SpotifySignIn.code(from: callback, expectedState: state))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(returning: .failure(.cancelled))
                } else {
                    continuation.resume(returning: .failure(.denied(error?.localizedDescription ?? "unknown")))
                }
            }
            session.presentationContextProvider = self
            // Shares Safari's cookies, so a Spotify login there carries over.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(returning: .failure(.denied("couldn't open the sign-in page")))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        }
    }
}
