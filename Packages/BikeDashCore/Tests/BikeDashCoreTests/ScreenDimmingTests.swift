import XCTest
@testable import BikeDashCore

final class ScreenDimmingTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: Double) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func riding(_ dimming: ScreenDimming, _ seconds: Double) -> Bool {
        dimming.shouldDim(at: at(seconds), enabled: true, rideActive: true, appActive: true)
    }

    func testDimsAfterTenQuietSeconds() {
        let dimming = ScreenDimming(now: at(0))
        XCTAssertFalse(riding(dimming, 9.9))
        XCTAssertTrue(riding(dimming, 10))
    }

    func testATouchStartsTheTenSecondsAgain() {
        var dimming = ScreenDimming(now: at(0))
        XCTAssertTrue(riding(dimming, 12))
        dimming.wake(at: at(12))
        XCTAssertFalse(riding(dimming, 21))
        XCTAssertTrue(riding(dimming, 22))
    }

    func testAnOlderWakeDoesNotShortenANewerOne() {
        var dimming = ScreenDimming(now: at(0))
        dimming.wake(at: at(20))
        dimming.wake(at: at(15))
        XCTAssertFalse(riding(dimming, 29))
    }

    func testOnlyDuringARideWithTheAppInFrontAndTheSettingOn() {
        let dimming = ScreenDimming(now: at(0))
        XCTAssertFalse(dimming.shouldDim(at: at(60), enabled: false, rideActive: true, appActive: true))
        XCTAssertFalse(dimming.shouldDim(at: at(60), enabled: true, rideActive: false, appActive: true))
        XCTAssertFalse(dimming.shouldDim(at: at(60), enabled: true, rideActive: true, appActive: false))
    }

    func testDimsABrightScreenButLeavesADarkerOneAlone() {
        XCTAssertEqual(ScreenDimming.target(current: 0.8, level: 0.2), 0.2)
        XCTAssertNil(ScreenDimming.target(current: 0.15, level: 0.2))
        XCTAssertNil(ScreenDimming.target(current: 0.2, level: 0.2))
    }

    func testTheLevelStaysInRange() {
        XCTAssertEqual(ScreenDimming.target(current: 1, level: 0), 0.05)
        XCTAssertEqual(ScreenDimming.target(current: 1, level: 0.9), 0.6)
    }
}
