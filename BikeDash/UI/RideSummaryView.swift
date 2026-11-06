import BikeDashCore
import SwiftUI

/// Shown after Hold to stop, until New ride.
struct RideSummaryView: View {
    let ride: RideController

    var body: some View {
        let session = ride.session
        let end = session.finishedAt ?? Date()
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Text("Ride finished")
                .font(.largeTitle.bold())
                .foregroundStyle(Color.white)
            VStack(spacing: 12) {
                row("Distance", RideFormat.distance(session.distance) + " km")
                row("Moving time", RideFormat.duration(session.movingTime(at: end)))
                row("Elapsed", RideFormat.duration(session.elapsedTime(at: end)))
                row("Average speed", session.averageSpeed(at: end).map { RideFormat.speed($0) + " km/h" } ?? "--")
                row("Max speed", RideFormat.speed(session.maxSpeed) + " km/h")
                row("Average heart rate", session.averageHeartRate.map { "\($0) bpm" } ?? "--")
                row("Max heart rate", session.maxHeartRate > 0 ? "\(session.maxHeartRate) bpm" : "--")
            }
            .font(.title3)
            Text("Garmin has the full record of this ride.")
                .font(.footnote)
                .foregroundStyle(Color.gray)
            Spacer(minLength: 0)
            Button {
                ride.newRide()
            } label: {
                Text("New ride")
                    .font(.title2.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Color.gray)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(Color.white)
        }
    }
}
