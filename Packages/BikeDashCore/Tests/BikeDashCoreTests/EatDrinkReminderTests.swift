import XCTest
@testable import BikeDashCore

final class EatDrinkReminderTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: Double) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func minutes(_ value: Double) -> TimeInterval {
        value * 60
    }

    func testDueAfterTheIntervalOfMovingTime() {
        var reminder = EatDrinkReminder()
        XCTAssertNil(reminder.update(movingTime: minutes(29.9), intervalMinutes: 30, enabled: true, now: at(0)))
        XCTAssertEqual(reminder.update(movingTime: minutes(30), intervalMinutes: 30, enabled: true, now: at(1)), .show)
        XCTAssertTrue(reminder.isShowing)
    }

    func testPausesDoNotCount() {
        // Paused at 20 minutes of moving time for an hour: still not due.
        var reminder = EatDrinkReminder()
        for second in stride(from: 0.0, through: 3600, by: 60) {
            XCTAssertNil(reminder.update(movingTime: minutes(20), intervalMinutes: 30, enabled: true, now: at(second)))
        }
        XCTAssertEqual(reminder.remaining(movingTime: minutes(20), intervalMinutes: 30), minutes(10))
    }

    func testClearsItselfAfterFifteenSecondsAndCountsAgainFromThen() {
        var reminder = EatDrinkReminder()
        XCTAssertEqual(reminder.update(movingTime: minutes(30), intervalMinutes: 30, enabled: true, now: at(0)), .show)
        XCTAssertNil(reminder.update(movingTime: minutes(30) + 14, intervalMinutes: 30, enabled: true, now: at(14)))
        XCTAssertEqual(reminder.update(movingTime: minutes(30) + 15, intervalMinutes: 30, enabled: true, now: at(15)), .hide)
        XCTAssertFalse(reminder.isShowing)
        XCTAssertEqual(reminder.remaining(movingTime: minutes(30) + 15, intervalMinutes: 30), minutes(30))
    }

    func testATapDismissesAndCountsAgainFromThen() {
        var reminder = EatDrinkReminder()
        reminder.update(movingTime: minutes(30), intervalMinutes: 30, enabled: true, now: at(0))
        reminder.dismiss(movingTime: minutes(30) + 4)
        XCTAssertFalse(reminder.isShowing)
        XCTAssertNil(reminder.update(movingTime: minutes(60), intervalMinutes: 30, enabled: true, now: at(1800)))
        XCTAssertEqual(reminder.update(movingTime: minutes(60) + 4, intervalMinutes: 30, enabled: true, now: at(1804)), .show)
    }

    func testOffMeansNever() {
        var reminder = EatDrinkReminder()
        XCTAssertNil(reminder.update(movingTime: minutes(500), intervalMinutes: 15, enabled: false, now: at(0)))
    }

    func testSwitchingOffWhileShowingHidesIt() {
        var reminder = EatDrinkReminder()
        reminder.update(movingTime: minutes(15), intervalMinutes: 15, enabled: true, now: at(0))
        XCTAssertEqual(reminder.update(movingTime: minutes(15) + 2, intervalMinutes: 15, enabled: false, now: at(2)), .hide)
    }

    func testAShorterIntervalCountsFromTheLastRestart() {
        var reminder = EatDrinkReminder()
        reminder.restart(movingTime: minutes(10))
        XCTAssertNil(reminder.update(movingTime: minutes(24), intervalMinutes: 15, enabled: true, now: at(0)))
        XCTAssertEqual(reminder.update(movingTime: minutes(25), intervalMinutes: 15, enabled: true, now: at(60)), .show)
    }

    func testIntervalChoices() {
        XCTAssertEqual(EatDrinkReminder.intervalChoices, [15, 20, 25, 30, 35, 40, 45, 50, 55, 60])
        XCTAssertTrue(EatDrinkReminder.intervalChoices.contains(EatDrinkReminder.defaultInterval))
    }
}
