import Foundation

/// The ride timer: idle -> riding <-> paused (auto or manual) -> finished.
///
/// Moving time and distance count only while riding. Every time comes from a
/// timestamp, never from counting timer ticks, so the numbers don't depend on
/// how often the screen redraws.
public struct RideSession: Sendable {
    public enum State: Codable, Equatable, Sendable {
        case idle
        case riding
        case paused(PauseReason)
        case finished
    }

    public enum PauseReason: String, Codable, Equatable, Sendable {
        case manual
        case auto
    }

    public struct Settings: Sendable {
        public var autoPause: Bool
        /// Auto-pause when the speed stays below this (m/s)...
        public var pauseBelow: Double
        /// ...for this long.
        public var pauseAfter: TimeInterval
        /// Auto-resume when the speed stays above this (m/s)...
        public var resumeAbove: Double
        /// ...for this long.
        public var resumeAfter: TimeInterval

        public init(
            autoPause: Bool = true,
            pauseBelow: Double = 1.0,
            pauseAfter: TimeInterval = 4,
            resumeAbove: Double = 1.8,
            resumeAfter: TimeInterval = 2
        ) {
            self.autoPause = autoPause
            self.pauseBelow = pauseBelow
            self.pauseAfter = pauseAfter
            self.resumeAbove = resumeAbove
            self.resumeAfter = resumeAfter
        }
    }

    /// What's saved to disk, so a ride survives the app being closed.
    public struct Snapshot: Codable, Equatable, Sendable {
        public var state: State
        public var startedAt: Date?
        public var finishedAt: Date?
        public var movingBefore: TimeInterval
        public var ridingSince: Date?
        public var distance: Double
        public var maxSpeed: Double
        public var heartRateTotal: Double
        public var heartRateSamples: Int
        public var maxHeartRate: Int
        /// Optional so rides saved before ascent existed still load.
        public var ascent: Double?
    }

    /// Can change mid-ride (the auto-pause switch in Settings).
    public var settings: Settings
    public private(set) var state: State = .idle
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    /// Metres ridden, not counting pauses.
    public private(set) var distance: Double = 0
    /// Fastest smoothed speed while riding, m/s.
    public private(set) var maxSpeed: Double = 0
    public private(set) var maxHeartRate = 0
    /// Metres climbed while riding.
    public private(set) var ascent: Double = 0

    private var movingBefore: TimeInterval = 0
    private var altitude = AscentCounter()
    private var ridingSince: Date?
    private var heartRateTotal: Double = 0
    private var heartRateSamples = 0
    private var track: GPSTrack
    private var slowSince: Date?
    private var fastSince: Date?
    /// Distance covered while auto-paused but already moving again; it counts
    /// once the resume is confirmed.
    private var pendingDistance: Double = 0

    public init(settings: Settings = Settings(), gps: GPSTrack.Settings = GPSTrack.Settings()) {
        self.settings = settings
        self.track = GPSTrack(settings: gps)
    }

    public init(
        restoring snapshot: Snapshot,
        settings: Settings = Settings(),
        gps: GPSTrack.Settings = GPSTrack.Settings()
    ) {
        self.init(settings: settings, gps: gps)
        state = snapshot.state
        startedAt = snapshot.startedAt
        finishedAt = snapshot.finishedAt
        movingBefore = snapshot.movingBefore
        ridingSince = snapshot.ridingSince
        distance = snapshot.distance
        maxSpeed = snapshot.maxSpeed
        heartRateTotal = snapshot.heartRateTotal
        heartRateSamples = snapshot.heartRateSamples
        maxHeartRate = snapshot.maxHeartRate
        ascent = snapshot.ascent ?? 0
    }

    public var snapshot: Snapshot {
        Snapshot(
            state: state,
            startedAt: startedAt,
            finishedAt: finishedAt,
            movingBefore: movingBefore,
            ridingSince: ridingSince,
            distance: distance,
            maxSpeed: maxSpeed,
            heartRateTotal: heartRateTotal,
            heartRateSamples: heartRateSamples,
            maxHeartRate: maxHeartRate,
            ascent: ascent
        )
    }

    public var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    /// Riding or paused: a ride is under way.
    public var isActive: Bool { state == .riding || isPaused }

    // MARK: - Controls

    public mutating func start(at time: Date) {
        guard state == .idle else { return }
        state = .riding
        startedAt = time
        ridingSince = time
    }

