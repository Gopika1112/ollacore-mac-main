import Foundation
import SwiftUI

// MARK: - SessionStore (sensitive auth secrets in Keychain; UserDefaults only for harmless prefs)
@MainActor public final class SessionStore: ObservableObject {
    @Published public private(set) var sessionToken: String?
    @Published public private(set) var userId: String?
    public init() {
        sessionToken = KeychainHelper.read(account: "session_token")
        userId = KeychainHelper.read(account: "user_id")
    }
    public var isAuthenticated: Bool { sessionToken != nil }
    public func save(token: String, userId: String) {
        KeychainHelper.save(token, account: "session_token")
        KeychainHelper.save(userId, account: "user_id")
        self.sessionToken = token; self.userId = userId
    }
    public func clear() {
        KeychainHelper.clearAuth()
        RoomTokenCache.shared.clear()
        sessionToken = nil; userId = nil
    }
    public var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: "device_id") { return id }
        let id = "mac-\(UUID().uuidString.prefix(8))"; UserDefaults.standard.set(id, forKey: "device_id"); return id
    }
}

// MARK: - AuthViewModel (mirrors Android AuthViewModel: PHONE_INPUT -> OTP -> AUTHENTICATED)
@MainActor public final class AuthViewModel: ObservableObject {
    public enum Step { case phoneInput, otp, authenticated }
    @Published public var step: Step = .phoneInput
    @Published public var phone = ""
    @Published public var otpCode = ""
    @Published public var isLoading = false
    @Published public var error: String?
    @Published public var displayName: String?
    @Published public var about: String?
    @Published public var avatarUrl: String?
    public let session = SessionStore()
    private let api = OllacoreAPI.shared

    public init() { if session.isAuthenticated { step = .authenticated } }
    public func requestOtp() async {
        isLoading = true; defer { isLoading = false }
        do { _ = try await api.requestOtp(phone: phone); step = .otp }
        catch { self.error = error.localizedDescription }
    }
    public func verifyOtp() async {
        isLoading = true; defer { isLoading = false }
        do {
            let r = try await api.verifyOtp(phone: phone, code: otpCode)
            session.save(token: r.session_token, userId: r.user_id)
            displayName = r.display_name; step = .authenticated
        } catch { self.error = error.localizedDescription }
    }
    public func logout() async {
        if let t = session.sessionToken { await api.logout(token: t) }
        session.clear(); step = .phoneInput
    }
}

// MARK: - Home / Chat ViewModels (mirror HomeViewModel + ChatViewModel + ChatRepository)
@MainActor public final class HomeViewModel: ObservableObject {
    @Published public var inbox: [InboxItem] = []; @Published public var isLoading = false
    private let api = OllacoreAPI.shared
    public func refresh(token: String) async {
        isLoading = true; defer { isLoading = false }
        inbox = (try? await api.getInbox(token: token)) ?? []
    }
}
@MainActor public final class ChatViewModel: ObservableObject {
    @Published public var messages: [MessageResponse] = []
    @Published public var rateLimitedNotice: String?
    public var socket = ChatWebSocket()
    private let api = OllacoreAPI.shared
    private var seenIds: Set<String> = []
    private var currentRoom = "", currentToken = ""
    public func join(roomToken: String, roomId: String, wsUrl: String) async {
        currentRoom = roomId; currentToken = roomToken
        let hist = (try? await api.listMessages(roomToken: roomToken, roomId: roomId)) ?? []
        messages = hist.sorted { $0.event_seq < $1.event_seq }
        seenIds = Set(messages.map(\.id))
        RoomTokenCache.shared.set(roomId: roomId, token: roomToken, wsURL: wsUrl, rtcURL: "")
        socket.onEvent = { [weak self] e in
            Task { @MainActor in
                guard let self else { return }
                switch e {
                case .messageCreated(let m):
                    guard !self.seenIds.contains(m.id) else { break } // duplicate prevention
                    self.seenIds.insert(m.id)
                    self.messages.append(m)
                    self.messages.sort { $0.event_seq < $1.event_seq } // ordering by seq
                case .messageUpdated(let m):
                    if let i = self.messages.firstIndex(where: { $0.id == m.id }) { self.messages[i] = m }
                case .messageDeleted(_, let id): self.messages.removeAll { $0.id == id }
                case .error(let code, let msg, _):
                    if code == "rate_limited" { self.rateLimitedNotice = msg } // WS 429 surfaced, not fatal
                case .resync:
                    // Fell too far behind: refetch history, reset cursor.
                    let fresh = (try? await self.api.listMessages(roomToken: self.currentToken, roomId: self.currentRoom)) ?? []
                    self.messages = fresh.sorted { $0.event_seq < $1.event_seq }
                    self.seenIds = Set(fresh.map(\.id))
                default: break
                }
            }
        }
        socket.connect(url: wsUrl, token: roomToken)
    }
    public func send(roomId: String, text: String) { socket.sendMessage(roomId: roomId, text: text) }
    /// Retry reuses the same client_message_id for idempotency.
    public func retry(roomId: String, text: String, clientId: String) { socket.sendMessage(roomId: roomId, text: text, clientId: clientId) }
    public func disconnect() { socket.disconnect() }
}

// MARK: - Backend message search (GET /v1/rooms/{id}/messages/search, room-token plane)
@MainActor public final class RoomSearchViewModel: ObservableObject {
    @Published public var results: [MessageResponse] = []
    @Published public var isSearching = false
    private let api = OllacoreAPI.shared
    public func search(roomId: String, query: String, sessionToken: String? = nil, deviceId: String? = nil) async {
        guard !query.isEmpty else { results = []; return }
        isSearching = true; defer { isSearching = false }
        var rt = RoomTokenCache.shared.get(roomId: roomId)
        if rt == nil, let sessionToken, let deviceId {
            // Lazily mint a room token so sidebar search works before the chat is opened.
            if let fresh = try? await api.roomToken(token: sessionToken, roomId: roomId, deviceId: deviceId) {
                RoomTokenCache.shared.set(roomId: roomId, token: fresh.access_token, wsURL: fresh.chat_websocket_url, rtcURL: fresh.rtc_websocket_url)
                rt = RoomTokenCache.shared.get(roomId: roomId)
            }
        }
        guard let rt else { results = []; return }
        do {
            results = try await api.searchMessages(roomToken: rt.token, roomId: roomId, q: query)
        } catch let e as ApiException where e.isRateLimited {
            // Honor Retry-After: keep prior results, caller may retry after delay.
            try? await Task.sleep(nanoseconds: UInt64(e.retryAfterSeconds ?? 2) * 1_000_000_000)
            results = (try? await api.searchMessages(roomToken: rt.token, roomId: roomId, q: query)) ?? results
        } catch { results = [] }
    }
}

// MARK: - CallLogStore (mirrors Android CallLogStore — client-only JSON)
public struct CallEntry: Codable, Identifiable { public var id: String; public var roomId: String; public var peerName: String; public var audioOnly: Bool; public var date: Date }
@MainActor public final class CallLogStore: ObservableObject {
    @Published public var entries: [CallEntry] = []
    public init() {
        if let d = UserDefaults.standard.data(forKey: "call_log"),
           let e = try? JSONDecoder().decode([CallEntry].self, from: d) { entries = e }
    }
    public func add(_ e: CallEntry) { entries.insert(e, at: 0); persist() }
    public func clear() { entries = []; persist() }
    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: "call_log") }
}
