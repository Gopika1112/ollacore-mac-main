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
        OllacoreAPI.testBaseOverride = ":::bad:::"
        defer { OllacoreAPI.testBaseOverride = nil }
        let api = OllacoreAPI(session: URLSession(configuration: .ephemeral))
        let u = api.url(path: "directory/inbox", query: [URLQueryItem(name: "limit", value: "30")])
        XCTAssertTrue(u.absoluteString.contains("directory/inbox"))
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

    func testSearchRaceKeepsLatest() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            let url = req.url!.absoluteString
            let q = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            if q == "a" { Thread.sleep(forTimeInterval: 0.3) }
            let body = #"{"messages":[{"id":"m-\#(q)","room_id":"r","sender_id":"u","kind":"text","body":{"text":"\#(q)"},"created_at":"t","event_seq":1}],"has_more":false}"#
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
        let vm = RoomSearchViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
        RoomTokenCache.shared.set(roomId: "r", token: "t", wsURL: "w", rtcURL: "c", expiresAt: "2999-01-01T00:00:00Z")
        async let s1: Void = vm.search(roomId: "r", query: "a")
        async let s2: Void = vm.search(roomId: "r", query: "ab")
        _ = await (s1, s2)
        XCTAssertEqual(vm.results.first?.body["text"]?.value as? String, "ab")
        RoomTokenCache.shared.clear()
    }

    func testExpiredCacheTokenTreatedAsAbsent() {
        RoomTokenCache.shared.set(roomId: "r", token: "old", wsURL: "w", rtcURL: "c", expiresAt: "2000-01-01T00:00:00Z")
        XCTAssertNil(RoomTokenCache.shared.get(roomId: "r"))
        RoomTokenCache.shared.set(roomId: "r", token: "fresh", wsURL: "w", rtcURL: "c", expiresAt: "2999-01-01T00:00:00Z")
        XCTAssertEqual(RoomTokenCache.shared.get(roomId: "r")?.token, "fresh")
        RoomTokenCache.shared.set(roomId: "r", token: "bad", wsURL: "w", rtcURL: "c", expiresAt: "not-a-date")
        XCTAssertNil(RoomTokenCache.shared.get(roomId: "r"))
        RoomTokenCache.shared.clear()
    }

    func testMarkReadIsSingleCall() async {
        var reads = 0
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            if req.url!.absoluteString.hasSuffix("/read") { reads += 1 }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = req.url!.absoluteString.contains("/messages?") || req.url!.absoluteString.contains("/messages?")
                ? #"{"messages":[{"id":"m1","room_id":"r","sender_id":"peer","kind":"text","body":{"text":"hi"},"created_at":"t","event_seq":1},{"id":"m2","room_id":"r","sender_id":"peer","kind":"text","body":{"text":"yo"},"created_at":"t","event_seq":2}],"has_more":false}"#
                : "{}"
            return (resp, Data(body.utf8))
        }
        let vm = ChatViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        vm.markVisibleAsRead(roomId: "r")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(reads, 1)
        vm.disconnect()
    }

    func testUnauthorizedPostsAndLogsOut() async {
        let posted = expectation(description: "401 notification")
        let obs = NotificationCenter.default.addObserver(forName: .ollacoreUnauthorized, object: nil, queue: nil) { _ in posted.fulfill() }
        defer { NotificationCenter.default.removeObserver(obs) }
        let api = mockApi(status: 401, body: #"{"code":"unauthorized","message":"expired"}"#)
        _ = try? await api.getInbox(token: "dead")
        await fulfillment(of: [posted], timeout: 2)
        let vm = AuthViewModel(api: mockApi(status: 200, body: "{}"))
        vm.session.save(token: "t", userId: "u")
        vm.step = .authenticated // simulate a live session; init ran before the save
        vm.handleUnauthorized()
        XCTAssertFalse(vm.session.isAuthenticated)
    }

    func testMalformedWsUrlsReportError() {
        var chatErr: ChatEvent?
        let ws = ChatWebSocket()
        ws.onEvent = { chatErr = $0 }
        ws.connect(url: ":::bad:::", token: "t")
        XCTAssertFalse(ws.isConnected)
        if case .error(let code, _, _) = chatErr { XCTAssertEqual(code, "invalid_url") }
        else { XCTFail("expected invalid_url") }
        var rtcErr: RtcEvent?
        let rtc = RtcWebSocket()
        rtc.onEvent = { rtcErr = $0 }
        rtc.connect(url: "http://not-ws.example/x", token: "t")
        if case .error = rtcErr {} else { XCTFail("expected rtc error") }
    }

    func testExtendedEncodingCases() {
        let api = OllacoreAPI(session: URLSession(configuration: .ephemeral))
        let u = api.url(segments: ["rooms", "r %?/ü", "messages"], query: [URLQueryItem(name: "q", value: "héllo wörld")])
        let s = u.absoluteString
        XCTAssertFalse(s.contains(" "), s)
        XCTAssertTrue(s.contains("r%20%25%3F/%C3%BC") || s.contains("r%20%25%3F%2F%C3%BC"), s)
    }

    func testWsxSchemeRejected() {
        var got: ChatEvent?
        let ws = ChatWebSocket()
        ws.onEvent = { got = $0 }
        ws.connect(url: "wsx://example.com/chat", token: "t")
        XCTAssertFalse(ws.isConnected)
        if case .error(let code, _, _) = got { XCTAssertEqual(code, "invalid_url") }
        else { XCTFail("expected invalid_url") }
    }

    func testCredentialNeverInQuery() {
        XCTAssertTrue(OllacoreAPI.urlCarriesCredential(URL(string: "https://h/p?access_token=x")!))
        XCTAssertTrue(OllacoreAPI.urlCarriesCredential(URL(string: "https://h/p?api_key=x")!))
        XCTAssertFalse(OllacoreAPI.urlCarriesCredential(URL(string: "https://h/p?device_id=d&limit=30")!))
    }

    func testAllowedBase() {
        XCTAssertTrue(AppConfig.isAllowedBase("https://api.ollacore.com/v1"))
        XCTAssertTrue(AppConfig.isAllowedBase("https://t.ollacore.com/v1"))
        XCTAssertTrue(AppConfig.isAllowedBase("http://localhost:8080/v1"))
        XCTAssertFalse(AppConfig.isAllowedBase("http://api.ollacore.com/v1"))
        XCTAssertFalse(AppConfig.isAllowedBase("https://evil.example.com/v1"))
        XCTAssertFalse(AppConfig.isAllowedBase(":::bad:::"))
    }

    func testSaveReturnsTrueAndSetsSession() {
        let s = SessionStore()
        XCTAssertTrue(s.save(token: "t", userId: "u"))
        XCTAssertTrue(s.isAuthenticated)
        s.clear()
    }

    func testNonHttpsDownloadRejected() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = req.url!.absoluteString.contains("/download")
                ? #"{"download_url":"http://insecure.example/f"}"#
                : #"{"messages":[],"has_more":false}"#
            return (resp, Data(body.utf8))
        }
        let vm = ChatViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        let u = await vm.resolveAttachmentURL(attachmentId: "a")
        XCTAssertNil(u)
        vm.disconnect()
    }

    func testCancelOrphansInflightSearch() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            Thread.sleep(forTimeInterval: 0.3)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"messages":[{"id":"m","room_id":"r","sender_id":"u","kind":"text","body":{"text":"stale"},"created_at":"t","event_seq":1}],"has_more":false}"#.utf8))
        }
        let vm = RoomSearchViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
        RoomTokenCache.shared.set(roomId: "r", token: "t", wsURL: "w", rtcURL: "c", expiresAt: "2999-01-01T00:00:00Z")
        let t = Task { await vm.search(roomId: "r", query: "q") }
        for _ in 0..<5 { await Task.yield() }
        vm.cancel()
        await t.value
        XCTAssertTrue(vm.results.isEmpty)
        RoomTokenCache.shared.clear()
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
