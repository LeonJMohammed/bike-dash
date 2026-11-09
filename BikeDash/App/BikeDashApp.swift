import SwiftUI

@main
struct BikeDashApp: App {
    // Created at launch so Bluetooth state restoration can hand the watch and
    // sensors back, and a ride saved before the app closed is picked up again.
    @State private var history: RideHistory
    @State private var ride: RideController
    @State private var spotify: SpotifyController

    init() {
        let history = RideHistory()
        _history = State(initialValue: history)
        _ride = State(initialValue: RideController(
            heartRate: HeartRateService(),
            sensors: CyclingSensorService(),
            location: LocationService(),
            altimeter: AltimeterService(),
            history: history
        ))
        _spotify = State(initialValue: SpotifyController())
    }

    var body: some Scene {
        WindowGroup {
            RootView(ride: ride, spotify: spotify, history: history)
                .preferredColorScheme(.dark)
        }
    }
}
