import ActivityKit
import BikeDashCore
import Foundation
import os

private let log = Logger(subsystem: "com.jlmoh.bikedash", category: "live-activity")

/// The ride's Live Activity: started with the ride, updated at most every few
/// seconds (pauses and resumes at once), ended when the ride stops. Updates
/// come from the app itself while it runs during the ride, so no push.
@MainActor
final class LiveActivityController {
    private var activity: Activity<RideActivityAttributes>?
    private var throttle = LiveActivityThrottle(minInterval: 5)

    /// Demo mode leaves Live Activities alone unless launched with `-liveActivity 1`.
    private var allowed: Bool {
        !DemoMode.isOn || UserDefaults.standard.bool(forKey: "liveActivity")
    }

    /// A ride started.
    func start(_ state: RideActivityState, startedAt: Date) {
        guard allowed else { return }
        endAll()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.notice("Live Activities are off for Bike Dash in Settings")
            return
        }
        do {
            activity = try Activity.request(
                attributes: RideActivityAttributes(startedAt: startedAt),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            throttle.reset()
            _ = throttle.shouldSend(state, at: Date())
        } catch {
            log.error("Couldn't start the Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The app was opened again mid-ride: carry on with the Live Activity
    /// already showing, or start one.
    func resume(_ state: RideActivityState, startedAt: Date) {
        guard allowed else { return }
        if let existing = Activity<RideActivityAttributes>.activities.first {
            activity = existing
            throttle.reset()
            update(state, at: Date())
        } else {
            start(state, startedAt: startedAt)
        }
    }

    /// Often (every second and on sensor packets); sends only what the throttle allows.
    func update(_ state: RideActivityState, at now: Date) {
        guard let activity, throttle.shouldSend(state, at: now) else { return }
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// The ride stopped: take it off the lock screen and the Dynamic Island.
    func end(_ state: RideActivityState) {
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
    }

    /// No ride under way: clear any left over (say, after the app was closed mid-ride and the ride finished).
    func endAll() {
        activity = nil
        for leftover in Activity<RideActivityAttributes>.activities {
            Task {
                await leftover.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
