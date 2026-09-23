import XCTest
@testable import OllaCoreMac

/// Edge-case coverage: search guards, resend blocks, URL shapes, local stores. No network.
@MainActor final class EdgeTests: XCTestCase {
    func testEmptyQuerySkipsNetwork() async {
        var called = false
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            called = true
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"messages":[],"has_more":false}"#.utf8))
        }
        let vm = RoomSearchViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
        await vm.search(roomId: "r", query: "")
        XCTAssertFalse(called); XCTAssertTrue(vm.results.isEmpty)
    }

    func testBlockedResendSetsErrorWithoutNetwork() async {
        let vm = AuthViewModel()
        vm.resendCooldownSeconds = 60
        vm.lastOtpRequestAt = Date()
        await vm.requestOtp()
        XCTAssertTrue(vm.error?.contains("Wait") ?? false)
        XCTAssertEqual(vm.step, .phoneInput)
    }

    func testUrlShapes() {
        let api = OllacoreAPI(session: URLSession(configuration: .ephemeral))
        let inbox = api.url(path: "directory/inbox", query: [URLQueryItem(name: "limit", value: "30")])
        XCTAssertTrue(inbox.absoluteString.hasSuffix("/v1/directory/inbox?limit=30"))
        let lead = api.url(path: "/directory/me")
        XCTAssertTrue(lead.absoluteString.hasSuffix("/v1/directory/me"))
    }

    func testCallLogRoundTrip() {
        let store = CallLogStore()
        let e = CallEntry(id: "1", roomId: "r", peerName: "QA", audioOnly: true, date: Date(timeIntervalSince1970: 1))
        store.add(e)
        XCTAssertEqual(store.entries.first?.peerName, "QA")
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testLegacyCorruptQuarantined() {
        UserDefaults.standard.set(Data("old-garbage".utf8), forKey: "call_log")
        UserDefaults.standard.set(0, forKey: "call_log_version")
        _ = CallLogStore()
        let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("call_log_corrupt_backup") }
        XCTAssertEqual(keys.count, 1)
        XCTAssertNil(UserDefaults.standard.data(forKey: "call_log"))
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        UserDefaults.standard.removeObject(forKey: "call_log_version")
    }

    private func corruptKeys() -> [String] {
        UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("call_log_corrupt_backup") }
    }

    func testCorruptCallLogQuarantined() {
        UserDefaults.standard.set(Data("garbage".utf8), forKey: "call_log_v1")
        UserDefaults.standard.set(1, forKey: "call_log_version")
        let store = CallLogStore()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(corruptKeys().count, 1)
        XCTAssertNil(UserDefaults.standard.data(forKey: "call_log_v1"))
        // A second corruption event keeps its own backup instead of overwriting.
        UserDefaults.standard.set(Data("garbage2".utf8), forKey: "call_log_v1")
        _ = CallLogStore()
        XCTAssertEqual(corruptKeys().count, 2)
        for k in corruptKeys() { UserDefaults.standard.removeObject(forKey: k) }
    }

    func testDeviceIdStable() {
        let s = SessionStore()
        XCTAssertEqual(s.deviceId, s.deviceId)
        XCTAssertTrue(s.deviceId.hasPrefix("mac-"))
    }
}
