import SwiftUI

/// The strip above the numbers: is each Bluetooth link up (heart rate, speed,
/// cadence), and is GPS in use.
struct StatusStrip: View {
    let ride: RideController
    let now: Date

    var body: some View {
        HStack(spacing: 14) {
            StatusDot(label: "HR", color: heartRateColor)
            StatusDot(label: "SPEED", color: sensorColor(.speed))
            StatusDot(label: "CADENCE", color: sensorColor(.cadence))
            Spacer(minLength: 0)
            switch ride.speedSource {
            case .gpsFallback: Badge(text: "GPS FALLBACK", fill: Theme.warning, ink: .black)
            case .gps: Badge(text: "GPS", fill: Color(white: 0.22), ink: .white)
            case .sensor: EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    /// Green with a reading, orange while it looks or waits, grey when Bluetooth is unavailable.
    private var heartRateColor: Color {
        if ride.heartRate.bpm(at: now) != nil { return Theme.ok }
        switch ride.heartRate.state {
        case .bluetoothOff, .notAllowed, .unsupported: return Theme.dim
        default: return Theme.warning
        }
    }

    /// Green when connected, orange while waiting for it to wake up, grey when
    /// none is paired or Bluetooth is unavailable.
    private func sensorColor(_ role: CyclingSensorService.Role) -> Color {
        guard ride.sensors.bluetooth == .on, let link = ride.sensors.link(role) else { return Theme.dim }
        return link == .connected ? Theme.ok : Theme.warning
    }
}

private struct StatusDot: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .font(Theme.tileLabel)
                .foregroundStyle(color == Theme.dim ? Theme.dim : Color.white)
        }
    }
}

private struct Badge: View {
    let text: String
    let fill: Color
    let ink: Color

    var body: some View {
        Text(text)
            .font(Theme.tileLabel)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(fill, in: Capsule())
            .foregroundStyle(ink)
    }
}
