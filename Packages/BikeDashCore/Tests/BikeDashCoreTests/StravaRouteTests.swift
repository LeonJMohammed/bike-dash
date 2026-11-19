@testable import BikeDashCore
import XCTest

final class StravaRouteTests: XCTestCase {
    func testDecodesTheServiceReply() throws {
        let json = Data("""
        {"routes":[
          {"id":"3344550000000000123","name":"Old loop","kind":"ride","sub_type":1,"distance_m":42195.5,
           "elevation_gain_m":310.2,"estimated_moving_time_s":null,"updated_at":"2026-10-01T10:00:00Z",
           "private":true,"starred":false,"summary_polyline":"abc"},
          {"id":"9","name":"Track","kind":"swim","distance_m":5000,"elevation_gain_m":0,"updated_at":null,
           "private":false,"starred":true}
        ],"private_hidden":false}
        """.utf8)
        let list = try JSONDecoder().decode(StravaRouteList.self, from: json)
        XCTAssertFalse(list.privateHidden)
        XCTAssertEqual(list.routes.count, 2)
        let route = list.routes[0]
        XCTAssertEqual(route.id, "3344550000000000123", "big ids stay exact")
        XCTAssertEqual(route.kind, .ride)
        XCTAssertEqual(route.distance, 42195.5)
        XCTAssertEqual(route.elevationGain, 310.2)
        XCTAssertTrue(route.isPrivate)
        XCTAssertEqual(route.updated, Date(timeIntervalSince1970: 1_790_848_800))
        XCTAssertEqual(list.routes[1].kind, .other, "unknown kinds don't fail the list")
        XCTAssertNil(list.routes[1].updated)
        XCTAssertTrue(list.routes[1].starred)
    }

    func testDatesWithFractionalSeconds() {
        XCTAssertEqual(StravaRoute.parseDate("2026-10-01T10:00:00.250Z")!.timeIntervalSince1970, 1_790_848_800.25, accuracy: 0.001)
        XCTAssertNil(StravaRoute.parseDate("yesterday"))
    }
}
