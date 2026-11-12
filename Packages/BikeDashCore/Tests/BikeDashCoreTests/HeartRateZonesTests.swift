import XCTest
@testable import BikeDashCore

final class HeartRateZonesTests: XCTestCase {
    private let zones = HeartRateZones(maxHeartRate: 190)

    func testZoneEdgesAreTenPercentSteps() {
        // 50, 60, 70, 80, 90 and 100% of 190.
        XCTAssertEqual((1...6).map { zones.lowerBound(of: $0) }, [95, 114, 133, 152, 171, 190])
    }

    func testZoneForHeartRate() {
        XCTAssertEqual(zones.zone(for: 94), 0)
        XCTAssertEqual(zones.zone(for: 95), 1)
        XCTAssertEqual(zones.zone(for: 113), 1)
        XCTAssertEqual(zones.zone(for: 114), 2)
        XCTAssertEqual(zones.zone(for: 151), 3)
        XCTAssertEqual(zones.zone(for: 152), 4)
        XCTAssertEqual(zones.zone(for: 171), 5)
        XCTAssertEqual(zones.zone(for: 205), 5)
    }

    func testPositionInsideTheZone() {
        XCTAssertEqual(zones.position(of: 95, in: 1), 0, accuracy: 0.001)
        XCTAssertEqual(zones.position(of: 142, in: 3), 0.474, accuracy: 0.001)  // (142 - 133) / 19
        XCTAssertEqual(zones.position(of: 120, in: 1), 1)  // above the zone: its top
        XCTAssertEqual(zones.position(of: 90, in: 1), 0)   // below the zone: its bottom
        XCTAssertEqual(zones.position(of: 80, in: 0), 0)
    }

    func testMaxHeartRateIsKeptSensible() {
        XCTAssertEqual(HeartRateZones(maxHeartRate: 50).maxHeartRate, 120)
        XCTAssertEqual(HeartRateZones(maxHeartRate: 300).maxHeartRate, 230)
    }
}

final class ZoneTrackerTests: XCTestCase {
    private let zones = HeartRateZones(maxHeartRate: 190)  // zone 4 starts at 152

    func testFirstReadingSetsTheZoneWithoutCountingAsAChange() {
        var tracker = ZoneTracker()
        XCTAssertFalse(tracker.update(bpm: 140, zones: zones))
        XCTAssertEqual(tracker.zone, 3)
    }

    func testWobblingOnABoundaryDoesNotFlicker() {
        var tracker = ZoneTracker()
        tracker.update(bpm: 150, zones: zones)
        for bpm in [151, 152, 153, 152, 151, 153] {
            XCTAssertFalse(tracker.update(bpm: bpm, zones: zones))
        }
        XCTAssertEqual(tracker.zone, 3)
        // Clearly over the line: 2 bpm past 152.
        XCTAssertTrue(tracker.update(bpm: 154, zones: zones))
        XCTAssertEqual(tracker.zone, 4)
        // Back down needs 2 bpm under 152 too.
        XCTAssertFalse(tracker.update(bpm: 151, zones: zones))
        XCTAssertTrue(tracker.update(bpm: 149, zones: zones))
        XCTAssertEqual(tracker.zone, 3)
    }

    func testABigJumpGoesStraightToTheNewZone() {
        var tracker = ZoneTracker()
        tracker.update(bpm: 100, zones: zones)
        XCTAssertTrue(tracker.update(bpm: 175, zones: zones))
        XCTAssertEqual(tracker.zone, 5)
    }

    func testBelowZoneOneAndBack() {
        var tracker = ZoneTracker()
        tracker.update(bpm: 80, zones: zones)
        XCTAssertEqual(tracker.zone, 0)
        XCTAssertFalse(tracker.update(bpm: 96, zones: zones))  // 1 bpm into zone 1: not yet
        XCTAssertTrue(tracker.update(bpm: 97, zones: zones))
        XCTAssertEqual(tracker.zone, 1)
    }

    func testResetStartsAgain() {
        var tracker = ZoneTracker()
        tracker.update(bpm: 140, zones: zones)
        tracker.reset()
        XCTAssertNil(tracker.zone)
        XCTAssertFalse(tracker.update(bpm: 180, zones: zones))
        XCTAssertEqual(tracker.zone, 5)
    }
}
