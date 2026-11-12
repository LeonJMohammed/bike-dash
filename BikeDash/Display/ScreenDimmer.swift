import BikeDashCore
import UIKit

/// Dims the screen during a ride after 10 seconds without a touch, to the level
/// set in Settings, and puts the brightness back on any touch (or lap, reminder
/// or heart rate zone change), when the ride ends, or when Bike Dash leaves the
/// front.
@MainActor
final class ScreenDimmer {
    static let enabledKey = "dimDuringRides"
    static let levelKey = "dimBrightness"

    private var schedule = ScreenDimming(now: Date())
    /// The brightness to go back to, while dimmed.
    private var savedBrightness: CGFloat?

    /// The screen Bike Dash is on.
    static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var level: Double {
        UserDefaults.standard.object(forKey: levelKey) as? Double ?? ScreenDimming.defaultLevel
    }

    /// Brighten now, and dim again 10 seconds from now.
    func wake(at now: Date) {
        schedule.wake(at: now)
        restore()
    }

    /// Once a second during a ride.
    func update(at now: Date, rideActive: Bool, appActive: Bool) {
        if schedule.shouldDim(at: now, enabled: Self.isEnabled, rideActive: rideActive, appActive: appActive) {
            dim()
        } else {
            restore()
        }
    }

    /// Back to the brightness from before dimming, if dimmed.
    func restore() {
        guard let saved = savedBrightness else { return }
        savedBrightness = nil
        Self.screen?.brightness = saved
    }

    private func dim() {
        guard !DemoMode.isOn, let screen = Self.screen else { return }
        let current = savedBrightness ?? screen.brightness
        guard let target = ScreenDimming.target(current: Double(current), level: Self.level) else { return }
        if savedBrightness == nil { savedBrightness = current }
        if abs(screen.brightness - CGFloat(target)) > 0.001 {
            screen.brightness = CGFloat(target)
        }
    }
}
