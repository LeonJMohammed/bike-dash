import XCTest
@testable import BikeDashCore

final class RideThemeTests: XCTestCase {
    func testDefaultsToOLEDBlack() {
        XCTAssertEqual(RideTheme(stored: nil), .oledBlack)
        XCTAssertEqual(RideTheme(stored: "something old"), .oledBlack)
    }

    func testSavedChoiceRoundTrips() {
        for theme in RideTheme.allCases {
            XCTAssertEqual(RideTheme(stored: theme.rawValue), theme)
        }
    }

    func testOLEDOutlinesControls() {
        XCTAssertTrue(RideTheme.oledBlack.outlinesControls)
        XCTAssertFalse(RideTheme.standard.outlinesControls)
    }

    func testMusicBarColour() {
        XCTAssertFalse(RideTheme.oledBlack.musicBarUsesAlbumColour(albumColourSetting: false))
        XCTAssertTrue(RideTheme.oledBlack.musicBarUsesAlbumColour(albumColourSetting: true))
        XCTAssertTrue(RideTheme.standard.musicBarUsesAlbumColour(albumColourSetting: false))
    }
}
