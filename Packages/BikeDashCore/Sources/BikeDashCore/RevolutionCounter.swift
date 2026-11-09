import Foundation

/// Turns the running revolution count and "last event time" that a CSC sensor
/// sends into a rate (wheel or crank revolutions per second), and counts the
/// new revolutions for the distance.
///
/// - A notification whose event time hasn't changed is a repeat: ignored.
/// - Event times wrap every 64 s, crank counts every 65,536 revolutions and
///   wheel counts at 2^32; differences are taken modulo those.
/// - With no new revolution for `staleAfter`, the rate reads 0 (coasting or
///   stopped). The first revolution after that, or after connecting, starts
///   afresh: it counts for distance but gives no rate, because the time since
///   the one before spans the stop (and may have wrapped).
public struct RevolutionCounter: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The first reading: nothing to compare it with yet.
        case baseline
        /// The event time or the count hasn't moved: a repeat notification.
        case duplicate
        /// New revolutions after a quiet spell: they count, but the rate starts afresh.
        case restart
        /// New revolutions and a new rate.
        case counted
        /// A jump no wheel or crank could make (the sensor restarted, or a bad
        /// packet): ignored, and counting starts again from this reading.
        case rejected
    }

    public struct Update: Equatable, Sendable {
        public var outcome: Outcome
        /// New revolutions to add to the distance.
        public var revolutions: Int
        /// Set when this revolution ends a stop: fewer than one turn per
        /// `staleAfter` since the last one, so it stood still from then.
        public var stoppedSince: Date? = nil
    }

    /// The reading the next one is compared with.
    public struct Reading: Equatable, Sendable {
        public var revolutions: UInt32
        public var eventTime: UInt16
        /// When it arrived, by the phone's clock.
        public var receivedAt: Date
    }

    /// The revolutions and time behind the current rate (for the debug view).
    public struct Interval: Equatable, Sendable {
        public var revolutions: Int
        public var seconds: Double
    }

    /// 2^32 for wheel counts, 2^16 for crank counts.
    public let countModulus: UInt64
    public let staleAfter: TimeInterval
    /// Revolutions per second nobody reaches; faster readings are glitches.
    public let maxRate: Double

    public private(set) var last: Reading?
    /// When the latest new revolution arrived; nil until one has, since
    /// connecting or since the last reset.
    public private(set) var lastRevolutionAt: Date?
    public private(set) var lastInterval: Interval?
    public private(set) var duplicates = 0
    public private(set) var rejections = 0
    private var currentRate: Double = 0

    public init(countModulus: UInt64, staleAfter: TimeInterval = 3, maxRate: Double) {
        self.countModulus = countModulus
        self.staleAfter = staleAfter
        self.maxRate = maxRate
    }

    /// Wheel revolutions. 15 a second is over 110 km/h on a road wheel.
    public static func wheel(staleAfter: TimeInterval = 3) -> RevolutionCounter {
        RevolutionCounter(countModulus: 1 << 32, staleAfter: staleAfter, maxRate: 15)
    }

    /// Crank revolutions. 4 a second is 240 rpm.
    public static func crank(staleAfter: TimeInterval = 3) -> RevolutionCounter {
        RevolutionCounter(countModulus: 1 << 16, staleAfter: staleAfter, maxRate: 4)
    }

    @discardableResult
    public mutating func add(revolutions: UInt32, eventTime: UInt16, at now: Date) -> Update {
        let reading = Reading(revolutions: revolutions, eventTime: eventTime, receivedAt: now)
        guard let last else {
            self.last = reading
            return Update(outcome: .baseline, revolutions: 0)
        }
        let new = (UInt64(revolutions) + countModulus - UInt64(last.revolutions) % countModulus) % countModulus
        guard eventTime != last.eventTime, new > 0 else {
            duplicates += 1
            return Update(outcome: .duplicate, revolutions: 0)
        }

        // More revolutions than fit in the time since the last reading (with
        // room for a late packet): the count jumped.
        let elapsed = max(0, now.timeIntervalSince(last.receivedAt))
        guard Double(new) <= maxRate * (elapsed + 2) else {
            rejections += 1
            self.last = reading
            lastRevolutionAt = nil
            lastInterval = nil
            currentRate = 0
            return Update(outcome: .rejected, revolutions: 0)
        }

        let count = Int(new)
        let previous = lastRevolutionAt
        self.last = reading
        lastRevolutionAt = now
        let quiet = previous.map { now.timeIntervalSince($0) }
        guard let quiet, quiet <= staleAfter else {
            currentRate = 0
            lastInterval = nil
            // After a dropout the count catches up with many turns at once;
            // after a stop it moves by one or two.
            let stopped = quiet.flatMap { Double(count) * staleAfter < $0 ? previous : nil }
            return Update(outcome: .restart, revolutions: count, stoppedSince: stopped)
        }

        // UInt16 subtraction wraps, which handles the 64 s rollover (the gap is
        // under `staleAfter` here, so it can't have wrapped twice). An interval
        // much longer than the time between packets means a glitch in the
        // sensor's clock: the revolutions still count, but the rate stays.
        let seconds = Double(eventTime &- last.eventTime) / 1024
        let rate = Double(count) / seconds
        if seconds <= elapsed + 2, rate <= maxRate {
            currentRate = rate
            lastInterval = Interval(revolutions: count, seconds: seconds)
        }
        return Update(outcome: .counted, revolutions: count)
    }

    /// Revolutions per second, or 0 when nothing new has arrived for `staleAfter`.
    public func rate(at now: Date) -> Double {
        guard let lastRevolutionAt, now.timeIntervalSince(lastRevolutionAt) <= staleAfter else { return 0 }
        return currentRate
    }

    /// Forgets the last reading, so the next one is a fresh baseline and adds nothing.
    public mutating func reset() {
        last = nil
        lastRevolutionAt = nil
        lastInterval = nil
        currentRate = 0
    }
}
