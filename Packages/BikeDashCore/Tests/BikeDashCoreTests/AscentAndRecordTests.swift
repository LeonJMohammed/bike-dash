import XCTest
@testable import BikeDashCore

final class AscentCounterTests: XCTestCase {
    func testSteadyClimb() {
        var counter = AscentCounter()
        for step in 0...500 { counter.add(Double(step) * 0.1) }  // 0 to 50 m
        XCTAssertEqual(counter.ascent, 50, accuracy: 0.11)
    }

    func testNoiseAddsNothing() {
        var counter = AscentCounter()
        let wobble: [Double] = [10, 10.4, 9.7, 10.3, 9.6, 10.2, 9.8, 10.4, 9.9]
        for altitude in wobble { counter.add(altitude) }
        XCTAssertEqual(counter.ascent, 0)
    }

    func testClimbDescendClimb() {
        var counter = AscentCounter()
        for step in 0...20 { counter.add(Double(step)) }        // up 20
        for step in 0...15 { counter.add(20 - Double(step)) }   // down 15
        for step in 0...10 { counter.add(5 + Double(step)) }    // up 10
        XCTAssertEqual(counter.ascent, 30, accuracy: 1)
    }

    func testRestartedSeriesDoesNotCountTheJump() {
        var counter = AscentCounter()
        for step in 0...10 { counter.add(Double(step) - 20) }   // -20 up to -10
        counter.breakSegment()
        for step in 0...5 { counter.add(Double(step)) }         // restarts at 0, up 5
        XCTAssertEqual(counter.ascent, 15, accuracy: 0.001)
    }
}

final class RideExtrasTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let metresPerDegree = GPSFix.earthRadius * .pi / 180

    private func fix(_ seconds: Double, north: Double, speed: Double) -> GPSFix {
        GPSFix(
            time: t0.addingTimeInterval(seconds),
            latitude: 10.65 + north / metresPerDegree,
            longitude: -61.5,
            horizontalAccuracy: 5,
            speed: speed
        )
    }

    func testAscentCountsOnlyWhileRiding() {
        var ride = RideSession()
        ride.addAltitude(0)
        ride.addAltitude(5)  // before the start
        ride.start(at: t0)
        for metres in 5...25 { ride.addAltitude(Double(metres)) }  // +20 riding
        ride.pause(at: t0.addingTimeInterval(60))
        for metres in 25...40 { ride.addAltitude(Double(metres)) }  // +15 paused
        ride.resume(at: t0.addingTimeInterval(120))
        for metres in 40...50 { ride.addAltitude(Double(metres)) }  // +10 riding
        XCTAssertEqual(ride.ascent, 30, accuracy: 0.001)
    }

    func testAveragePace() {
        var ride = RideSession()
        ride.start(at: t0)
        for s in 0...100 { ride.add(fix(Double(s), north: Double(s) * 5, speed: 5)) }  // 500 m in 100 s
        XCTAssertEqual(ride.averagePace(at: t0.addingTimeInterval(100)) ?? -1, 200, accuracy: 0.5)
    }

    func testRecordOfAFinishedRide() throws {
        var ride = RideSession()
        XCTAssertNil(ride.record())
        ride.start(at: t0)
        for s in 0...100 { ride.add(fix(Double(s), north: Double(s) * 5, speed: 5)) }
        ride.addHeartRate(150)
        ride.addAltitude(0)
        ride.addAltitude(12)
        ride.finish(at: t0.addingTimeInterval(100))

        let record = try XCTUnwrap(ride.record())
        XCTAssertEqual(record.distance, 500, accuracy: 1)
        XCTAssertEqual(record.movingTime, 100, accuracy: 0.001)
        XCTAssertEqual(record.ascent, 12, accuracy: 0.001)
        XCTAssertEqual(record.averageHeartRate, 150)
        XCTAssertEqual(record.averageSpeed ?? -1, 5, accuracy: 0.01)

        let decoded = try JSONDecoder().decode(RideRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
    }

    func testSnapshotFromBeforeAscentStillLoads() throws {
        // A ride.json written by build 10, which had no "ascent" field.
        let old = """
        {"state":{"riding":{}},"movingBefore":0,"distance":1234,"maxSpeed":5,\
        "heartRateTotal":0,"heartRateSamples":0,"maxHeartRate":0,"startedAt":800000000,"ridingSince":800000000}
        """
        let snapshot = try JSONDecoder().decode(RideSession.Snapshot.self, from: Data(old.utf8))
        let ride = RideSession(restoring: snapshot)
        XCTAssertEqual(ride.state, .riding)
        XCTAssertEqual(ride.distance, 1234)
        XCTAssertEqual(ride.ascent, 0)
    }

    func testAutoPauseCanBeSwitchedMidRide() {
        var ride = RideSession()
        ride.start(at: t0)
        ride.settings.autoPause = false
        for s in 0...20 { ride.add(fix(Double(s), north: 0, speed: 0)) }
        XCTAssertEqual(ride.state, .riding)
    }

    func testClockAndPaceFormats() {
        XCTAssertEqual(RideFormat.clock(0), "00:00")
        XCTAssertEqual(RideFormat.clock(65), "01:05")
        XCTAssertEqual(RideFormat.clock(3723), "1:02:03")
        XCTAssertEqual(RideFormat.pace(144), "02:24")
        XCTAssertEqual(RideFormat.pace(nil), "00:00")
        XCTAssertEqual(RideFormat.pace(1e9), "99:59")
        XCTAssertEqual(RideFormat.metres(85.6), "86")
    }
}
