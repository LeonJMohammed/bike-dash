import Foundation

/// Where speed and distance come from: the wheel sensor or the phone's GPS.
///
/// With the sensor preferred, GPS is only a fallback during a ride. It takes
/// over once the speed sensor has been disconnected for `fallbackAfter`, and
/// hands back once the sensor has been connected again for `recoverAfter`, so
/// a flaky connection doesn't switch GPS on and off.
public struct SpeedSourcePicker: Equatable, Sendable {
    public enum Preference: String, Codable, CaseIterable, Sendable {
        case sensor
        case gps
    }

    public enum Source: Equatable, Sendable {
        case sensor
        case gps
        /// The sensor is preferred but dropped out during the ride.
        case gpsFallback
    }

    public var preference: Preference
    public let fallbackAfter: TimeInterval
    public let recoverAfter: TimeInterval
    public private(set) var source: Source
    /// While a ride needs speed and the sensor is down: since when.
    public private(set) var sensorDownSince: Date?
    private var sensorBackSince: Date?

    public init(preference: Preference = .sensor, fallbackAfter: TimeInterval = 10, recoverAfter: TimeInterval = 5) {
        self.preference = preference
        self.fallbackAfter = fallbackAfter
        self.recoverAfter = recoverAfter
        source = preference == .gps ? .gps : .sensor
    }

    /// Call on every tick and every sensor packet. `pedalling` is true when
    /// the cadence sensor shows the cranks turning. Returns true when the
    /// source changed.
    @discardableResult
    public mutating func update(sensorConnected: Bool, ride: RideSession.State, pedalling: Bool, at now: Date) -> Bool {
        let needsSpeed: Bool
        switch ride {
        case .riding:
            needsSpeed = true
        case .paused(.auto):
            // Stopped, perhaps long enough for the sensors to fall asleep: GPS
            // is only worth starting if the pedals turn (moving again with no
            // wheel data). Once it has taken over, it stays through the stop.
            needsSpeed = pedalling || source != .sensor
        default:
            needsSpeed = false
        }

        let before = source
        if preference == .gps {
            source = .gps
            sensorDownSince = nil
            sensorBackSince = nil
        } else if !needsSpeed {
            source = .sensor
            sensorDownSince = nil
            sensorBackSince = nil
        } else if sensorConnected {
            sensorDownSince = nil
            if source == .gpsFallback {
                let since = sensorBackSince ?? now
                sensorBackSince = since
                if now.timeIntervalSince(since) >= recoverAfter {
                    source = .sensor
                    sensorBackSince = nil
                }
            } else {
                source = .sensor
            }
        } else {
            sensorBackSince = nil
            let since = sensorDownSince ?? now
            sensorDownSince = since
            // Already on GPS (the preference just changed mid-ride): stay on it.
            if source != .sensor || now.timeIntervalSince(since) >= fallbackAfter {
                source = .gpsFallback
            }
        }
        return source != before
    }

    /// Seconds until GPS takes over, while the sensor is down during a ride.
    public func secondsUntilFallback(at now: Date) -> TimeInterval? {
        guard source == .sensor, let sensorDownSince else { return nil }
        return max(0, fallbackAfter - now.timeIntervalSince(sensorDownSince))
    }
}
