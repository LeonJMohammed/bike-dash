import SwiftUI

@main
struct BikeDashApp: App {
    // Created at launch so Bluetooth state restoration can hand the watch back.
    @State private var heartRate = HeartRateService()
    @State private var location = LocationService()

    var body: some Scene {
        WindowGroup {
            RootView(heartRate: heartRate, location: location)
                .preferredColorScheme(.dark)
        }
    }
}
