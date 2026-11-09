import BikeDashCore
import SwiftUI

/// Raw sensor values, to check on a real ride: the counts and event times each
/// sensor sends, and what Bike Dash makes of them.
struct SensorDataView: View {
    let ride: RideController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let now = context.date
            List {
                sensorSection(.speed, now: now)
                sensorSection(.cadence, now: now)
                rideSection(now: now)
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .font(.callout.monospacedDigit())
        }
        .navigationTitle("Sensor data")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func sensorSection(_ role: CyclingSensorService.Role, now: Date) -> some View {
        let sensors = ride.sensors
        let counter = role == .speed ? sensors.wheel : sensors.crank
        let latest = sensors.device(role)?.latest
        Section(role == .speed ? "Speed sensor" : "Cadence sensor") {
            row("Sensor", sensors.paired[role]?.name ?? "Not paired")
            row("Link", sensors.statusText(role))
            row("Packets", packets(role, now: now))
            row("Flags", latest.map { flags($0.flags) } ?? "-")
            if role == .speed {
                row("Wheel revolutions", latest?.wheel.map { "\($0.revolutions)" } ?? "-")
                row("Wheel event time", latest?.wheel.map { eventTime($0.eventTime) } ?? "-")
            } else {
                row("Crank revolutions", latest?.crank.map { "\($0.revolutions)" } ?? "-")
                row("Crank event time", latest?.crank.map { eventTime($0.eventTime) } ?? "-")
            }
            row("Last interval", counter.lastInterval.map {
                String(format: "%d rev in %.3f s", $0.revolutions, $0.seconds)
            } ?? "-")
            row("Last new revolution", counter.lastRevolutionAt.map { ago($0, now: now) } ?? "-")
            if role == .speed {
                row("Speed", sensors.speed(at: now).map { RideFormat.speed($0) + " km/h" } ?? "-")
                row("Wheel circumference", "\(sensors.circumference) mm")
            } else {
                row("Cadence", sensors.cadence(at: now).map { RideFormat.cadence($0) + " rpm" } ?? "-")
            }
            row("Repeats ignored", "\(counter.duplicates)")
            row("Jumps rejected", "\(counter.rejections)")
        }
    }

    private func rideSection(now: Date) -> some View {
        Section("Ride") {
            row("Speed from", source)
            if let wait = ride.picker.secondsUntilFallback(at: now) {
                row("GPS takes over in", String(format: "%.0f s", wait.rounded(.up)))
            }
            row("GPS", gps(now: now))
            row("Distance", RideFormat.distance(ride.session.distance) + " km")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }

    private var source: String {
        switch ride.speedSource {
        case .sensor: return "Speed sensor"
        case .gps: return "GPS"
        case .gpsFallback: return "GPS fallback"
        }
    }

    private func packets(_ role: CyclingSensorService.Role, now: Date) -> String {
        guard let device = ride.sensors.device(role) else { return "-" }
        guard let last = device.lastPacketAt else { return "\(device.packets)" }
        return "\(device.packets), last \(ago(last, now: now))"
    }

    private func flags(_ value: UInt8) -> String {
        var parts: [String] = []
        if value & 0x01 != 0 { parts.append("wheel") }
        if value & 0x02 != 0 { parts.append("crank") }
        return String(format: "0x%02X", value) + (parts.isEmpty ? "" : " (\(parts.joined(separator: " + ")))")
    }

    /// The raw 1/1024 s value and what it is in seconds (it wraps every 64 s).
    private func eventTime(_ value: UInt16) -> String {
        String(format: "%d (%.3f s)", value, Double(value) / 1024)
    }

    private func ago(_ date: Date, now: Date) -> String {
        String(format: "%.1f s ago", max(0, now.timeIntervalSince(date)))
    }

    private func gps(now: Date) -> String {
        let location = ride.location
        guard location.isTracking else { return "Off" }
        guard let lastFixAt = location.lastFixAt, let accuracy = location.accuracy else { return "On, no fix yet" }
        return String(format: "On, ±%.0f m, ", accuracy) + ago(lastFixAt, now: now)
    }
}
