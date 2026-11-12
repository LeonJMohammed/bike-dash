import Foundation

/// A finished ride, as kept in the History tab.
public struct RideRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date
    /// Metres.
    public var distance: Double
    public var movingTime: TimeInterval
    public var elapsedTime: TimeInterval
    /// Metres climbed.
    public var ascent: Double
    /// m/s.
    public var maxSpeed: Double
    public var averageHeartRate: Int?
    public var maxHeartRate: Int?
    /// The splits; nil for rides saved before laps existed.
    public var laps: [Lap]?

    /// Average moving speed, m/s.
    public var averageSpeed: Double? {
        movingTime > 0 ? distance / movingTime : nil
    }

    /// Seconds per km.
    public var averagePace: TimeInterval? {
        distance >= 10 ? movingTime / (distance / 1000) : nil
    }

    /// Splits worth listing: a ride that's one lap long has none.
    public var splits: [Lap] {
        let laps = laps ?? []
        return laps.count >= 2 ? laps : []
    }
}

extension RideSession {
    /// The finished ride for the history, or nil if the ride isn't finished.
    public func record(id: UUID = UUID()) -> RideRecord? {
        guard state == .finished, let startedAt, let finishedAt else { return nil }
        return RideRecord(
            id: id,
            startedAt: startedAt,
            finishedAt: finishedAt,
            distance: distance,
            movingTime: movingTime(at: finishedAt),
            elapsedTime: elapsedTime(at: finishedAt),
            ascent: ascent,
            maxSpeed: maxSpeed,
            averageHeartRate: averageHeartRate,
            maxHeartRate: maxHeartRate > 0 ? maxHeartRate : nil,
            laps: laps
        )
    }
}
