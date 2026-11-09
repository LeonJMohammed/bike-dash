import XCTest
@testable import BikeDashCore

final class RideSessionTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let metresPerDegree = GPSFix.earthRadius * .pi / 180

    private func at(_ seconds: Double) -> Date {
        t0.addingTimeInterval(seconds)
    }

    /// A fix `north` metres north of a point in Trinidad, `seconds` after t0.
    private func fix(_ seconds: Double, north: Double, speed: Double) -> GPSFix {
        GPSFix(
            time: at(seconds),
            latitude: 10.65 + north / metresPerDegree,
            longitude: -61.5,
            horizontalAccuracy: 5,
            speed: speed
        )
    }

    func testMovingTimeCountsWhileRiding() {
        var ride = RideSession()
        ride.start(at: at(0))
        XCTAssertEqual(ride.state, .riding)
        XCTAssertEqual(ride.movingTime(at: at(90)), 90, accuracy: 0.001)
        XCTAssertEqual(ride.elapsedTime(at: at(90)), 90, accuracy: 0.001)
    }

    func testManualPauseStopsTheClockAndDistanceAndNeverResumesByItself() {
        var ride = RideSession()
        ride.start(at: at(0))
        for s in 0...10 { ride.add(fix(Double(s), north: Double(s) * 5, speed: 5)) }  // 50 m
        ride.pause(at: at(10))
        for s in 11...40 { ride.add(fix(Double(s), north: Double(s) * 5, speed: 5)) }  // moving, paused
        XCTAssertEqual(ride.state, .paused(.manual))
        ride.resume(at: at(40))
        for s in 41...50 { ride.add(fix(Double(s), north: Double(s) * 5, speed: 5)) }  // 50 m
        XCTAssertEqual(ride.movingTime(at: at(50)), 20, accuracy: 0.001)
        XCTAssertEqual(ride.distance, 100, accuracy: 1)
    }

    func testTrafficLightAutoPausesAndResumes() {
        var ride = RideSession()
        ride.start(at: at(0))
        // 60 s at 5 m/s, 30 s stopped at the lights, 60 s at 5 m/s: 600 m in all.
        for s in 0...150 {
            let t = Double(s)
            let north = t <= 60 ? t * 5 : (t <= 90 ? 300 : 300 + (t - 90) * 5)
            let speed = (t > 60 && t <= 90) ? 0.0 : 5.0
            ride.add(fix(t, north: north, speed: speed))
            if s == 75 { XCTAssertEqual(ride.state, .paused(.auto)) }
        }
        XCTAssertEqual(ride.state, .riding)
        // About 64 s before the stop and 58 s after it (the pause starts once the
        // 3 s speed average drops, and the resume counts from when it rose).
        XCTAssertEqual(ride.movingTime(at: at(150)), 122, accuracy: 1)
        XCTAssertEqual(ride.distance, 600, accuracy: 10)
    }

    func testGPSDriftWhileStandingStillAddsNothing() {
        var ride = RideSession()
        ride.start(at: at(0))
        let wobble: [Double] = [0, 3, -2, 4, -3, 1, 2, -4, 0, 3, -1, 2]
        for (s, north) in wobble.enumerated() {
            ride.add(fix(Double(s), north: north, speed: 0.3))
        }
        XCTAssertEqual(ride.state, .paused(.auto))
        XCTAssertEqual(ride.distance, 0, accuracy: 0.001)
        XCTAssertEqual(ride.movingTime(at: at(11)), 0, accuracy: 0.001)
    }

    func testTunnelKeepsRidingAndBridgesTheGap() {
        var ride = RideSession()
        ride.start(at: at(0))
        for s in 0...30 { ride.add(fix(Double(s), north: Double(s) * 5, speed: 5)) }
        // No fixes for 30 s, then the signal comes back 155 m further on.
        for s in 61...70 { ride.add(fix(Double(s), north: Double(s) * 5, speed: 5)) }
        XCTAssertEqual(ride.state, .riding)
        XCTAssertEqual(ride.distance, 350, accuracy: 1)
        XCTAssertEqual(ride.movingTime(at: at(70)), 70, accuracy: 0.001)
    }

    func testPausingDuringAnAutoPauseMakesItManual() {
        var ride = RideSession()
        ride.start(at: at(0))
        for s in 0...6 { ride.add(fix(Double(s), north: 0, speed: 0)) }
        XCTAssertEqual(ride.state, .paused(.auto))
        ride.pause(at: at(6))
        for s in 7...20 { ride.add(fix(Double(s), north: Double(s - 6) * 5, speed: 5)) }
        XCTAssertEqual(ride.state, .paused(.manual))
    }

    func testAutoPauseCanBeTurnedOff() {
        var ride = RideSession(settings: RideSession.Settings(autoPause: false))
        ride.start(at: at(0))
        for s in 0...20 { ride.add(fix(Double(s), north: 0, speed: 0)) }
        XCTAssertEqual(ride.state, .riding)
    }

    func testFinishFreezesTheClocks() {
        var ride = RideSession()
        ride.start(at: at(0))
        ride.finish(at: at(100))
        XCTAssertEqual(ride.state, .finished)
        XCTAssertEqual(ride.movingTime(at: at(500)), 100, accuracy: 0.001)
        XCTAssertEqual(ride.elapsedTime(at: at(500)), 100, accuracy: 0.001)
    }

    func testHeartRateCountsOnlyWhileRiding() {
        var ride = RideSession()
        ride.addHeartRate(150)  // before the start
        ride.start(at: at(0))
        ride.addHeartRate(120)
        ride.addHeartRate(140)
        ride.pause(at: at(10))
        ride.addHeartRate(180)  // while paused
        XCTAssertEqual(ride.averageHeartRate, 130)
        XCTAssertEqual(ride.maxHeartRate, 140)
    }

    func testSnapshotRoundTrip() throws {
        var ride = RideSession()
        ride.start(at: at(0))
        for s in 0...10 { ride.add(fix(Double(s), north: Double(s) * 5, speed: 5)) }
        ride.addHeartRate(130)
        ride.pause(at: at(10))

        let data = try JSONEncoder().encode(ride.snapshot)
        let restored = RideSession(restoring: try JSONDecoder().decode(RideSession.Snapshot.self, from: data))
        XCTAssertEqual(restored.snapshot, ride.snapshot)
        XCTAssertEqual(restored.state, .paused(.manual))
        XCTAssertEqual(restored.movingTime(at: at(50)), 10, accuracy: 0.001)
        XCTAssertEqual(restored.averageHeartRate, 130)
    }

    func testResetGoesBackToIdle() {
        var ride = RideSession()
        ride.start(at: at(0))
        ride.finish(at: at(10))
        ride.reset()
        XCTAssertEqual(ride.state, .idle)
        XCTAssertEqual(ride.distance, 0)
        XCTAssertEqual(ride.movingTime(at: at(20)), 0)
    }

    // MARK: - Wheel sensor

    func testWheelSensorPausesFromTheLastRevolutionAndResumesWhenTheWheelTurns() {
        var ride = RideSession(settings: .wheelSensor(autoPause: true))
        ride.start(at: at(0))
        for s in 1...60 { ride.addMovement(distance: 5, speed: 5, at: at(Double(s))) }  // 300 m
        // The wheel last turned at 60; its speed reads 0 three seconds later.
        ride.addMovement(distance: 0, speed: 5, at: at(62), stillSince: at(60))
        XCTAssertEqual(ride.state, .riding)
        ride.addMovement(distance: 0, speed: 0, at: at(64), stillSince: at(60))
        XCTAssertEqual(ride.state, .paused(.auto))
        XCTAssertEqual(ride.movingTime(at: at(90)), 60, accuracy: 0.001)
        // Off again at 90: the first revolution gives no speed yet, the second does.
        ride.addMovement(distance: 2.1, speed: 0, at: at(90), stillSince: at(90))
        XCTAssertEqual(ride.state, .paused(.auto))
        ride.addMovement(distance: 2.1, speed: 2.1, at: at(91))
        XCTAssertEqual(ride.state, .riding)
        XCTAssertEqual(ride.distance, 302.1, accuracy: 0.001)
        XCTAssertEqual(ride.movingTime(at: at(100)), 69, accuracy: 0.001)
    }

    func testWheelSensorDistanceCountsOnlyWhileRiding() {
        var ride = RideSession(settings: .wheelSensor(autoPause: false))
        ride.addMovement(distance: 100, speed: 5, at: at(0))  // before the start
        ride.start(at: at(1))
        ride.addMovement(distance: 50, speed: 8, at: at(10))
        ride.pause(at: at(10))
        ride.addMovement(distance: 30, speed: 3, at: at(20))  // walking the bike, paused
        XCTAssertEqual(ride.distance, 50, accuracy: 0.001)
        XCTAssertEqual(ride.maxSpeed, 8, accuracy: 0.001)
    }

    func testStartingWhileStandingStillPausesWithNoMovingTime() {
        var ride = RideSession(settings: .wheelSensor(autoPause: true))
        ride.start(at: at(100))
        // The wheel last turned long before the start.
        ride.addMovement(distance: 0, speed: 0, at: at(101), stillSince: at(40))
        XCTAssertEqual(ride.state, .paused(.auto))
        XCTAssertEqual(ride.movingTime(at: at(120)), 0, accuracy: 0.001)
    }

    func testBreakingTheGPSTrackSkipsTheStretchTheSensorCovered() {
        var ride = RideSession()
        ride.start(at: at(0))
        for s in 0...10 { ride.add(fix(Double(s), north: Double(s) * 5, speed: 5)) }  // 50 m by GPS
        ride.breakGPSTrack()
        ride.addMovement(distance: 100, speed: 5, at: at(30))  // 100 m by the sensor
        for s in 31...40 { ride.add(fix(Double(s), north: 500 + Double(s - 31) * 5, speed: 5)) }  // 45 m by GPS
        XCTAssertEqual(ride.distance, 195, accuracy: 1)
    }
}

final class RideFormatTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(RideFormat.duration(0), "0:00")
        XCTAssertEqual(RideFormat.duration(59.9), "0:59")
        XCTAssertEqual(RideFormat.duration(61), "1:01")
        XCTAssertEqual(RideFormat.duration(3600), "1:00:00")
        XCTAssertEqual(RideFormat.duration(3723), "1:02:03")
    }

    func testSpeedAndDistance() {
        XCTAssertEqual(RideFormat.speed(5), "18.0")
        XCTAssertEqual(RideFormat.distance(1234), "1.23")
        XCTAssertEqual(RideFormat.distance(1500), "1.50")
    }

    func testCadence() {
        XCTAssertEqual(RideFormat.cadence(87.6), "88")
        XCTAssertEqual(RideFormat.cadence(0), "0")
    }
}
