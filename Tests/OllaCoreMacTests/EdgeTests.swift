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

    func testCorruptCallLogQuarantined() {
        UserDefaults.standard.set(Data("garbage".utf8), forKey: "call_log_v1")
        UserDefaults.standard.set(1, forKey: "call_log_version")
        let store = CallLogStore()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: "call_log_corrupt_backup"))
        XCTAssertNil(UserDefaults.standard.data(forKey: "call_log_v1"))
        UserDefaults.standard.removeObject(forKey: "call_log_corrupt_backup")
    }

    func testDeviceIdStable() {
        let s = SessionStore()
        XCTAssertEqual(s.deviceId, s.deviceId)
        XCTAssertTrue(s.deviceId.hasPrefix("mac-"))
    }
}
