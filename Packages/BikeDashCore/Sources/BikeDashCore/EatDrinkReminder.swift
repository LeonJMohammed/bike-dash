import Foundation

/// "Eat / Drink" every so many minutes of moving time, so the countdown waits
/// while the ride is paused. The banner clears itself after `showFor` seconds,
/// or sooner with a tap, and the countdown starts again from then.
public struct EatDrinkReminder: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case show
        case hide
    }

    /// The Settings picker: 15 to 60 minutes in 5-minute steps.
    public static let intervalChoices = Array(stride(from: 15, through: 60, by: 5))
    public static let defaultInterval = 30
    public static let showFor: TimeInterval = 15

    /// Moving time (seconds) when the countdown last started.
    public private(set) var countdownStart: TimeInterval = 0
    /// When the banner went up; nil while it's down.
    public private(set) var shownAt: Date?

    public init() {}

    public var isShowing: Bool { shownAt != nil }

    /// Moving time left until the next reminder, in seconds.
    public func remaining(movingTime: TimeInterval, intervalMinutes: Int) -> TimeInterval {
        max(0, countdownStart + Double(intervalMinutes) * 60 - movingTime)
    }

    /// Once a second during a ride. Returns what the banner should do.
    public mutating func update(movingTime: TimeInterval, intervalMinutes: Int, enabled: Bool, now: Date) -> Change? {
        if let shownAt {
            // Switched off while showing, or shown long enough: down, and count again.
            guard enabled, now.timeIntervalSince(shownAt) < Self.showFor else {
                self.shownAt = nil
                countdownStart = movingTime
                return .hide
            }
            return nil
        }
        guard enabled, remaining(movingTime: movingTime, intervalMinutes: intervalMinutes) == 0 else { return nil }
        shownAt = now
        return .show
    }

    /// A tap on the banner: down, and the countdown starts again from now.
    public mutating func dismiss(movingTime: TimeInterval) {
        shownAt = nil
        countdownStart = movingTime
    }

    /// A new ride, or the reminder just switched on: count from here.
    public mutating func restart(movingTime: TimeInterval) {
        shownAt = nil
        countdownStart = movingTime
    }
}
