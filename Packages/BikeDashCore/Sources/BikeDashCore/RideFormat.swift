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

    /// km/h with one decimal, from m/s.
    public static func speed(_ metresPerSecond: Double) -> String {
        String(format: "%.1f", metresPerSecond * 3.6)
    }

    /// km with two decimals, from metres.
    public static func distance(_ metres: Double) -> String {
        String(format: "%.2f", metres / 1000)
    }
}
