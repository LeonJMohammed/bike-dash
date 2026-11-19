import BikeDashCore
import Foundation
import Observation

/// Follows the ride along the picked route: where the rider is on it, the next
/// turn (warned about 100 m before), and whether they're off it. Created when
/// a ride with a route starts; GPS runs only while it exists. Speed and
/// distance still come from the sensors.
@MainActor
@Observable
final class RouteNavigator {
    enum Event {
        /// A turn about 100 m ahead: banner and one buzz.
        case turn(RouteTurn)
        /// More than 40 m off the route for 10 s: banner, buzz and chime.
        case offRoute
        case backOnRoute
    }

    let saved: SavedRoute
    let route: Route
    let turns: [RouteTurn]

    /// Where the rider is on the route, after the first trusted fix.
    private(set) var position: RoutePosition?
    /// The rider's last trusted position and direction of travel.
    private(set) var rider: RoutePoint?
    private(set) var heading: Double?
    private(set) var offRoute = false
    /// The turn on the banner and how far off it is.
    private(set) var turn: RouteTurn?
    private(set) var toTurn: Double?

    /// Fixes less accurate than this (metres) are ignored.
    static let maxAccuracy = 30.0

    @ObservationIgnored private var tracker: RouteTracker
    @ObservationIgnored private var warner: TurnWarner
    @ObservationIgnored private var monitor = OffRouteMonitor()

    init(saved: SavedRoute, route: Route) {
        self.saved = saved
        self.route = route
        let turns = RouteTurns.find(on: route)
        self.turns = turns
        tracker = RouteTracker(route: route)
        warner = TurnWarner(turns: turns)
    }

    /// The rider has been on the route at least once.
    var joined: Bool { monitor.joined }

    /// Metres to the finish along the route (the whole route before a fix).
    var remaining: Double { position?.remaining ?? route.length }

    /// Metres from the rider to the route line.
    var offset: Double? { position?.offset }

    /// A GPS fix while the ride is under way. Returns what's worth an alert.
    func add(_ fix: GPSFix, riding: Bool) -> [Event] {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= Self.maxAccuracy else { return [] }
        // iOS's course is good once moving; below walking pace it wanders.
        let course = fix.course >= 0 && fix.speed >= 2 ? fix.course : nil
        let position = tracker.update(latitude: fix.latitude, longitude: fix.longitude, course: course)
        self.position = position
        rider = RoutePoint(latitude: fix.latitude, longitude: fix.longitude)
        heading = tracker.heading

        var events: [Event] = []
        switch monitor.update(offset: position.offset, at: fix.time, riding: riding) {
        case .off:
            offRoute = true
            events.append(.offRoute)
        case .back:
            offRoute = false
            events.append(.backOnRoute)
        case nil:
            break
        }

        switch warner.update(progress: position.distanceAlong) {
        case .show(let index):
            if !offRoute { events.append(.turn(turns[index])) }
        case .hide, nil:
            break
        }
        // Off the route, the turns ahead don't apply until back on it.
        turn = offRoute ? nil : warner.current.map { turns[$0] }
        toTurn = offRoute ? nil : warner.distanceToCurrent(from: position.distanceAlong)
        return events
    }
}
