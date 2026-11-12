import ActivityKit
import BikeDashCore
import Foundation

/// The ride's Live Activity, shared by the app (which starts, updates and ends
/// it) and the widget extension (which draws it).
struct RideActivityAttributes: ActivityAttributes {
    typealias ContentState = RideActivityState

    var startedAt: Date
}

/// Where a tap on the Live Activity goes: the ride screen.
enum RideLink {
    static let url = URL(string: "bikedash://ride")!

    static func isRide(_ url: URL) -> Bool {
        url.scheme == "bikedash" && url.host == "ride"
    }
}
