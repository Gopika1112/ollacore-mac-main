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
    /// Returns false when Keychain storage fails: the caller must NOT treat the
    /// session as authenticated, or the user appears logged in until restart.
    @discardableResult
    public func save(token: String, userId: String) -> Bool {
        let okToken = KeychainHelper.save(token, account: "session_token")
        let okUser = KeychainHelper.save(userId, account: "user_id")
        guard okToken && okUser else {
            KeychainHelper.delete(account: "session_token")
            KeychainHelper.delete(account: "user_id")
            return false
        }
        self.sessionToken = token; self.userId = userId
        return true
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
    private let api: OllacoreAPI
    private var authObserver: NSObjectProtocol?
    public init(api: OllacoreAPI = .shared) {
        self.api = api
        if session.isAuthenticated { step = .authenticated }
        authObserver = NotificationCenter.default.addObserver(forName: .ollacoreUnauthorized, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleUnauthorized() }
        }
    }
    deinit {
        if let t = authObserver { NotificationCenter.default.removeObserver(t) }
    }
    /// Central 401 handling: a dead credential signs out everywhere at once, never stranded.
    public func handleUnauthorized() {
        guard step == .authenticated else { return }
        session.clear()
        step = .phoneInput
        error = "Session expired. Please sign in again."
    }
    /// Backend resend cap is 3/min: space OTP requests 20s apart, surfaced in UI.
    public var resendCooldownSeconds = 20
    public var lastOtpRequestAt: Date?
    public func canResend(now: Date = Date()) -> Bool {
        guard let last = lastOtpRequestAt else { return true }
        return now.timeIntervalSince(last) >= Double(resendCooldownSeconds)
    }
    public func resendRemaining(now: Date = Date()) -> Int {
        guard let last = lastOtpRequestAt else { return 0 }
        return max(0, Int((Double(resendCooldownSeconds) - now.timeIntervalSince(last)).rounded(.up)))
    }

    public func requestOtp() async {
        guard canResend() else { error = "Wait \(resendRemaining())s before resending the code."; return }
        isLoading = true; defer { isLoading = false }
        do {
            _ = try await api.requestOtp(phone: phone)
            lastOtpRequestAt = Date() // cooldown starts only on success; failures stay retryable
            step = .otp
        } catch { self.error = error.localizedDescription }
    }
    public func verifyOtp() async {
        isLoading = true; defer { isLoading = false }
        do {
            let r = try await api.verifyOtp(phone: phone, code: otpCode)
            guard session.save(token: r.session_token, userId: r.user_id) else {
                error = "Verified, but the session could not be stored securely. Please try again."
                return
            }
            displayName = r.display_name; step = .authenticated
        } catch { self.error = error.localizedDescription }
    }
    public func logout() async {
        // Local session always clears (security); a server failure is surfaced, not hidden.
        var serverOk = true
        if let t = session.sessionToken { serverOk = await api.logout(token: t) }
        session.clear(); step = .phoneInput
        if !serverOk { error = "Signed out on this device; the server did not confirm logout." }
    }
}

// MARK: - Home / Chat ViewModels (mirror HomeViewModel + ChatViewModel + ChatRepository)
@MainActor public final class HomeViewModel: ObservableObject {
    @Published public var inbox: [InboxItem] = []; @Published public var isLoading = false
    @Published public var error: String?
    private let api = OllacoreAPI.shared
    public func refresh(token: String) async {
        isLoading = true; defer { isLoading = false }
        do {
            inbox = try await api.getInbox(token: token)
            error = nil
        } catch {
            // Preserve last good data: failure surfaces as an error, never as an empty inbox.
            self.error = error.localizedDescription
        }
    }
}
public enum ReceiptState { case sent, delivered, read }

