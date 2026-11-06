import SwiftUI

struct RootView: View {
    let ride: RideController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if ride.session.state == .finished {
                RideSummaryView(ride: ride)
            } else {
                DashboardView(ride: ride)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: ride.appBecameActive()
            case .background: ride.appWentToBackground()
            default: break
            }
        }
    }
}
