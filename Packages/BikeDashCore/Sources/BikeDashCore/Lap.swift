import Foundation

/// One finished lap: what it covered in moving time only.
public struct Lap: Codable, Hashable, Identifiable, Sendable {
    public enum Trigger: String, Codable, Sendable {
        /// Every so many km (Settings).
        case auto
        /// The LAP button.
        case manual
        /// The part from the last lap to the end of the ride.
        case finish
    }

    /// 1 for the first lap.
    public var number: Int
    public var trigger: Trigger
    public var endedAt: Date
    /// Metres.
    public var distance: Double
    public var movingTime: TimeInterval
    public var averageHeartRate: Int?
    /// While pedalling: coasting (0 rpm) doesn't count.
    public var averageCadence: Int?

    public var id: Int { number }

    /// m/s.
    public var averageSpeed: Double? {
        movingTime > 0 ? distance / movingTime : nil
    }

    public init(
        number: Int,
        trigger: Trigger,
        endedAt: Date,
        distance: Double,
        movingTime: TimeInterval,
        averageHeartRate: Int?,
        averageCadence: Int?
    ) {
        self.number = number
        self.trigger = trigger
        self.endedAt = endedAt
        self.distance = distance
        self.movingTime = movingTime
        self.averageHeartRate = averageHeartRate
        self.averageCadence = averageCadence
    }
}

extension RideSession {
    /// Where the lap under way started: the ride's running totals then.
    public struct LapStart: Codable, Equatable, Sendable {
        public var distance: Double = 0
        public var movingTime: TimeInterval = 0
        public var heartRateTotal: Double = 0
        public var heartRateSamples = 0
        public var cadenceTotal: Double = 0
        public var cadenceSamples = 0
    }
}
