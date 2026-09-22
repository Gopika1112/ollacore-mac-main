import Foundation

public struct ApiException: Error, LocalizedError {
    public var message: String; public var code: String?; public var httpStatus: Int?
    public var retryAfterSeconds: Int?
    public var errorDescription: String? { message }
    public var isRateLimited: Bool { httpStatus == 429 }
}

/// Mirrors Android OllacoreApi.kt — directory plane (session token) + client plane (room token).
public final class OllacoreAPI {
    public static let shared = OllacoreAPI()
    public var apiBase = AppConfig.apiBase
    public var appId: String { AppConfig.appId }
    private let session = URLSession.shared
    private let json = JSONEncoder()

    /// URL builder: path segments percent-encoded, query via URLQueryItem — never manual concatenation.
    /// `path` is relative to apiBase (e.g. "directory/inbox"), without leading "/v1".
    func url(path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(string: apiBase) ?? URLComponents(string: "https://api.ollacore.com/v1")!
        let basePath = c.path
        let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        c.path = basePath + "/" + encoded
        c.queryItems = query.isEmpty ? nil : query
        return c.url ?? URL(string: "https://api.ollacore.com/v1/\(encoded)")!
    }
    private func req(url: URL, method: String, sessionToken: String? = nil, roomToken: String? = nil, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let t = sessionToken ?? roomToken { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        r.httpBody = body
        return r
    }
    private func req(_ path: String, method: String, sessionToken: String? = nil, roomToken: String? = nil, body: Data? = nil) -> URLRequest {
        req(url: url(path: path), method: method, sessionToken: sessionToken, roomToken: roomToken, body: body)
    }
    private func enc<T: Encodable>(_ v: T) throws -> Data { try JSONEncoder().encode(v) }
    private func exec<T: Decodable>(_ r: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw ApiException(message: "No response", code: nil, httpStatus: nil) }
        guard (200..<300).contains(http.statusCode) else {
            // 422 is plain-text (framework rejection); 429 carries Retry-After — both per /docs/errors/.
            let retry = OllacoreConventions.retryAfterSeconds(headers: http.allHeaderFields)
            if http.statusCode == 422 {
                let text = String(data: data, encoding: .utf8) ?? "unprocessable"
                throw ApiException(message: text, code: "unprocessable", httpStatus: 422, retryAfterSeconds: retry)
            }
            let err = try? JSONDecoder().decode(ApiError.self, from: data)
            throw ApiException(message: err?.message ?? "HTTP \(http.statusCode)", code: err?.code, httpStatus: http.statusCode, retryAfterSeconds: retry)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    /// Fire-and-forget that reports success so silent failures (receipts, devices, logout) are visible to callers.
    @discardableResult
    private func fire(_ r: URLRequest) async -> Bool {
        do {
            let (_, resp) = try await session.data(for: r)
            return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch { return false }
    }

    private func requireAppId() throws {
        if appId.isEmpty { throw ApiException(message: "App not configured: set OLLACORE_APP_ID.", code: "missing_config", httpStatus: nil) }
    }

    // Directory Auth
    public func requestOtp(phone: String) async throws -> OtpResponse {
        try requireAppId()
        return try await exec(req("/directory/otp/request", method: "POST", body: try enc(OtpRequest(app_id: appId, phone: phone))))
    }
    public func verifyOtp(phone: String, code: String) async throws -> OtpVerifyResponse {
        try requireAppId()
        return try await exec(req("/directory/otp/verify", method: "POST", body: try enc(OtpVerify(app_id: appId, phone: phone, code: code))))
    }
    public func getProfile(token: String) async throws -> UserProfile {
        try await exec(req("/directory/me", method: "GET", sessionToken: token))
    }
    public func updateProfile(token: String, req: UpdateProfileRequest) async throws -> UserProfile {
        try await exec(self.req("/directory/me", method: "PATCH", sessionToken: token, body: try enc(req)))
    }
    public func logout(token: String) async { await fire(req("/directory/logout", method: "POST", sessionToken: token, body: Data("{}".utf8))) }

    // Conversations / inbox
    public func listConversations(token: String) async throws -> [ConversationSummary] {
        struct R: Decodable { var conversations: [ConversationSummary] }
        let r: R = try await exec(req("/directory/conversations", method: "GET", sessionToken: token))
        return r.conversations
    }
    public func getInbox(token: String, limit: Int = 30) async throws -> [InboxItem] {
        struct R: Decodable { var conversations: [InboxItem] }
        let r: R = try await exec(req(url: url(path: "directory/inbox", query: [URLQueryItem(name: "limit", value: "\(limit)")]), method: "GET", sessionToken: token))
        return r.conversations
    }
    public func openDirect(token: String, peerUserId: String) async throws -> ConversationSummary {
        struct B: Encodable { var peer_user_id: String }
        return try await exec(req("/directory/conversations/direct", method: "POST", sessionToken: token, body: try enc(B(peer_user_id: peerUserId))))
    }
    public func createGroup(token: String, members: [String], name: String) async throws -> ConversationSummary {
        struct B: Encodable { var member_user_ids: [String]; var name: String }
        return try await exec(req("/directory/conversations/group", method: "POST", sessionToken: token, body: try enc(B(member_user_ids: members, name: name))))
    }
    public func roomToken(token: String, roomId: String, deviceId: String) async throws -> RoomTokenResponse {
        try await exec(req(url: url(path: "directory/conversations/\(roomId)/token", query: [URLQueryItem(name: "device_id", value: deviceId)]), method: "GET", sessionToken: token))
    }
    public func lookupContacts(token: String, phones: [String]) async throws -> [ContactUser] {
        struct B: Encodable { var phones: [String] }; struct R: Decodable { var contacts: [ContactUser] }
        let r: R = try await exec(req("/directory/contacts/lookup", method: "POST", sessionToken: token, body: try enc(B(phones: phones))))
        return r.contacts
    }

    // Messages (room token)
    public func listMessages(roomToken: String, roomId: String, limit: Int = 50, afterSeq: Int? = nil, beforeSeq: Int? = nil) async throws -> [MessageResponse] {
        struct R: Decodable { var messages: [MessageResponse]; var has_more: Bool }
        var q: [URLQueryItem] = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let a = afterSeq { q.append(URLQueryItem(name: "after_seq", value: "\(a)")) }
        if let b = beforeSeq { q.append(URLQueryItem(name: "before_seq", value: "\(b)")) }
        let r: R = try await exec(req(url: url(path: "rooms/\(roomId)/messages", query: q), method: "GET", roomToken: roomToken))
        return r.messages
    }
    public func sendMessage(roomToken: String, roomId: String, clientId: String, kind: String, body: [String: AnyCodable], replyTo: String? = nil, attachments: [String] = []) async throws -> MessageResponse {
        struct B: Encodable { var client_message_id: String; var kind: String; var body: [String: AnyCodable]; var reply_to: String?; var attachment_ids: [String] }
        return try await exec(req("/rooms/\(roomId)/messages", method: "POST", roomToken: roomToken, body: try enc(B(client_message_id: clientId, kind: kind, body: body, reply_to: replyTo, attachment_ids: attachments))))
    }
    @discardableResult
    public func markRead(roomToken: String, roomId: String, messageId: String) async -> Bool {
        await fire(req("/rooms/\(roomId)/messages/\(messageId)/read", method: "POST", roomToken: roomToken, body: Data()))
    }
    /// Documented endpoint: GET /v1/rooms/{room_id}/messages/search?q=&limit= (Client API).
    public func searchMessages(roomToken: String, roomId: String, q: String, limit: Int = 20) async throws -> [MessageResponse] {
        struct R: Decodable { var messages: [MessageResponse]; var has_more: Bool }
        let r: R = try await exec(req(url: url(path: "rooms/\(roomId)/messages/search", query: [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: "\(limit)")]), method: "GET", roomToken: roomToken))
        return r.messages
    }

    // Devices
    public func listDevices(token: String) async throws -> [DeviceResponse] {
        struct R: Decodable { var devices: [DeviceResponse] }
        let r: R = try await exec(req("/directory/devices", method: "GET", sessionToken: token))
        return r.devices
    }
    @discardableResult
    public func registerDevice(token: String, platform: String = "macos", pushToken: String) async -> Bool {
        struct B: Encodable { var platform: String; var push_token: String }
        guard let body = try? enc(B(platform: platform, push_token: pushToken)) else { return false }
        return await fire(req("/directory/devices", method: "POST", sessionToken: token, body: body))
    }
}