public struct FailedDraft: Identifiable {
    public var id: String // client_message_id, reused on retry for idempotency
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

@MainActor public final class ChatViewModel: ObservableObject {
    @Published public var messages: [MessageResponse] = []
    @Published public var rateLimitedNotice: String?
    @Published public var receipts: [String: ReceiptState] = [:]
    @Published public var reactions: [String: [String: Int]] = [:]
    @Published public var activeCall: (callId: String, initiator: String)?
    @Published public var attachmentURLs: [String: URL] = [:]
    @Published public private(set) var failedDrafts: [FailedDraft] = []
    @Published public private(set) var sendingCount = 0
    @Published public var replyTo: MessageResponse?
    @Published public private(set) var deletedIds: Set<String> = []
    @Published public var selectionMode = false
    @Published public private(set) var selectedIds: Set<String> = []
    @Published public var connectionError: String?
    @Published public var accessRevoked = false
    /// Set by the view: re-mint a room token and reconnect after 4401.
    public var onTokenExpired: (() -> Void)?
    private var pendingFrames: [String: (clientId: String, text: String)] = [:] // frame request_id → send
    public var socket = ChatWebSocket()
    private let api: OllacoreAPI
    public init(api: OllacoreAPI = .shared) { self.api = api }
    private var seenIds: Set<String> = []
    private var joinGen = 0
    private var currentRoom = "", currentToken = ""
    /// ST-01: bound in-memory history so long sessions can't grow without limit.
    public var maxRetainedMessages = 300
    private func enforceWindow() {
        guard messages.count > maxRetainedMessages else { return }
        messages = Array(messages.sorted { $0.event_seq < $1.event_seq }.suffix(maxRetainedMessages))
        seenIds = Set(messages.map(\.id))
    }
    public var ownId: String?
    @Published public var historyError: String?
    @Published public var historyLoaded = false
    public func join(roomToken: String, roomId: String, wsUrl: String, ownId: String? = nil, expiresAt: String? = nil) async {
        if let ownId { self.ownId = ownId }
        // Defensive: never stack sockets if join is called twice for any reason.
        socket.disconnect()
        socket.onEvent = nil
        socket.onSendFailure = nil
        joinGen += 1
        let gen = joinGen
        currentRoom = roomId; currentToken = roomToken
        connectionError = nil; accessRevoked = false
        historyError = nil; historyLoaded = false
        // Per-room state never carries over: a recycled VM starts clean.
        receipts.removeAll(); reactions.removeAll()
        failedDrafts.removeAll(); pendingFrames.removeAll(); sendingCount = 0
        selectedIds.removeAll(); selectionMode = false
        do {
            let hist = try await api.listMessages(roomToken: roomToken, roomId: roomId)
            guard gen == joinGen else { return } // superseded by a newer join: publish nothing
            historyError = nil // success clears any error left by an older join
            messages = hist.sorted { $0.event_seq < $1.event_seq }
            seenIds = Set(messages.map(\.id))
            enforceWindow()
            historyLoaded = true
        } catch {
            // Failed history: stay out of the socket and report, instead of an empty room.
            // Guarded like the success path: a stale join's failure must not stain the new room.
            guard gen == joinGen else { return }
            historyError = error.localizedDescription
            return
        }
        RoomTokenCache.shared.set(roomId: roomId, token: roomToken, wsURL: wsUrl, rtcURL: "", expiresAt: expiresAt)
        socket.onSendFailure = { [weak self] reqId in
            Task { @MainActor in self?.failPending(requestId: reqId) }
        }
        socket.onEvent = { [weak self] e in
            Task { @MainActor in
                guard let self else { return }
                switch e {
                case .messageCreated(let m):
                    guard self.isCurrentRoom(m.room_id) else { break } // cross-room events never apply
                    guard !self.seenIds.contains(m.id) else { break } // duplicate prevention
                    self.seenIds.insert(m.id)
                    self.messages.append(m)
                    self.messages.sort { $0.event_seq < $1.event_seq } // ordering by seq
                    self.enforceWindow()
                    if m.sender_id == self.ownId {
                        if self.receipts[m.id] == nil { self.receipts[m.id] = .sent }
                        // A send we tracked succeeded: clear pending + any failed draft.
                        if let cid = m.client_message_id { self.clearPending(clientId: cid) }
                    }
                case .messageUpdated(let m):
                    guard self.isCurrentRoom(m.room_id) else { break }
                    if let i = self.messages.firstIndex(where: { $0.id == m.id }) { self.messages[i] = m }
                case .messageDeleted(let room, let id):
                    guard self.isCurrentRoom(room) else { break }
                    // Tombstone: keep the row so history doesn't look corrupted.
                    self.deletedIds.insert(id)
                    self.reactions.removeValue(forKey: id)
                case .ack(let reqId):
                    self.pendingFrames.removeValue(forKey: reqId)
                    self.sendingCount = self.pendingFrames.count
                case .error(let code, let msg, let reqId):
                    if code == "rate_limited" { self.rateLimitedNotice = msg }
                    if let reqId { self.failPending(requestId: reqId) }
                case .receiptDelivered(let room, let id):
                    guard self.isCurrentRoom(room) else { break }; self.receipts[id] = .delivered
                case .receiptRead(let room, let id):
                    guard self.isCurrentRoom(room) else { break }; self.receipts[id] = .read
                case .reactionAdded(let room, let id, let emoji):
                    guard self.isCurrentRoom(room) else { break }
                    var m = self.reactions[id] ?? [:]; m[emoji, default: 0] += 1; self.reactions[id] = m
                case .reactionRemoved(let room, let id, let emoji):
                    guard self.isCurrentRoom(room) else { break }
                    var m = self.reactions[id] ?? [:]
                    m[emoji, default: 1] -= 1
                    if (m[emoji] ?? 0) <= 0 { m.removeValue(forKey: emoji) }
                    self.reactions[id] = m.isEmpty ? nil : m
                case .callStarted(let room, let callId):
                    guard self.isCurrentRoom(room) else { break }
                    // Banner only: in-call audio/video UI is not built; never fake an answered call.
                    self.activeCall = (callId, "")
                case .callEnded(let room, _):
                    guard self.isCurrentRoom(room) else { break }; self.activeCall = nil
                case .tokenExpired:
                    self.connectionError = "Session expired. Reopen the chat to reconnect."
                    self.onTokenExpired?()
                case .membershipRevoked: self.accessRevoked = true
                case .resync:
                    // Fell too far behind: refetch history, reset cursor.
                    // Generation-guarded: a room switch mid-fetch must not restore stale data.
                    let gen = self.joinGen
                    let fresh = (try? await self.api.listMessages(roomToken: self.currentToken, roomId: self.currentRoom)) ?? []
                    guard gen == self.joinGen else { break }
                    self.messages = fresh.sorted { $0.event_seq < $1.event_seq }
                    self.seenIds = Set(fresh.map(\.id))
                    self.enforceWindow()
                default: break
                }
            }
        }
        socket.connect(url: wsUrl, token: roomToken)
    }
    private func clearPending(clientId: String) {
        pendingFrames = pendingFrames.filter { $0.value.clientId != clientId }
        sendingCount = pendingFrames.count
        failedDrafts.removeAll { $0.id == clientId }
    }
    private func isCurrentRoom(_ room: String) -> Bool { room == currentRoom }
    private func failPending(requestId: String) {
        guard let p = pendingFrames.removeValue(forKey: requestId) else { return }
        sendingCount = pendingFrames.count
        if !failedDrafts.contains(where: { $0.id == p.clientId }) {
            failedDrafts.append(FailedDraft(id: p.clientId, text: p.text))
        }
    }
    @discardableResult
    public func send(roomId: String, text: String) -> String {
        // ST-03: the view trims too, but programmatic sends must never push blanks.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let clientId = UUID().uuidString
        let reqId = socket.sendMessage(roomId: roomId, text: text, clientId: clientId, replyTo: replyTo?.id)
        pendingFrames[reqId] = (clientId, text)
        sendingCount = pendingFrames.count
        replyTo = nil
        return reqId
    }
    /// Retry reuses the same client_message_id for idempotency.
    @discardableResult
    public func retry(roomId: String, text: String, clientId: String) -> String {
        let reqId = socket.sendMessage(roomId: roomId, text: text, clientId: clientId)
        pendingFrames[reqId] = (clientId, text)
        sendingCount = pendingFrames.count
        failedDrafts.removeAll { $0.id == clientId }
        return reqId
    }
    /// Paging for long chats: prepends older messages (deduplicated), newest stay put.
    public func loadMore() async {
        guard historyLoaded, !currentRoom.isEmpty, let oldest = messages.map(\.event_seq).min() else { return }
        guard let older = try? await api.listMessages(roomToken: currentToken, roomId: currentRoom, beforeSeq: oldest) else { return }
        for m in older where !seenIds.contains(m.id) && m.room_id == currentRoom {
            seenIds.insert(m.id)
            messages.append(m)
        }
        messages.sort { $0.event_seq < $1.event_seq }
        enforceWindow()
    }
    public func retryDraft(roomId: String, draft: FailedDraft) {
        let reqId = socket.sendMessage(roomId: roomId, text: draft.text, clientId: draft.id)
        pendingFrames[reqId] = (draft.id, draft.text)
        sendingCount = pendingFrames.count
        failedDrafts.removeAll { $0.id == draft.id }
    }
    public func deleteMessage(roomId: String, messageId: String) {
        socket.deleteMessage(roomId: roomId, messageId: messageId)
        Task { _ = await api.deleteMessage(roomToken: currentToken, roomId: roomId, messageId: messageId) }
        deletedIds.insert(messageId) // optimistic tombstone; server echo confirms
    }
    public func forwardMessage(_ msg: MessageResponse, toRoomId: String, sessionToken: String, deviceId: String) async -> Bool {
        // Fresh id: a forward is a new message (unlike retry, which must reuse the id).
        guard let rt = try? await api.roomToken(token: sessionToken, roomId: toRoomId, deviceId: deviceId) else { return false }
        let body = msg.body
        return (try? await api.sendMessage(roomToken: rt.access_token, roomId: toRoomId, clientId: UUID().uuidString, kind: msg.kind, body: body, attachmentIds: msg.attachment_ids)) != nil
    }
    // MARK: Selection
    public func toggleSelect(id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
        if selectedIds.isEmpty { selectionMode = false }
    }
    public func clearSelection() { selectedIds.removeAll(); selectionMode = false }
    public func deleteSelected(roomId: String) {
        for id in selectedIds { deleteMessage(roomId: roomId, messageId: id) }
        clearSelection()
    }
    public func disconnect() {
        joinGen += 1 // invalidate any in-flight join: it must not connect after the view is gone
        socket.disconnect()
    }
    public func addReaction(roomId: String, messageId: String, emoji: String) {
        socket.addReaction(roomId: roomId, messageId: messageId, emoji: emoji)
        Task { _ = await api.addReaction(roomToken: currentToken, roomId: roomId, messageId: messageId, emoji: emoji) }
    }
    public func removeReaction(roomId: String, messageId: String, emoji: String) {
        socket.removeReaction(roomId: roomId, messageId: messageId, emoji: emoji)
        Task { _ = await api.removeReaction(roomToken: currentToken, roomId: roomId, messageId: messageId, emoji: emoji) }
    }
    public func markVisibleAsRead(roomId: String) {
        // One receipt for the latest message: the read cursor already covers everything before it.
        guard let last = messages.last else { return }
        socket.markRead(roomId: roomId, messageId: last.id)
        Task { _ = await api.markRead(roomToken: currentToken, roomId: roomId, messageId: last.id) }
    }
    public func dismissCall() { activeCall = nil }
    public var currentSenderId: String? { ownId }
    public func receiptLabel(for messageId: String) -> String {
        switch receipts[messageId] {
        case .read: return "✓✓ read"
        case .delivered: return "✓✓"
        default: return "✓"
        }
    }
    public func receiptColor(for messageId: String) -> Color {
        receipts[messageId] == .read ? .blue : .secondary
    }
    public func resolveAttachmentURL(attachmentId: String) async -> URL? {
        if let u = attachmentURLs[attachmentId] { return u }
        guard !currentRoom.isEmpty,
              let r = try? await api.downloadAttachment(roomToken: currentToken, roomId: currentRoom, attachmentId: attachmentId),
              let u = URL(string: r.download_url),
              u.scheme?.lowercased() == "https" else { return nil } // S-05: presigned URLs must be https
        attachmentURLs[attachmentId] = u
        return u
    }
}

// MARK: - Backend message search (GET /v1/rooms/{id}/messages/search, room-token plane)
@MainActor public final class RoomSearchViewModel: ObservableObject {
    @Published public var results: [MessageResponse] = []
    @Published public var isSearching = false
    private let api: OllacoreAPI
    private var generation = 0
    public init(api: OllacoreAPI = .shared) { self.api = api }
    /// Orphans any in-flight search: its results can never publish afterwards.
    public func cancel() { generation += 1; isSearching = false }
    public func search(roomId: String, query: String, sessionToken: String? = nil, deviceId: String? = nil) async {
        generation += 1
        let gen = generation
        guard !query.isEmpty else { results = []; return }
        isSearching = true; defer { if gen == generation { isSearching = false } }
        var rt = RoomTokenCache.shared.get(roomId: roomId)
        if rt == nil, let sessionToken, let deviceId {
            // Lazily mint a room token so sidebar search works before the chat is opened.
            if let fresh = try? await api.roomToken(token: sessionToken, roomId: roomId, deviceId: deviceId) {
                RoomTokenCache.shared.set(roomId: roomId, token: fresh.access_token, wsURL: fresh.chat_websocket_url, rtcURL: fresh.rtc_websocket_url, expiresAt: fresh.expires_at)
                rt = RoomTokenCache.shared.get(roomId: roomId)
            }
        }
        guard gen == generation else { return } // superseded: never publish stale work
        guard let rt else { results = []; return }
        do {
            let found = try await api.searchMessages(roomToken: rt.token, roomId: roomId, q: query)
            if gen == generation { results = found }
        } catch let e as ApiException where e.isRateLimited {
            // Honor Retry-After: keep prior results, caller may retry after delay.
            // Clamped both ends: negatives can't trap, huge values can't stall past 60s.
            try? await Task.sleep(nanoseconds: UInt64(min(max(0, e.retryAfterSeconds ?? 2), 60)) * 1_000_000_000)
            guard gen == generation, !Task.isCancelled else { return }
            if let retry = try? await api.searchMessages(roomToken: rt.token, roomId: roomId, q: query),
               gen == generation, !Task.isCancelled { results = retry }
        } catch {
            if gen == generation { results = [] }
        }
    }
}

// MARK: - CallLogStore (mirrors Android CallLogStore — client-only JSON)
public struct CallEntry: Codable, Identifiable { public var id: String; public var roomId: String; public var peerName: String; public var audioOnly: Bool; public var date: Date }
@MainActor public final class CallLogStore: ObservableObject {
    static let storeVersion = 1
    private static let key = "call_log_v1"
    private static let versionKey = "call_log_version"
    private static let corruptPrefix = "call_log_corrupt_backup"
    private static let maxBackups = 5
    @Published public var entries: [CallEntry] = []
    public init() {
        let v = UserDefaults.standard.integer(forKey: Self.versionKey)
        if v == 0, let legacy = UserDefaults.standard.data(forKey: "call_log") {
            // Migrate the original unversioned store once, then stamp the version.
            // Undecodable legacy data is quarantined like current data, never dropped.
            if let e = try? JSONDecoder().decode([CallEntry].self, from: legacy) {
                entries = e
            } else {
                Self.quarantine(legacy)
            }
            UserDefaults.standard.removeObject(forKey: "call_log")
            UserDefaults.standard.set(Self.storeVersion, forKey: Self.versionKey)
            persist()
            return
        }
        guard let d = UserDefaults.standard.data(forKey: Self.key) else { return }
        if let e = try? JSONDecoder().decode([CallEntry].self, from: d) {
            entries = e
        } else {
            // Corrupt data is quarantined (rotated, newest kept) and the log restarts empty.
            Self.quarantine(d)
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }
    private static func quarantine(_ d: Data) {
        // Never overwrite: regenerate until the key is actually unused.
        var key = ""
        repeat {
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let nonce = Int.random(in: 0..<100000)
            key = "\(corruptPrefix)_\(stamp)_\(nonce)"
        } while UserDefaults.standard.object(forKey: key) != nil
        UserDefaults.standard.set(d, forKey: key)
        let olds = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(corruptPrefix) }.sorted()
        for extra in olds.dropLast(maxBackups) {
            UserDefaults.standard.removeObject(forKey: extra)
        }
    }
    public func add(_ e: CallEntry) { entries.insert(e, at: 0); persist() }
    public func clear() { entries = []; persist() }
    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.key)
        UserDefaults.standard.set(Self.storeVersion, forKey: Self.versionKey)
    }
}
