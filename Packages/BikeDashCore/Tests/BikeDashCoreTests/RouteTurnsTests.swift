@testable import BikeDashCore
import XCTest

final class RouteTurnsTests: XCTestCase {
    /// A route through `corners` (metres north, east of RouteTests.base),
    /// with a point every `step` metres, as Strava draws them.
    static func path(_ corners: [(north: Double, east: Double)], every step: Double = 50) -> Route {
        var points: [RoutePoint] = [RouteTests.at(north: corners[0].north, east: corners[0].east)]
        for (a, b) in zip(corners, corners.dropFirst()) {
            let length = ((b.north - a.north) * (b.north - a.north) + (b.east - a.east) * (b.east - a.east)).squareRoot()
            let count = max(1, Int((length / step).rounded(.up)))
            for i in 1...count {
                let t = Double(i) / Double(count)
                points.append(RouteTests.at(north: a.north + t * (b.north - a.north), east: a.east + t * (b.east - a.east)))
            }
        }
        return Route(name: "test", points: points)!
    }

    /// Corners from legs: a bearing in degrees and a length in metres.
    static func legs(_ legs: [(bearing: Double, length: Double)]) -> [(north: Double, east: Double)] {
        var corners: [(north: Double, east: Double)] = [(0, 0)]
        for leg in legs {
            let last = corners.last!
            let r = leg.bearing * .pi / 180
            corners.append((last.north + cos(r) * leg.length, last.east + sin(r) * leg.length))
        }
        return corners
    }

    // MARK: - Finding turns

    func testASquareHasARightTurnAtEachCorner() {
        for step in [50.0, 10.0] {
            // Clockwise from the south-west corner; the last corner is the finish.
            let route = Self.path([(0, 0), (500, 0), (500, 500), (0, 500), (0, 0)], every: step)
            let turns = RouteTurns.find(on: route)
            XCTAssertEqual(turns.map(\.direction), [.right, .right, .right], "every \(step) m")
            for (turn, at) in zip(turns, [500.0, 1000, 1500]) {
                XCTAssertEqual(turn.distance, at, accuracy: 10, "every \(step) m")
                XCTAssertEqual(turn.angle, 90, accuracy: 5, "every \(step) m")
            }
            XCTAssertEqual(turns.first?.label, "RIGHT")
        }
    }

    func testSlightAndSharpTurnsBothWays() {
        // North, slight left (50), sharp right (135), left (90), slight right (45).
        let route = Self.path(Self.legs([(0, 300), (310, 300), (85, 300), (355, 300), (40, 300)]), every: 25)
        let turns = RouteTurns.find(on: route)
        XCTAssertEqual(turns.map(\.direction), [.slightLeft, .sharpRight, .left, .slightRight])
        XCTAssertEqual(turns.map(\.label), ["SLIGHT LEFT", "SHARP RIGHT", "LEFT", "SLIGHT RIGHT"])
        for (turn, angle) in zip(turns, [-50.0, 135, -90, 45]) {
            XCTAssertEqual(turn.angle, angle, accuracy: 3)
        }
    }

    func testAGentleBendIsNotATurn() {
        // A quarter circle of 300 m radius, a point every 20 m: a bend in the road.
        let points = stride(from: 0.0, through: 90, by: 3.8).map { degrees -> RoutePoint in
            let r = degrees * .pi / 180
            return RouteTests.at(north: 300 * sin(r), east: 300 - 300 * cos(r))
        }
        XCTAssertEqual(RouteTurns.find(on: Route(name: "bend", points: points)!), [])
    }

    func testABendBelowTheThresholdIsNotATurn() {
        let route = Self.path(Self.legs([(0, 300), (35, 300)]))
        XCTAssertEqual(RouteTurns.find(on: route), [])
    }

