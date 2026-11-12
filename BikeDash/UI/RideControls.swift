import BikeDashCore
import SwiftUI

/// Small ride buttons (Start; Pause, Lap and Hold to stop while riding; Resume
/// and Hold to stop while paused) with the Settings button at the end, and
/// History too when no ride is under way.
struct RideControlRow: View {
    let ride: RideController
    let showHistory: () -> Void
    let showSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch ride.session.state {
            case .riding:
                PillButton(symbol: "pause.fill", title: "PAUSE") { ride.pause() }
                PillButton(symbol: "flag.checkered", title: "LAP") { ride.lap() }
                HoldToStopButton { ride.finish() }
            case .paused:
                PillButton(symbol: "play.fill", title: "RESUME") { ride.resume() }
                HoldToStopButton { ride.finish() }
            default:
                PillButton(symbol: "play.fill", title: "START") { ride.start() }
                    .disabled(ride.session.state == .finished)
            }
            Spacer(minLength: 0)
            // History waits until the ride is over, to make room for LAP.
            if !ride.session.isActive {
                CircleButton(symbol: "clock", action: showHistory)
            }
            CircleButton(symbol: "gearshape.fill", action: showSettings)
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
    }
}

/// A red pill: filled in the Standard theme, a red outline in OLED black.
struct PillButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @AppStorage(Theme.rideThemeKey) private var theme = RideTheme.default.rawValue

    var body: some View {
        let outlined = RideTheme(stored: theme).outlinesControls
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .bold))
                Text(title)
                    .font(Theme.pillLabel)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background {
                if outlined {
                    Capsule().strokeBorder(Theme.red, lineWidth: 2)
                } else {
                    Capsule().fill(Theme.red)
                }
            }
            .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
    }
}

struct CircleButton: View {
    let symbol: String
    let action: () -> Void
    @AppStorage(Theme.rideThemeKey) private var theme = RideTheme.default.rawValue

    var body: some View {
        let outlined = RideTheme(stored: theme).outlinesControls
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background {
                    if outlined {
                        Circle().strokeBorder(Theme.outline, lineWidth: 1.5)
                    } else {
                        Circle().fill(Color(white: 0.16))
                    }
                }
                .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
    }
}

/// Stopping needs a 1-second press, so rain or a bump can't end the ride.
/// The pill fills red while you hold (from black in the OLED black theme).
struct HoldToStopButton: View {
    let action: () -> Void
    @State private var pressing = false
    @AppStorage(Theme.rideThemeKey) private var theme = RideTheme.default.rawValue

    var body: some View {
        let outlined = RideTheme(stored: theme).outlinesControls
        Text("HOLD TO STOP")
            .font(Theme.pillLabel)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(height: 48)
        .background {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    outlined ? Color.black : Theme.darkRed
                    Theme.red
                        .frame(width: pressing ? geo.size.width : 0)
                        .animation(pressing ? .linear(duration: 1) : .easeOut(duration: 0.15), value: pressing)
                }
            }
            .clipShape(Capsule())
            .overlay {
                if outlined { Capsule().strokeBorder(Theme.darkRed, lineWidth: 2) }
            }
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
