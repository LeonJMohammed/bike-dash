import XCTest
@testable import BikeDashCore

final class SpotifyAuthTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: Double) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func token(expiringAt seconds: Double) -> SpotifyAccessToken {
        SpotifyAccessToken(value: "A", expiresAt: at(seconds))
    }

    // MARK: Expiry

    func testATokenIsRefreshedFiveMinutesBeforeItRunsOut() {
        let access = token(expiringAt: 3600)
        XCTAssertFalse(access.needsRefresh(at: at(3299)))
        XCTAssertTrue(access.needsRefresh(at: at(3300)))
        XCTAssertTrue(access.isUsable(at: at(3599)))
        XCTAssertFalse(access.isUsable(at: at(3600)))
    }

    func testAFreshTokenIsUsedAsItIs() {
        let access = token(expiringAt: 3600)
        XCTAssertEqual(SpotifyTokenPlan.decide(access: access, hasRefreshToken: true, now: at(0)), .use(access))
        XCTAssertEqual(SpotifyTokenPlan.decide(access: access, hasRefreshToken: false, now: at(0)), .use(access))
    }

    func testANearlyExpiredTokenIsRefreshedWhenItCanBe() {
        let access = token(expiringAt: 3600)
        XCTAssertEqual(SpotifyTokenPlan.decide(access: access, hasRefreshToken: true, now: at(3400)), .refresh)
        XCTAssertEqual(SpotifyTokenPlan.decide(access: nil, hasRefreshToken: true, now: at(0)), .refresh)
    }

    func testWithoutARefreshTokenATokenIsUsedToTheLastMinute() {
        let access = token(expiringAt: 3600)
        XCTAssertEqual(SpotifyTokenPlan.decide(access: access, hasRefreshToken: false, now: at(3500)), .use(access))
        XCTAssertEqual(SpotifyTokenPlan.decide(access: access, hasRefreshToken: false, now: at(3600)), .signIn)
        XCTAssertEqual(SpotifyTokenPlan.decide(access: nil, hasRefreshToken: false, now: at(0)), .signIn)
    }

    // MARK: The token service's replies

    func testDecodesASwapReply() throws {
        let json = #"{"access_token":"A1","expires_in":3600,"refresh_token":"v1.sealed","scope":"app-remote-control"}"#
        let reply = try JSONDecoder().decode(SpotifyTokenResponse.self, from: Data(json.utf8))
        XCTAssertEqual(reply, SpotifyTokenResponse(accessToken: "A1", expiresIn: 3600, refreshToken: "v1.sealed"))
        XCTAssertEqual(reply.accessToken(receivedAt: at(10)), SpotifyAccessToken(value: "A1", expiresAt: at(3610)))
    }

    func testDecodesARefreshReplyWithAStringExpiryAndNoRefreshToken() throws {
        let json = #"{"access_token":"A2","expires_in":"1800"}"#
        let reply = try JSONDecoder().decode(SpotifyTokenResponse.self, from: Data(json.utf8))
        XCTAssertEqual(reply.expiresIn, 1800)
        XCTAssertNil(reply.refreshToken)
    }

    func testAnEmptyRefreshTokenCountsAsNone() throws {
        let json = #"{"access_token":"A","expires_in":3600,"refresh_token":""}"#
        XCTAssertNil(try JSONDecoder().decode(SpotifyTokenResponse.self, from: Data(json.utf8)).refreshToken)
    }

    func testAReplyWithoutAnAccessTokenIsAnError() {
        XCTAssertThrowsError(try JSONDecoder().decode(SpotifyTokenResponse.self, from: Data(#"{"error":"x"}"#.utf8)))
    }

    // MARK: Failures

    func testOnlyInvalidGrantMeansSignInAgain() {
        let invalid = Data(#"{"error":"invalid_grant"}"#.utf8)
        XCTAssertEqual(SpotifyTokenFailure.classify(status: 400, body: invalid), .signInAgain)
        XCTAssertEqual(SpotifyTokenFailure.classify(status: 401, body: invalid), .signInAgain)
        XCTAssertEqual(SpotifyTokenFailure.classify(status: 400, body: Data(#"{"error":"missing_code"}"#.utf8)), .tryLater)
        XCTAssertEqual(SpotifyTokenFailure.classify(status: 400, body: nil), .tryLater)
    }

    func testThePCOrSpotifyBeingDownIsTryLater() {
        XCTAssertEqual(SpotifyTokenFailure.classify(status: nil, body: nil), .tryLater)
        XCTAssertEqual(SpotifyTokenFailure.classify(status: 503, body: Data(#"{"error":"spotify_unreachable"}"#.utf8)), .tryLater)
        XCTAssertEqual(SpotifyTokenFailure.classify(status: 502, body: Data(#"{"error":"invalid_grant"}"#.utf8)), .tryLater)
        // Cloudflare's login page (Access not bypassed) or the tunnel's own error pages.
        XCTAssertEqual(SpotifyTokenFailure.classify(status: 302, body: Data("<html>".utf8)), .tryLater)
        XCTAssertEqual(SpotifyTokenFailure.classify(status: 530, body: nil), .tryLater)
    }

    // MARK: Sign-in

    func testTheAuthorizeURL() throws {
        let url = SpotifySignIn.authorizeURL(clientID: "cid", redirectURI: "bikedash://spotify-login-callback", state: "s1")
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.host, "accounts.spotify.com")
        XCTAssertEqual(c.path, "/authorize")
        let items = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items, [
            "client_id": "cid",
            "response_type": "code",
            "redirect_uri": "bikedash://spotify-login-callback",
            "scope": "app-remote-control",
            "state": "s1",
        ])
    }

    func testTheCodeComesBackWithOurState() {
        let url = URL(string: "bikedash://spotify-login-callback?code=C1&state=s1")!
        XCTAssertEqual(SpotifySignIn.code(from: url, expectedState: "s1"), .success("C1"))
    }

    func testARedirectForSomeoneElsesRequestIsRefused() {
        let url = URL(string: "bikedash://spotify-login-callback?code=C1&state=other")!
        XCTAssertEqual(SpotifySignIn.code(from: url, expectedState: "s1"), .failure(.stateMismatch))
        let noState = URL(string: "bikedash://spotify-login-callback?code=C1")!
        XCTAssertEqual(SpotifySignIn.code(from: noState, expectedState: "s1"), .failure(.stateMismatch))
    }

    func testCancelledDeniedAndEmpty() {
        let cancelled = URL(string: "bikedash://spotify-login-callback?error=access_denied&state=s1")!
        XCTAssertEqual(SpotifySignIn.code(from: cancelled, expectedState: "s1"), .failure(.cancelled))
        let other = URL(string: "bikedash://spotify-login-callback?error=server_error&state=s1")!
        XCTAssertEqual(SpotifySignIn.code(from: other, expectedState: "s1"), .failure(.denied("server_error")))
        let empty = URL(string: "bikedash://spotify-login-callback?state=s1&code=")!
        XCTAssertEqual(SpotifySignIn.code(from: empty, expectedState: "s1"), .failure(.noCode))
    }

    // MARK: Form body

    func testFormBodyEscapesEverythingButUnreservedCharacters() {
        let body = FormBody.encode([("code", "a+b/c=d&e f"), ("refresh_token", "v1.Ab-_~")])
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "code=a%2Bb%2Fc%3Dd%26e%20f&refresh_token=v1.Ab-_~")
    }

    func testFormBodyEscapesNonASCII() {
        XCTAssertEqual(String(decoding: FormBody.encode([("x", "é")]), as: UTF8.self), "x=%C3%A9")
    }

    // MARK: Backoff

    func testTheBackoffIs2515ThenEvery30Seconds() {
        var backoff = ReconnectBackoff()
        XCTAssertEqual((0..<6).map { _ in backoff.nextDelay() }, [2, 5, 15, 30, 30, 30])
    }

    func testThePromptComesOnceTheQuickTriesHaveFailed() {
        var backoff = ReconnectBackoff()
        for _ in 0..<3 {
            _ = backoff.nextDelay()
            XCTAssertFalse(backoff.showsReconnectPrompt)
        }
        _ = backoff.nextDelay()
        XCTAssertTrue(backoff.showsReconnectPrompt)
    }

    func testASuccessStartsTheBackoffAgain() {
        var backoff = ReconnectBackoff()
        for _ in 0..<5 { _ = backoff.nextDelay() }
        backoff.reset()
        XCTAssertFalse(backoff.showsReconnectPrompt)
        XCTAssertEqual(backoff.nextDelay(), 2)
    }
}
