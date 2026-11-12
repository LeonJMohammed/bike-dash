import Foundation

/// When the ride screen dims: after `dimAfter` seconds with nothing worth
/// looking at (no touch, lap, reminder or heart rate zone change), while a ride
/// is under way and Bike Dash is in front.
public struct ScreenDimming: Equatable, Sendable {
    /// The dimmed brightness when Settings has none yet (0 to 1).
    public static let defaultLevel = 0.2
    /// The range the Settings slider offers.
    public static let levelRange = 0.05...0.6

    public let dimAfter: TimeInterval
    /// The last touch or other reason to look.
    public private(set) var lastWake: Date

    public init(dimAfter: TimeInterval = 10, now: Date) {
        self.dimAfter = dimAfter
        lastWake = now
    }

    /// Something worth seeing: brighten, and dim again `dimAfter` from now.
    public mutating func wake(at now: Date) {
        lastWake = max(lastWake, now)
    }

    public func shouldDim(at now: Date, enabled: Bool, rideActive: Bool, appActive: Bool) -> Bool {
        enabled && rideActive && appActive && now.timeIntervalSince(lastWake) >= dimAfter
    }

    /// The brightness to dim to, or nil to leave the screen alone because it's
    /// already darker (a dark room, or auto-brightness got there first).
    public static func target(current: Double, level: Double) -> Double? {
        let level = min(max(level, levelRange.lowerBound), levelRange.upperBound)
        return current > level ? level : nil
    }
}
