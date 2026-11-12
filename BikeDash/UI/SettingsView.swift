import BikeDashCore
import SwiftUI

struct SettingsView: View {
    enum Page: String, Hashable {
        case sensors, sensorData
    }

    let ride: RideController
    let spotify: SpotifyController
    @Environment(\.dismiss) private var dismiss
    /// `-page sensors|sensorData` opens one at launch (simulator screenshots).
    @State private var path: [Page] = UserDefaults.standard.string(forKey: "page")
        .flatMap(Page.init(rawValue:)).map { [$0] } ?? []
    @State private var wheelText = ""
    @FocusState private var editingWheel: Bool
    @AppStorage(Theme.rideThemeKey) private var rideTheme = RideTheme.default.rawValue
    @AppStorage(Theme.albumColourKey) private var albumColour = false
    @AppStorage(ScreenDimmer.enabledKey) private var dimEnabled = true
    @AppStorage(ScreenDimmer.levelKey) private var dimLevel = ScreenDimming.defaultLevel
    /// While the dimming slider moves, the screen shows that level; this is
    /// the brightness to go back to.
    @State private var brightnessBeforePreview: CGFloat?

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    Picker("Ride theme", selection: Binding(
                        get: { RideTheme(stored: rideTheme) },
                        set: { rideTheme = $0.rawValue }
                    )) {
                        ForEach(RideTheme.allCases, id: \.self) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    if RideTheme(stored: rideTheme) == .oledBlack {
                        Toggle("Album colour behind the music", isOn: $albumColour)
                    }
                    Toggle("Dim during rides", isOn: $dimEnabled)
                    if dimEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Dimmed brightness", value: "\(Int((dimLevel * 100).rounded()))%")
                            Slider(value: $dimLevel, in: ScreenDimming.levelRange, step: 0.05) { editing in
                                previewDimming(editing)
                            }
                        }
                    }
                } header: {
                    Text("Display")
                } footer: {
                    Text("OLED black keeps the ride screen pure black, with outlines instead of filled buttons. During a ride the screen dims after 10 seconds without a touch, and any touch brightens it again. Drag the slider to see the level.")
                }

                Section {
                    Toggle("Auto-pause", isOn: Binding(
                        get: { ride.autoPause },
                        set: { ride.setAutoPause($0) }
                    ))
                } header: {
                    Text("Ride")
                } footer: {
                    Text("With the speed sensor it pauses when the wheel stops and resumes when it turns. With GPS it pauses below 3.6 km/h and resumes above 6.5 km/h.")
                }

                Section {
                    Picker("Speed from", selection: Binding(
                        get: { ride.speedPreference },
                        set: { ride.setSpeedPreference($0) }
                    )) {
                        Text("Sensor").tag(SpeedSourcePicker.Preference.sensor)
                        Text("GPS").tag(SpeedSourcePicker.Preference.gps)
                    }
                    LabeledContent("Wheel circumference") {
                        HStack(spacing: 4) {
                            TextField("2105", text: $wheelText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .focused($editingWheel)
                                .frame(width: 64)
                            Text("mm")
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    Menu("Common wheel sizes") {
                        ForEach(CyclingSensorService.commonWheels) { wheel in
                            Button("\(wheel.name) · \(wheel.millimetres) mm") {
                                setWheel(wheel.millimetres)
                            }
                        }
                    }
                } header: {
                    Text("Speed and distance")
                } footer: {
                    Text("With Sensor, GPS stays off. It only takes over if the speed sensor is disconnected for 10 s during a ride, and GPS FALLBACK shows at the top. For exact distance, measure one turn of the front wheel in mm.")
                }

                Section {
                    sensorRow(.speed)
                    sensorRow(.cadence)
                    NavigationLink("Pair sensors", value: Page.sensors)
                    NavigationLink("Sensor data", value: Page.sensorData)
                } header: {
                    Text("Sensors")
                } footer: {
                    Text("Paired sensors connect by themselves when they wake up: spin the wheel or turn the crank.")
                }

                Section("Heart rate") {
                    LabeledContent("Watch", value: ride.heartRate.deviceName ?? "None yet")
                    LabeledContent("Status", value: ride.heartRate.statusText)
                    if ride.heartRate.deviceName != nil {
                        Button("Forget watch", role: .destructive) {
                            ride.heartRate.forgetWatch()
                        }
                    }
                }

                Section {
                    LabeledContent("Status", value: spotifyStatus)
                    if spotify.status == .connected {
                        Button("Disconnect") { spotify.disconnect() }
                    } else if spotify.isConfigured {
                        Button("Connect Spotify") { spotify.connectViaSpotifyApp() }
                    }
                } header: {
                    Text("Spotify")
                } footer: {
                    Text("Connecting opens Spotify, starts your music and comes back here.")
                }

                Section {
                    LabeledContent("Version", value: AppInfo.summary)
                    LabeledContent("Signed until", value: SigningInfo.expiryText)
                } header: {
                    Text("App")
                } footer: {
                    Text("Free signing lasts 7 days; the Mac renews it.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .sensors: SensorsView(sensors: ride.sensors)
                case .sensorData: SensorDataView(ride: ride)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editingWheel = false }
                }
            }
            .onAppear { wheelText = String(ride.sensors.circumference) }
            .onChange(of: editingWheel) { _, editing in
                if !editing { setWheel(Int(wheelText) ?? 0) }
            }
            .onChange(of: dimLevel) { _, level in
                if brightnessBeforePreview != nil { ScreenDimmer.screen?.brightness = CGFloat(level) }
            }
            .onDisappear { previewDimming(false) }
        }
    }

    private func sensorRow(_ role: CyclingSensorService.Role) -> some View {
        LabeledContent(role.title) {
            VStack(alignment: .trailing, spacing: 2) {
                if let name = ride.sensors.paired[role]?.name {
                    Text(name)
                }
                Text(ride.sensors.statusText(role))
                    .font(.footnote)
                    .foregroundStyle(ride.sensors.isConnected(role) ? Theme.ok : Theme.dim)
            }
        }
    }

    /// Shows the dimmed level while the slider is held, then puts the brightness back.
    private func previewDimming(_ editing: Bool) {
        guard let screen = ScreenDimmer.screen else { return }
        if editing {
            if brightnessBeforePreview == nil { brightnessBeforePreview = screen.brightness }
            screen.brightness = CGFloat(dimLevel)
        } else if let before = brightnessBeforePreview {
            screen.brightness = before
            brightnessBeforePreview = nil
        }
    }

    /// Keeps a size in range (1000 to 3000 mm); anything else puts the old one back.
    private func setWheel(_ millimetres: Int) {
        ride.sensors.setCircumference(millimetres)
        wheelText = String(ride.sensors.circumference)
    }

    private var spotifyStatus: String {
        switch spotify.status {
        case .notConfigured: return "Not set up"
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        }
    }
}
