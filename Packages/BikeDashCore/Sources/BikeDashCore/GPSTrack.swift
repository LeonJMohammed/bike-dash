import Foundation

/// Decides which GPS fixes to trust, and keeps a smoothed speed and the
/// distance covered.
public struct GPSTrack: Sendable {
    public struct Settings: Sendable {
        /// Fixes less accurate than this (metres) are dropped.
        public var maxAccuracy: Double
        /// A fix implying a faster move than this (m/s) is a GPS jump and is dropped.
        public var maxSpeed: Double
        /// Speed is averaged over this many seconds.
        public var speedWindow: TimeInterval
        /// Below this speed (m/s), position jitter adds no distance.
        public var stationarySpeed: Double
        /// After this many jumps in a row, trust the new position: the fix we
        /// were measuring from was the outlier.
        public var jumpsBeforeReanchor: Int

        public init(
            maxAccuracy: Double = 20,
            maxSpeed: Double = 25,
            speedWindow: TimeInterval = 3,
            stationarySpeed: Double = 0.5,
            jumpsBeforeReanchor: Int = 3
        ) {
            self.maxAccuracy = maxAccuracy
            self.maxSpeed = maxSpeed
            self.speedWindow = speedWindow
            self.stationarySpeed = stationarySpeed
            self.jumpsBeforeReanchor = jumpsBeforeReanchor
        }
    }

    public let settings: Settings
    /// Metres covered since the last reset.
    public private(set) var distance: Double = 0
    public private(set) var lastFix: GPSFix?
    private var window: [GPSFix] = []
    private var jumpsInARow = 0

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Adds a fix. Returns false when it was dropped.
    @discardableResult
    public mutating func add(_ fix: GPSFix) -> Bool {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= settings.maxAccuracy else { return false }
        guard let last = lastFix else {
            accept(fix)
            return true
        }
        let seconds = fix.time.timeIntervalSince(last.time)
        guard seconds > 0 else { return false }
        let metres = last.distance(to: fix)

        if metres / seconds > settings.maxSpeed {
            jumpsInARow += 1
            guard jumpsInARow >= settings.jumpsBeforeReanchor else { return false }
            breakSegment()
            accept(fix)
            return true
        }

        let doppler = [last.speed, fix.speed].filter { $0 >= 0 }
        let segmentSpeed = doppler.max() ?? metres / seconds
        if segmentSpeed >= settings.stationarySpeed {
            distance += metres
        }
        accept(fix)
        return true
    }

    /// Smoothed speed in m/s, or nil when there's no fix newer than `staleAfter`.
    public func speed(at now: Date, staleAfter: TimeInterval = 5) -> Double? {
        guard let last = lastFix, now.timeIntervalSince(last.time) <= staleAfter else { return nil }
        let doppler = window.map(\.speed).filter { $0 >= 0 }
        if !doppler.isEmpty {
            return doppler.reduce(0, +) / Double(doppler.count)
        }
        // No Doppler speed: use distance over time across the window.
        guard let first = window.first else { return nil }
        let seconds = last.time.timeIntervalSince(first.time)
        return seconds > 0 ? first.distance(to: last) / seconds : nil
    }

    /// Starts a new segment, so the next fix adds no distance (after a pause or a stop).
    public mutating func breakSegment() {
        lastFix = nil
        window.removeAll()
        jumpsInARow = 0
    }

    public mutating func reset() {
        distance = 0
        breakSegment()
    }

    private mutating func accept(_ fix: GPSFix) {
        jumpsInARow = 0
        lastFix = fix
        window.append(fix)
        let maxAge = settings.speedWindow  // a local, so the closure doesn't touch self
        window.removeAll { fix.time.timeIntervalSince($0.time) > maxAge }
    }
}
