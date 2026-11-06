import BikeDashCore
import SwiftUI

/// Step 1 test screen: the live heart rate from the watch's broadcast.
struct HeartRateScreen: View {
    let heartRate: HeartRateService

    var body: some View {
        // Redraw once a second so a stale reading turns into "--".
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let bpm = heartRate.bpm(at: context.date)
            VStack(spacing: 14) {
                Text(bpm.map { "\($0)" } ?? "--")
                    .font(.system(size: 160, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(bpm == nil ? Color.gray : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("bpm")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.gray)
                Label(statusText(bpm: bpm), systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(bpm == nil ? Color.orange : Color.green)
                if let name = heartRate.deviceName {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(Color.white)
                }
                Text(detailText(at: context.date))
                    .font(.footnote.monospaced())
                    .foregroundStyle(Color.gray)
                if heartRate.deviceName != nil {
                    Button("Forget watch", role: .destructive) { heartRate.forgetWatch() }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                }
            }
            .padding()
        }
    }

    private func statusText(bpm: Int?) -> String {
        switch heartRate.state {
        case .starting: return "Starting Bluetooth"
        case .bluetoothOff: return "Bluetooth is off"
        case .notAllowed: return "Allow Bluetooth in Settings > Bike Dash"
        case .unsupported: return "This phone has no Bluetooth LE"
        case .searching: return "Looking for a heart rate broadcast"
        case .waiting: return "Waiting for the watch"
        case .connected: return bpm == nil ? "Connected, no heart rate yet" : "Live"
        }
    }

    private func detailText(at now: Date) -> String {
        var parts = ["\(heartRate.packetCount) packets"]
        if let at = heartRate.latestAt {
            parts.append("last \(Int(now.timeIntervalSince(at)))s ago")
        }
        if heartRate.latest?.sensorContact == HeartRateMeasurement.SensorContact.notDetected {
            parts.append("no skin contact")
        }
        return parts.joined(separator: " · ")
    }
}
