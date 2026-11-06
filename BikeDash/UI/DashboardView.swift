import BikeDashCore
import SwiftUI

/// The ride screen: heart rate, speed, distance and moving time, plus controls.
struct DashboardView: View {
    let ride: RideController

    var body: some View {
        VStack(spacing: 14) {
            HeartRatePanel(heartRate: ride.heartRate)
            Divider().overlay(Color.gray.opacity(0.4))
            RideReadouts(ride: ride)
            Spacer(minLength: 0)
            RideControls(ride: ride)
            Text(AppInfo.summary)
                .font(.caption2.monospaced())
                .foregroundStyle(Color.gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Speed, distance, moving time and a status line (GPS or pause).
struct RideReadouts: View {
    let ride: RideController

    var body: some View {
        // Redraw once a second for the clock and a stale speed.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let speed = ride.session.speed(at: now)
            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(speed.map { RideFormat.speed($0) } ?? "--")
                        .font(.system(size: 110, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(speed == nil ? Color.gray : Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("km/h")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.gray)
                }
                HStack(spacing: 0) {
                    metric(RideFormat.distance(ride.session.distance), label: "km")
                    metric(RideFormat.duration(ride.session.movingTime(at: now)), label: "moving")
                }
                Label(statusText(speed: speed), systemImage: statusSymbol)
                    .font(.headline)
                    .foregroundStyle(statusColor(speed: speed))
            }
        }
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private func statusText(speed: Double?) -> String {
        switch ride.session.state {
        case .paused(.auto): return "Auto-paused"
        case .paused(.manual): return "Paused"
        default: break
        }
        let location = ride.location
        if location.permission == .denied { return "Allow location in Settings > Bike Dash" }
        if !location.isTracking { return "GPS off" }
        if location.lastFixAt == nil { return "Waiting for GPS" }
        if speed == nil { return "No GPS signal" }
        if let accuracy = location.accuracy, accuracy >= 0 { return "GPS ±\(Int(accuracy.rounded())) m" }
        return "GPS on"
    }

    private var statusSymbol: String {
        ride.session.isPaused ? "pause.circle.fill" : "location.fill"
    }

    private func statusColor(speed: Double?) -> Color {
        if ride.session.isPaused { return Color.yellow }
        if !ride.location.isTracking { return Color.gray }
        return speed == nil ? Color.orange : Color.green
    }
}

/// Start, Pause/Resume and Hold to stop.
struct RideControls: View {
    let ride: RideController

    var body: some View {
        switch ride.session.state {
        case .idle:
            bigButton("Start", color: Color.green) { ride.start() }
        case .riding:
            HStack(spacing: 12) {
                bigButton("Pause", color: Color.yellow) { ride.pause() }
                HoldToStopButton { ride.finish() }
            }
        case .paused:
            HStack(spacing: 12) {
                bigButton("Resume", color: Color.green) { ride.resume() }
                HoldToStopButton { ride.finish() }
            }
        case .finished:
            EmptyView()
        }
    }

    private func bigButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(color, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(Color.black)
        }
        .buttonStyle(.plain)
    }
}

/// Stopping needs a 1-second press, so rain or a bump can't end the ride.
struct HoldToStopButton: View {
    let action: () -> Void
    @State private var pressing = false

    var body: some View {
        Text(pressing ? "Keep holding" : "Hold to stop")
            .font(.title2.weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color.red.opacity(pressing ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(Color.white)
            .contentShape(Rectangle())
            .onLongPressGesture(
                minimumDuration: 1.0,
                maximumDistance: 40,
                perform: action,
                onPressingChanged: { pressing = $0 }
            )
    }
}
