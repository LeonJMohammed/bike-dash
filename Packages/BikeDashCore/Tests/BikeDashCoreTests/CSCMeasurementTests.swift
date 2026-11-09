import XCTest
@testable import BikeDashCore

final class CSCMeasurementTests: XCTestCase {
    func testWheelOnly() throws {
        // Flags 0x01; 0x00012345 = 74,565 revolutions; event time 0x0400 = 1,024 (1 s).
        let packet = try XCTUnwrap(CSCMeasurement(data: Data([0x01, 0x45, 0x23, 0x01, 0x00, 0x00, 0x04])))
        XCTAssertEqual(packet.wheel, CSCMeasurement.Wheel(revolutions: 74_565, eventTime: 1_024))
        XCTAssertNil(packet.crank)
        XCTAssertEqual(packet.kind, .speed)
    }

    func testCrankOnly() throws {
        // Flags 0x02; 300 revolutions (0x012C); event time 0xFFFF.
        let packet = try XCTUnwrap(CSCMeasurement(data: Data([0x02, 0x2C, 0x01, 0xFF, 0xFF])))
        XCTAssertNil(packet.wheel)
        XCTAssertEqual(packet.crank, CSCMeasurement.Crank(revolutions: 300, eventTime: 65_535))
        XCTAssertEqual(packet.kind, .cadence)
    }

    func testWheelAndCrank() throws {
        // Wheel: 0xFFFFFFFF revolutions at 0x1234. Crank: 0x0102 at 0xABCD.
        let data = Data([0x03, 0xFF, 0xFF, 0xFF, 0xFF, 0x34, 0x12, 0x02, 0x01, 0xCD, 0xAB])
        let packet = try XCTUnwrap(CSCMeasurement(data: data))
        XCTAssertEqual(packet.wheel, CSCMeasurement.Wheel(revolutions: UInt32.max, eventTime: 0x1234))
        XCTAssertEqual(packet.crank, CSCMeasurement.Crank(revolutions: 0x0102, eventTime: 0xABCD))
        XCTAssertEqual(packet.kind, .speedAndCadence)
    }

    func testTruncatedPacketsAreRejected() {
        XCTAssertNil(CSCMeasurement(data: Data()))
        XCTAssertNil(CSCMeasurement(data: Data([0x01, 0x01, 0x00, 0x00, 0x00, 0x00])))  // wheel, a byte short
        XCTAssertNil(CSCMeasurement(data: Data([0x02, 0x01, 0x00, 0x00])))              // crank, a byte short
        XCTAssertNil(CSCMeasurement(data: Data([0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x01, 0x00, 0x00])))
    }

    func testFlagsWithNoDataGiveAnEmptyMeasurement() throws {
        let packet = try XCTUnwrap(CSCMeasurement(data: Data([0x00])))
        XCTAssertNil(packet.wheel)
        XCTAssertNil(packet.crank)
        XCTAssertNil(packet.kind)
    }

    func testUnknownFlagBitsAndTrailingBytesAreIgnored() throws {
        let packet = try XCTUnwrap(CSCMeasurement(data: Data([0x82, 0x05, 0x00, 0x00, 0x08, 0xEE])))
        XCTAssertEqual(packet.crank, CSCMeasurement.Crank(revolutions: 5, eventTime: 2_048))
        XCTAssertNil(packet.wheel)
    }

    func testDataSliceWithNonZeroStartIndex() {
        let slice = Data([0xFF, 0x02, 0x07, 0x00, 0x00, 0x02]).dropFirst()
        XCTAssertEqual(CSCMeasurement(data: slice)?.crank, CSCMeasurement.Crank(revolutions: 7, eventTime: 512))
    }

    func testBuiltMeasurementsSetTheirFlags() {
        XCTAssertEqual(CSCMeasurement(wheel: .init(revolutions: 1, eventTime: 2), crank: nil).flags, 0x01)
        XCTAssertEqual(CSCMeasurement(wheel: nil, crank: .init(revolutions: 1, eventTime: 2)).flags, 0x02)
    }

