import XCTest
@testable import BikeDashCore

final class SpeedSourcePickerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: Double) -> Date {
        t0.addingTimeInterval(seconds)
    }

    /// One update while riding.
    @discardableResult
    private func riding(_ picker: inout SpeedSourcePicker, sensor: Bool, at seconds: Double) -> Bool {
        picker.update(sensorConnected: sensor, ride: .riding, pedalling: false, at: at(seconds))
    }

    func testGPSPreferenceAlwaysUsesGPS() {
        var picker = SpeedSourcePicker(preference: .gps)
        XCTAssertEqual(picker.source, .gps)
        riding(&picker, sensor: true, at: 0)
        XCTAssertEqual(picker.source, .gps)
    }

    func testNoGPSWithoutARideUnderWay() {
        var picker = SpeedSourcePicker()
        for s in 0...60 {
            picker.update(sensorConnected: false, ride: .idle, pedalling: false, at: at(Double(s)))
        }
        XCTAssertEqual(picker.source, .sensor)
    }

    func testFallsBackAfterTenSecondsWithoutTheSensor() {
        var picker = SpeedSourcePicker()
        riding(&picker, sensor: true, at: 0)
        XCTAssertFalse(riding(&picker, sensor: false, at: 1))
        XCTAssertFalse(riding(&picker, sensor: false, at: 10.9))
        XCTAssertEqual(picker.secondsUntilFallback(at: at(10.9)) ?? -1, 0.1, accuracy: 0.001)
        XCTAssertTrue(riding(&picker, sensor: false, at: 11))
        XCTAssertEqual(picker.source, .gpsFallback)
        XCTAssertNil(picker.secondsUntilFallback(at: at(11)))
    }

    func testAShortDropoutDoesNotStartGPS() {
        var picker = SpeedSourcePicker()
        for s in 0..<8 { riding(&picker, sensor: false, at: Double(s)) }
        riding(&picker, sensor: true, at: 8)
        for s in 9..<17 { riding(&picker, sensor: false, at: Double(s)) }
        XCTAssertEqual(picker.source, .sensor)
    }

    func testHandsBackOnceTheSensorHasBeenBackFiveSeconds() {
        var picker = SpeedSourcePicker()
        riding(&picker, sensor: false, at: 0)
        riding(&picker, sensor: false, at: 10)
        XCTAssertEqual(picker.source, .gpsFallback)
        riding(&picker, sensor: true, at: 20)
        riding(&picker, sensor: true, at: 24)
        XCTAssertEqual(picker.source, .gpsFallback)
        // A flaky link starts the wait again.
        riding(&picker, sensor: false, at: 24.5)
        riding(&picker, sensor: true, at: 25)
        riding(&picker, sensor: true, at: 29)
        XCTAssertEqual(picker.source, .gpsFallback)
        XCTAssertTrue(riding(&picker, sensor: true, at: 30))
        XCTAssertEqual(picker.source, .sensor)
    }

    func testAManualPauseSwitchesGPSOff() {
        var picker = SpeedSourcePicker()
        riding(&picker, sensor: false, at: 0)
        riding(&picker, sensor: false, at: 10)
        XCTAssertEqual(picker.source, .gpsFallback)
        picker.update(sensorConnected: false, ride: .paused(.manual), pedalling: true, at: at(15))
        XCTAssertEqual(picker.source, .sensor)
        // Riding again: another 10 s before GPS comes back.
        riding(&picker, sensor: false, at: 60)
        riding(&picker, sensor: false, at: 69)
        XCTAssertEqual(picker.source, .sensor)
        riding(&picker, sensor: false, at: 70)
        XCTAssertEqual(picker.source, .gpsFallback)
    }

    func testALongStopWithTheSensorsAsleepLeavesGPSOff() {
        var picker = SpeedSourcePicker()
        riding(&picker, sensor: true, at: 0)
        // Auto-paused at a café: the sensors fall asleep and disconnect.
        for s in 1...600 {
            picker.update(sensorConnected: false, ride: .paused(.auto), pedalling: false, at: at(Double(s)))
        }
        XCTAssertEqual(picker.source, .sensor)
        // Pedalling away with the speed sensor still gone: GPS after 10 s.
        picker.update(sensorConnected: false, ride: .paused(.auto), pedalling: true, at: at(601))
        picker.update(sensorConnected: false, ride: .paused(.auto), pedalling: true, at: at(610))
        XCTAssertEqual(picker.source, .sensor)
        picker.update(sensorConnected: false, ride: .paused(.auto), pedalling: true, at: at(611))
        XCTAssertEqual(picker.source, .gpsFallback)
    }

    func testGPSStaysOnThroughAnAutoPause() {
        var picker = SpeedSourcePicker()
        riding(&picker, sensor: false, at: 0)
        riding(&picker, sensor: false, at: 10)
        XCTAssertEqual(picker.source, .gpsFallback)
        // Stopped at the lights while on GPS: it stays on, ready to resume.
        for s in 11...60 {
            picker.update(sensorConnected: false, ride: .paused(.auto), pedalling: false, at: at(Double(s)))
        }
        XCTAssertEqual(picker.source, .gpsFallback)
    }

    func testChangingThePreferenceMidRide() {
        var picker = SpeedSourcePicker()
        riding(&picker, sensor: false, at: 0)
        picker.preference = .gps
        XCTAssertTrue(riding(&picker, sensor: false, at: 1))
        XCTAssertEqual(picker.source, .gps)
        // Back to the sensor while it's still down: GPS carries on as the fallback.
        picker.preference = .sensor
        riding(&picker, sensor: false, at: 2)
        XCTAssertEqual(picker.source, .gpsFallback)

        // With the sensor connected, it switches straight over.
        var other = SpeedSourcePicker(preference: .gps)
        other.preference = .sensor
        riding(&other, sensor: true, at: 0)
        XCTAssertEqual(other.source, .sensor)
    }
}
