import SwiftUI

/// One screen: the numbers (with a route picked, fewer numbers and the map), a
/// row of small ride buttons, Spotify, and the heart rate zone strip along the
/// very bottom. Routes, History and Settings open as sheets from the small buttons.
struct MainView: View {
    enum Panel: String, Identifiable {
        case routes, history, settings
        var id: String { rawValue }
    }

    let ride: RideController
    let spotify: SpotifyController
    let history: RideHistory
    let routes: RouteLibrary
    /// `-sheet history|settings` opens one at launch (simulator screenshots).
    @State private var panel = Panel(rawValue: UserDefaults.standard.string(forKey: "sheet") ?? "")

    var body: some View {
        VStack(spacing: 0) {
            if let lap = ride.lapShowing {
                LapPage(lap: lap) { ride.dismissLap() }
            } else if let route = ride.mapRoute {
                RouteRidePage(ride: ride, route: route, navigator: ride.navigator)
            } else {
                MetricsPage(ride: ride)
            }
            RideControlRow(
                ride: ride,
                routePicked: routes.nextRide != nil,
                showRoutes: { panel = .routes },
                showHistory: { panel = .history },
                showSettings: { panel = .settings }
            )
            NowPlayingPanel(spotify: spotify)
            HeartRateZoneBar(ride: ride)
        }
        .overlay(alignment: .top) {
            if ride.reminderShowing {
                ReminderBanner { ride.dismissReminder() }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: ride.rideScreenRequests) {
            panel = nil
        }
        .sheet(item: $panel) { panel in
            switch panel {
            case .routes: RoutesView(library: routes)
            case .history: HistoryView(history: history)
            case .settings: SettingsView(ride: ride, spotify: spotify)
            }
        }
        .fullScreenCover(isPresented: summaryShown) {
            if let record = ride.session.record() {
                RideSummaryView(record: record) { ride.newRide() }
            }
        }
    }

    /// Shown while the ride is finished; DONE starts afresh.
    private var summaryShown: Binding<Bool> {
        Binding(
            get: { ride.session.state == .finished },
            set: { shown in
                if !shown { ride.newRide() }
            }
        )
    }
}