    func testWhatEachKindSends() {
        XCTAssertTrue(CSCSensorKind.speed.sendsWheel)
        XCTAssertFalse(CSCSensorKind.speed.sendsCrank)
        XCTAssertFalse(CSCSensorKind.cadence.sendsWheel)
        XCTAssertTrue(CSCSensorKind.cadence.sendsCrank)
        XCTAssertTrue(CSCSensorKind.speedAndCadence.sendsWheel)
        XCTAssertTrue(CSCSensorKind.speedAndCadence.sendsCrank)
    }
}

final class RevolutionCounterTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: Double) -> Date {
        t0.addingTimeInterval(seconds)
    }

    /// The sensor's clock for `seconds`: 1/1024 s ticks, wrapping every 64 s.
    private func ticks(_ seconds: Double) -> UInt16 {
        UInt16(truncatingIfNeeded: Int((seconds * 1024).rounded()))
    }

    func testFirstReadingIsABaseline() {
        var wheel = RevolutionCounter.wheel()
        XCTAssertEqual(wheel.add(revolutions: 500, eventTime: 1_000, at: at(0)), .init(outcome: .baseline, revolutions: 0))
        XCTAssertEqual(wheel.rate(at: at(0)), 0)
    }

    func testFirstRevolutionAfterConnectingCountsButGivesNoRate() {
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: 100, eventTime: ticks(10), at: at(0))
        XCTAssertEqual(wheel.add(revolutions: 101, eventTime: ticks(10.8), at: at(1)), .init(outcome: .restart, revolutions: 1))
        XCTAssertEqual(wheel.rate(at: at(1)), 0)
    }

    func testSteadyWheelGivesSpeed() {
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: 100, eventTime: ticks(10), at: at(0))
        wheel.add(revolutions: 103, eventTime: ticks(10.75), at: at(1))
        XCTAssertEqual(wheel.add(revolutions: 107, eventTime: ticks(11.75), at: at(2)), .init(outcome: .counted, revolutions: 4))
        XCTAssertEqual(wheel.rate(at: at(2)), 4, accuracy: 0.001)
        // 4 revolutions a second on a 2,105 mm wheel is 30.3 km/h.
        XCTAssertEqual(wheel.rate(at: at(2)) * 2.105 * 3.6, 30.31, accuracy: 0.01)
        XCTAssertEqual(wheel.lastInterval, .init(revolutions: 4, seconds: 1))
    }

    func testCadence() {
        var crank = RevolutionCounter.crank()
        crank.add(revolutions: 10, eventTime: ticks(5), at: at(0))
        crank.add(revolutions: 11, eventTime: ticks(5.7), at: at(1))
        crank.add(revolutions: 12, eventTime: ticks(6.4), at: at(2))  // 0.7 s a turn
        XCTAssertEqual(crank.rate(at: at(2)) * 60, 85.7, accuracy: 0.1)
    }

    func testEventTimeRollover() {
        // The sensor's clock wraps from 65,535 to 0 every 64 s.
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: 1, eventTime: 63_000, at: at(0))
        wheel.add(revolutions: 2, eventTime: 64_000, at: at(1))
        // 65,536 - 64,000 + 488 = 2,024 ticks.
        XCTAssertEqual(wheel.add(revolutions: 4, eventTime: 488, at: at(2)), .init(outcome: .counted, revolutions: 2))
        XCTAssertEqual(wheel.rate(at: at(2)), 2 / (2_024.0 / 1_024), accuracy: 0.0001)
    }

    func testCrankCountRollover() {
        var crank = RevolutionCounter.crank()
        crank.add(revolutions: 65_534, eventTime: ticks(1), at: at(0))
        crank.add(revolutions: 65_535, eventTime: ticks(1.7), at: at(1))
        XCTAssertEqual(crank.add(revolutions: 0, eventTime: ticks(2.4), at: at(2)), .init(outcome: .counted, revolutions: 1))
        XCTAssertEqual(crank.rate(at: at(2)) * 60, 85.7, accuracy: 0.1)
        XCTAssertEqual(crank.add(revolutions: 1, eventTime: ticks(3.1), at: at(3)).revolutions, 1)
    }

    func testWheelCountRollover() {
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: UInt32.max - 1, eventTime: ticks(1), at: at(0))
        wheel.add(revolutions: UInt32.max, eventTime: ticks(1.5), at: at(1))
        XCTAssertEqual(wheel.add(revolutions: 2, eventTime: ticks(2.25), at: at(2)), .init(outcome: .counted, revolutions: 3))
        XCTAssertEqual(wheel.rate(at: at(2)), 4, accuracy: 0.001)
    }

    func testRepeatedEventTimeIsIgnored() {
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: 10, eventTime: ticks(1), at: at(0))
        wheel.add(revolutions: 11, eventTime: ticks(1.5), at: at(0.5))
        wheel.add(revolutions: 12, eventTime: ticks(2), at: at(1))  // 2 revolutions a second
        // Between revolutions the sensor repeats its last values.
        XCTAssertEqual(wheel.add(revolutions: 12, eventTime: ticks(2), at: at(2)), .init(outcome: .duplicate, revolutions: 0))
        XCTAssertEqual(wheel.add(revolutions: 12, eventTime: ticks(2), at: at(3)).outcome, .duplicate)
        XCTAssertEqual(wheel.duplicates, 2)
        XCTAssertEqual(wheel.rate(at: at(3)), 2, accuracy: 0.001)
    }

    func testSpeedReadsZeroThreeSecondsAfterTheLastRevolution() {
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: 10, eventTime: ticks(1), at: at(0))
        wheel.add(revolutions: 11, eventTime: ticks(1.5), at: at(0.5))
        wheel.add(revolutions: 12, eventTime: ticks(2), at: at(1))
        // Repeats keep arriving, but they don't keep the speed alive.
        for s in 2...6 { wheel.add(revolutions: 12, eventTime: ticks(2), at: at(Double(s))) }
        XCTAssertEqual(wheel.rate(at: at(3.9)), 2, accuracy: 0.001)
        XCTAssertEqual(wheel.rate(at: at(4.1)), 0)
        XCTAssertEqual(wheel.lastRevolutionAt, at(1))
    }

    func testCountChangeWithTheSameEventTimeWaitsForTheNextEvent() {
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: 10, eventTime: ticks(1), at: at(0))
        // The count moved but the event time didn't: ignored...
        XCTAssertEqual(wheel.add(revolutions: 11, eventTime: ticks(1), at: at(0.5)).outcome, .duplicate)
        // ...and nothing is lost, because the next event carries both revolutions.
        XCTAssertEqual(wheel.add(revolutions: 12, eventTime: ticks(2), at: at(1)).revolutions, 2)
    }

    func testEventTimeMovingWithoutARevolutionIsIgnored() {
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: 10, eventTime: ticks(1), at: at(0))
        XCTAssertEqual(wheel.add(revolutions: 10, eventTime: ticks(2), at: at(1)).outcome, .duplicate)
    }

    func testAfterAStopTheFirstRevolutionStartsAfresh() {
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: 10, eventTime: ticks(1), at: at(0))
        wheel.add(revolutions: 11, eventTime: ticks(1.5), at: at(0.5))
        wheel.add(revolutions: 12, eventTime: ticks(2), at: at(1))
        // 70 s at the lights: longer than the 64 s the sensor's clock takes to wrap.
        XCTAssertEqual(wheel.rate(at: at(30)), 0)
        // The first turn says the wheel stood still from its last turn, at 1 s.
        XCTAssertEqual(
            wheel.add(revolutions: 13, eventTime: ticks(72), at: at(72)),
            .init(outcome: .restart, revolutions: 1, stoppedSince: at(1))
        )
        XCTAssertEqual(wheel.rate(at: at(72)), 0)
        XCTAssertEqual(wheel.add(revolutions: 14, eventTime: ticks(73), at: at(73)), .init(outcome: .counted, revolutions: 1))
        XCTAssertEqual(wheel.rate(at: at(73)), 1, accuracy: 0.001)
    }

    func testShortDropoutCatchesUpTheDistance() {
        // Disconnected for 6 s while riding: the first packet back carries
        // every revolution since, and it wasn't a stop.
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: 100, eventTime: ticks(1), at: at(0))
        wheel.add(revolutions: 104, eventTime: ticks(2), at: at(1))
        XCTAssertEqual(wheel.add(revolutions: 128, eventTime: ticks(8), at: at(7)), .init(outcome: .restart, revolutions: 24))
    }

    func testAShortPauseBetweenTurnsIsAStopToo() {
        // 4 s for one turn is slower than the speed can show (one turn in 3 s).
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: 10, eventTime: ticks(1), at: at(0))
        wheel.add(revolutions: 11, eventTime: ticks(1.5), at: at(0.5))
        XCTAssertEqual(wheel.add(revolutions: 12, eventTime: ticks(5.5), at: at(4.5)).stoppedSince, at(0.5))
    }

    func testImpossibleJumpIsRejected() {
        // The sensor restarted (a new battery) and counts from 0 again.
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: 5_000, eventTime: ticks(1), at: at(0))
        wheel.add(revolutions: 5_004, eventTime: ticks(2), at: at(1))
        XCTAssertEqual(wheel.add(revolutions: 3, eventTime: ticks(0.5), at: at(2)), .init(outcome: .rejected, revolutions: 0))
        XCTAssertEqual(wheel.rejections, 1)
        // Counting carries on from the new numbers.
        XCTAssertEqual(wheel.add(revolutions: 6, eventTime: ticks(1.25), at: at(3)), .init(outcome: .restart, revolutions: 3))
        XCTAssertEqual(wheel.add(revolutions: 10, eventTime: ticks(2.25), at: at(4)), .init(outcome: .counted, revolutions: 4))
    }

    func testImpossibleCrankJumpIsRejected() {
        var crank = RevolutionCounter.crank()
        crank.add(revolutions: 4_000, eventTime: ticks(1), at: at(0))
        XCTAssertEqual(crank.add(revolutions: 2, eventTime: ticks(1.5), at: at(1)).outcome, .rejected)
    }

    func testImpossibleRateKeepsTheLastRateButCountsTheRevolutions() {
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: 10, eventTime: 1_000, at: at(0))
        wheel.add(revolutions: 11, eventTime: 1_512, at: at(0.5))
        wheel.add(revolutions: 12, eventTime: 2_024, at: at(1))  // 2 a second
        // Three revolutions 2 ticks apart would be 1,500 a second: a glitch in the event time.
        XCTAssertEqual(wheel.add(revolutions: 15, eventTime: 2_026, at: at(2)), .init(outcome: .counted, revolutions: 3))
        XCTAssertEqual(wheel.rate(at: at(2)), 2, accuracy: 0.001)
    }

    func testResetStartsAgainWithoutAddingDistance() {
        var wheel = RevolutionCounter.wheel()
        wheel.add(revolutions: 10, eventTime: ticks(1), at: at(0))
        wheel.add(revolutions: 12, eventTime: ticks(2), at: at(1))
        wheel.reset()
        XCTAssertEqual(wheel.add(revolutions: 50, eventTime: ticks(20), at: at(20)), .init(outcome: .baseline, revolutions: 0))
        XCTAssertEqual(wheel.rate(at: at(20)), 0)
    }
}
