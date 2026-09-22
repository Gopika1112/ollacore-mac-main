import Foundation

// MARK: - Directory Auth
public struct OtpRequest: Codable { public var app_id: String; public var phone: String }
public struct OtpResponse: Codable { public var dispatched: Bool; public var expires_at: String? }
public struct OtpVerify: Codable { public var app_id: String; public var phone: String; public var code: String }
public struct OtpVerifyResponse: Codable { public var session_token: String; public var user_id: String; public var display_name: String? }
public struct UserProfile: Codable { public var id: String; public var phone: String; public var display_name: String?; public var about: String?; public var avatar_url: String?; public var photo_url: String? }
public struct UpdateProfileRequest: Codable { public var display_name: String?; public var about: String?; public var avatar_url: String? }

// MARK: - Contacts & Conversations
public struct ContactUser: Codable { public var user_id: String; public var phone: String; public var display_name: String? }
public struct ConversationSummary: Codable { public var room_id: String; public var kind: String; public var name: String?; public var created_at: String? }
public struct InboxPeer: Codable { public var phone: String; public var user_id: String; public var display_name: String? }
public struct LastMessage: Codable { public var preview: String?; public var sender_id: String?; public var created_at: String?; public var event_seq: Int?; public var kind: String? }
public struct InboxItem: Codable { public var room_id: String; public var kind: String; public var name: String?; public var peer: InboxPeer?; public var last_message: LastMessage?; public var unread_count: Int }

// MARK: - Room token
public struct IceServer: Codable { public var urls: [String]; public var username: String?; public var credential: String? }
public struct E2eeConfig: Codable {
    public var encrypted: Bool; public var content_free_push: Bool
    public init(encrypted: Bool = false, content_free_push: Bool = false) {
        self.encrypted = encrypted; self.content_free_push = content_free_push
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        encrypted = try c.decodeIfPresent(Bool.self, forKey: .encrypted) ?? false
        content_free_push = try c.decodeIfPresent(Bool.self, forKey: .content_free_push) ?? false
    }
    private enum CodingKeys: String, CodingKey { case encrypted, content_free_push }
}
public struct RoomTokenResponse: Codable {
    public var access_token: String; public var expires_at: String
    public var chat_websocket_url: String; public var rtc_websocket_url: String
    public var ice_servers: [IceServer]; public var e2ee: E2eeConfig?
    private enum CodingKeys: String, CodingKey {
        case access_token, expires_at, chat_websocket_url, rtc_websocket_url, ice_servers, e2ee
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        access_token = try c.decode(String.self, forKey: .access_token)
        expires_at = try c.decode(String.self, forKey: .expires_at)
        chat_websocket_url = try c.decode(String.self, forKey: .chat_websocket_url)
        rtc_websocket_url = try c.decode(String.self, forKey: .rtc_websocket_url)
        ice_servers = try c.decodeIfPresent([IceServer].self, forKey: .ice_servers) ?? []
        e2ee = try c.decodeIfPresent(E2eeConfig.self, forKey: .e2ee)
    }
}

// MARK: - Messages
public struct MessageResponse: Codable, Identifiable {
    public var id: String; public var room_id: String; public var sender_id: String
    public var kind: String; public var body: [String: AnyCodable]
    public var created_at: String; public var event_seq: Int
    public var client_message_id: String?; public var reply_to: String?
    public var edited_at: String?; public var attachment_ids: [String]
    private enum CodingKeys: String, CodingKey {
        case id, room_id, sender_id, kind, body, created_at, event_seq
        case client_message_id, reply_to, edited_at, attachment_ids
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        room_id = try c.decode(String.self, forKey: .room_id)
        sender_id = try c.decode(String.self, forKey: .sender_id)
        kind = try c.decode(String.self, forKey: .kind)
        body = try c.decode([String: AnyCodable].self, forKey: .body)
        created_at = try c.decode(String.self, forKey: .created_at)
        event_seq = try c.decode(Int.self, forKey: .event_seq)
        client_message_id = try c.decodeIfPresent(String.self, forKey: .client_message_id)
        reply_to = try c.decodeIfPresent(String.self, forKey: .reply_to)
        edited_at = try c.decodeIfPresent(String.self, forKey: .edited_at)
        attachment_ids = try c.decodeIfPresent([String].self, forKey: .attachment_ids) ?? []
    }
}
public struct AttachmentInfo: Codable { public var attachment_id: String; public var mime: String?; public var filename: String?; public var byte_size: Int64? }
public struct Participant: Codable { public var principal_id: String; public var role: String?; public var display_name: String?; public var phone: String? }
public struct DeviceResponse: Codable, Identifiable { public var id: String; public var platform: String; public var push_token: String; public var app_id: String; public var updated_at: String }
public struct ApiError: Codable { public var code: String; public var message: String }
public enum MessageKinds { public static let text="text", image="image", video="video", audio="audio", file="file", location="location" }

// AnyCodable supporting nested objects/arrays (locations, structured payloads).
public struct AnyCodable: Codable {
    public var value: Any
    public init(_ value: Any) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) }
        else if let o = try? c.decode([String: AnyCodable].self) { value = o.mapValues { $0.value } }
        else { value = "" }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let s as String: try c.encode(s)
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let a as [Any]: try c.encode(a.map(AnyCodable.init))
        case let o as [String: Any]: try c.encode(o.mapValues(AnyCodable.init))
        default: try c.encode(String(describing: value))
        }
    }
}
