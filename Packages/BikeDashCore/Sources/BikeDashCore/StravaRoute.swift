import Foundation

/// One of your saved Strava routes, as the home PC's routes service lists it
/// (server/strava-routes.js). Route ids are strings: Strava's are too big for
/// JSON numbers.
public struct StravaRoute: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case ride, run, other

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// Metres.
    public var distance: Double
    /// Metres climbed, by Strava's count.
    public var elevationGain: Double
    /// ISO 8601, as Strava gives it.
    public var updatedAt: String?
    public var isPrivate: Bool
    public var starred: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, kind, starred
        case distance = "distance_m"
        case elevationGain = "elevation_gain_m"
        case updatedAt = "updated_at"
        case isPrivate = "private"
    }

    public init(id: String, name: String, kind: Kind, distance: Double, elevationGain: Double,
                updatedAt: String? = nil, isPrivate: Bool = false, starred: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.distance = distance
        self.elevationGain = elevationGain
        self.updatedAt = updatedAt
        self.isPrivate = isPrivate
        self.starred = starred
    }

    /// When the route was last changed on Strava.
    public var updated: Date? {
        updatedAt.flatMap { Self.parseDate($0) }
    }

    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// The routes service's reply to `GET list`.
public struct StravaRouteList: Codable, Equatable, Sendable {
    public var routes: [StravaRoute]
    /// Strava's read_all permission is missing, so private routes aren't listed.
    public var privateHidden: Bool

    enum CodingKeys: String, CodingKey {
        case routes
        case privateHidden = "private_hidden"
    }

    public init(routes: [StravaRoute], privateHidden: Bool) {
        self.routes = routes
        self.privateHidden = privateHidden
    }
}
