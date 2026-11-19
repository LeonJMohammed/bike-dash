import Foundation

/// Where the rider is on a route.
public struct RoutePosition: Equatable, Sendable {
    /// Metres from the start, along the route, to the closest point on it.
    public var distanceAlong: Double
    /// Metres from the rider to the route line.
    public var offset: Double
    /// The route segment (points[segment] to points[segment + 1]) that point is on.
    public var segment: Int
    /// Metres to the finish along the route.
    public var remaining: Double
}

/// Follows a rider along a route, one GPS position at a time.
///
/// The closest point on the whole route isn't always the right one: on an
/// out-and-back road, the way out and the way back are the same road, and a
/// loop starts where it finishes. So after the first fix it looks near where
/// the rider was (a little behind, up to a kilometre ahead), and only looks
/// over the whole route when nothing near fits, such as after a shortcut.
/// At the very first fix it takes the earliest part of the route that's
/// about as close as any, so a loop or an out-and-back starts at its start.
///
/// Where two parts of the route are about as close (the way out and the way
/// back of the same road), the one pointing the way the rider is going is
/// favoured. Without that, GPS error along the road at a turnaround can make
/// the way out look a couple of metres behind and the way back 25 m ahead,
/// and the tracker would then follow the way out backwards.
public struct RouteTracker: Sendable {
    public let route: Route
    public private(set) var position: RoutePosition?
    /// The rider's direction of travel in degrees, once they've moved.
    public private(set) var heading: Double?
    /// Where the heading was last measured from.
    private var anchor: RoutePoint?

    /// Movement needed before the fixes give a heading (GPS noise below that).
    static let headingAfter = 8.0
    /// A part of the route this far off the heading points the other way.
    static let againstHeading = 90.0
    /// Pointing the other way counts like this many metres of extra progress:
    /// enough to win a turnaround, not enough for a wrong heading (GPS noise)
    /// to throw progress hundreds of metres along the route.
    static let wrongWayCost = 100.0

    /// How far behind and ahead of the last position to look first.
    public static let lookBehind = 150.0
    public static let lookAhead = 1000.0
    /// Within this of the route the rider counts as on it, for picking up
    /// progress elsewhere on the route.
    public static let onRouteWithin = 50.0
    /// Candidates this much further away than the closest still count as ties,
    /// broken by progress (GPS error, roads side by side).
    static let tieMargin = 20.0

    public init(route: Route) {
        self.route = route
    }

    /// A new GPS position; returns where that puts the rider. `course` is the
    /// GPS course in degrees when the phone has a good one (CLLocation.course);
    /// without it the heading comes from the fixes themselves.
    @discardableResult
    public mutating func update(latitude: Double, longitude: Double, course: Double? = nil) -> RoutePosition {
        updateHeading(RoutePoint(latitude: latitude, longitude: longitude), course: course)
        let all = Self.closestPerSegment(on: route, latitude: latitude, longitude: longitude)
        let passes = Self.passes(all)
        let anywhere = passes.min { $0.offset < $1.offset }!

        guard let previous = position else {
            // First fix: the earliest of the near-ties (that point the way the
            // rider is going, if that's known yet).
            let ties = passes.filter { $0.offset <= anywhere.offset + Self.tieMargin }
            let pick = Self.goingTheWay(heading, ties).min { $0.distanceAlong < $1.distanceAlong }!
            position = pick.position
            return pick.position
        }

        let low = previous.distanceAlong - Self.lookBehind
        let high = previous.distanceAlong + Self.lookAhead
        func inWindow(_ p: RoutePosition) -> Bool { p.distanceAlong >= low && p.distanceAlong <= high }
        let near = Self.closestToProgress(passes.filter { inWindow($0.position) }, previous: previous.distanceAlong, heading: heading)

        var pick: RoutePosition
        if let near, near.offset <= Self.onRouteWithin {
            pick = near
        } else {
            let far = Self.closestToProgress(passes, previous: previous.distanceAlong, heading: heading)!
            if far.offset <= Self.onRouteWithin {
                pick = far   // back on the route somewhere else (a shortcut, or turned back)
            } else {
                // Off the route: progress stays where it was heading; the offset
                // is the distance to the nearest part of the route.
                pick = near ?? all.map(\.position).filter(inWindow).min { $0.offset < $1.offset } ?? far
                pick.offset = anywhere.offset
            }
        }
        position = pick
        return pick
    }

