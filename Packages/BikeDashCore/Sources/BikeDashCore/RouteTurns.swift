import Foundation

/// A turn on a route, found from the route's shape alone (no map data): where
/// its direction changes by more than `RouteTurns.minAngle` over a short way.
public struct RouteTurn: Equatable, Sendable {
    public enum Direction: String, Equatable, Sendable {
        case slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn
    }

    /// Metres from the start, along the route.
    public var distance: Double
    /// How much the route turns, in degrees: positive to the right.
    public var angle: Double
    public var direction: Direction
    public var latitude: Double
    public var longitude: Double

    /// What the banner says: "LEFT", "SLIGHT RIGHT", "TURN AROUND".
    public var label: String {
        switch direction {
        case .slightLeft: return "SLIGHT LEFT"
        case .left: return "LEFT"
        case .sharpLeft: return "SHARP LEFT"
        case .slightRight: return "SLIGHT RIGHT"
        case .right: return "RIGHT"
        case .sharpRight: return "SHARP RIGHT"
        case .uTurn: return "TURN AROUND"
        }
    }
}

/// Finds a route's turns.
///
/// At every route point it compares the direction over the 30 m before it
/// with the 30 m after it, so a corner drawn with many points, or a few, reads
/// the same, and a long gentle bend never adds up to a turn. Neighbouring
/// points that turn the same way are one turn, placed at the sharpest point.
/// Strava draws the way back of an out-and-back on the same line, so a turn of
/// 150 degrees or more whose two sides stay together is "turn around"; one
/// whose sides spread apart (a hairpin) is a sharp turn.
public enum RouteTurns {
    /// Smaller changes of direction aren't turns (bends in the road).
    public static let minAngle = 40.0
    static let slightBelow = 65.0
    static let sharpFrom = 120.0
    static let uTurnFrom = 150.0
    /// The stretch before and after a point that its direction is measured over.
    static let span = 30.0
    /// Points of one turn are no further apart than this.
    static let joinWithin = 25.0
    /// A turn around goes back along the same road: its two sides stay closer
    /// than this at 30, 60 and 90 m from the turn.
    static let sameRoad = 25.0

    public static func find(on route: Route) -> [RouteTurn] {
        var candidates: [(distance: Double, angle: Double)] = []
        for d in route.distances where d >= span && d <= route.length - span {
            let angle = turn(on: route, from: d - span, at: d, to: d + span)
            if abs(angle) >= minAngle {
                candidates.append((d, angle))
            }
        }

        // Join neighbouring points that turn the same way into one turn.
        var groups: [[(distance: Double, angle: Double)]] = []
        for candidate in candidates {
            if let last = groups.last?.last,
               candidate.distance - last.distance <= joinWithin,
               (candidate.angle > 0) == (last.angle > 0) || abs(candidate.angle) >= uTurnFrom || abs(last.angle) >= uTurnFrom {
                groups[groups.count - 1].append(candidate)
            } else {
                groups.append([candidate])
            }
        }

        return groups.compactMap { group -> RouteTurn? in
            let apex = group.max { abs($0.angle) < abs($1.angle) }!
            // The whole turn: from before its first point to after its last.
            let first = group.first!.distance, last = group.last!.distance
            let angle = turn(on: route, from: max(0, first - span), at: first, to: min(route.length, last + span), exitFrom: last)
            guard abs(angle) >= minAngle else { return nil }
            let point = route.point(atDistance: apex.distance)
            return RouteTurn(
                distance: apex.distance,
                angle: angle,
                direction: direction(angle, backAlongTheSameRoad: retraces(route, at: apex.distance)),
                latitude: point.latitude,
                longitude: point.longitude
            )
        }
    }

    static func direction(_ angle: Double, backAlongTheSameRoad: Bool) -> RouteTurn.Direction {
        let size = abs(angle)
        if size >= uTurnFrom && backAlongTheSameRoad { return .uTurn }
        let right = angle > 0
        if size < slightBelow { return right ? .slightRight : .slightLeft }
        if size < sharpFrom { return right ? .right : .left }
        return right ? .sharpRight : .sharpLeft
    }

