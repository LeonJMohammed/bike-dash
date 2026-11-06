import Foundation

/// One GPS position report. Independent of CoreLocation so the maths can be
/// tested with `swift test`.
public struct GPSFix: Equatable, Sendable {
    public var time: Date
    public var latitude: Double
    public var longitude: Double
    /// Metres; negative means invalid.
    public var horizontalAccuracy: Double
    /// Doppler speed in m/s; negative means invalid.
    public var speed: Double

    public init(time: Date, latitude: Double, longitude: Double, horizontalAccuracy: Double, speed: Double) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
    }

    /// Mean Earth radius in metres.
    public static let earthRadius = 6_371_008.8

    /// Great-circle distance to another fix, in metres (haversine).
    public func distance(to other: GPSFix) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * Self.earthRadius * asin(min(1, sqrt(h)))
    }
}
