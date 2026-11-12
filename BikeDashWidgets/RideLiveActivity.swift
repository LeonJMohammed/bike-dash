import ActivityKit
import BikeDashCore
import SwiftUI
import WidgetKit

@main
struct BikeDashWidgets: WidgetBundle {
    var body: some Widget {
        RideLiveActivity()
    }
}

/// The ride on the lock screen (speed, heart rate, ride time, distance) and in
/// the Dynamic Island (speed and heart rate; expanded adds time, distance and
/// cadence). Black, like the ride screen. A tap opens the ride screen.
struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            LockScreenRide(state: context.state)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(Color.white)
                .widgetURL(RideLink.url)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BigNumber(value: state.speedText, unit: "km/h")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BigNumber(value: state.heartRateText, unit: "bpm", tint: LiveColours.heart)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        RideClock(state: state)
                            .font(LiveFonts.middle)
                        Spacer()
                        Text(state.distanceText + " km")
                            .font(LiveFonts.middle)
                        Spacer()
                        Text(state.cadenceText + " rpm")
                            .font(LiveFonts.middle)
                    }
                    .padding(.horizontal, 6)
                    if state.paused {
                        Text("PAUSED")
                            .font(LiveFonts.label)
                            .foregroundStyle(LiveColours.paused)
                    }
                }
            } compactLeading: {
                Text(state.speedText)
                    .font(LiveFonts.compact)
                    .foregroundStyle(state.paused ? LiveColours.paused : Color.white)
            } compactTrailing: {
                HStack(spacing: 2) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(LiveColours.heart)
                    Text(state.heartRateText)
                }
                .font(LiveFonts.compact)
            } minimal: {
                Text(state.speedText)
                    .font(LiveFonts.minimal)
                    .minimumScaleFactor(0.6)
            }
            .widgetURL(RideLink.url)
            .keylineTint(LiveColours.accent)
        }
    }
}

private enum LiveColours {
    static let heart = Color(red: 0.95, green: 0.25, blue: 0.25)
    static let paused = Color.yellow
    static let accent = Color(red: 0.02, green: 0.71, blue: 0.83)  // the app icon's cyan
    static let dim = Color(white: 0.6)
}

private enum LiveFonts {
    static let big = Font.system(size: 34, weight: .bold).width(.condensed).monospacedDigit()
    static let middle = Font.system(size: 20, weight: .semibold).width(.condensed).monospacedDigit()
    static let label = Font.system(size: 12, weight: .semibold).width(.condensed)
    static let compact = Font.system(size: 15, weight: .bold).width(.condensed).monospacedDigit()
    static let minimal = Font.system(size: 13, weight: .bold).width(.condensed).monospacedDigit()
}

/// Moving time: counts up on its own while riding, frozen while paused.
private struct RideClock: View {
    let state: RideActivityState

    var body: some View {
        if let start = state.clockStart {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.center)
        } else {
            Text(state.movingTimeText)
                .foregroundStyle(LiveColours.paused)
        }
    }
}

private struct BigNumber: View {
    let value: String
    let unit: String
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(LiveFonts.big)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit.uppercased())
                .font(LiveFonts.label)
                .foregroundStyle(LiveColours.dim)
        }
    }
}

/// The lock screen: four numbers across, like a small bike computer.
private struct LockScreenRide: View {
    let state: RideActivityState

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label("Bike Dash", systemImage: "bicycle")
                    .font(LiveFonts.label)
                    .foregroundStyle(LiveColours.accent)
                Spacer()
                if state.paused {
                    Text("PAUSED")
                        .font(LiveFonts.label)
                        .foregroundStyle(LiveColours.paused)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                cell(Text(state.speedText), "km/h")
                cell(Text(state.heartRateText).foregroundStyle(LiveColours.heart), "bpm")
                cell(RideClock(state: state), "time")
                cell(Text(state.distanceText), "km")
            }
        }
        .padding(14)
        .foregroundStyle(Color.white)
    }

    private func cell(_ value: some View, _ unit: String) -> some View {
        VStack(spacing: 0) {
            value
                .font(LiveFonts.big)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(unit.uppercased())
                .font(LiveFonts.label)
                .foregroundStyle(LiveColours.dim)
        }
        .frame(maxWidth: .infinity)
    }
}
