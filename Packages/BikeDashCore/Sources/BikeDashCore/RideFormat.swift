import Foundation

/// How ride numbers are written on screen (km/h and km).
public enum RideFormat {
    /// "0:42", "12:05", "1:02:03".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Bike-computer clock: "00:42", "12:05", then "1:02:03" from an hour.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// Minutes and seconds per km, "02:24"; "00:00" until there's a pace.
    public static func pace(_ secondsPerKm: TimeInterval?) -> String {
        guard let secondsPerKm, secondsPerKm.isFinite, secondsPerKm > 0 else { return "00:00" }
        let total = min(Int(secondsPerKm.rounded()), 99 * 60 + 59)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Whole metres, "86".
    public static func metres(_ metres: Double) -> String {
        String(Int(metres.rounded()))
    }

    /// km/h with one decimal, from m/s.
    public static func speed(_ metresPerSecond: Double) -> String {
        String(format: "%.1f", metresPerSecond * 3.6)
    }

    /// km with two decimals, from metres.
    public static func distance(_ metres: Double) -> String {
        String(format: "%.2f", metres / 1000)
    }

    /// Whole revolutions per minute, "88".
    public static func cadence(_ rpm: Double) -> String {
        String(Int(rpm.rounded()))
    }
}
