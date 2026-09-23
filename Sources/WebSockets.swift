import Foundation

/// Mirrors Android ChatWebSocket.kt — Sec-WebSocket-Protocol: chatbox, bearer.<token>
public enum ChatEvent {
    case connected, disconnected(code: Int), ack(String), error(code: String, message: String, requestId: String?)
    case messageCreated(MessageResponse), messageUpdated(MessageResponse), messageDeleted(roomId: String, messageId: String)
    case receiptDelivered(roomId: String, messageId: String), receiptRead(roomId: String, messageId: String)
    case reactionAdded(roomId: String, messageId: String, emoji: String), reactionRemoved(roomId: String, messageId: String, emoji: String)
    case memberAdded(roomId: String, user: String), memberRemoved(roomId: String, user: String)
    case typing(roomId: String, user: String, started: Bool), presence(roomId: String, user: String, online: Bool)
    case attachmentReady(roomId: String, attachmentId: String), attachmentFailed(roomId: String, attachmentId: String)
    case callStarted(roomId: String, callId: String), callEnded(roomId: String, callId: String)
    case resync(roomId: String), pong
}

public final class ChatWebSocket: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    public private(set) var isConnected = false
    public var onEvent: ((ChatEvent) -> Void)?
    /// Highest processed event_id per room (docs: persist per room, reconnect with catchup + overlap).
    public private(set) var highestSeqByRoom: [String: Int] = [:]
    private var pingTimer: Timer?

    public func connect(url: String, token: String) {
        // Token is never in the query string (would leak to logs) — subprotocol only.
        var r = URLRequest(url: URL(string: url)!)
        r.setValue("chatbox, bearer.\(token)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = s.webSocketTask(with: r)
        task?.resume()
        isConnected = true
        listen()
        onEvent?(.connected)
        // Resume from last seq with deliberate overlap; keep-alive ping for idle connections.
        for (room, seq) in highestSeqByRoom { catchup(roomId: room, afterSeq: max(0, seq - 5)) }
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in self?.ping() }
    }
    private func listen() {
        task?.receive { [weak self] res in
            if case .success(.string(let text)) = res, let d = text.data(using: .utf8),
               let frame = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                self?.handleFrame(frame)
            }
            self?.listen()
        }
    }
    private func track(room: String, eventId: Int) {
        guard eventId > 0, !room.isEmpty else { return }
        highestSeqByRoom[room] = max(highestSeqByRoom[room] ?? 0, eventId)
    }
    private func decodeMessage(_ payload: [String: Any], roomId: String) -> MessageResponse? {
        var p = payload; if p["room_id"] == nil { p["room_id"] = roomId }
        guard let d = try? JSONSerialization.data(withJSONObject: p) else { return nil }
        return try? JSONDecoder().decode(MessageResponse.self, from: d)
    }
    func handleFrame(_ f: [String: Any]) {
        let type = f["type"] as? String ?? ""
        let roomId = f["room_id"] as? String ?? ""
        let eventId = f["event_id"] as? Int ?? 0
        let payload = f["payload"] as? [String: Any] ?? [:]
        let reqId = f["request_id"] as? String
        switch type {
        case "ack": onEvent?(.ack(reqId ?? ""))
        case "error":
            let e = f["error"] as? [String: Any]
            onEvent?(.error(code: e?["code"] as? String ?? "unknown", message: e?["message"] as? String ?? "error", requestId: reqId))
        case "message.created":
            track(room: roomId, eventId: eventId)
            if let m = decodeMessage(payload, roomId: roomId) { onEvent?(.messageCreated(m)) }
        case "message.updated":
            track(room: roomId, eventId: eventId)
            if let m = decodeMessage(payload, roomId: roomId) { onEvent?(.messageUpdated(m)) }
        case "message.deleted":
            track(room: roomId, eventId: eventId)
            onEvent?(.messageDeleted(roomId: roomId, messageId: payload["id"] as? String ?? ""))
        case "receipt.delivered": onEvent?(.receiptDelivered(roomId: roomId, messageId: payload["message_id"] as? String ?? ""))
        case "receipt.read": onEvent?(.receiptRead(roomId: roomId, messageId: payload["message_id"] as? String ?? ""))
        case "reaction.added": onEvent?(.reactionAdded(roomId: roomId, messageId: payload["message_id"] as? String ?? "", emoji: payload["emoji"] as? String ?? ""))
        case "reaction.removed": onEvent?(.reactionRemoved(roomId: roomId, messageId: payload["message_id"] as? String ?? "", emoji: payload["emoji"] as? String ?? ""))
        case "member.added": onEvent?(.memberAdded(roomId: roomId, user: payload["principal_id"] as? String ?? ""))
        case "member.removed": onEvent?(.memberRemoved(roomId: roomId, user: payload["principal_id"] as? String ?? ""))
        case "typing.started": onEvent?(.typing(roomId: roomId, user: payload["principal_id"] as? String ?? "", started: true))
        case "typing.stopped": onEvent?(.typing(roomId: roomId, user: payload["principal_id"] as? String ?? "", started: false))
        case "presence.changed": onEvent?(.presence(roomId: roomId, user: payload["principal_id"] as? String ?? "", online: payload["online"] as? Bool ?? false))
        case "attachment.ready": onEvent?(.attachmentReady(roomId: roomId, attachmentId: payload["attachment_id"] as? String ?? ""))
        case "attachment.failed": onEvent?(.attachmentFailed(roomId: roomId, attachmentId: payload["attachment_id"] as? String ?? ""))
        case "call.started": onEvent?(.callStarted(roomId: roomId, callId: payload["call_id"] as? String ?? ""))
        case "call.ended": onEvent?(.callEnded(roomId: roomId, callId: payload["call_id"] as? String ?? ""))
        case "resync": onEvent?(.resync(roomId: roomId))
        case "pong": onEvent?(.pong)
        default: break
        }
    }
    @discardableResult
    public func send(type: String, roomId: String? = nil, payload: [String: Any] = [:]) -> String {
        let reqId = UUID().uuidString
        var frame: [String: Any] = ["v": 1, "request_id": reqId, "type": type, "payload": payload]
        if let roomId { frame["room_id"] = roomId } // omit when nil — never send null
        if let d = try? JSONSerialization.data(withJSONObject: frame), let s = String(data: d, encoding: .utf8) {
            task?.send(.string(s)) { _ in }
        }
        return reqId
    }
    public func catchup(roomId: String, afterSeq: Int, limit: Int = 200) { send(type: "catchup", payload: ["after_seq": afterSeq, "limit": limit]) }
    public func ping() { send(type: "ping") }
    /// Idempotent send: reuse `clientId` on retry so the server dedupes (never mint a fresh id per retry).
    @discardableResult
    public func sendMessage(roomId: String, text: String, clientId: String = UUID().uuidString) -> String {
        send(type: "message.send", roomId: roomId, payload: ["client_message_id": clientId, "kind": "text", "body": ["text": text], "attachment_ids": []])
    }
    public func addReaction(roomId: String, messageId: String, emoji: String) {
        send(type: "reaction.add", roomId: roomId, payload: ["message_id": messageId, "emoji": emoji])
    }
    public func removeReaction(roomId: String, messageId: String, emoji: String) {
        send(type: "reaction.remove", roomId: roomId, payload: ["message_id": messageId, "emoji": emoji])
    }
    public func markRead(roomId: String, messageId: String) {
        send(type: "receipt.read", roomId: roomId, payload: ["message_id": messageId])
    }
    public func disconnect() { pingTimer?.invalidate(); isConnected = false; task?.cancel(with: .normalClosure, reason: nil); onEvent?(.disconnected(code: 1000)) }
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // 4401 = re-mint + reconnect + catchup; 4403 = do NOT reconnect; 1001 = backoff reconnect.
        onEvent?(.disconnected(code: code.rawValue))
    }
}

