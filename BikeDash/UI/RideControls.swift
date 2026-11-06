import SwiftUI

/// Small ride buttons (Start, or Pause/Resume and Hold to stop) with the
/// History and Settings buttons at the end.
struct RideControlRow: View {
    let ride: RideController
    let showHistory: () -> Void
    let showSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch ride.session.state {
            case .riding:
                PillButton(symbol: "pause.fill", title: "PAUSE") { ride.pause() }
                HoldToStopButton { ride.finish() }
            case .paused:
                PillButton(symbol: "play.fill", title: "RESUME") { ride.resume() }
                HoldToStopButton { ride.finish() }
            default:
                PillButton(symbol: "play.fill", title: "START") { ride.start() }
                    .disabled(ride.session.state == .finished)
            }
            Spacer(minLength: 0)
            CircleButton(symbol: "clock", action: showHistory)
            CircleButton(symbol: "gearshape.fill", action: showSettings)
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
    }
}

struct PillButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                Text(title)
                    .font(Theme.pillLabel)
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            .background(Theme.red, in: Capsule())
            .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
    }
}

struct CircleButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(Color(white: 0.16), in: Circle())
                .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
    }
}

/// Stopping needs a 1-second press, so rain or a bump can't end the ride.
/// The pill fills red while you hold.
struct HoldToStopButton: View {
    let action: () -> Void
    @State private var pressing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.fill")
                .font(.system(size: 15, weight: .bold))
            Text("HOLD TO STOP")
                .font(Theme.pillLabel)
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Theme.darkRed
                    Theme.red
                        .frame(width: pressing ? geo.size.width : 0)
                        .animation(pressing ? .linear(duration: 1) : .easeOut(duration: 0.15), value: pressing)
                }
            }
            .clipShape(Capsule())
        }
        .foregroundStyle(Color.white)
        .contentShape(Capsule())
        .onLongPressGesture(
            minimumDuration: 1.0,
            maximumDistance: 40,
            perform: action,
            onPressingChanged: { pressing = $0 }
        )
    }
}
