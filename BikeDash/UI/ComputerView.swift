import SwiftUI

/// The Computer tab: swipeable pages (numbers, music) above the ride buttons.
struct ComputerView: View {
    let ride: RideController
    let spotify: SpotifyController
    @State private var page = UserDefaults.standard.integer(forKey: "page")

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                MetricsPage(ride: ride).tag(0)
                MusicPage(spotify: spotify).tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            PageDots(count: 2, current: page)
                .padding(.vertical, 10)
            ActionBar(ride: ride, spotify: spotify) {
                withAnimation { page = 1 }
            }
        }
    }
}

struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.white : Color(white: 0.35))
                    .frame(width: 18, height: 4)
            }
        }
    }
}

/// START OUTDOOR RIDE with status tiles, or Pause/Resume with Hold to stop.
struct ActionBar: View {
    let ride: RideController
    let spotify: SpotifyController
    let showMusic: () -> Void

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                primary
                    .frame(width: geo.size.width * 0.48)
                secondary
            }
        }
        .frame(height: 76)
    }

    @ViewBuilder private var primary: some View {
        switch ride.session.state {
        case .riding:
            BarButton(symbol: "pause.fill", title: "PAUSE") { ride.pause() }
        case .paused:
            BarButton(symbol: "play.fill", title: "RESUME") { ride.resume() }
        default:
            Button {
                ride.start()
            } label: {
                VStack(spacing: 2) {
                    Text("START")
                        .font(Theme.buttonTitle)
                    Text("OUTDOOR RIDE")
                        .font(Theme.buttonSubtitle)
                        .opacity(0.85)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.red)
                .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .disabled(ride.session.state == .finished)
        }
    }

    @ViewBuilder private var secondary: some View {
        if ride.session.isActive {
            HoldToStopButton { ride.finish() }
        } else {
            HStack(spacing: 1) {
                BarTile(symbol: "heart.fill", label: "WATCH", ready: ride.heartRate.bpm(at: Date()) != nil)
                BarTile(symbol: "location.fill", label: "GPS", ready: ride.location.isTracking && ride.location.lastFixAt != nil)
                BarTile(symbol: "music.note", label: "MUSIC", ready: spotify.status == .connected, action: showMusic)
            }
        }
    }
}

struct BarButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .bold))
                Text(title)
                    .font(Theme.buttonTitle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.red)
            .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
    }
}

/// A small dark-red tile: an icon, a label, and a green/orange ready dot.
struct BarTile: View {
    let symbol: String
    let label: String
    var ready: Bool?
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
            Text(label)
                .font(Theme.tileLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.darkRed)
        .foregroundStyle(Color.white)
        .overlay(alignment: .topTrailing) {
            if let ready {
                Circle()
                    .fill(ready ? Color.green : Theme.warning)
                    .frame(width: 9, height: 9)
                    .padding(8)
            }
        }
    }
}

/// Stopping needs a 1-second press, so rain or a bump can't end the ride.
/// The bar fills red while you hold.
struct HoldToStopButton: View {
    let action: () -> Void
    @State private var pressing = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Theme.darkRed
                Theme.red
                    .frame(width: pressing ? geo.size.width : 0)
                    .animation(pressing ? .linear(duration: 1) : .easeOut(duration: 0.15), value: pressing)
                HStack(spacing: 10) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 22, weight: .bold))
                    Text(pressing ? "KEEP HOLDING" : "HOLD TO STOP")
                        .font(Theme.barLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(Color.white)
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(
            minimumDuration: 1.0,
            maximumDistance: 40,
            perform: action,
            onPressingChanged: { pressing = $0 }
        )
    }
}
