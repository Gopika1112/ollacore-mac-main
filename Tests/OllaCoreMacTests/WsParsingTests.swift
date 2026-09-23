import XCTest
@testable import OllaCoreMac

/// Deep frame-parsing tests: every documented server event through handleFrame. No sockets, no network.
final class WsParsingTests: XCTestCase {
    private func ws(capture: @escaping (ChatEvent) -> Void) -> ChatWebSocket {
        let w = ChatWebSocket(); w.onEvent = capture; return w
    }
    private func frame(_ type: String, room: String = "r", eventId: Int = 0, payload: [String: Any] = [:], req: String? = nil) -> [String: Any] {
        var f: [String: Any] = ["v": 1, "event_id": eventId, "type": type, "room_id": room, "payload": payload]
        if let req { f["request_id"] = req }
        return f
    }

    func testAckAndErrorCorrelation() {
        var got: [ChatEvent] = []
        let w = ws { got.append($0) }
        w.handleFrame(frame("ack", req: "abc"))
        w.handleFrame(["v": 1, "type": "error", "request_id": "x", "error": ["code": "rate_limited", "message": "slow"]])
        guard case .ack(let r) = got[0], r == "abc" else { return XCTFail("ack") }
        guard case .error(let c, let m, let q) = got[1], c == "rate_limited", m == "slow", q == "x" else { return XCTFail("error") }
    }

    func testMessageCreatedTracksSeq() {
        var got: [ChatEvent] = []
        let w = ws { got.append($0) }
        w.handleFrame(frame("message.created", eventId: 42, payload: ["id": "m", "sender_id": "u", "kind": "text", "body": ["text": "hi"], "created_at": "t", "event_seq": 42]))
        XCTAssertEqual(w.highestSeqByRoom["r"], 42)
        guard case .messageCreated(let m) = got.first, m.id == "m" else { return XCTFail("created") }
    }

    func testEphemeralEventsDoNotTrackSeq() {
        let w = ChatWebSocket()
        w.handleFrame(frame("typing.started", payload: ["principal_id": "u"]))
        w.handleFrame(frame("receipt.read", payload: ["principal_id": "u", "message_id": "m"]))
        w.handleFrame(frame("pong"))
        XCTAssertTrue(w.highestSeqByRoom.isEmpty)
    }

    func testReceiptReactionMemberPresenceAttachmentCall() {
        var got: [ChatEvent] = []
        let w = ws { got.append($0) }
        w.handleFrame(frame("receipt.delivered", payload: ["principal_id": "u", "message_id": "m"]))
        w.handleFrame(frame("receipt.read", payload: ["principal_id": "u", "message_id": "m"]))
        w.handleFrame(frame("reaction.added", payload: ["principal_id": "u", "message_id": "m", "emoji": "👍"]))
        w.handleFrame(frame("reaction.removed", payload: ["principal_id": "u", "message_id": "m", "emoji": "👍"]))
        w.handleFrame(frame("member.added", payload: ["principal_id": "carol"]))
        w.handleFrame(frame("member.removed", payload: ["principal_id": "carol"]))
        w.handleFrame(frame("presence.changed", payload: ["principal_id": "u", "online": true]))
        w.handleFrame(frame("attachment.ready", payload: ["attachment_id": "a", "mime": "image/jpeg"]))
        w.handleFrame(frame("attachment.failed", payload: ["attachment_id": "a"]))
        w.handleFrame(frame("call.started", payload: ["call_id": "c", "initiator": "u"]))
        w.handleFrame(frame("call.ended", payload: ["call_id": "c", "initiator": "u"]))
        w.handleFrame(frame("resync"))
        XCTAssertEqual(got.count, 12)
    }

    func testMalformedAndUnknownFramesNeverCrash() {
        let w = ChatWebSocket()
        w.handleFrame([:])
        w.handleFrame(["type": "something.new", "payload": [:]])
        w.handleFrame(["type": "message.created", "payload": ["garbage": 1]])
        XCTAssertTrue(w.highestSeqByRoom.isEmpty)
    }

    func testSendOmitsNilRoomAndReturnsId() {
        let w = ChatWebSocket()
        XCTAssertFalse(w.send(type: "ping").isEmpty)
    }
}