    /// A manual pause. Pausing during an auto-pause makes it manual, so it
    /// won't resume by itself (for example when walking the bike).
    public mutating func pause(at time: Date) {
        switch state {
        case .riding: stopRiding(at: time, reason: .manual)
        case .paused(.auto): state = .paused(.manual)
        default: break
        }
    }

    public mutating func resume(at time: Date) {
        guard isPaused else { return }
        startRiding(at: time)
    }

    public mutating func finish(at time: Date) {
        guard isActive else { return }
        if state == .riding { closeRidingInterval(at: time) }
        state = .finished
        finishedAt = time
    }

    /// Back to idle for the next ride.
    public mutating func reset() {
        self = RideSession(settings: settings, gps: track.settings)
    }

    // MARK: - Inputs

    /// Every GPS fix, ridden or not: it also keeps the speed fresh before the
    /// start and drives auto-pause and auto-resume.
    public mutating func add(_ fix: GPSFix) {
        let before = track.distance
        guard track.add(fix) else { return }
        let delta = track.distance - before
        let speed = track.speed(at: fix.time)
        switch state {
        case .riding:
            distance += delta
            if let speed { maxSpeed = max(maxSpeed, speed) }
            checkAutoPause(speed: speed, at: fix.time)
        case .paused(.auto):
            checkAutoResume(speed: speed, delta: delta, at: fix.time)
        default:
            break
        }
    }

    /// One barometer reading (relative altitude, metres). Climbing counts only while riding.
    public mutating func addAltitude(_ metres: Double) {
        let before = altitude.ascent
        altitude.add(metres)
        if state == .riding {
            ascent += altitude.ascent - before
        }
    }

    /// Call when the altimeter (re)starts: its readings start again from 0.
    public mutating func resetAltitudeReference() {
        altitude.breakSegment()
    }

    /// One heart rate sample (the app sends one a second). Counts only while riding.
    public mutating func addHeartRate(_ bpm: Int) {
        guard state == .riding, bpm > 0 else { return }
        heartRateTotal += Double(bpm)
        heartRateSamples += 1
        maxHeartRate = max(maxHeartRate, bpm)
    }

    // MARK: - Readings

    public func movingTime(at now: Date) -> TimeInterval {
        movingBefore + (ridingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    public func elapsedTime(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    /// Smoothed current speed in m/s, or nil without a fresh fix.
    public func speed(at now: Date) -> Double? {
        track.speed(at: now)
    }

    /// Average moving speed in m/s.
    public func averageSpeed(at now: Date) -> Double? {
        let moving = movingTime(at: now)
        return moving > 0 ? distance / moving : nil
    }

    /// Average pace in seconds per km, once there's some distance.
    public func averagePace(at now: Date) -> TimeInterval? {
        guard distance >= 10 else { return nil }
        return movingTime(at: now) / (distance / 1000)
    }

    public var averageHeartRate: Int? {
        heartRateSamples > 0 ? Int((heartRateTotal / Double(heartRateSamples)).rounded()) : nil
    }

    // MARK: - Private

    private mutating func checkAutoPause(speed: Double?, at time: Date) {
        guard settings.autoPause, let speed else { return }
        guard speed < settings.pauseBelow else {
            slowSince = nil
            return
        }
        let since = slowSince ?? time
        slowSince = since
        if time.timeIntervalSince(since) >= settings.pauseAfter {
            // Pause from when it first went slow, so the wait isn't moving time.
            stopRiding(at: since, reason: .auto)
        }
    }

    private mutating func checkAutoResume(speed: Double?, delta: Double, at time: Date) {
        guard let speed, speed > settings.resumeAbove else {
            fastSince = nil
            pendingDistance = 0
            return
        }
        let since = fastSince ?? time
        fastSince = since
        pendingDistance += delta
        if time.timeIntervalSince(since) >= settings.resumeAfter {
            // Resume from when it first went fast, and keep the distance since then.
            distance += pendingDistance
            startRiding(at: since)
        }
    }

    private mutating func stopRiding(at time: Date, reason: PauseReason) {
        closeRidingInterval(at: time)
        state = .paused(reason)
    }

    private mutating func startRiding(at time: Date) {
        state = .riding
        ridingSince = time
        slowSince = nil
        fastSince = nil
        pendingDistance = 0
    }

    private mutating func closeRidingInterval(at time: Date) {
        if let ridingSince {
            movingBefore += max(0, time.timeIntervalSince(ridingSince))
        }
        ridingSince = nil
        slowSince = nil
    }
}
