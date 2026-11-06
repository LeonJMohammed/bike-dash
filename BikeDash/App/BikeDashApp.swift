import SwiftUI

@main
struct BikeDashApp: App {
    // Created at launch so Bluetooth state restoration can hand the watch back,
    // and a ride saved before the app closed is picked up again.
    @State private var ride: RideController

    init() {
        _ride = State(initialValue: RideController(
            heartRate: HeartRateService(),
            location: LocationService()
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView(ride: ride)
                .preferredColorScheme(.dark)
        }
    }
}
