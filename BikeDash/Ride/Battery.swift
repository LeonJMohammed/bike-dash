import UIKit

/// The phone's battery, kept with each ride (start and end), so long rides
/// with the map show what GPS and the screen cost.
@MainActor
enum Battery {
    /// Percent, or nil when iOS doesn't say (the simulator).
    static func percent() -> Int? {
        if DemoMode.isOn { return demoLevels.isEmpty ? nil : demoLevels.removeFirst() }
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        guard level >= 0 else { return nil }
        return Int((level * 100).rounded())
    }

    /// Demo mode: the start and end of the replayed ride.
    private static var demoLevels = [92, 81]
}