/// Mirrors Android RtcWebSocket.kt — offer/answer/candidate/leave signalling.
public enum RtcEvent { case connected, offer(sdp: String, requestId: Int?), answer(sdp: String), ended, error(String) }
public final class RtcWebSocket: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    public var onEvent: ((RtcEvent) -> Void)?
    public func connect(url: String, token: String) {
        var r = URLRequest(url: URL(string: url)!); r.setValue("chatbox, bearer.\(token)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        task = URLSession(configuration: .default, delegate: self, delegateQueue: .main).webSocketTask(with: r)
        task?.resume(); listen(); onEvent?(.connected)
    }
    private func listen() {
        task?.receive { [weak self] res in
            if case .success(.string(let t)) = res, let d = t.data(using: .utf8),
               let f = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if f["type"] as? String == "offer" { self?.onEvent?(.offer(sdp: f["sdp"] as? String ?? "", requestId: f["request_id"] as? Int)) }
                else if f["type"] as? String == "answer" { self?.onEvent?(.answer(sdp: f["sdp"] as? String ?? "")) }
                else if f["event"] != nil { self?.onEvent?(.ended) }
            }
            self?.listen()
        }
    }
    public func sendOffer(sdp: String) { send(["cmd": "offer", "sdp": ["type": "offer", "sdp": sdp]]) }
    public func sendAnswer(sdp: String, requestId: Int? = nil) {
        var f: [String: Any] = ["cmd": "answer", "sdp": sdp]
        if let requestId { f["request_id"] = requestId } // echo re-offer request_id per docs
        send(f)
    }
    public func sendCandidate(candidate: String, sdpMid: String, sdpMLineIndex: Int) {
        send(["cmd": "candidate", "candidate": ["candidate": candidate, "sdpMid": sdpMid, "sdpMLineIndex": sdpMLineIndex]])
    }
    public func leave() { send(["cmd": "leave"]) }
    private func send(_ f: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: f), let s = String(data: d, encoding: .utf8) { task?.send(.string(s)) { _ in } }
    }
}
