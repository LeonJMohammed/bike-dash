import Foundation

/// What the Live Activity shows (lock screen and Dynamic Island). Plain data,
/// so the app and its widget extension share it and it can be tested here.
public struct RideActivityState: Codable, Hashable, Sendable {
    /// m/s; nil without a reading.
    public var speed: Double?
    public var heartRate: Int?
    public var cadence: Int?
    /// Metres.
    public var distance: Double
    /// Moving time when this was made.
    public var movingTime: TimeInterval
    /// While riding: when the moving time would have been 0, so the clock can
    /// count up on its own between updates. Nil while paused.
    public var clockStart: Date?
    public var paused: Bool

    public init(
        speed: Double?,
        heartRate: Int?,
        cadence: Int?,
        distance: Double,
        movingTime: TimeInterval,
        clockStart: Date?,
        paused: Bool
    ) {
        self.speed = speed
        self.heartRate = heartRate
        self.cadence = cadence
        self.distance = distance
        self.movingTime = movingTime
        self.clockStart = clockStart
        self.paused = paused
    }

    /// The ride's numbers at `now`.
    public init(session: RideSession, speed: Double?, heartRate: Int?, cadence: Double?, at now: Date) {
        let moving = session.movingTime(at: now)
        self.init(
            speed: speed,
            heartRate: heartRate,
            cadence: cadence.map { Int($0.rounded()) },
            distance: session.distance,
            movingTime: moving,
            clockStart: session.state == .riding ? now.addingTimeInterval(-moving) : nil,
            paused: session.isPaused
        )
    }

    public var speedText: String { speed.map { RideFormat.speed($0) } ?? "--" }
    public var heartRateText: String { heartRate.map(String.init) ?? "--" }
    public var cadenceText: String { cadence.map(String.init) ?? "--" }
    public var distanceText: String { RideFormat.distance(distance) }
    public var movingTimeText: String { RideFormat.clock(movingTime) }

    /// Whether the two would look different on screen.
    func looksDifferent(from other: RideActivityState) -> Bool {
        speedText != other.speedText || heartRateText != other.heartRateText
            || cadenceText != other.cadenceText || distanceText != other.distanceText
            || paused != other.paused
    }
}

/// Keeps Live Activity updates within the system's budget: at most one every
/// `minInterval` seconds, and none when nothing on screen would change. A pause
/// or resume goes out at once. (The ride clock counts up on its own.)
public struct LiveActivityThrottle: Sendable {
    public let minInterval: TimeInterval
    private var lastSent: RideActivityState?
    private var lastSentAt: Date?

    public init(minInterval: TimeInterval = 5) {
        self.minInterval = minInterval
    }

    /// True when `state` should be sent now; it then counts as sent.
    public mutating func shouldSend(_ state: RideActivityState, at now: Date) -> Bool {
        let send: Bool
        if let lastSent, let lastSentAt {
            if state.paused != lastSent.paused {
                send = true
            } else {
                send = now.timeIntervalSince(lastSentAt) >= minInterval && state.looksDifferent(from: lastSent)
            }
        } else {
            send = true
        }
        if send {
            lastSent = state
            lastSentAt = now
        }
        return send
    }

    /// A new Live Activity: the next state goes out at once.
    public mutating func reset() {
        lastSent = nil
        lastSentAt = nil
    }
}
