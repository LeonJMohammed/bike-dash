import SwiftUI

struct SettingsView: View {
    let ride: RideController
    let spotify: SpotifyController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Auto-pause", isOn: Binding(
                        get: { ride.autoPause },
                        set: { ride.setAutoPause($0) }
                    ))
                } header: {
                    Text("Ride")
                } footer: {
                    Text("Pauses below 3.6 km/h and resumes above 6.5 km/h.")
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
