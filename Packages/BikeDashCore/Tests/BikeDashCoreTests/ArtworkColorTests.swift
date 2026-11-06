import XCTest
@testable import BikeDashCore

final class ArtworkColorTests: XCTestCase {
    private func assertClose(_ a: RGB, _ b: RGB, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.red, b.red, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.green, b.green, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, accuracy: 0.001, file: file, line: line)
    }

    func testTheMostCommonColourfulShadeWins() throws {
        let blue = RGB(red: 0.1, green: 0.2, blue: 0.8)
        let red = RGB(red: 0.9, green: 0.1, blue: 0.1)
        let grey = RGB(red: 0.5, green: 0.5, blue: 0.5)
        let pixels = Array(repeating: blue, count: 60)
            + Array(repeating: red, count: 20)
            + Array(repeating: grey, count: 100)  // greys don't count, however many
        assertClose(try XCTUnwrap(ArtworkColor.dominant(pixels)), blue)
    }

    func testAGreyCoverGivesItsAverage() throws {
        let pixels = Array(repeating: RGB(red: 0.4, green: 0.4, blue: 0.4), count: 10)
            + Array(repeating: RGB(red: 0.6, green: 0.6, blue: 0.6), count: 10)
        assertClose(try XCTUnwrap(ArtworkColor.dominant(pixels)), RGB(red: 0.5, green: 0.5, blue: 0.5))
    }

    func testNoPixels() {
        XCTAssertNil(ArtworkColor.dominant([]))
    }

    func testBrightColoursAreDarkenedForWhiteText() {
        let yellow = RGB(red: 1, green: 1, blue: 0)
        let background = ArtworkColor.background(for: yellow)
        XCTAssertLessThanOrEqual(background.luminance, 0.2801)
        XCTAssertEqual(background.red, background.green, accuracy: 0.0001)  // same hue
        XCTAssertEqual(background.blue, 0)
    }

    func testDarkColoursStayAsTheyAre() {
        let navy = RGB(red: 0.05, green: 0.08, blue: 0.3)
        XCTAssertEqual(ArtworkColor.background(for: navy), navy)
    }
}