    /// The change of direction, in degrees (positive to the right), between
    /// the way in (from `from` to `at`) and the way out (from `exitFrom`, or
    /// `at`, to `to`).
    static func turn(on route: Route, from: Double, at: Double, to: Double, exitFrom: Double? = nil) -> Double {
        let inBearing = Geo.bearing(route.point(atDistance: from), route.point(atDistance: at))
        let outBearing = Geo.bearing(route.point(atDistance: exitFrom ?? at), route.point(atDistance: to))
        return signedDifference(from: inBearing, to: outBearing)
    }

    /// -180 to 180: how far to turn right (positive) from one bearing to another.
    static func signedDifference(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d >= 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// Whether the route comes back along the road it went out on.
    static func retraces(_ route: Route, at distance: Double) -> Bool {
        for k in [30.0, 60.0, 90.0] where distance - k >= 0 && distance + k <= route.length {
            if Geo.distance(route.point(atDistance: distance - k), route.point(atDistance: distance + k)) > sameRoad {
                return false
            }
        }
        return true
    }
}

/// When to warn about the next turn: once, about 100 m before it, until the
/// rider has passed it.
public struct TurnWarner: Sendable {
    public enum Event: Equatable, Sendable {
        /// A new warning: show the banner and buzz.
        case show(Int)
        /// The turn is passed (or progress jumped away from it): take it down.
        case hide
    }

    public static let warnWithin = 100.0
    /// The banner stays this far past the turn, for GPS lag.
    public static let passedAfter = 15.0
    /// Progress dropping this much (rejoining earlier on the route, or a loop
    /// starting over) re-arms the turns ahead.
    static let jumpBack = 200.0

    public let turns: [RouteTurn]
    /// The turn on the banner, if any (an index into `turns`).
    public private(set) var current: Int?
    private var warned: Set<Int> = []
    private var lastProgress: Double?

    public init(turns: [RouteTurn]) {
        self.turns = turns
    }

    /// Metres from the rider to the turn on the banner.
    public func distanceToCurrent(from progress: Double) -> Double? {
        current.map { max(0, turns[$0].distance - progress) }
    }

    public mutating func update(progress: Double) -> Event? {
        if let lastProgress, progress < lastProgress - Self.jumpBack {
            warned = warned.filter { turns[$0].distance <= progress }
        }
        lastProgress = progress

        // The next turn not yet passed.
        let next = turns.firstIndex { $0.distance > progress - Self.passedAfter }
        guard let next, turns[next].distance - progress <= Self.warnWithin else {
            guard current != nil else { return nil }
            current = nil
            return .hide
        }
        guard current != next else { return nil }
        current = next
        // One buzz per turn, even if the banner comes and goes.
        return warned.insert(next).inserted ? .show(next) : nil
    }
}

/// Off the route: more than 40 m from it for 10 seconds while riding. Back on
/// it once within 30 m. Nothing before the rider first reaches the route, so
/// riding to the start isn't "off route".
public struct OffRouteMonitor: Sendable {
    public enum Event: Equatable, Sendable {
        /// Alert: banner, buzz and chime.
        case off
        /// Back on the route: take the banner down.
        case back
    }

    public static let offBeyond = 40.0
    public static let offFor: TimeInterval = 10
    public static let backWithin = 30.0

    public private(set) var isOff = false
    /// The rider has been on the route at least once.
    public private(set) var joined = false
    private var awaySince: Date?

    public init() {}

    /// Each trusted GPS fix. `riding` is false while paused: time standing
    /// off the route (a shop, a café) doesn't count towards an alert.
    public mutating func update(offset: Double, at time: Date, riding: Bool) -> Event? {
        if offset <= Self.offBeyond {
            joined = true
            awaySince = nil
            if isOff && offset <= Self.backWithin {
                isOff = false
                return .back
            }
            return nil
        }
        guard joined, riding else {
            awaySince = nil
            return nil
        }
        let since = awaySince ?? time
        awaySince = since
        if !isOff && time.timeIntervalSince(since) >= Self.offFor {
            isOff = true
            return .off
        }
        return nil
    }
}
