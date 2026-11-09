import BikeDashCore
import SwiftUI

/// Pairing: what's paired for speed and cadence, and the sensors nearby with
/// what each one sends (read from its data, not its name).
struct SensorsView: View {
    let sensors: CyclingSensorService

    var body: some View {
        Form {
            Section("Paired") {
                ForEach(CyclingSensorService.Role.allCases) { role in
                    pairedRow(role)
                }
            }

            Section {
                if nearby.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for sensors. Spin the wheel or turn the crank to wake one up.")
                            .foregroundStyle(Theme.dim)
                    }
                }
                ForEach(nearby) { device in
                    nearbyRow(device)
                }
            } header: {
                Text("Nearby")
            } footer: {
                Text("A sensor takes one Bluetooth connection at a time, so close other apps that use it (such as Cadence), or Bike Dash can't connect. The Garmin uses ANT+, so it isn't affected.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Pair sensors")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sensors.startScan() }
        .onDisappear { sensors.stopScan() }
    }

    /// Unpaired sensors the scan found, in a steady order.
    private var nearby: [CyclingSensorService.Device] {
        sensors.devices.values
            .filter { !sensors.isPaired($0.id) }
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
    }

    private func pairedRow(_ role: CyclingSensorService.Role) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(role.title)
                    .font(.headline)
                if let name = sensors.paired[role]?.name {
                    Text(name)
                }
                Text(sensors.statusText(role))
                    .font(.footnote)
                    .foregroundStyle(sensors.isConnected(role) ? Theme.ok : Theme.dim)
                if let warning = mismatch(role) {
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                }
            }
            Spacer()
            if sensors.paired[role] != nil {
                Button("Forget", role: .destructive) { sensors.forget(role) }
                    .buttonStyle(.borderless)
            }
        }
    }

    /// A paired sensor whose data says it's set to the other mode.
    private func mismatch(_ role: CyclingSensorService.Role) -> String? {
        guard let kind = sensors.device(role)?.kind else { return nil }
        switch role {
        case .speed where !kind.sendsWheel:
            return "It sends cadence, not speed. Switch it to speed mode, or pair another."
        case .cadence where !kind.sendsCrank:
            return "It sends speed, not cadence. Switch it to cadence mode, or pair another."
        default:
            return nil
        }
    }

    private func nearbyRow(_ device: CyclingSensorService.Device) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                Text(detail(device))
                    .font(.footnote)
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            if let kind = device.kind {
                Button(useTitle(kind)) { sensors.use(device.id) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.red)
            }
        }
    }

    private func detail(_ device: CyclingSensorService.Device) -> String {
        var parts: [String] = []
        switch (device.kind, device.link) {
        case (let kind?, _): parts.append(Self.kindName(kind))
        case (nil, .connected): parts.append("Spin the wheel or turn the crank to see what it sends")
        case (nil, _): parts.append("Connecting")
        }
        if let rssi = device.rssi { parts.append("\(rssi) dBm") }
        return parts.joined(separator: " · ")
    }

    private func useTitle(_ kind: CSCSensorKind) -> String {
        switch kind {
        case .speed: return "Use for speed"
        case .cadence: return "Use for cadence"
        case .speedAndCadence: return "Use for both"
        }
    }

    static func kindName(_ kind: CSCSensorKind) -> String {
        switch kind {
        case .speed: return "Sends speed"
        case .cadence: return "Sends cadence"
        case .speedAndCadence: return "Sends speed and cadence"
        }
    }
}
