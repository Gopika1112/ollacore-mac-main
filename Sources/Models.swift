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
public struct E2eeConfig: Codable { public var encrypted: Bool; public var content_free_push: Bool }
public struct RoomTokenResponse: Codable { public var access_token: String; public var expires_at: String; public var chat_websocket_url: String; public var rtc_websocket_url: String; public var ice_servers: [IceServer]; public var e2ee: E2eeConfig? }

// MARK: - Messages
public struct MessageResponse: Codable, Identifiable {
    public var id: String; public var room_id: String; public var sender_id: String
    public var kind: String; public var body: [String: AnyCodable]
    public var created_at: String; public var event_seq: Int
    public var client_message_id: String?; public var reply_to: String?
    public var edited_at: String?; public var attachment_ids: [String]
}
public struct AttachmentInfo: Codable { public var attachment_id: String; public var mime: String?; public var filename: String?; public var byte_size: Int64? }
public struct Participant: Codable { public var principal_id: String; public var role: String?; public var display_name: String?; public var phone: String? }
public struct DeviceResponse: Codable, Identifiable { public var id: String; public var platform: String; public var push_token: String; public var app_id: String; public var updated_at: String }
public struct ApiError: Codable { public var code: String; public var message: String }
public enum MessageKinds { public static let text="text", image="image", video="video", audio="audio", file="file", location="location" }

// Minimal AnyCodable for body dictionaries
public struct AnyCodable: Codable {
    public var value: Any
    public init(_ value: Any) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let b = try? c.decode(Bool.self) { value = b }
        else { value = "" }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let s as String: try c.encode(s)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let b as Bool: try c.encode(b)
        default: try c.encode(String(describing: value))
        }
    }
}
