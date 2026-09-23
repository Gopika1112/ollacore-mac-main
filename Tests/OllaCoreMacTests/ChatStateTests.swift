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

    func testJoinSortsAndSeeds() async throws {
        let vm = vmWithHistory(#"{"messages":[{"id":"b","room_id":"r","sender_id":"u","kind":"text","body":{"text":"2"},"created_at":"t","event_seq":2},{"id":"a","room_id":"r","sender_id":"u","kind":"text","body":{"text":"1"},"created_at":"t","event_seq":1}],"has_more":false}"#)
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        XCTAssertEqual(vm.messages.map(\.id), ["a", "b"])
        vm.disconnect()
    }

    func testSendAckErrorRetryFlow() async throws {
        let vm = vmWithHistory(#"{"messages":[],"has_more":false}"#)
        await vm.join(roomToken: "t", roomId: "r", wsUrl: "ws://invalid", ownId: "u")
        let rid = vm.send(roomId: "r", text: "hello")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.sendingCount, 1)
        vm.socket.onEvent?(.ack(rid))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.sendingCount, 0)
        let rid2 = vm.send(roomId: "r", text: "again")
        for _ in 0..<20 { await Task.yield() }
        vm.socket.onEvent?(.error(code: "send_failed", message: "x", requestId: rid2))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.failedDrafts.count, 1)
        // Server echo with same client id clears pending + failed.
        let cid = vm.failedDrafts.first!.id
        let d = Data(#"{"id":"m9","room_id":"r","sender_id":"u","kind":"text","body":{"text":"again"},"created_at":"t","event_seq":9,"client_message_id":"\#(cid)"}"#.utf8)
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
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertNil(vm.reactions["m1"])
        XCTAssertNil(vm.activeCall)
        vm.disconnect()
    }
}
