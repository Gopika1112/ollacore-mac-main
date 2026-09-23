import XCTest
@testable import OllaCoreMac

/// Receipt/reaction/call/duplicate state. Mocked history, events driven directly. No network.
@MainActor final class ChatStateTests: XCTestCase {
    private func msg(_ id: String, seq: Int) throws -> MessageResponse {
        let d = Data(#"{"id":"\#(id)","room_id":"r","sender_id":"u","kind":"text","body":{"text":"hi"},"created_at":"2026-01-01T00:00:00Z","event_seq":\#(seq)}"#.utf8)
        return try JSONDecoder().decode(MessageResponse.self, from: d)
    }
    private func vmWithHistory(_ json: String) -> ChatViewModel {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }
        return ChatViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
    }

    func testHistoryFailureStaysOutOfSocket() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data("{}".utf8))
        }
        let vm = ChatViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        XCTAssertNotNil(vm.historyError)
        XCTAssertFalse(vm.historyLoaded)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.socket.isConnected)
        vm.disconnect()
    }

    func testCrossRoomEventsIgnored() async throws {
        let vm = vmWithHistory(#"{"messages":[],"has_more":false}"#)
        await vm.join(roomToken: "t", roomId: "A", wsUrl: "ws://invalid", ownId: "u")
        let other = try JSONDecoder().decode(MessageResponse.self, from: Data(#"{"id":"mx","room_id":"B","sender_id":"u","kind":"text","body":{"text":"x"},"created_at":"t","event_seq":1}"#.utf8))
        vm.socket.onEvent?(.messageCreated(other))
        vm.socket.onEvent?(.receiptRead(roomId: "B", messageId: "mx"))
        vm.socket.onEvent?(.reactionAdded(roomId: "B", messageId: "mx", emoji: "👍"))
        vm.socket.onEvent?(.messageDeleted(roomId: "B", messageId: "mx"))
        vm.socket.onEvent?(.callStarted(roomId: "B", callId: "c9"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertTrue(vm.reactions.isEmpty)
        XCTAssertNil(vm.activeCall)
        XCTAssertFalse(vm.deletedIds.contains("mx"))
        vm.disconnect()
    }

    func testWindowCapsHistory() async throws {
        let vm = vmWithHistory(#"{"messages":[],"has_more":false}"#)
        vm.maxRetainedMessages = 3
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        for i in 1...5 {
            let d = Data(#"{"id":"m\#(i)","room_id":"r","sender_id":"u","kind":"text","body":{"text":"x"},"created_at":"t","event_seq":\#(i)}"#.utf8)
            let m = try JSONDecoder().decode(MessageResponse.self, from: d)
            vm.socket.onEvent?(.messageCreated(m))
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.messages.count, 3)
        XCTAssertEqual(vm.messages.map(\.event_seq), [3, 4, 5])
        vm.disconnect()
    }

    func testEmptySendIgnored() async throws {
        let vm = vmWithHistory(#"{"messages":[],"has_more":false}"#)
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        XCTAssertEqual(vm.send(roomId: "r", text: "   "), "")
        XCTAssertEqual(vm.sendingCount, 0)
        XCTAssertTrue(vm.failedDrafts.isEmpty)
        vm.disconnect()
    }

    func testHasMoreGatesLoadMore() async throws {
        var calls = 0
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            calls += 1
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"messages":[{"id":"m1","room_id":"r","sender_id":"u","kind":"text","body":{"text":"x"},"created_at":"t","event_seq":1}],"has_more":false}"#.utf8))
        }
        let vm = ChatViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        XCTAssertFalse(vm.hasMoreHistory)
        let before = calls
        await vm.loadMore()
        XCTAssertEqual(calls, before) // no network when exhausted
        vm.disconnect()
    }

    func testOversizeUploadRefused() async throws {
        let vm = vmWithHistory(#"{"messages":[],"has_more":false}"#)
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        vm.uploadAndSend(roomId: "r", data: Data(count: 101 * 1024 * 1024), filename: "big.bin", mime: "application/octet-stream", kind: "file")
        if case .failed(let name, _) = vm.uploadState { XCTAssertEqual(name, "big.bin") }
        else { XCTFail("expected failed state") }
        vm.disconnect()
    }

    func testLoadMorePrepends() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let url = req.url!.absoluteString
            let body = url.contains("before_seq")
                ? #"{"messages":[{"id":"m0","room_id":"r","sender_id":"u","kind":"text","body":{"text":"old"},"created_at":"t","event_seq":0}],"has_more":false}"#
                : #"{"messages":[{"id":"m1","room_id":"r","sender_id":"u","kind":"text","body":{"text":"new"},"created_at":"t","event_seq":1}],"has_more":false}"#
            return (resp, Data(body.utf8))
        }
        let vm = ChatViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        await vm.loadMore()
        XCTAssertEqual(vm.messages.map(\.id), ["m0", "m1"])
        vm.disconnect()
    }

    func testStaleJoinFailureIgnored() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            let url = req.url!.absoluteString
            if url.contains("/rooms/A/") {
                Thread.sleep(forTimeInterval: 0.3)
                let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (resp, Data("{}".utf8))
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let room = url.contains("/rooms/B/") ? "B" : "?"
            let body = #"{"messages":[{"id":"m-\#(room)","room_id":"\#(room)","sender_id":"u","kind":"text","body":{"text":"x"},"created_at":"t","event_seq":1}],"has_more":false}"#
            return (resp, Data(body.utf8))
        }
        let vm = ChatViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
        async let j1: Void = vm.join(roomToken: "t", roomId: "A", wsUrl: "ws://invalid", ownId: "u")
        async let j2: Void = vm.join(roomToken: "t", roomId: "B", wsUrl: "ws://invalid", ownId: "u")
        _ = await (j1, j2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(vm.historyError) // A's late failure must not stain B
        XCTAssertTrue(vm.historyLoaded)
        XCTAssertEqual(vm.messages.first?.id, "m-B")
        vm.disconnect()
    }

    func testDisconnectCancelsInflightJoin() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            Thread.sleep(forTimeInterval: 0.3)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"messages":[],"has_more":false}"#.utf8))
        }
        let vm = ChatViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
        async let j: Void = vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        for _ in 0..<5 { await Task.yield() }
        vm.disconnect()
        await j.value
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(vm.socket.isConnected)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertNil(vm.historyError)
        XCTAssertFalse(vm.historyLoaded)
    }

    func testHugeRetryAfterCapped() async {
        var calls = 0
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            calls += 1
            if calls == 1 {
                let resp = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "999999"])!
                return (resp, Data(#"{"code":"rate_limited","message":"slow"}"#.utf8))
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"messages":[],"has_more":false}"#.utf8))
        }
        let vm = RoomSearchViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
        RoomTokenCache.shared.set(roomId: "r", token: "t", wsURL: "w", rtcURL: "c", expiresAt: "2999-01-01T00:00:00Z")
        let start = Date()
        await vm.search(roomId: "r", query: "q")
        // One capped 60s wait + one retry: far sooner than the 999999s demanded.
        XCTAssertLessThan(Date().timeIntervalSince(start), 90)
        XCTAssertEqual(calls, 2)
        RoomTokenCache.shared.clear()
    }

    func testRoomSwitchResetsState() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let room = req.url!.absoluteString.contains("/rooms/A/") ? "A" : "B"
            let body = #"{"messages":[{"id":"m-\#(room)","room_id":"\#(room)","sender_id":"u","kind":"text","body":{"text":"\#(room)"},"created_at":"t","event_seq":1}],"has_more":false}"#
            return (resp, Data(body.utf8))
        }
        let vm = ChatViewModel(api: OllacoreAPI(session: URLSession(configuration: cfg)))
        await vm.join(roomToken: "t", roomId: "A", wsUrl: "ws://invalid", ownId: "u")
        XCTAssertEqual(vm.messages.first?.id, "m-A")
        await vm.join(roomToken: "t", roomId: "B", wsUrl: "ws://invalid", ownId: "u")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.messages.first?.id, "m-B")
        XCTAssertEqual(vm.messages.count, 1)
        vm.disconnect()
    }

    func testUnicodeAndLongSendTracked() async throws {
        let vm = vmWithHistory(#"{"messages":[],"has_more":false}"#)
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        let long = String(repeating: "ü", count: 5000)
        let rid = vm.send(roomId: "r", text: long)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(rid.isEmpty)
        XCTAssertEqual(vm.failedDrafts.count, 1) // disconnected: fail-fast draft
        XCTAssertEqual(vm.failedDrafts.first?.text.count, 5000)
        vm.disconnect()
    }

    func testJoinSortsAndSeeds() async throws {
        let vm = vmWithHistory(#"{"messages":[{"id":"b","room_id":"r","sender_id":"u","kind":"text","body":{"text":"2"},"created_at":"t","event_seq":2},{"id":"a","room_id":"r","sender_id":"u","kind":"text","body":{"text":"1"},"created_at":"t","event_seq":1}],"has_more":false}"#)
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        XCTAssertEqual(vm.messages.map(\.id), ["a", "b"])
        vm.disconnect()
    }

    func testSendAckErrorRetryFlow() async throws {
        let vm = vmWithHistory(#"{"messages":[],"has_more":false}"#)
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        // Disconnected socket: send fails fast into a retryable draft (R-02).
        let rid = vm.send(roomId: "r", text: "hello")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.failedDrafts.count, 1)
        XCTAssertEqual(vm.sendingCount, 0)
        // A late ack for the failed frame changes nothing.
        vm.socket.onEvent?(.ack(rid))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.failedDrafts.count, 1)
        // Server echo with same client id clears the failed draft.
        let cid = vm.failedDrafts.first!.id
        let d = Data(#"{"id":"m9","room_id":"r","sender_id":"u","kind":"text","body":{"text":"hello"},"created_at":"t","event_seq":9,"client_message_id":"\#(cid)"}"#.utf8)
        let m = try JSONDecoder().decode(MessageResponse.self, from: d)
        vm.socket.onEvent?(.messageCreated(m))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(vm.failedDrafts.isEmpty)
        XCTAssertEqual(vm.receiptLabel(for: "m9"), "✓")
        vm.disconnect()
    }

    func testReplyTombstoneSelection() async throws {
        let vm = vmWithHistory(#"{"messages":[],"has_more":false}"#)
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        let m = try msg("m1", seq: 1)
        vm.socket.onEvent?(.messageCreated(m))
        for _ in 0..<20 { await Task.yield() }
        vm.replyTo = m
        _ = vm.send(roomId: "r", text: "reply")
        XCTAssertNil(vm.replyTo) // consumed on send
        vm.socket.onEvent?(.messageDeleted(roomId: "r", messageId: "m1"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(vm.deletedIds.contains("m1"))
        XCTAssertTrue(vm.messages.contains(where: { $0.id == "m1" })) // tombstone keeps the row
        vm.toggleSelect(id: "m1")
        XCTAssertTrue(vm.selectionMode)
        vm.toggleSelect(id: "m1")
        XCTAssertFalse(vm.selectionMode)
        vm.disconnect()
    }

    func testDuplicateSuppressedAndReceiptsReactionsCalls() async throws {
        let vm = vmWithHistory(#"{"messages":[],"has_more":false}"#)
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        let m = try msg("m1", seq: 1)
        vm.socket.onEvent?(.messageCreated(m))
        vm.socket.onEvent?(.messageCreated(m))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.messages.count, 1)
        vm.socket.onEvent?(.receiptDelivered(roomId: "r", messageId: "m1"))
        vm.socket.onEvent?(.receiptRead(roomId: "r", messageId: "m1"))
        vm.socket.onEvent?(.reactionAdded(roomId: "r", messageId: "m1", emoji: "👍"))
        vm.socket.onEvent?(.reactionAdded(roomId: "r", messageId: "m1", emoji: "👍"))
        vm.socket.onEvent?(.callStarted(roomId: "r", callId: "c1"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.receiptLabel(for: "m1"), "✓✓ read")
        XCTAssertEqual(vm.reactions["m1"]?["👍"], 2)
        XCTAssertNotNil(vm.activeCall)
        vm.socket.onEvent?(.reactionRemoved(roomId: "r", messageId: "m1", emoji: "👍"))
        vm.socket.onEvent?(.reactionRemoved(roomId: "r", messageId: "m1", emoji: "👍"))
        vm.socket.onEvent?(.callEnded(roomId: "r", callId: "c1"))
        vm.socket.onEvent?(.messageDeleted(roomId: "r", messageId: "m1"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.messages.count, 1) // tombstone: row kept, rendered as deleted
        XCTAssertTrue(vm.deletedIds.contains("m1"))
        XCTAssertNil(vm.reactions["m1"])
        XCTAssertNil(vm.activeCall)
        vm.disconnect()
    }
}
