import XCTest
@testable import OllaCoreMac

/// Mock transport for HTTP-level tests. No network, no secrets — runs on CI.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let h = MockURLProtocol.handler else { return }
        let (resp, data) = h(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ApiMockTests: XCTestCase {
    private func api(status: Int, headers: [String: String] = [:], body: Data) -> OllacoreAPI {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (resp, body)
        }
        return OllacoreAPI(session: URLSession(configuration: cfg))
    }

    func test429MapsRetryAfter() async {
        let api = api(status: 429, headers: ["Retry-After": "9"], body: Data(#"{"code":"rate_limited","message":"slow"}"#.utf8))
        do { _ = try await api.getInbox(token: "t"); XCTFail("should throw") }
        catch let e as ApiException { XCTAssertTrue(e.isRateLimited); XCTAssertEqual(e.retryAfterSeconds, 9) }
        catch { XCTFail("wrong error") }
    }

    func test422PlainText() async {
        let api = api(status: 422, body: Data("unknown field tenant_id".utf8))
        do { _ = try await api.getInbox(token: "t"); XCTFail("should throw") }
        catch let e as ApiException { XCTAssertEqual(e.code, "unprocessable"); XCTAssertTrue(e.message.contains("tenant_id")) }
        catch { XCTFail("wrong error") }
    }

    func test401And404Parse() async {
        for (status, code) in [(401, "unauthorized"), (404, "not_found")] {
            let api = api(status: status, body: Data(#"{"code":"\#(code)","message":"m"}"#.utf8))
            do { _ = try await api.getInbox(token: "t"); XCTFail("should throw") }
            catch let e as ApiException { XCTAssertEqual(e.httpStatus, status); XCTAssertEqual(e.code, code) }
            catch { XCTFail("wrong error") }
        }
    }

    func testSearchURLEncoding() async {
        var captured: URL?
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            captured = req.url
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"messages":[],"has_more":false}"#.utf8))
        }
        let api = OllacoreAPI(session: URLSession(configuration: cfg))
        _ = try? await api.searchMessages(roomToken: "t", roomId: "room 1", q: "a&b+c")
        let s = captured?.absoluteString ?? ""
        XCTAssertTrue(s.contains("rooms/room%201/messages/search"), s)
        XCTAssertTrue(s.contains("q=a%26b%2Bc") || s.contains("q=a%26b+c"), s)
    }

    func testAuthHeadersPerPlane() async {
        var captured: [URLRequest] = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            captured.append(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = req.url!.absoluteString.contains("/search")
                ? #"{"messages":[],"has_more":false}"#
                : #"{"conversations":[]}"#
            return (resp, Data(body.utf8))
        }
        let api = OllacoreAPI(session: URLSession(configuration: cfg))
        _ = try? await api.getInbox(token: "sess-abc")
        _ = try? await api.searchMessages(roomToken: "room-xyz", roomId: "r", q: "hi")
        XCTAssertEqual(captured[0].value(forHTTPHeaderField: "Authorization"), "Bearer sess-abc")
        XCTAssertEqual(captured[1].value(forHTTPHeaderField: "Authorization"), "Bearer room-xyz")
        XCTAssertEqual(captured[0].httpMethod, "GET")
    }

    func testSendAndReactionBodies() async {
        var captured: [URLRequest] = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            captured.append(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("{}".utf8))
        }
        let api = OllacoreAPI(session: URLSession(configuration: cfg))
        _ = await api.addReaction(roomToken: "t", roomId: "r", messageId: "m", emoji: "👍")
        XCTAssertEqual(captured[0].httpMethod, "POST")
        let body = try? JSONSerialization.jsonObject(with: captured[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["emoji"] as? String, "👍")
        XCTAssertTrue(captured[0].url!.absoluteString.contains("/messages/m/reactions"))
    }

    func testAttachmentInitCompleteShapes() async {
        var captured: [URLRequest] = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            captured.append(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = req.url!.absoluteString.contains("/init")
                ? #"{"attachment_id":"a1","upload_url":"https://up.example/p","expires_at":"e"}"#
                : "{}"
            return (resp, Data(body.utf8))
        }
        let api = OllacoreAPI(session: URLSession(configuration: cfg))
        let initR = try? await api.initAttachment(roomToken: "t", roomId: "r", filename: "p.png", mime: "image/png", byteSize: 10)
        XCTAssertEqual(initR?.attachment_id, "a1")
        XCTAssertTrue(captured[0].url!.absoluteString.contains("/attachments/init"))
        XCTAssertEqual(captured[0].httpMethod, "POST")
        let initBody = try? JSONSerialization.jsonObject(with: captured[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(initBody?["mime"] as? String, "image/png")
        let ok = await api.completeAttachment(roomToken: "t", roomId: "r", attachmentId: "a1")
        XCTAssertTrue(ok)
        XCTAssertTrue(captured[1].url!.absoluteString.contains("/attachments/a1/complete"))
    }

    func testDefaultTimeouts() {
        let s = OllacoreAPI.defaultSession()
        XCTAssertEqual(s.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(s.configuration.timeoutIntervalForResource, 60)
    }

    func testRoomTokenURLUsesQueryItem() async {
        var captured: URL?
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            captured = req.url
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"access_token":"t","expires_at":"e","chat_websocket_url":"w","rtc_websocket_url":"c","ice_servers":[]}"#.utf8))
        }
        let api = OllacoreAPI(session: URLSession(configuration: cfg))
        _ = try? await api.roomToken(token: "t", roomId: "r/1", deviceId: "mac 1")
        let s = captured?.absoluteString ?? ""
        XCTAssertTrue(s.contains("conversations/r%2F1/token"), s)
        XCTAssertTrue(s.contains("device_id=mac%201") || s.contains("device_id=mac+1"), s)
    }
}
