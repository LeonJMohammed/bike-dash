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
        /// A new lap every this many metres of riding; nil for no auto laps.
        public var autoLapDistance: Double?

        public init(
            autoPause: Bool = true,
            pauseBelow: Double = 1.0,
            pauseAfter: TimeInterval = 4,
            resumeAbove: Double = 1.8,
            resumeAfter: TimeInterval = 2,
            autoLapDistance: Double? = nil
        ) {
            self.autoPause = autoPause
            self.pauseBelow = pauseBelow
            self.pauseAfter = pauseAfter
            self.resumeAbove = resumeAbove
            self.resumeAfter = resumeAfter
            self.autoLapDistance = autoLapDistance
        }

        /// GPS speed wobbles, so it waits a few seconds before pausing or resuming.
        public static func gps(autoPause: Bool) -> Settings {
            Settings(autoPause: autoPause)
        }

        /// The wheel sensor's speed is exact and reads 0 once the wheel has
        /// stopped (no revolution for 3 s). So it pauses as soon as it reads 0,
        /// counted from the last revolution, and resumes as soon as the wheel
        /// gives a speed again.
        public static func wheelSensor(autoPause: Bool) -> Settings {
            Settings(autoPause: autoPause, pauseBelow: 0.5, pauseAfter: 0, resumeAbove: 0.5, resumeAfter: 0)
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
        /// Optional so rides saved before laps and cadence existed still load.
        public var laps: [Lap]?
        public var lapStart: LapStart?
        public var cadenceTotal: Double?
        public var cadenceSamples: Int?
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
    /// Finished laps, oldest first.
    public private(set) var laps: [Lap] = []

    private var movingBefore: TimeInterval = 0
    private var altitude = AscentCounter()
    private var ridingSince: Date?
    private var heartRateTotal: Double = 0
    private var heartRateSamples = 0
    private var cadenceTotal: Double = 0
    private var cadenceSamples = 0
    private var lapStart = LapStart()
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
        laps = snapshot.laps ?? []
        lapStart = snapshot.lapStart ?? LapStart()
        cadenceTotal = snapshot.cadenceTotal ?? 0
        cadenceSamples = snapshot.cadenceSamples ?? 0
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
            ascent: ascent,
            laps: laps,
            lapStart: lapStart,
            cadenceTotal: cadenceTotal,
            cadenceSamples: cadenceSamples
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
        // The stretch since the last lap is the final lap.
        closeLap(at: time, trigger: .finish)
        state = .finished
        finishedAt = time
    }

    /// The LAP button: ends the lap under way. Returns it, or nil when there's
    /// nothing to it yet (no ride, or no time or distance since the last lap).
    @discardableResult
    public mutating func lap(at time: Date) -> Lap? {
        guard isActive else { return nil }
        return closeLap(at: time, trigger: .manual)
    }

    /// Back to idle for the next ride.
    public mutating func reset() {
        self = RideSession(settings: settings, gps: track.settings)
    }

    // MARK: - Inputs

    /// Every GPS fix, ridden or not, while GPS is the speed source: it also
    /// keeps the speed fresh before the start and drives auto-pause and auto-resume.
    public mutating func add(_ fix: GPSFix) {
        let before = track.distance
        guard track.add(fix) else { return }
        addMovement(distance: track.distance - before, speed: track.speed(at: fix.time), at: fix.time)
    }

    /// Distance and speed from whichever source is in use (the wheel sensor
    /// sends one per packet and one a second). `stillSince` is when the wheel
    /// last turned: once the speed reads 0, an auto-pause counts from then.
    public mutating func addMovement(distance delta: Double, speed: Double?, at time: Date, stillSince: Date? = nil) {
        switch state {
        case .riding:
            distance += delta
            if let speed { maxSpeed = max(maxSpeed, speed) }
            checkAutoPause(speed: speed, at: time, stillSince: stillSince)
        case .paused(.auto):
            checkAutoResume(speed: speed, delta: delta, at: time)
        default:
            break
        }
        if state == .riding { checkAutoLap(at: time) }
    }

    /// GPS takes over from the wheel sensor (or the other way round): the next
    /// fix starts a new GPS segment, so the gap isn't counted twice.
    public mutating func breakGPSTrack() {
        track.breakSegment()
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

    /// One cadence sample (the app sends one a second). Counts only while
    /// riding and pedalling, so coasting doesn't pull the average down.
    public mutating func addCadence(_ rpm: Double) {
        guard state == .riding, rpm > 0 else { return }
        cadenceTotal += rpm
        cadenceSamples += 1
    }

    // MARK: - Readings

    public func movingTime(at now: Date) -> TimeInterval {
        movingBefore + (ridingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    public func elapsedTime(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    /// Smoothed GPS speed in m/s, or nil without a fresh fix.
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

    /// Ends the lap once it's as long as the auto-lap distance (measured from
    /// the last lap, auto or manual).
    private mutating func checkAutoLap(at time: Date) {
        guard let lapLength = settings.autoLapDistance, lapLength > 0,
              distance - lapStart.distance >= lapLength else { return }
        closeLap(at: time, trigger: .auto)
    }

    /// Adds the lap under way to `laps` and starts the next one, unless it has
    /// no time or distance yet.
    @discardableResult
    private mutating func closeLap(at time: Date, trigger: Lap.Trigger) -> Lap? {
        let moving = movingTime(at: time)
        let lapDistance = distance - lapStart.distance
        let lapTime = moving - lapStart.movingTime
        guard lapDistance >= 1 || lapTime >= 1 else { return nil }
        let lap = Lap(
            number: laps.count + 1,
            trigger: trigger,
            endedAt: time,
            distance: lapDistance,
            movingTime: lapTime,
            averageHeartRate: Self.average(heartRateTotal - lapStart.heartRateTotal, heartRateSamples - lapStart.heartRateSamples),
            averageCadence: Self.average(cadenceTotal - lapStart.cadenceTotal, cadenceSamples - lapStart.cadenceSamples)
        )
        laps.append(lap)
        lapStart = LapStart(
            distance: distance,
            movingTime: moving,
            heartRateTotal: heartRateTotal,
            heartRateSamples: heartRateSamples,
            cadenceTotal: cadenceTotal,
            cadenceSamples: cadenceSamples
        )
        return lap
    }

    private static func average(_ total: Double, _ samples: Int) -> Int? {
        samples > 0 ? Int((total / Double(samples)).rounded()) : nil
    }

    private mutating func checkAutoPause(speed: Double?, at time: Date, stillSince: Date?) {
        guard settings.autoPause, let speed else { return }
        guard speed < settings.pauseBelow else {
            slowSince = nil
            return
        }
        let since = slowSince ?? min(stillSince ?? time, time)
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
