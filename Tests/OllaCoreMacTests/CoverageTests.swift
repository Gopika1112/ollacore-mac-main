import XCTest
@testable import OllaCoreMac

/// Covers the previously inspection-only fixes. Mocked transport, no network, no secrets.
@MainActor final class CoverageTests: XCTestCase {
    private func mockApi(status: Int, body: String) -> OllacoreAPI {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
        return OllacoreAPI(session: URLSession(configuration: cfg))
    }

    func testSocketDisconnectFlag() {
        let ws = ChatWebSocket()
        XCTAssertFalse(ws.isConnected)
        ws.connect(url: "ws://invalid", token: "t")
        XCTAssertTrue(ws.isConnected)
        ws.disconnect()
        XCTAssertFalse(ws.isConnected)
    }

    func testRtcOfferCarriesRequestId() {
        let e = RtcEvent.offer(sdp: "v=0", requestId: 7)
        if case .offer(let sdp, let rid) = e {
            XCTAssertEqual(sdp, "v=0"); XCTAssertEqual(rid, 7)
        } else { XCTFail("wrong case") }
    }

    func testLazySearchMintsToken() async {
        // Room token endpoint returns a token; search returns empty. Verifies lazy mint path.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            let url = req.url!.absoluteString
            let body = url.contains("/token")
                ? #"{"access_token":"rt","expires_at":"e","chat_websocket_url":"w","rtc_websocket_url":"c","ice_servers":[]}"#
                : #"{"messages":[],"has_more":false}"#
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
        let vm = RoomSearchViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
        await vm.search(roomId: "r", query: "hi", sessionToken: "sess", deviceId: "d")
        XCTAssertNotNil(RoomTokenCache.shared.get(roomId: "r"))
        RoomTokenCache.shared.clear()
    }

    func testMissingConfigGuard() async {
        // CI has no OLLACORE_APP_ID: requestOtp must fail fast with missing_config, no network.
        let api = OllacoreAPI(session: URLSession(configuration: .ephemeral))
        do { _ = try await api.requestOtp(phone: "+15550001111"); XCTFail("should throw") }
        catch let e as ApiException { XCTAssertEqual(e.code, "missing_config") }
        catch { XCTFail("wrong error") }
    }

    func testBadBaseFallsBackWithoutCrash() {
        let api = OllacoreAPI(session: URLSession(configuration: .ephemeral))
        api.apiBase = ":::not a url:::"
        let u = api.url(path: "directory/inbox", query: [URLQueryItem(name: "limit", value: "30")])
        XCTAssertTrue(u.absoluteString.contains("directory/inbox"))
        api.apiBase = AppConfig.apiBase
    }

    func testFireReportsFailure() async {
        let api = mockApi(status: 500, body: "{}")
        let ok = await api.markRead(roomToken: "t", roomId: "r", messageId: "m")
        XCTAssertFalse(ok)
    }

    func testLogoutSurfacesServerFailure() async {
        let bad = mockApi(status: 500, body: "{}")
        let vm = AuthViewModel(api: bad)
        vm.session.save(token: "t", userId: "u")
        await vm.logout()
        XCTAssertFalse(vm.session.isAuthenticated) // local session always clears
        XCTAssertNotNil(vm.error) // ...but the server failure is shown, not swallowed
        XCTAssertEqual(vm.step, .phoneInput)
        // Success path clears without error.
        let good = mockApi(status: 200, body: "{}")
        let vm2 = AuthViewModel(api: good)
        vm2.session.save(token: "t", userId: "u")
        await vm2.logout()
        XCTAssertNil(vm2.error)
    }

    func testResendCooldown() {
        let vm = AuthViewModel()
        vm.resendCooldownSeconds = 20
        XCTAssertTrue(vm.canResend(now: Date(timeIntervalSince1970: 1000)))
        vm.lastOtpRequestAt = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(vm.canResend(now: Date(timeIntervalSince1970: 1010)))
        XCTAssertEqual(vm.resendRemaining(now: Date(timeIntervalSince1970: 1010)), 10)
        XCTAssertTrue(vm.canResend(now: Date(timeIntervalSince1970: 1021)))
    }
}
