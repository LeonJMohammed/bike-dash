import Foundation

/// One point of a planned route.
public struct RoutePoint: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Metres above sea level, when the GPX has it.
    public var elevation: Double?

    public init(latitude: Double, longitude: Double, elevation: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
    }
}

/// A planned route (a Strava route's GPX): the line to follow, how far along it
/// each point is, and its climbing.
public struct Route: Equatable, Sendable {
    public let name: String
    public let points: [RoutePoint]
    /// Metres from the start to each point; the first is 0.
    public let distances: [Double]
    /// Metres climbed, counting only rises of more than `climbThreshold`, so
    /// the jitter in the elevation data doesn't add up.
    public let elevationGain: Double

    /// Rises smaller than this between a low and the next high aren't counted.
    public static let climbThreshold = 2.0
    /// Points closer than this to the one before are dropped.
    static let minimumSpacing = 0.5

    public enum ParseError: Error, Equatable {
        case notGPX
        case tooFewPoints
    }

    /// Needs at least two points that are apart.
    public init?(name: String, points: [RoutePoint]) {
        var kept: [RoutePoint] = []
        var distances: [Double] = []
        for point in points where point.latitude.isFinite && point.longitude.isFinite
            && abs(point.latitude) <= 90 && abs(point.longitude) <= 180 {
            guard let last = kept.last else {
                kept.append(point)
                distances.append(0)
                continue
            }
            let step = Geo.distance(last, point)
            guard step >= Self.minimumSpacing else { continue }
            kept.append(point)
            distances.append(distances[distances.count - 1] + step)
        }
        guard kept.count >= 2 else { return nil }
        self.name = name
        self.points = kept
        self.distances = distances
        elevationGain = Self.climb(kept.compactMap(\.elevation))
    }

    /// Metres from start to finish.
    public var length: Double { distances[distances.count - 1] }

    public var hasElevation: Bool { points.contains { $0.elevation != nil } }

    /// The southwest and northeast corners.
    public var bounds: (south: Double, west: Double, north: Double, east: Double) {
        var south = 90.0, north = -90.0, west = 180.0, east = -180.0
        for point in points {
            south = min(south, point.latitude)
            north = max(north, point.latitude)
            west = min(west, point.longitude)
            east = max(east, point.longitude)
        }
        return (south, west, north, east)
    }

    /// The point `metres` from the start, between the two route points around it.
    public func point(atDistance metres: Double) -> RoutePoint {
        if metres <= 0 { return points[0] }
        if metres >= length { return points[points.count - 1] }
        var low = 0, high = distances.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if distances[mid] <= metres { low = mid } else { high = mid }
        }
        let span = distances[high] - distances[low]
        let t = span > 0 ? (metres - distances[low]) / span : 0
        let a = points[low], b = points[high]
        var elevation: Double?
        if let ea = a.elevation, let eb = b.elevation { elevation = ea + (eb - ea) * t }
        return RoutePoint(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t,
            elevation: elevation ?? a.elevation ?? b.elevation
        )
    }

    /// One elevation sample in the profile.
    public struct ProfilePoint: Equatable, Sendable, Identifiable {
        public var distance: Double
        public var elevation: Double
        public var id: Double { distance }
    }

    /// Up to `samples` evenly spaced elevations from start to finish, for a
    /// chart; empty without elevation data.
    public func elevationProfile(samples: Int = 200) -> [ProfilePoint] {
        guard hasElevation, samples >= 2 else { return [] }
        return (0..<samples).compactMap { index in
            let distance = length * Double(index) / Double(samples - 1)
            guard let elevation = point(atDistance: distance).elevation else { return nil }
            return ProfilePoint(distance: distance, elevation: elevation)
        }
    }

    /// Reads a GPX file: the track points (`trkpt`), or the route points
    /// (`rtept`) if it has no track, with their elevations. The name comes from
    /// the GPX, or `fallbackName`.
    public static func parseGPX(_ data: Data, fallbackName: String = "Route") throws -> Route {
        let reader = GPXReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.sawGPX else { throw ParseError.notGPX }
        let points = reader.trackPoints.isEmpty ? reader.routePoints : reader.trackPoints
        let name = reader.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let route = Route(name: (name?.isEmpty == false ? name : nil) ?? fallbackName, points: points) else {
            throw ParseError.tooFewPoints
        }
        return route
    }

    /// Climb with hysteresis: a rise counts once it's more than the threshold
    /// above the lowest point since the last counted high.
    static func climb(_ elevations: [Double]) -> Double {
        guard var low = elevations.first else { return 0 }
        var high = low
        var total = 0.0
        var climbing = false
        for elevation in elevations.dropFirst() {
            if climbing {
                if elevation > high {
                    total += elevation - high
                    high = elevation
                } else if elevation < high - Self.climbThreshold {
                    climbing = false
                    low = elevation
                }
            } else {
                if elevation < low {
                    low = elevation
                } else if elevation > low + Self.climbThreshold {
                    total += elevation - low
                    high = elevation
                    climbing = true
                }
            }
        }
        return total
    }
}