    func testAnOutAndBackTurnsAround() {
        // Strava draws the way back on the very same line.
        let route = Self.path([(0, 0), (1000, 0), (0, 0)])
        let turns = RouteTurns.find(on: route)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.direction, .uTurn)
        XCTAssertEqual(turns.first?.label, "TURN AROUND")
        XCTAssertEqual(turns.first?.distance ?? 0, 1000, accuracy: 1)
    }

    func testAHairpinIsASharpTurnNotTurnAround() {
        // 160 degrees, but the road climbs away on the other side.
        let route = Self.path(Self.legs([(0, 300), (160, 300)]), every: 20)
        let turns = RouteTurns.find(on: route)
        XCTAssertEqual(turns.map(\.direction), [.sharpRight])
    }

    func testACornerDrawnWithManyPointsIsOneTurn() {
        // North, then a 10 m radius corner to the east drawn every 2 m, then east.
        var points = stride(from: 0.0, to: 290, by: 2).map { RouteTests.at(north: $0) }
        for degrees in stride(from: 0.0, through: 90, by: 12) {
            let r = degrees * .pi / 180
            points.append(RouteTests.at(north: 290 + 10 * sin(r), east: 10 - 10 * cos(r)))
        }
        points += stride(from: 12.0, through: 300, by: 2).map { RouteTests.at(north: 300, east: $0) }
        let turns = RouteTurns.find(on: Route(name: "corner", points: points)!)
        XCTAssertEqual(turns.map(\.direction), [.right])
        XCTAssertEqual(turns.first?.distance ?? 0, 298, accuracy: 10)
        XCTAssertEqual(turns.first?.angle ?? 0, 90, accuracy: 6)
    }

    func testAJogIsTwoTurns() {
        // Right onto a 60 m stretch, then left again.
        let route = Self.path([(0, 0), (300, 0), (300, 60), (600, 60)], every: 10)
        let turns = RouteTurns.find(on: route)
        XCTAssertEqual(turns.map(\.direction), [.right, .left])
        XCTAssertEqual(turns.first?.distance ?? 0, 300, accuracy: 12)
        XCTAssertEqual(turns.last?.distance ?? 0, 360, accuracy: 12)
    }

    func testTheTurnIsWhereTheCornerIs() {
        let route = Self.path([(0, 0), (400, 0), (400, -400)])
        let turn = RouteTurns.find(on: route).first!
        XCTAssertEqual(turn.direction, .left)
        XCTAssertEqual(Geo.distance(RoutePoint(latitude: turn.latitude, longitude: turn.longitude), RouteTests.at(north: 400)), 0, accuracy: 1)
    }

    func testAPointAheadOfTheRider() {
        let from = RouteTests.at(north: 0)
        let ahead = Geo.offset(from, bearing: 90, distance: 150)
        XCTAssertEqual(Geo.distance(from, ahead), 150, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(from, ahead), 90, accuracy: 0.1)
    }

    // MARK: - Warning about them

    static func turn(at distance: Double, _ direction: RouteTurn.Direction = .right) -> RouteTurn {
        RouteTurn(distance: distance, angle: 90, direction: direction, latitude: 0, longitude: 0)
    }

    func testWarnsOnceAbout100MetresBeforeEachTurn() {
        var warner = TurnWarner(turns: [Self.turn(at: 500), Self.turn(at: 560, .left), Self.turn(at: 1500)])
        XCTAssertNil(warner.update(progress: 300))
        XCTAssertEqual(warner.update(progress: 400), .show(0))
        XCTAssertNil(warner.update(progress: 450))
        XCTAssertEqual(warner.distanceToCurrent(from: 450), 50)
        // Just past the turn the banner stays (GPS lag)...
        XCTAssertNil(warner.update(progress: 510))
        XCTAssertEqual(warner.current, 0)
        // ...then the next turn, close behind, takes over with its own buzz.
        XCTAssertEqual(warner.update(progress: 520), .show(1))
        XCTAssertEqual(warner.update(progress: 580), .hide)
        XCTAssertNil(warner.current)
        XCTAssertNil(warner.update(progress: 1300))
        XCTAssertEqual(warner.update(progress: 1400), .show(2))
    }

    func testOneBuzzPerTurnEvenIfTheBannerComesAndGoes() {
        var warner = TurnWarner(turns: [Self.turn(at: 500)])
        XCTAssertEqual(warner.update(progress: 410), .show(0))
        XCTAssertEqual(warner.update(progress: 380), .hide)   // GPS stepped back
        XCTAssertNil(warner.update(progress: 420))
        XCTAssertEqual(warner.current, 0, "the banner is back, without a second buzz")
    }

    func testAShortcutSkipsTheTurnsItCutOut() {
        var warner = TurnWarner(turns: [Self.turn(at: 500), Self.turn(at: 900), Self.turn(at: 1500)])
        XCTAssertNil(warner.update(progress: 200))
        XCTAssertEqual(warner.update(progress: 1450), .show(2))
    }

    func testGoingBackAlongTheRouteWarnsAgain() {
        var warner = TurnWarner(turns: [Self.turn(at: 500)])
        XCTAssertEqual(warner.update(progress: 450), .show(0))
        XCTAssertEqual(warner.update(progress: 700), .hide)
        // Rejoined much earlier (or a loop starting over): the turn is ahead again.
        XCTAssertNil(warner.update(progress: 100))
        XCTAssertEqual(warner.update(progress: 420), .show(0))
    }

    // MARK: - Off route

    func testOffRouteAfter40MetresFor10Seconds() {
        var monitor = OffRouteMonitor()
        let t0 = Date(timeIntervalSince1970: 1_790_848_800)
        XCTAssertNil(monitor.update(offset: 5, at: t0, riding: true))
        for s in 1...10 {
            XCTAssertNil(monitor.update(offset: 60, at: t0.addingTimeInterval(Double(s)), riding: true), "at \(s) s")
        }
        XCTAssertEqual(monitor.update(offset: 60, at: t0.addingTimeInterval(11), riding: true), .off)
        XCTAssertTrue(monitor.isOff)
        XCTAssertNil(monitor.update(offset: 80, at: t0.addingTimeInterval(12), riding: true), "one alert")
        XCTAssertNil(monitor.update(offset: 35, at: t0.addingTimeInterval(13), riding: true), "not back until within 30 m")
        XCTAssertEqual(monitor.update(offset: 25, at: t0.addingTimeInterval(14), riding: true), .back)
        XCTAssertFalse(monitor.isOff)
    }

    func testABriefWanderIsNotOffRoute() {
        var monitor = OffRouteMonitor()
        let t0 = Date(timeIntervalSince1970: 1_790_848_800)
        XCTAssertNil(monitor.update(offset: 0, at: t0, riding: true))
        for s in 1...8 { XCTAssertNil(monitor.update(offset: 50, at: t0.addingTimeInterval(Double(s)), riding: true)) }
        XCTAssertNil(monitor.update(offset: 20, at: t0.addingTimeInterval(9), riding: true))
        for s in 10...18 { XCTAssertNil(monitor.update(offset: 50, at: t0.addingTimeInterval(Double(s)), riding: true)) }
        XCTAssertFalse(monitor.isOff)
    }

    func testNothingBeforeReachingTheRoute() {
        var monitor = OffRouteMonitor()
        let t0 = Date(timeIntervalSince1970: 1_790_848_800)
        for s in 0...60 { XCTAssertNil(monitor.update(offset: 900, at: t0.addingTimeInterval(Double(s)), riding: true)) }
        XCTAssertFalse(monitor.joined)
        XCTAssertNil(monitor.update(offset: 30, at: t0.addingTimeInterval(61), riding: true))
        XCTAssertTrue(monitor.joined)
    }

    func testTimeStoppedOffTheRouteDoesntCount() {
        var monitor = OffRouteMonitor()
        let t0 = Date(timeIntervalSince1970: 1_790_848_800)
        XCTAssertNil(monitor.update(offset: 0, at: t0, riding: true))
        XCTAssertNil(monitor.update(offset: 60, at: t0.addingTimeInterval(1), riding: true))
        for s in 2...60 { XCTAssertNil(monitor.update(offset: 60, at: t0.addingTimeInterval(Double(s)), riding: false)) }
        // Riding again, still off: a fresh 10 seconds.
        for s in 61...70 { XCTAssertNil(monitor.update(offset: 60, at: t0.addingTimeInterval(Double(s)), riding: true)) }
        XCTAssertEqual(monitor.update(offset: 60, at: t0.addingTimeInterval(71), riding: true), .off)
    }

    // MARK: - The ride record

    func testTheRecordKeepsTheRouteAndBattery() throws {
        var session = RideSession()
        let t0 = Date(timeIntervalSince1970: 1_790_848_800)
        session.routeName = "Brian Lara Cricket Academy Loop"
        session.batteryAtStart = 92
        session.start(at: t0)
        // Picked up again after the app closed: still there.
        session = RideSession(restoring: try JSONDecoder().decode(RideSession.Snapshot.self, from: JSONEncoder().encode(session.snapshot)))
        session.batteryAtEnd = 81
        session.finish(at: t0.addingTimeInterval(3600))
        let record = try XCTUnwrap(session.record())
        XCTAssertEqual(record.routeName, "Brian Lara Cricket Academy Loop")
        XCTAssertEqual(record.batteryText, "Battery 92% → 81%")

        // Rides saved before these existed still load.
        var plain = record
        plain.routeName = nil
        plain.batteryAtStart = nil
        plain.batteryAtEnd = nil
        let old = try JSONDecoder().decode(RideRecord.self, from: JSONEncoder().encode(plain))
        XCTAssertNil(old.batteryText)
        XCTAssertNil(old.routeName)
    }
}
