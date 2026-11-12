import Foundation

/// Five heart rate zones from a max heart rate: 50–60, 60–70, 70–80, 80–90 and
/// 90–100% of max. Below 50% is zone 0 (none lit).
public struct HeartRateZones: Equatable, Sendable {
    public static let defaultMax = 190
    /// What the Settings field accepts.
    public static let maxRange = 120...230
    public static let count = 5

    public let maxHeartRate: Int

    /// Out-of-range values are pulled into `maxRange`.
    public init(maxHeartRate: Int) {
        self.maxHeartRate = min(max(maxHeartRate, Self.maxRange.lowerBound), Self.maxRange.upperBound)
    }

    /// The lowest heart rate in `zone` (1 to 5); `lowerBound(of: 6)` is max.
    public func lowerBound(of zone: Int) -> Double {
        Double(maxHeartRate * (4 + zone)) / 10
    }

    /// 1 to 5, or 0 below 50% of max. Above max is still zone 5.
    public func zone(for bpm: Int) -> Int {
        // Whole tenths of max, in integers so 60% exactly is zone 2.
        let tenths = bpm * 10 / maxHeartRate
        guard tenths >= 5 else { return 0 }
        return min(Self.count, tenths - 4)
    }

    /// Where `bpm` sits in `zone`: 0 at its bottom, 1 at its top, clamped.
    /// For zone 0 it's always 0.
    public func position(of bpm: Int, in zone: Int) -> Double {
        guard zone >= 1 else { return 0 }
        let low = lowerBound(of: zone)
        let high = lowerBound(of: zone + 1)
        return min(max((Double(bpm) - low) / (high - low), 0), 1)
    }
}

/// The lit zone. It only moves on once the heart rate is `margin` bpm past a
/// zone's edge, so a heart rate sitting on a boundary doesn't make the bar
/// flicker or keep waking a dimmed screen.
public struct ZoneTracker: Equatable, Sendable {
    public let margin: Double
    /// Nil until the first reading.
    public private(set) var zone: Int?

    public init(margin: Double = 2) {
        self.margin = margin
    }

    /// Returns true when the zone changed (the first reading isn't a change).
    @discardableResult
    public mutating func update(bpm: Int, zones: HeartRateZones) -> Bool {
        let raw = zones.zone(for: bpm)
        guard let current = zone else {
            zone = raw
            return false
        }
        guard raw != current else { return false }
        let low = current >= 1 ? zones.lowerBound(of: current) : -Double.infinity
        let high = current < HeartRateZones.count ? zones.lowerBound(of: current + 1) : Double.infinity
        if Double(bpm) >= low - margin, Double(bpm) < high + margin { return false }
        zone = raw
        return true
    }

    /// The signal was lost: start again with the next reading.
    public mutating func reset() {
        zone = nil
    }
}