/// Distances on the Earth.
public enum Geo {
    /// Great-circle distance in metres (haversine).
    public static func distance(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        distance(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    public static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dLat = p2 - p1
        let dLon = (lon2 - lon1) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(p1) * cos(p2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * GPSFix.earthRadius * asin(min(1, sqrt(h)))
    }

    /// Compass bearing from one point to another, 0–360 degrees (0 is north).
    public static func bearing(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        let p1 = a.latitude * .pi / 180
        let p2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The point `distance` metres from `p` towards `bearing` (flat Earth:
    /// fine for the few hundred metres the ride map looks ahead).
    public static func offset(_ p: RoutePoint, bearing: Double, distance: Double) -> RoutePoint {
        let metresPerDegree = GPSFix.earthRadius * .pi / 180
        let r = bearing * .pi / 180
        return RoutePoint(
            latitude: p.latitude + cos(r) * distance / metresPerDegree,
            longitude: p.longitude + sin(r) * distance / (metresPerDegree * cos(p.latitude * .pi / 180))
        )
    }
}

/// XMLParser delegate for GPX: collects trkpt/rtept with ele, and the first name.
private final class GPXReader: NSObject, XMLParserDelegate {
    var trackPoints: [RoutePoint] = []
    var routePoints: [RoutePoint] = []
    var name: String?
    var sawGPX = false

    private var current: RoutePoint?
    private var currentIsTrack = false
    private var text = ""
    private var depthInPoint = 0
    private var readingName = false
    private var readingElevation = false

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let tag = Self.local(element)
        switch tag {
        case "gpx":
            sawGPX = true
        case "trkpt", "rtept":
            if let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) {
                current = RoutePoint(latitude: lat, longitude: lon)
                currentIsTrack = tag == "trkpt"
            }
            depthInPoint = 1
        case "wpt":
            // A waypoint isn't part of the line, and its name isn't the route's.
            current = nil
            depthInPoint = 1
        case "ele" where current != nil && depthInPoint == 1:
            readingElevation = true
            text = ""
        case "name" where name == nil && current == nil && depthInPoint == 0:
            readingName = true
            text = ""
        default:
            if depthInPoint > 0 { depthInPoint += 1 }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingName || readingElevation { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let tag = Self.local(element)
        switch tag {
        case "trkpt", "rtept":
            if let point = current {
                if currentIsTrack { trackPoints.append(point) } else { routePoints.append(point) }
            }
            current = nil
            depthInPoint = 0
        case "wpt":
            depthInPoint = 0
        case "ele" where readingElevation:
            current?.elevation = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
            readingElevation = false
        case "name" where readingName:
            name = text
            readingName = false
        default:
            if depthInPoint > 1 { depthInPoint -= 1 }
        }
    }

    /// "gpx:trkpt" → "trkpt".
    private static func local(_ element: String) -> String {
        element.split(separator: ":").last.map(String.init) ?? element
    }
}
