import XCTest
@testable import BikeDashCore

final class RideActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: Double) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func state(speed: Double = 8, bpm: Int = 140, distance: Double = 1000, paused: Bool = false) -> RideActivityState {
        RideActivityState(
            speed: speed, heartRate: bpm, cadence: 88, distance: distance,
            movingTime: 120, clockStart: paused ? nil : at(-120), paused: paused
        )
    }

    func testStateFromARide() {
        var ride = RideSession()
        ride.start(at: at(0))
        ride.addMovement(distance: 500, speed: 5, at: at(100))
        let riding = RideActivityState(session: ride, speed: 5, heartRate: 150, cadence: 87.6, at: at(100))
        XCTAssertEqual(riding.distance, 500)
        XCTAssertEqual(riding.movingTime, 100, accuracy: 0.001)
        XCTAssertEqual(riding.clockStart, at(0))  // the clock counts up from the start
        XCTAssertEqual(riding.cadence, 88)
        XCTAssertFalse(riding.paused)
        XCTAssertEqual(riding.speedText, "18.0")
        XCTAssertEqual(riding.distanceText, "0.50")

        ride.pause(at: at(100))
        let paused = RideActivityState(session: ride, speed: nil, heartRate: nil, cadence: nil, at: at(130))
        XCTAssertTrue(paused.paused)
        XCTAssertNil(paused.clockStart)
        XCTAssertEqual(paused.movingTimeText, "01:40")
        XCTAssertEqual(paused.speedText, "--")
    }

    func testFirstUpdateGoesOutThenAtMostEveryFiveSeconds() {
        var throttle = LiveActivityThrottle()
        XCTAssertTrue(throttle.shouldSend(state(), at: at(0)))
        XCTAssertFalse(throttle.shouldSend(state(speed: 9), at: at(4.9)))
        XCTAssertTrue(throttle.shouldSend(state(speed: 9), at: at(5)))
    }

    func testNothingNewIsNotSent() {
        var throttle = LiveActivityThrottle()
        throttle.shouldSend(state(), at: at(0))
        // Same numbers on screen (8 m/s and 8.001 m/s are both 28.8 km/h).
        XCTAssertFalse(throttle.shouldSend(state(speed: 8.001), at: at(30)))
        XCTAssertTrue(throttle.shouldSend(state(bpm: 141), at: at(31)))
    }

    func testPauseAndResumeGoOutAtOnce() {
        var throttle = LiveActivityThrottle()
        throttle.shouldSend(state(), at: at(0))
        XCTAssertTrue(throttle.shouldSend(state(paused: true), at: at(1)))
        XCTAssertTrue(throttle.shouldSend(state(paused: false), at: at(2)))
    }

    func testResetSendsTheNextOneAtOnce() {
        var throttle = LiveActivityThrottle()
        throttle.shouldSend(state(), at: at(0))
        throttle.reset()
        XCTAssertTrue(throttle.shouldSend(state(), at: at(1)))
    }
}