    /// Forgets the last position and heading (the next fix is treated as the first).
    public mutating func reset() {
        position = nil
        heading = nil
        anchor = nil
    }

    private mutating func updateHeading(_ fix: RoutePoint, course: Double?) {
        if let course, course.isFinite, course >= 0 {
            heading = course.truncatingRemainder(dividingBy: 360)
            anchor = fix
            return
        }
        guard let from = anchor else {
            anchor = fix
            return
        }
        if Geo.distance(from, fix) >= Self.headingAfter {
            heading = Geo.bearing(from, fix)
            anchor = fix
        }
    }

    /// The candidates pointing the way the rider is going; all of them when
    /// none do or the heading isn't known (turning back on purpose, standing).
    static func goingTheWay(_ heading: Double?, _ candidates: [Candidate]) -> [Candidate] {
        guard let heading else { return candidates }
        let along = candidates.filter { angle($0.bearing, heading) < againstHeading }
        return along.isEmpty ? candidates : along
    }

    /// The angle between two bearings, 0 to 180.
    static func angle(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /// Among candidates within the tie margin of the closest, the one whose
    /// progress is nearest the previous progress. Riders go forwards, so going
    /// back counts three times over: at the far end of an out-and-back, 100 m
    /// further on (the way back) beats 100 m back (the way out). A part of the
    /// route pointing against the rider's heading costs `wrongWayCost` more.
    static func closestToProgress(_ candidates: [Candidate], previous: Double, heading: Double?) -> RoutePosition? {
        guard let best = candidates.min(by: { $0.offset < $1.offset }) else { return nil }
        func cost(_ c: Candidate) -> Double {
            let step = c.distanceAlong - previous
            var cost = step >= 0 ? step : -step * 3
            if let heading, angle(c.bearing, heading) >= againstHeading { cost += wrongWayCost }
            return cost
        }
        return candidates
            .filter { $0.offset <= best.offset + tieMargin }
            .min { cost($0) < cost($1) }?.position
    }

    /// The places where the route passes closest to the rider: the points
    /// nearer than the route just before and just after them. On a straight
    /// road that's one point; an out-and-back has one on the way out and one
    /// on the way back. Comparing these, not every segment's closest point,
    /// keeps the end of the previous segment from looking like a near-tie.
    static func passes(_ all: [Candidate]) -> [Candidate] {
        let last = all.count - 1
        let found: [Candidate] = all.indices.compactMap { i in
            let c = all[i]
            let isPass: Bool
            if c.t <= 0 {
                isPass = i == 0 || all[i - 1].t >= 1
            } else if c.t >= 1 {
                isPass = i == last || all[i + 1].t <= 0
            } else {
                isPass = true
            }
            return isPass ? c : nil
        }
        // The closest point overall is always a pass; this only guards rounding.
        return found.isEmpty ? all : found
    }

    /// A segment's closest point to the rider, how far along the segment it
    /// is (0 at its start, 1 at its end), and the segment's bearing.
    struct Candidate {
        var position: RoutePosition
        var t: Double
        var bearing: Double
        var offset: Double { position.offset }
        var distanceAlong: Double { position.distanceAlong }
    }

    /// The closest point of each segment to the rider.
    static func closestPerSegment(on route: Route, latitude: Double, longitude: Double) -> [Candidate] {
        // Flat metres around the rider: plenty accurate over a few kilometres.
        let metresPerDegree = GPSFix.earthRadius * .pi / 180
        let east = cos(latitude * .pi / 180) * metresPerDegree
        func xy(_ p: RoutePoint) -> (x: Double, y: Double) {
            ((p.longitude - longitude) * east, (p.latitude - latitude) * metresPerDegree)
        }
        var out: [Candidate] = []
        out.reserveCapacity(route.points.count - 1)
        var a = xy(route.points[0])
        for i in 0..<(route.points.count - 1) {
            let b = xy(route.points[i + 1])
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            var t = lengthSquared > 0 ? -(a.x * dx + a.y * dy) / lengthSquared : 0
            t = min(1, max(0, t))
            let qx = a.x + t * dx, qy = a.y + t * dy
            let along = route.distances[i] + t * (route.distances[i + 1] - route.distances[i])
            out.append(Candidate(position: RoutePosition(
                distanceAlong: along,
                offset: (qx * qx + qy * qy).squareRoot(),
                segment: i,
                remaining: max(0, route.length - along)
            ), t: t, bearing: (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)))
            a = b
        }
        return out
    }
}
