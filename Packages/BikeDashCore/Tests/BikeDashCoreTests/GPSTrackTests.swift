import XCTest
@testable import BikeDashCore

final class GPSTrackTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Metres per degree of latitude, matching GPSFix's Earth radius.
    private let metresPerDegree = GPSFix.earthRadius * .pi / 180

    /// A fix `north` metres north of a point in Trinidad, `seconds` after the start.
    private func fix(_ seconds: Double, north: Double, accuracy: Double = 5, speed: Double = -1) -> GPSFix {
        GPSFix(
            time: start.addingTimeInterval(seconds),
            latitude: 10.65 + north / metresPerDegree,
            longitude: -61.5,
            horizontalAccuracy: accuracy,
            speed: speed
        )
    }

    func testOneDegreeOfLatitude() {
        let a = GPSFix(time: start, latitude: 0, longitude: 0, horizontalAccuracy: 5, speed: 0)
        let b = GPSFix(time: start, latitude: 1, longitude: 0, horizontalAccuracy: 5, speed: 0)
        XCTAssertEqual(a.distance(to: b), 111_195, accuracy: 1)
    }

    func testSteadyRideAddsUpDistanceAndSpeed() {
        var track = GPSTrack()
        for s in 0...60 {
            XCTAssertTrue(track.add(fix(Double(s), north: Double(s) * 5, speed: 5)))
        }
        XCTAssertEqual(track.distance, 300, accuracy: 0.5)
        XCTAssertEqual(track.speed(at: start.addingTimeInterval(60)) ?? -1, 5, accuracy: 0.001)
    }

    func testSpeedGoesStale() {
        var track = GPSTrack()
        track.add(fix(0, north: 0, speed: 5))
        XCTAssertNotNil(track.speed(at: start.addingTimeInterval(5)))
        XCTAssertNil(track.speed(at: start.addingTimeInterval(6)))
    }

    func testInaccurateFixesAreDropped() {
        var track = GPSTrack()
        track.add(fix(0, north: 0, speed: 5))
        XCTAssertFalse(track.add(fix(1, north: 5, accuracy: 50, speed: 5)))
        XCTAssertFalse(track.add(fix(2, north: 10, accuracy: -1, speed: 5)))
        XCTAssertEqual(track.distance, 0)
    }

    func testOneGPSJumpIsDropped() {
        var track = GPSTrack()
        track.add(fix(0, north: 0, speed: 5))
        XCTAssertFalse(track.add(fix(1, north: 1_000, speed: 5)))
        XCTAssertTrue(track.add(fix(2, north: 10, speed: 5)))
        XCTAssertEqual(track.distance, 10, accuracy: 0.1)
    }

    func testRepeatedJumpsMoveTheStartWithoutAddingDistance() {
        var track = GPSTrack()
        track.add(fix(0, north: 0, speed: 5))  // the outlier we start from
        XCTAssertFalse(track.add(fix(1, north: 1_000, speed: 5)))
        XCTAssertFalse(track.add(fix(2, north: 1_005, speed: 5)))
        XCTAssertTrue(track.add(fix(3, north: 1_010, speed: 5)))  // third jump in a row
        XCTAssertTrue(track.add(fix(4, north: 1_015, speed: 5)))
        XCTAssertEqual(track.distance, 5, accuracy: 0.1)
    }

    func testJitterWhileStoppedAddsNoDistance() {
        var track = GPSTrack()
        let wobble: [Double] = [0, 3, -2, 4, -3, 1, 2, -4, 0, 3]
        for (s, north) in wobble.enumerated() {
            track.add(fix(Double(s), north: north, speed: 0.2))
        }
        XCTAssertEqual(track.distance, 0)
    }

    func testWithoutDopplerSpeedTheMovementItselfCounts() {
        var track = GPSTrack()
        for s in 0...10 {
            track.add(fix(Double(s), north: Double(s) * 4))  // speed invalid (-1)
        }
        XCTAssertEqual(track.distance, 40, accuracy: 0.1)
        XCTAssertEqual(track.speed(at: start.addingTimeInterval(10)) ?? -1, 4, accuracy: 0.01)
    }

    func testOutOfOrderAndRepeatedFixesAreDropped() {
        var track = GPSTrack()
        track.add(fix(5, north: 0, speed: 5))
        XCTAssertFalse(track.add(fix(4, north: 5, speed: 5)))
        XCTAssertFalse(track.add(fix(5, north: 5, speed: 5)))
    }

    func testBreakSegmentSkipsTheGap() {
        var track = GPSTrack()
        track.add(fix(0, north: 0, speed: 5))
        track.add(fix(1, north: 5, speed: 5))
        track.breakSegment()
        track.add(fix(60, north: 500, speed: 5))
        track.add(fix(61, north: 505, speed: 5))
        XCTAssertEqual(track.distance, 10, accuracy: 0.1)
    }

    func testResetClearsDistanceAndSpeed() {
        var track = GPSTrack()
        track.add(fix(0, north: 0, speed: 5))
        track.add(fix(1, north: 5, speed: 5))
        track.reset()
        XCTAssertEqual(track.distance, 0)
        XCTAssertNil(track.speed(at: start.addingTimeInterval(1)))
    }
}
