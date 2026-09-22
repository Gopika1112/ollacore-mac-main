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
