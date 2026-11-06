import SwiftUI

enum AppTab: String {
    case history, computer, settings
}

/// The three tabs with the bike-computer tab bar, plus the ride summary that
/// appears after Hold to stop.
struct MainView: View {
    let ride: RideController
    let spotify: SpotifyController
    let history: RideHistory
    @State private var tab = AppTab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .computer

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .history: HistoryView(history: history)
                case .computer: ComputerView(ride: ride, spotify: spotify)
                case .settings: SettingsView(ride: ride, spotify: spotify)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            BottomTabBar(selection: $tab)
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: summaryShown) {
            if let record = ride.session.record() {
                RideSummaryView(record: record) { ride.newRide() }
                    .presentationBackground(Color.black)
            }
        }
    }

    /// Shown while the ride is finished; closing it starts afresh.
    private var summaryShown: Binding<Bool> {
        Binding(
            get: { ride.session.state == .finished },
            set: { shown in
                if !shown { ride.newRide() }
            }
        )
    }
}

struct BottomTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 0) {
            item(.history, symbol: "clock", label: "HISTORY")
            item(.computer, symbol: "iphone", label: "COMPUTER")
            item(.settings, symbol: "slider.horizontal.3", label: "SETTINGS")
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .background(Color.black)
    }

    private func item(_ tab: AppTab, symbol: String, label: String) -> some View {
        Button {
            selection = tab
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 24))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .tracking(0.6)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(selection == tab ? Color.white : Theme.dim)
        }
        .buttonStyle(.plain)
    }
}
