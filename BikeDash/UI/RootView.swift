import SwiftUI

struct RootView: View {
    let ride: RideController
    let spotify: SpotifyController
    let history: RideHistory
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MainView(ride: ride, spotify: spotify, history: history)
            .onOpenURL { spotify.handle($0) }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    ride.appBecameActive()
                    spotify.appBecameActive()
                case .background:
                    ride.appWentToBackground()
                    spotify.appWentToBackground()
                default:
                    break
                }
            }
            .task {
                if DemoMode.isOn {
                    DemoMode.load(ride: ride, spotify: spotify, history: history)
                }
            }
    }
}
