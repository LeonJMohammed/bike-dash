import XCTest
@testable import BikeDashCore

final class HeartRateMeasurementTests: XCTestCase {
    func testEightBitHeartRate() throws {
        let packet = try XCTUnwrap(HeartRateMeasurement(data: Data([0x00, 72])))
        XCTAssertEqual(packet.bpm, 72)
        XCTAssertEqual(packet.sensorContact, .notSupported)
        XCTAssertNil(packet.energyExpended)
        XCTAssertTrue(packet.rrIntervals.isEmpty)
    }

    func testSixteenBitHeartRate() throws {
        let packet = try XCTUnwrap(HeartRateMeasurement(data: Data([0x01, 0x2C, 0x01])))
        XCTAssertEqual(packet.bpm, 300)
    }

    func testSensorContactBits() {
        XCTAssertEqual(HeartRateMeasurement(data: Data([0x06, 60]))?.sensorContact, .detected)
        XCTAssertEqual(HeartRateMeasurement(data: Data([0x04, 60]))?.sensorContact, .notDetected)
        XCTAssertEqual(HeartRateMeasurement(data: Data([0x02, 60]))?.sensorContact, .notSupported)
    }

    func testEnergyAndRRIntervals() throws {
        // Flags: energy (0x08) + RR (0x10). 140 bpm, 258 kJ, RR 1024 and 512 (1.0 s, 0.5 s).
        let data = Data([0x18, 140, 0x02, 0x01, 0x00, 0x04, 0x00, 0x02])
        let packet = try XCTUnwrap(HeartRateMeasurement(data: data))
        XCTAssertEqual(packet.bpm, 140)
        XCTAssertEqual(packet.energyExpended, 258)
        XCTAssertEqual(packet.rrIntervals, [1.0, 0.5])
    }

    func testRRIntervalsWithoutEnergy() throws {
        let packet = try XCTUnwrap(HeartRateMeasurement(data: Data([0x10, 90, 0x00, 0x03])))
        XCTAssertNil(packet.energyExpended)
        XCTAssertEqual(packet.rrIntervals, [0.75])
    }

    func testOddTrailingByteIsIgnored() throws {
        let packet = try XCTUnwrap(HeartRateMeasurement(data: Data([0x10, 90, 0x00, 0x04, 0x05])))
        XCTAssertEqual(packet.rrIntervals, [1.0])
    }

    func testTruncatedPacketsAreRejected() {
        XCTAssertNil(HeartRateMeasurement(data: Data()))
        XCTAssertNil(HeartRateMeasurement(data: Data([0x00])))
        XCTAssertNil(HeartRateMeasurement(data: Data([0x01, 0x2C])))
    }

    func testDataSliceWithNonZeroStartIndex() {
        let slice = Data([0xFF, 0x00, 75]).dropFirst()
        XCTAssertEqual(HeartRateMeasurement(data: slice)?.bpm, 75)
    }
}
