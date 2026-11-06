import SwiftUI

/// Step 2 test panel: GPS speed and distance, with Start/Stop for test rides.
struct GPSPanel: View {
    let location: LocationService

    var body: some View {
        // Redraw once a second so a lost signal turns the speed into "--".
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let speed = location.isTracking ? location.track.speed(at: context.date) : nil
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(speed.map { String(format: "%.1f", $0 * 3.6) } ?? "--")
                        .font(.system(size: 110, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(speed == nil ? Color.gray : Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("km/h")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.gray)
                }
                Text(String(format: "%.2f km", location.track.distance / 1000))
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white)
                Label(statusText(speed: speed), systemImage: "location.fill")
                    .font(.headline)
                    .foregroundStyle(statusColor(speed: speed))
                if location.droppedCount > 0 {
                    Text("\(location.droppedCount) inaccurate fixes ignored")
                        .font(.footnote.monospaced())
                        .foregroundStyle(Color.gray)
                }
                HStack(spacing: 12) {
                    Button(location.isTracking ? "Stop GPS" : "Start GPS") {
                        if location.isTracking { location.stop() } else { location.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Reset distance") { location.resetDistance() }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
        }
    }

    private func statusText(speed: Double?) -> String {
        if location.permission == .denied { return "Allow location in Settings > Bike Dash" }
        if !location.isTracking { return "GPS off" }
        if location.lastFixAt == nil { return "Waiting for GPS" }
        if speed == nil { return "No GPS signal" }
        if let accuracy = location.accuracy, accuracy >= 0 { return "GPS ±\(Int(accuracy.rounded())) m" }
        return "GPS on"
    }

    private func statusColor(speed: Double?) -> Color {
        if !location.isTracking { return Color.gray }
        return speed == nil ? Color.orange : Color.green
    }
}
