@testable import BikeDashCore
import XCTest

final class RouteTests: XCTestCase {
    static let base = (lat: 10.65, lon: -61.5)
    static let metresPerDegree = GPSFix.earthRadius * .pi / 180
    static var metresPerDegreeEast: Double { cos(base.lat * .pi / 180) * metresPerDegree }

    /// A point `north` and `east` metres from the base.
    static func at(north: Double, east: Double = 0, ele: Double? = nil) -> RoutePoint {
        RoutePoint(latitude: base.lat + north / metresPerDegree, longitude: base.lon + east / metresPerDegreeEast, elevation: ele)
    }

    static func gpx(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx creator="StravaGPX" version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
        \(body)
        </gpx>
        """.utf8)
    }

    // MARK: - GPX

    func testReadsStravaStyleTrackWithElevationAndName() throws {
        let route = try Route.parseGPX(Self.gpx("""
          <metadata><name>Sunday loop</name><link href="https://www.strava.com/routes/1"/></metadata>
          <trk><name>Sunday loop</name><type>cycling</type><trkseg>
            <trkpt lat="10.650000" lon="-61.500000"><ele>10.0</ele></trkpt>
            <trkpt lat="10.651000" lon="-61.500000"><ele>14.5</ele><time>2026-01-01T00:00:00Z</time></trkpt>
            <trkpt lat="10.652000" lon="-61.500000"><ele>12.0</ele></trkpt>
          </trkseg></trk>
        """))
        XCTAssertEqual(route.name, "Sunday loop")
        XCTAssertEqual(route.points.count, 3)
        XCTAssertEqual(route.points[1].elevation, 14.5)
        XCTAssertEqual(route.length, 0.002 * Self.metresPerDegree, accuracy: 0.5)
        XCTAssertEqual(route.distances[0], 0)
        XCTAssertEqual(route.elevationGain, 4.5, accuracy: 0.001)
    }

    func testRoutePointsWhenThereIsNoTrack_AndWaypointsIgnored() throws {
        let route = try Route.parseGPX(Self.gpx("""
          <wpt lat="0" lon="0"><name>Café</name><ele>99</ele></wpt>
          <rte><name>Hills</name>
            <rtept lat="10.65" lon="-61.5"/>
            <rtept lat="10.66" lon="-61.5"/>
          </rte>
        """))
        XCTAssertEqual(route.name, "Hills")
        XCTAssertEqual(route.points.count, 2)
        XCTAssertNil(route.points[0].elevation)
        XCTAssertFalse(route.hasElevation)
        XCTAssertEqual(route.elevationProfile(), [])
    }

    func testFallbackNameAndBadFiles() throws {
        let unnamed = try Route.parseGPX(Self.gpx("""
          <trk><trkseg><trkpt lat="10.65" lon="-61.5"/><trkpt lat="10.66" lon="-61.5"/></trkseg></trk>
        """), fallbackName: "Strava route")
        XCTAssertEqual(unnamed.name, "Strava route")

        XCTAssertThrowsError(try Route.parseGPX(Data("<html>nope</html>".utf8))) {
            XCTAssertEqual($0 as? Route.ParseError, .notGPX)
        }
        XCTAssertThrowsError(try Route.parseGPX(Data("not xml at all".utf8)))
        XCTAssertThrowsError(try Route.parseGPX(Self.gpx("<trk><trkseg><trkpt lat=\"10\" lon=\"-61\"/></trkseg></trk>"))) {
            XCTAssertEqual($0 as? Route.ParseError, .tooFewPoints)
        }
    }

    func testRepeatsAndBadCoordinatesAreDropped() {
        let route = Route(name: "r", points: [
            Self.at(north: 0), Self.at(north: 0.2), Self.at(north: 100),
            RoutePoint(latitude: .nan, longitude: 0), RoutePoint(latitude: 95, longitude: 0), Self.at(north: 200),
        ])!
        XCTAssertEqual(route.points.count, 3)
        XCTAssertEqual(route.length, 200, accuracy: 0.1)
        XCTAssertNil(Route(name: "r", points: [Self.at(north: 0), Self.at(north: 0.1)]))
    }

    // MARK: - Climb and profile

    func testClimbIgnoresSmallWobbles() {
        XCTAssertEqual(Route.climb([10, 11, 10, 11.5, 10, 11]), 0)          // never 2 m up
        XCTAssertEqual(Route.climb([10, 20, 19, 25]), 15)                    // one climb with a dip under 2 m
        XCTAssertEqual(Route.climb([10, 20, 15, 25]), 20)                    // 10 up, down 5, 10 up
        XCTAssertEqual(Route.climb([50, 40, 30]), 0)
        XCTAssertEqual(Route.climb([]), 0)
    }

    func testProfileAndPointAtDistance() {
        let route = Route(name: "r", points: [Self.at(north: 0, ele: 0), Self.at(north: 1000, ele: 100), Self.at(north: 2000, ele: 50)])!
        let profile = route.elevationProfile(samples: 5)
        XCTAssertEqual(profile.count, 5)
        XCTAssertEqual(profile.first?.distance, 0)
        XCTAssertEqual(profile.last!.distance, route.length, accuracy: 0.001)
        XCTAssertEqual(profile[1].elevation, 50, accuracy: 0.5)
        XCTAssertEqual(profile[2].elevation, 100, accuracy: 0.5)

        let mid = route.point(atDistance: 500)
        XCTAssertEqual(Geo.distance(mid, Self.at(north: 500)), 0, accuracy: 0.5)
        XCTAssertEqual(mid.elevation!, 50, accuracy: 0.1)
        XCTAssertEqual(route.point(atDistance: -5), route.points[0])
        XCTAssertEqual(route.point(atDistance: 99_999), route.points[2])
    }

    func testBoundsAndBearing() {
        let route = Route(name: "r", points: [Self.at(north: 0), Self.at(north: 500, east: 300), Self.at(north: -100, east: -50)])!
        let b = route.bounds
        XCTAssertEqual(b.south, Self.at(north: -100).latitude, accuracy: 1e-9)
        XCTAssertEqual(b.north, Self.at(north: 500).latitude, accuracy: 1e-9)
        XCTAssertEqual(b.west, Self.at(north: 0, east: -50).longitude, accuracy: 1e-9)
        XCTAssertEqual(b.east, Self.at(north: 0, east: 300).longitude, accuracy: 1e-9)
        XCTAssertEqual(Geo.bearing(Self.at(north: 0), Self.at(north: 100)), 0, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(Self.at(north: 0), Self.at(north: 0, east: 100)), 90, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(Self.at(north: 0), Self.at(north: -100)), 180, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(Self.at(north: 0), Self.at(north: 0, east: -100)), 270, accuracy: 0.01)
    }

    // MARK: - Progress along the route

    /// Straight north for 2 km, a point every 50 m (about Strava's spacing).
    static let straight = Route(name: "s", points: stride(from: 0.0, through: 2000, by: 50).map { at(north: $0) })!

    func testProgressAndOffsetOnAStraightRoad() {
        var tracker = RouteTracker(route: Self.straight)
        let p = tracker.update(latitude: Self.at(north: 520, east: 20).latitude, longitude: Self.at(north: 520, east: 20).longitude)
        XCTAssertEqual(p.distanceAlong, 520, accuracy: 0.5)
        XCTAssertEqual(p.offset, 20, accuracy: 0.5)
        XCTAssertEqual(p.remaining, 1480, accuracy: 0.5)
        XCTAssertEqual(p.segment, 10)

        // Before the start and past the finish: clamped to the ends.
        tracker.reset()
        let before = tracker.update(latitude: Self.at(north: -30).latitude, longitude: Self.base.lon)
        XCTAssertEqual(before.distanceAlong, 0, accuracy: 0.01)
        XCTAssertEqual(before.offset, 30, accuracy: 0.5)
    }

    func testRidingBesideTheRoadTracksEveryMetre() {
        // 15 m to the side (GPS error, a wide road), a fix every 10 m: the
        // ends of segments must never pull progress back.
        var tracker = RouteTracker(route: Self.straight)
        for north in stride(from: 0.0, through: 2000, by: 10) {
            let p = Self.at(north: north, east: 15)
            let position = tracker.update(latitude: p.latitude, longitude: p.longitude)
            XCTAssertEqual(position.distanceAlong, north, accuracy: 0.5, "at \(north)")
            XCTAssertEqual(position.offset, 15, accuracy: 0.5, "at \(north)")
        }
    }

    func testOutAndBackFollowsTheWayOutThenTheWayBack() {
        // 1 km north, then back down the same road.
        let points = stride(from: 0.0, through: 1000, by: 50).map { Self.at(north: $0) }
            + stride(from: 950.0, through: 0, by: -50).map { Self.at(north: $0, east: 3) }
        var tracker = RouteTracker(route: Route(name: "oab", points: points)!)
        func ride(_ north: Double) -> RoutePosition {
            let p = Self.at(north: north, east: 1)
            return tracker.update(latitude: p.latitude, longitude: p.longitude)
        }
        XCTAssertEqual(ride(0).distanceAlong, 0, accuracy: 3, "starts at the start, not the finish")
        for north in stride(from: 100.0, through: 900, by: 100) {
            XCTAssertEqual(ride(north).distanceAlong, north, accuracy: 3, "way out at \(north)")
        }
        XCTAssertEqual(ride(1000).distanceAlong, 1000, accuracy: 5)
        for north in stride(from: 900.0, through: 100, by: -100) {
            XCTAssertEqual(ride(north).distanceAlong, 2000 - north, accuracy: 5, "way back at \(north)")
        }
        XCTAssertEqual(ride(0).remaining, 0, accuracy: 5)
    }

    func testATurnaroundOnTheSameLineFollowsTheDirectionOfTravel() {
        // The way back is the very same line (as Strava draws it), and the GPS
        // reads 12 m south all ride. At the turn the way out then looks 12 m
        // behind and the way back 12 m ahead; going by progress alone, the
        // tracker would follow the way out backwards. The heading decides.
        let points = stride(from: 0.0, through: 1000, by: 50).map { Self.at(north: $0) }
            + stride(from: 950.0, through: 0, by: -50).map { Self.at(north: $0) }
        let route = Route(name: "same road", points: points)!
        var tracker = RouteTracker(route: route)
        var last = 0.0
        for d in stride(from: 0.0, through: 2000, by: 10) {
            let north = d <= 1000 ? d : 2000 - d
            let p = Self.at(north: north - 12, east: 3)
            let along = tracker.update(latitude: p.latitude, longitude: p.longitude).distanceAlong
            XCTAssertEqual(along, d, accuracy: 15, "at \(d)")
            XCTAssertGreaterThanOrEqual(along, last - 1, "never backwards, at \(d)")
            last = along
        }

        // With the GPS course, even the first fix picks the way back.
        var fresh = RouteTracker(route: route)
        let mid = Self.at(north: 500, east: 2)
        XCTAssertEqual(fresh.update(latitude: mid.latitude, longitude: mid.longitude, course: 180).distanceAlong, 1500, accuracy: 1)
        fresh.reset()
        XCTAssertNil(fresh.heading)
        XCTAssertEqual(fresh.update(latitude: mid.latitude, longitude: mid.longitude).distanceAlong, 500, accuracy: 1)
    }

    func testLoopStartsAtZeroAndFinishesAtFullLength() {
        // A square 500 m a side, finishing where it started.
        var points: [RoutePoint] = []
        for d in stride(from: 0.0, to: 500, by: 50) { points.append(Self.at(north: d)) }
        for d in stride(from: 0.0, to: 500, by: 50) { points.append(Self.at(north: 500, east: d)) }
        for d in stride(from: 500.0, to: 0, by: -50) { points.append(Self.at(north: d, east: 500)) }
        for d in stride(from: 500.0, through: 0, by: -50) { points.append(Self.at(north: 0, east: d)) }
        var tracker = RouteTracker(route: Route(name: "loop", points: points)!)
        let start = tracker.update(latitude: Self.at(north: 5).latitude, longitude: Self.at(north: 5).longitude)
        XCTAssertEqual(start.distanceAlong, 5, accuracy: 1)
        for (north, east, along) in [(250.0, 0.0, 250.0), (500, 250, 750), (250, 500, 1250), (0, 250, 1750), (0, 30, 1970)] {
            let p = Self.at(north: north, east: east)
            XCTAssertEqual(tracker.update(latitude: p.latitude, longitude: p.longitude).distanceAlong, along, accuracy: 2)
        }
        let finish = tracker.update(latitude: Self.base.lat, longitude: Self.base.lon)
        XCTAssertEqual(finish.distanceAlong, 2000, accuracy: 1, "the finish, not back to the start")
    }

    func testOffRouteKeepsProgressAndReportsTheDistance() {
        var tracker = RouteTracker(route: Self.straight)
        let on = Self.at(north: 400)
        tracker.update(latitude: on.latitude, longitude: on.longitude)
        let off = Self.at(north: 450, east: 120)
        let p = tracker.update(latitude: off.latitude, longitude: off.longitude)
        XCTAssertEqual(p.offset, 120, accuracy: 1)
        XCTAssertEqual(p.distanceAlong, 450, accuracy: 2)
    }

    func testAShortcutPicksUpProgressFurtherOn() {
        // An L: 1 km north, then 1.5 km east. Cutting across the corner.
        let points = stride(from: 0.0, through: 1000, by: 50).map { Self.at(north: $0) }
            + stride(from: 50.0, through: 1500, by: 50).map { Self.at(north: 1000, east: $0) }
        var tracker = RouteTracker(route: Route(name: "L", points: points)!)
        let start = Self.at(north: 100)
        tracker.update(latitude: start.latitude, longitude: start.longitude)
        let cut = Self.at(north: 1000, east: 1200)   // 2.2 km along, far beyond the look-ahead
        let p = tracker.update(latitude: cut.latitude, longitude: cut.longitude)
        XCTAssertEqual(p.distanceAlong, 2200, accuracy: 2)
        XCTAssertEqual(p.offset, 0, accuracy: 1)
    }
}
