import BikeDashCore
import SwiftUI

/// A finished lap's numbers, in place of the ride numbers for about 5 seconds:
/// distance, moving time, average speed, heart rate and cadence. A tap goes
/// back to the ride numbers early.
struct LapPage: View {
    let lap: Lap
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("LAP \(lap.number)")
                    .font(Theme.barLabel)
                    .foregroundStyle(Theme.paused)
                Text(lap.trigger == .auto ? "AUTO" : "MANUAL")
                    .font(Theme.tileLabel)
                    .foregroundStyle(Theme.dim)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            HorizontalRule()
            GeometryReader { geo in
                // Rows are 1 : 2 : 1 : 1 like the ride numbers, less the three rules.
                let row = (geo.size.height - 3) / 5
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        MetricTile(label: "LAP DISTANCE", value: RideFormat.distance(lap.distance), size: row * 0.56)
                        VerticalRule()
                        MetricTile(label: "LAP TIME", value: RideFormat.clock(lap.movingTime), size: row * 0.56)
                    }
                    .frame(height: row)
                    HorizontalRule()
                    MetricTile(
                        label: "LAP AVG SPEED",
                        value: lap.averageSpeed.map { RideFormat.speed($0) } ?? "--",
                        size: row * 1.25
                    )
                    .frame(height: row * 2)
                    HorizontalRule()
                    HStack(spacing: 0) {
                        MetricTile(label: "AVG HR", value: lap.averageHeartRate.map { "\($0)" } ?? "--", size: row * 0.56)
                        VerticalRule()
                        MetricTile(label: "AVG CADENCE", value: lap.averageCadence.map { "\($0)" } ?? "--", size: row * 0.56)
                    }
                    .frame(height: row)
                    HorizontalRule()
                    Text("Back to the ride in a moment · tap to go back now")
                        .font(.footnote)
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityAction(named: "Back to the ride", onDismiss)
    }
}
