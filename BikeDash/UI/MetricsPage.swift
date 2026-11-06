import BikeDashCore
import SwiftUI

/// The main bike-computer page: Distance | Time, Speed, Ascent | Heart rate, Avg pace.
struct MetricsPage: View {
    let ride: RideController

    var body: some View {
        // Redraw once a second for the clock and stale readings.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let session = ride.session
            let speed = session.speed(at: now)
            let bpm = ride.heartRate.bpm(at: now)
            GeometryReader { geo in
                // Rows are 1 : 2 : 1 : 1, less the three 1-pt rules.
                let row = (geo.size.height - 3) / 5
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        MetricTile(label: "DISTANCE", value: RideFormat.distance(session.distance), size: row * 0.56)
                        VerticalRule()
                        MetricTile(
                            label: timeLabel(session),
                            value: RideFormat.clock(session.movingTime(at: now)),
                            size: row * 0.56,
                            labelColor: session.isPaused ? Theme.paused : Color.white
                        )
                    }
                    .frame(height: row)
                    HorizontalRule()
                    MetricTile(
                        label: speedLabel(speed),
                        value: speed.map { RideFormat.speed($0) } ?? "--",
                        size: row * 1.25,
                        labelColor: speed == nil ? Theme.warning : Color.white
                    )
                    .frame(height: row * 2)
                    HorizontalRule()
                    HStack(spacing: 0) {
                        MetricTile(label: "ASCENT", value: RideFormat.metres(session.ascent), size: row * 0.56)
                        VerticalRule()
                        MetricTile(
                            label: bpm == nil ? "HEART RATE · NO WATCH" : "HEART RATE",
                            value: bpm.map { "\($0)" } ?? "--",
                            size: row * 0.56,
                            labelColor: bpm == nil ? Theme.warning : Color.white
                        )
                    }
                    .frame(height: row)
                    HorizontalRule()
                    MetricTile(label: "AVG PACE", value: RideFormat.pace(session.averagePace(at: now)), size: row * 0.56)
                        .frame(height: row)
                }
            }
        }
    }

    private func timeLabel(_ session: RideSession) -> String {
        switch session.state {
        case .paused(.auto): return "TIME · AUTO-PAUSED"
        case .paused(.manual): return "TIME · PAUSED"
        default: return "TIME"
        }
    }

    private func speedLabel(_ speed: Double?) -> String {
        let location = ride.location
        if location.permission == .denied { return "SPEED · ALLOW LOCATION" }
        if speed == nil { return location.isTracking ? "SPEED · NO GPS" : "SPEED · GPS OFF" }
        return "SPEED"
    }
}
