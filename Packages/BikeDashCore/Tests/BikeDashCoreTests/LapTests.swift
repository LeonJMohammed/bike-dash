import XCTest
@testable import BikeDashCore

final class LapTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: Double) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func session(autoLap: Double?) -> RideSession {
        RideSession(settings: RideSession.Settings(autoPause: false, autoLapDistance: autoLap))
    }

    /// One sample a second from `from` to `to`, `speed` metres each.
    private func ride(_ session: inout RideSession, from: Int, to: Int, speed: Double = 10, bpm: Int? = nil, rpm: Double? = nil) {
        for second in from...to {
            session.addMovement(distance: speed, speed: speed, at: at(Double(second)))
            if let bpm { session.addHeartRate(bpm) }
            if let rpm { session.addCadence(rpm) }
        }
    }

    func testAutoLapEveryKilometre() {
        var ride = session(autoLap: 1000)
        ride.start(at: at(0))
        self.ride(&ride, from: 1, to: 250)  // 2.5 km in 250 s
        XCTAssertEqual(ride.laps.count, 2)
        XCTAssertEqual(ride.laps.map(\.trigger), [.auto, .auto])
        XCTAssertEqual(ride.laps[0].distance, 1000, accuracy: 0.001)
        XCTAssertEqual(ride.laps[0].movingTime, 100, accuracy: 0.001)
        XCTAssertEqual(ride.laps[1].distance, 1000, accuracy: 0.001)
        XCTAssertEqual(ride.laps[0].averageSpeed ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(ride.laps.map(\.number), [1, 2])
    }

    func testFinishAddsTheLastStretchAsALap() {
        var ride = session(autoLap: 1000)
        ride.start(at: at(0))
        self.ride(&ride, from: 1, to: 250)
        ride.finish(at: at(250))
        XCTAssertEqual(ride.laps.count, 3)
        XCTAssertEqual(ride.laps[2].trigger, .finish)
        XCTAssertEqual(ride.laps[2].distance, 500, accuracy: 0.001)
        XCTAssertEqual(ride.laps[2].movingTime, 50, accuracy: 0.001)
    }

    func testFinishRightOnAnAutoLapAddsNoEmptyLap() {
        var ride = session(autoLap: 1000)
        ride.start(at: at(0))
        self.ride(&ride, from: 1, to: 200)
        ride.finish(at: at(200))
        XCTAssertEqual(ride.laps.count, 2)
    }

    func testAutoLapCountsFromAManualLap() {
        var ride = session(autoLap: 1000)
        ride.start(at: at(0))
        self.ride(&ride, from: 1, to: 30)  // 300 m
        let manual = ride.lap(at: at(30))
        XCTAssertEqual(manual?.trigger, .manual)
        XCTAssertEqual(manual?.distance ?? 0, 300, accuracy: 0.001)
        self.ride(&ride, from: 31, to: 129)
        XCTAssertEqual(ride.laps.count, 1)
        self.ride(&ride, from: 130, to: 130)  // 1000 m since the manual lap
        XCTAssertEqual(ride.laps.count, 2)
        XCTAssertEqual(ride.laps[1].trigger, .auto)
        XCTAssertEqual(ride.laps[1].movingTime, 100, accuracy: 0.001)
    }

    func testPausedTimeIsNotInTheLap() {
        var ride = session(autoLap: 1000)
        ride.start(at: at(0))
        self.ride(&ride, from: 1, to: 50)  // 500 m
        ride.pause(at: at(50))
        ride.resume(at: at(110))  // a minute at the café
        self.ride(&ride, from: 111, to: 160)  // 500 m more: lap 1 done
        XCTAssertEqual(ride.laps.count, 1)
        XCTAssertEqual(ride.laps[0].movingTime, 100, accuracy: 0.001)
    }

    func testLapAveragesHeartRateAndCadenceWhilePedalling() {
        var ride = session(autoLap: 1000)
        ride.start(at: at(0))
        self.ride(&ride, from: 1, to: 50, bpm: 120, rpm: 80)
        self.ride(&ride, from: 51, to: 100, bpm: 140, rpm: 0)  // coasting: cadence 0
        XCTAssertEqual(ride.laps.count, 1)
        XCTAssertEqual(ride.laps[0].averageHeartRate, 130)
        XCTAssertEqual(ride.laps[0].averageCadence, 80)
        self.ride(&ride, from: 101, to: 200, bpm: 150, rpm: 90)
        XCTAssertEqual(ride.laps[1].averageHeartRate, 150)
        XCTAssertEqual(ride.laps[1].averageCadence, 90)
    }

    func testNoLapWithoutARideOrWithNothingInIt() {
        var ride = session(autoLap: nil)
        XCTAssertNil(ride.lap(at: at(0)))
        ride.start(at: at(0))
        self.ride(&ride, from: 1, to: 20)
        XCTAssertNotNil(ride.lap(at: at(20)))
        XCTAssertNil(ride.lap(at: at(20)))  // pressed twice
        XCTAssertEqual(ride.laps.count, 1)
    }

    func testNoAutoLapsWhenOff() {
        var ride = session(autoLap: nil)
        ride.start(at: at(0))
        self.ride(&ride, from: 1, to: 2000)  // 20 km
        XCTAssertTrue(ride.laps.isEmpty)
        ride.finish(at: at(2000))
        XCTAssertEqual(ride.laps.count, 1)
        XCTAssertTrue(ride.record()?.splits.isEmpty ?? false)  // one lap isn't worth listing
    }

    func testLapsSurviveASnapshotAndGoIntoTheRecord() throws {
        var ride = session(autoLap: 1000)
        ride.start(at: at(0))
        self.ride(&ride, from: 1, to: 150, bpm: 130, rpm: 85)
        let data = try JSONEncoder().encode(ride.snapshot)
        var restored = RideSession(
            restoring: try JSONDecoder().decode(RideSession.Snapshot.self, from: data),
            settings: RideSession.Settings(autoPause: false, autoLapDistance: 1000)
        )
        XCTAssertEqual(restored.laps, ride.laps)
        // The lap under way carries on from where it was: 500 m in, 500 m to go.
        self.ride(&restored, from: 151, to: 200)
        XCTAssertEqual(restored.laps.count, 2)
        XCTAssertEqual(restored.laps[1].distance, 1000, accuracy: 0.001)
        restored.finish(at: at(200))
        let record = try XCTUnwrap(restored.record())
        XCTAssertEqual(record.laps?.count, 2)
        XCTAssertEqual(record.splits.count, 2)
    }

    func testRidesSavedBeforeLapsStillLoad() throws {
        var ride = session(autoLap: 1000)
        ride.start(at: at(0))
        self.ride(&ride, from: 1, to: 150)
        ride.finish(at: at(150))

        // A snapshot and a record as saved before laps existed.
        let snapshot = try strip(["laps", "lapStart", "cadenceTotal", "cadenceSamples"], from: ride.snapshot)
        let oldRide = RideSession(restoring: try JSONDecoder().decode(RideSession.Snapshot.self, from: snapshot))
        XCTAssertTrue(oldRide.laps.isEmpty)
        XCTAssertEqual(oldRide.distance, 1500, accuracy: 0.001)

        let record = try strip(["laps"], from: try XCTUnwrap(ride.record()))
        let oldRecord = try JSONDecoder().decode(RideRecord.self, from: record)
        XCTAssertNil(oldRecord.laps)
        XCTAssertTrue(oldRecord.splits.isEmpty)
    }

    /// JSON for `value` without `keys`.
    private func strip<T: Encodable>(_ keys: [String], from value: T) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        for key in keys { object[key] = nil }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
