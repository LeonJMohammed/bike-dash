import BikeDashCore
import SwiftUI

/// A finished ride's numbers, in the same tile style as the ride screen.
struct RideSummaryView: View {
    let record: RideRecord
    /// Set right after a ride: a DONE button that clears it for the next one.
    var onDone: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(Theme.label)
                .foregroundStyle(Color.white)
                .padding(.vertical, 14)
            HorizontalRule()
            pair("DISTANCE", RideFormat.distance(record.distance), "MOVING TIME", RideFormat.clock(record.movingTime))
            HorizontalRule()
            pair(
                "AVG SPEED", record.averageSpeed.map { RideFormat.speed($0) } ?? "--",
                "MAX SPEED", RideFormat.speed(record.maxSpeed)
            )
            HorizontalRule()
            pair("ASCENT", RideFormat.metres(record.ascent), "AVG PACE", RideFormat.pace(record.averagePace))
            HorizontalRule()
            pair(
                "AVG HR", record.averageHeartRate.map { "\($0)" } ?? "--",
                "MAX HR", record.maxHeartRate.map { "\($0)" } ?? "--"
            )
            HorizontalRule()
            Text("Elapsed \(RideFormat.clock(record.elapsedTime)) · Garmin has the full record")
                .font(.footnote)
                .foregroundStyle(Theme.dim)
                .padding(.vertical, 12)
            Spacer(minLength: 0)
            if let onDone {
                Button(action: onDone) {
                    Text("DONE")
                        .font(Theme.buttonTitle)
                        .frame(maxWidth: .infinity, minHeight: 76)
                        .background(Theme.red)
                        .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.black)
    }

    private var title: String {
        if onDone != nil { return "RIDE FINISHED" }
        return record.startedAt
            .formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
            .uppercased()
    }

    private func pair(_ leftLabel: String, _ leftValue: String, _ rightLabel: String, _ rightValue: String) -> some View {
        HStack(spacing: 0) {
            MetricTile(label: leftLabel, value: leftValue, size: 54)
            VerticalRule()
            MetricTile(label: rightLabel, value: rightValue, size: 54)
        }
        .frame(height: 110)
    }
}
