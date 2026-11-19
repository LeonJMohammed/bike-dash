import BikeDashCore
import Foundation

/// The home PC's routes service (server/strava-routes.js) behind the Cloudflare
/// Tunnel: your saved Strava routes, and each one as GPX. It needs the app key
/// the PC minted (Secrets.xcconfig BIKE_DASH_ROUTES_KEY, Info.plist RoutesAppKey).
struct RoutesService {
    let baseURL: URL
    let appKey: String

    enum Failure: Error, Equatable {
        /// No connection, or the PC didn't answer in time.
        case offline
        /// Cloudflare Access's login page instead of the service (no bypass).
        case blocked
        /// The PC refused this build's key.
        case refused
        /// The PC answered, but couldn't get the routes (its error code).
        case server(String)

        var message: String {
            switch self {
            case .offline:
                return "Can't reach the home PC. Routes saved on this phone still work."
            case .blocked:
                return "The routes address is behind the Cloudflare login. It needs the Access bypass, like the Spotify one."
            case .refused:
                return "The home PC didn't accept this build's routes key."
            case .server(let code):
                switch code {
                case "strava_busy": return "Strava is busy. Try again in a few minutes."
                case "race_tracker_unreachable", "race_tracker_refused", "race_tracker_error":
                    return "The home PC couldn't get a Strava token from Race Tracker (\(code))."
                case "strava_not_connected", "strava_auth":
                    return "Strava needs connecting again in Race Tracker (\(code))."
                case "not_found": return "Strava doesn't have that route any more."
                default: return "The home PC couldn't get the routes (\(code))."
                }
            }
        }
    }

    /// From Info.plist; nil when this build has no routes key.
    static var configured: RoutesService? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "RoutesServiceURL") as? String,
              let url = URL(string: text), !text.isEmpty,
              let key = Bundle.main.object(forInfoDictionaryKey: "RoutesAppKey") as? String,
              key.hasPrefix("v1.") else { return nil }
        return RoutesService(baseURL: url, appKey: key)
    }

    func list() async throws -> StravaRouteList {
        let data = try await get("list", timeout: 30)
        guard let list = try? JSONDecoder().decode(StravaRouteList.self, from: data) else {
            throw Failure.server("bad_reply")
        }
        return list
    }

    func gpx(id: String) async throws -> Data {
        try await get("\(id)/gpx", timeout: 60)
    }

    private func get(_ path: String, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.setValue("Bearer \(appKey)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await NoRedirects.session.data(for: request)
        } catch {
            throw Failure.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            return data
        case 300..<400:
            throw Failure.blocked
        case 401:
            throw Failure.refused
        default:
            let code = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error
            throw Failure.server(code ?? "http_\(status)")
        }
    }

    /// `{"error":"…", …}`; other fields (numbers too) are ignored.
    private struct ErrorReply: Decodable {
        let error: String?
    }
}
