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
    /// The number fields share the keyboard's Done button.
    enum Field: Hashable {
        case wheel, maxHeartRate
    }

    @FocusState private var editing: Field?
    @State private var maxHeartRateText = ""
    @AppStorage(RideController.maxHeartRateKey) private var maxHeartRate = HeartRateZones.defaultMax
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
                    Picker("Auto lap", selection: Binding(
                        get: { ride.autoLapKm },
                        set: { ride.setAutoLapKm($0) }
                    )) {
                        ForEach(RideController.autoLapChoices, id: \.self) { km in
                            Text(km == 0 ? "Off" : "Every \(km) km").tag(km)
                        }
                    }
                } header: {
                    Text("Ride")
                } footer: {
                    Text("With the speed sensor it pauses when the wheel stops and resumes when it turns. With GPS it pauses below 3.6 km/h and resumes above 6.5 km/h. A lap's numbers show for 5 seconds when it ends (auto lap, or the LAP button), and every lap is listed with the ride.")
                }

                Section {
                    Toggle("Reminders", isOn: Binding(
                        get: { ride.remindersOn },
                        set: { ride.setRemindersOn($0) }
                    ))
                    if ride.remindersOn {
                        Picker("Every", selection: Binding(
                            get: { ride.reminderInterval },
                            set: { ride.setReminderInterval($0) }
                        )) {
                            ForEach(EatDrinkReminder.intervalChoices, id: \.self) { minutes in
                                Text("\(minutes) min").tag(minutes)
                            }
                        }
                    }
                } header: {
                    Text("Eating and drinking")
                } footer: {
                    Text(reminderFooter)
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
                                .focused($editing, equals: .wheel)
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

                Section {
                    LabeledContent("Watch", value: ride.heartRate.deviceName ?? "None yet")
                    LabeledContent("Status", value: ride.heartRate.statusText)
                    if ride.heartRate.deviceName != nil {
                        Button("Forget watch", role: .destructive) {
                            ride.heartRate.forgetWatch()
                        }
                    }
                    LabeledContent("Max heart rate") {
                        HStack(spacing: 4) {
                            TextField("\(HeartRateZones.defaultMax)", text: $maxHeartRateText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .focused($editing, equals: .maxHeartRate)
                                .frame(width: 52)
                            Text("bpm")
                                .foregroundStyle(Theme.dim)
                        }
                    }
                } header: {
                    Text("Heart rate")
                } footer: {
                    Text(zonesFooter)
                }

                Section {
                    LabeledContent("Status", value: spotifyStatus)
                    if spotify.canSignIn {
                        LabeledContent("Signed in", value: spotify.isSignedIn ? "Yes, stays signed in" : "No")
                    }
                    if spotify.canSignIn && !spotify.isSignedIn {
                        Button(spotify.signingIn ? "Signing in…" : "Sign in to Spotify") { spotify.signIn() }
                            .disabled(spotify.signingIn)
                    }
                    if spotify.isConfigured && spotify.status != .connected {
                        Button("Open Spotify and connect") { spotify.connectViaSpotifyApp() }
                    }
                    if spotify.isSignedIn || spotify.status == .connected {
                        Button("Sign out", role: .destructive) { spotify.disconnect() }
                    }
                    if let error = spotify.lastError, spotify.status != .connected {
                        Text(error)
                            .foregroundStyle(Theme.dim)
                    }
                } header: {
                    Text("Spotify")
                } footer: {
                    Text(spotifyFooter)
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
                    Button("Done") { editing = nil }
                }
            }
            .onAppear {
                wheelText = String(ride.sensors.circumference)
                maxHeartRateText = String(maxHeartRate)
            }
            .onChange(of: editing) { previous, _ in
                switch previous {
                case .wheel: setWheel(Int(wheelText) ?? 0)
                case .maxHeartRate: setMaxHeartRate(Int(maxHeartRateText) ?? 0)
                case nil: break
                }
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

    /// Keeps a max heart rate in range (120 to 230); anything else puts the old one back.
    private func setMaxHeartRate(_ bpm: Int) {
        if HeartRateZones.maxRange.contains(bpm) { maxHeartRate = bpm }
        maxHeartRateText = String(maxHeartRate)
    }

    private var reminderFooter: String {
        var text = "A big \"Eat / Drink\" banner with a buzz and a chime (no chime with the ringer off). It counts moving time only, so it waits while you're paused. Tap it away, or it clears after 15 seconds and counts again."
        if let minutes = ride.minutesToReminder(at: Date()) {
            text += " Next in \(minutes) min of riding."
        }
        return text
    }

    /// Where each zone starts, for the footer.
    private var zonesFooter: String {
        let zones = HeartRateZones(maxHeartRate: maxHeartRate)
        let starts = (1...HeartRateZones.count).map { String(Int(zones.lowerBound(of: $0).rounded())) }
        return "Zones start at \(starts.dropLast().joined(separator: ", ")) and \(starts.last ?? "") bpm "
            + "(50, 60, 70, 80 and 90% of max). The strip along the bottom of the ride screen lights your zone."
    }

    /// Keeps a size in range (1000 to 3000 mm); anything else puts the old one back.
    private func setWheel(_ millimetres: Int) {
        ride.sensors.setCircumference(millimetres)
        wheelText = String(ride.sensors.circumference)
    }

    private var spotifyFooter: String {
        let retry = "When Spotify doesn't answer, Bike Dash tries again after 2, 5 and 15 seconds, then every 30 seconds, "
            + "and the music bar offers Reconnect Spotify, which opens Spotify and starts the music."
        guard spotify.canSignIn else {
            return "Connecting opens Spotify, starts your music and comes back here. " + retry
        }
        return "Sign in once; the home PC then renews the sign-in, so it lasts beyond the hour. " + retry
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
