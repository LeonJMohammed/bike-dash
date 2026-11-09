import BikeDashCore
import SwiftUI

/// The main bike-computer page: a status strip, then Distance | Time, Speed,
/// Cadence | Heart rate, Ascent | Avg pace.
struct MetricsPage: View {
    let ride: RideController

    var body: some View {
        // Redraw once a second for the clock and stale readings.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let session = ride.session
            let speed = ride.speed(at: now)
            let cadence = ride.sensors.cadence(at: now)
            let bpm = ride.heartRate.bpm(at: now)
            VStack(spacing: 0) {
                StatusStrip(ride: ride, now: now)
                HorizontalRule()
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
                            MetricTile(
                                label: cadenceLabel(cadence),
                                value: cadence.map { RideFormat.cadence($0) } ?? "--",
                                size: row * 0.56,
                                labelColor: cadence == nil ? Theme.warning : Color.white
                            )
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
                        HStack(spacing: 0) {
                            MetricTile(label: "ASCENT", value: RideFormat.metres(session.ascent), size: row * 0.56)
                            VerticalRule()
                            MetricTile(label: "AVG PACE", value: RideFormat.pace(session.averagePace(at: now)), size: row * 0.56)
                        }
                        .frame(height: row)
                    }
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
        if ride.speedSource == .sensor {
            guard speed == nil else { return "SPEED" }
            return "SPEED · " + sensorProblem(.speed, waiting: "WAITING FOR SENSOR")
        }
        let location = ride.location
        if location.permission == .denied { return "SPEED · ALLOW LOCATION" }
        if speed == nil { return location.isTracking ? "SPEED · NO GPS" : "SPEED · GPS OFF" }
        return "SPEED"
    }

    private func cadenceLabel(_ cadence: Double?) -> String {
        guard cadence == nil else { return "CADENCE" }
        return "CADENCE · " + sensorProblem(.cadence, waiting: "WAITING")
    }

    /// Why a sensor reading is missing, in a few words.
    private func sensorProblem(_ role: CyclingSensorService.Role, waiting: String) -> String {
        let sensors = ride.sensors
        if sensors.paired[role] == nil { return "NOT PAIRED" }
        switch sensors.bluetooth {
        case .off: return "BLUETOOTH OFF"
        case .notAllowed: return "ALLOW BLUETOOTH"
        default: return waiting
        }
    }
}
