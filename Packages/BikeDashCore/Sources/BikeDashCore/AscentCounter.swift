import Foundation

/// Total climb from a stream of altitude readings (the barometer's relative
/// altitude). Changes smaller than `threshold` are treated as noise.
public struct AscentCounter: Equatable, Sendable {
    public let threshold: Double
    /// Metres climbed.
    public private(set) var ascent: Double = 0
    private var reference: Double?

    public init(threshold: Double = 1.0) {
        self.threshold = threshold
    }

    public mutating func add(_ altitude: Double) {
        guard let reference else {
            self.reference = altitude
            return
        }
        if altitude - reference >= threshold {
            ascent += altitude - reference
            self.reference = altitude
        } else if reference - altitude >= threshold {
            self.reference = altitude
        }
    }

    /// The next reading starts a new series (the altimeter restarted from 0).
    public mutating func breakSegment() {
        reference = nil
    }
}
