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
    @Published public var typingUsers: Set<String> = []
    @Published public var presenceOnline: [String: Bool] = [:]
    @Published public var members: Set<String> = []
    /// Set by the view: re-mint a room token and reconnect after 4401.
    public var onTokenExpired: (() -> Void)?
    private var pendingFrames: [String: (clientId: String, text: String)] = [:] // frame request_id → send
    public var socket = ChatWebSocket()
    private let api: OllacoreAPI
    public init(api: OllacoreAPI = .shared) { self.api = api }
    private var seenIds: Set<String> = []
    private var joinGen = 0
    private var socketSession = 0
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
        uploadGen += 1 // a new room orphans any upload bound to the previous one
        let gen = joinGen
        currentRoom = roomId; currentToken = roomToken
        connectionError = nil; accessRevoked = false
        historyError = nil; historyLoaded = false
        // Per-room state never carries over: a recycled VM starts clean.
        receipts.removeAll(); reactions.removeAll()
        typingUsers.removeAll(); presenceOnline.removeAll(); members.removeAll()
        failedDrafts.removeAll(); pendingFrames.removeAll(); sendingCount = 0
        selectedIds.removeAll(); selectionMode = false
        deletedIds.removeAll(); attachmentURLs.removeAll()
        isLoadingMore = false; loadingMoreGen = nil
        do {
            let page = try await api.listMessages(roomToken: roomToken, roomId: roomId)
            guard gen == joinGen else { return } // superseded by a newer join: publish nothing
            historyError = nil // success clears any error left by an older join
            messages = page.messages.sorted { $0.event_seq < $1.event_seq }
            seenIds = Set(messages.map(\.id))
            hasMoreHistory = page.hasMore
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
        socketSession += 1
        let sess = socketSession
        socket.onSendFailure = { [weak self] reqId in
            Task { @MainActor in
                guard let self, self.socketSession == sess else { return }
                self.failPending(requestId: reqId)
            }
        }
        socket.onEvent = { [weak self] e in
            Task { @MainActor in
                guard let self, self.socketSession == sess else { return } // NEW-14: queued event after disconnect dies here
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
                case .typing(let room, let user, let started):
                    guard self.isCurrentRoom(room) else { break }
                    if started { self.typingUsers.insert(user) } else { self.typingUsers.remove(user) }
                case .presence(let room, let user, let online):
                    guard self.isCurrentRoom(room) else { break }
                    self.presenceOnline[user] = online
                case .memberAdded(let room, let user):
                    guard self.isCurrentRoom(room) else { break }
                    self.members.insert(user)
                case .memberRemoved(let room, let user):
                    guard self.isCurrentRoom(room) else { break }
                    self.members.remove(user)
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
                    // Room/token captured up front so the request itself targets the right room.
                    let gen = self.joinGen
                    let room = self.currentRoom, token = self.currentToken
                    let fresh = (try? await self.api.listMessages(roomToken: token, roomId: room))?.messages ?? []
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
    @Published public var hasMoreHistory = false
    @Published public var isLoadingMore = false
    private var loadingMoreGen: Int?
    /// Paging for long chats: prepends older messages (deduplicated), newest stay put.
    public func loadMore() async {
        guard historyLoaded, hasMoreHistory, !currentRoom.isEmpty, let oldest = messages.map(\.event_seq).min() else { return }
        let gen = joinGen
        let room = currentRoom, token = currentToken
        isLoadingMore = true
        loadingMoreGen = gen
        // NEW-19: only the operation that owns the spinner may clear it — but a
        // stale finish must still release it when nobody newer is loading.
        defer { if loadingMoreGen == gen { isLoadingMore = false; loadingMoreGen = nil } }
        guard let page = try? await api.listMessages(roomToken: token, roomId: room, beforeSeq: oldest) else { return }
        guard gen == joinGen, room == currentRoom else { return } // NEW-15: stale page never lands
        for m in page.messages where !seenIds.contains(m.id) && m.room_id == currentRoom {
            seenIds.insert(m.id)
            messages.append(m)
        }
        messages.sort { $0.event_seq < $1.event_seq }
        hasMoreHistory = page.hasMore
        enforceWindow()
    }
    public func retryDraft(roomId: String, draft: FailedDraft) {
        let reqId = socket.sendMessage(roomId: roomId, text: draft.text, clientId: draft.id)
        pendingFrames[reqId] = (draft.id, draft.text)
        sendingCount = pendingFrames.count
        failedDrafts.removeAll { $0.id == draft.id }
    }
    public func deleteMessage(roomId: String, messageId: String) {
        let token = currentToken
        socket.deleteMessage(roomId: roomId, messageId: messageId)
        Task { _ = await api.deleteMessage(roomToken: token, roomId: roomId, messageId: messageId) }
        deletedIds.insert(messageId) // optimistic tombstone; server echo confirms
    }
    public func forwardMessage(_ msg: MessageResponse, toRoomId: String, sessionToken: String, deviceId: String) async -> Bool {
        // Pin source credentials up front; abort if room switches mid-forward.
        let gen = joinGen
        let srcToken = currentToken, srcRoom = msg.room_id
        guard let rt = try? await api.roomToken(token: sessionToken, roomId: toRoomId, deviceId: deviceId) else { return false }
        guard gen == joinGen else { return false }
        // Re-init attachments in target room: ids are room-scoped, never copy verbatim.
        var newIds: [String] = []
        var failedCount = 0
        for aid in msg.attachment_ids {
            guard let dl = try? await api.downloadAttachment(roomToken: srcToken, roomId: srcRoom, attachmentId: aid),
                  let u = URL(string: dl.download_url),
                  let (data, _) = try? await URLSession.shared.data(from: u) else { failedCount += 1; continue }
            guard gen == joinGen else { return false }
            let mime = (msg.body["mime"]?.value as? String) ?? "application/octet-stream"
            let fn = (msg.body["filename"]?.value as? String) ?? aid
            guard let initR = try? await api.initAttachment(roomToken: rt.access_token, roomId: toRoomId, filename: fn, mime: mime, byteSize: data.count),
                  let putURL = URL(string: initR.upload_url) else { failedCount += 1; continue }
            var req = URLRequest(url: putURL); req.httpMethod = "PUT"
            let (_, resp) = (try? await URLSession.shared.upload(for: req, from: data)) ?? (Data(), URLResponse())
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { failedCount += 1; continue }
            if await api.completeAttachment(roomToken: rt.access_token, roomId: toRoomId, attachmentId: initR.attachment_id) {
                newIds.append(initR.attachment_id)
            } else { failedCount += 1 }
        }
        guard gen == joinGen else { return false }
        // Media forward with total attachment loss fails loudly instead of sending a naked message.
        if !msg.attachment_ids.isEmpty && msg.kind != MessageKinds.text && newIds.isEmpty { return false }
        let body = msg.body
        let atts: [String] = msg.kind == MessageKinds.text ? [] : newIds
        _ = failedCount // caller sees Bool; per-item loss tolerated when at least one succeeded
        return (try? await api.sendMessage(roomToken: rt.access_token, roomId: toRoomId, clientId: UUID().uuidString, kind: msg.kind, body: body, attachments: atts)) != nil
    }
    public func editMessage(roomId: String, messageId: String, text: String) {
        let gen = joinGen
        let token = currentToken
        // Optimistic update with edited flag.
        if let i = messages.firstIndex(where: { $0.id == messageId }) {
            var b = messages[i].body; b["text"] = AnyCodable(text)
            messages[i].body = b; messages[i].edited_at = "pending"
        }
        socket.editMessage(roomId: roomId, messageId: messageId, text: text)
        Task {
            guard let updated = try? await api.editMessage(roomToken: token, roomId: roomId, messageId: messageId, text: text) else { return }
            guard gen == joinGen, roomId == currentRoom else { return }
            if let i = messages.firstIndex(where: { $0.id == messageId }) { messages[i] = updated }
        }
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
        uploadGen += 1 // invalidate any in-flight upload for the same reason
        socketSession += 1 // orphan already-queued socket callbacks with the old session id
        socket.disconnect()
    }
    public func addReaction(roomId: String, messageId: String, emoji: String) {
        let token = currentToken
        socket.addReaction(roomId: roomId, messageId: messageId, emoji: emoji)
        Task { _ = await api.addReaction(roomToken: token, roomId: roomId, messageId: messageId, emoji: emoji) }
    }
    public func removeReaction(roomId: String, messageId: String, emoji: String) {
        let token = currentToken
        socket.removeReaction(roomId: roomId, messageId: messageId, emoji: emoji)
        Task { _ = await api.removeReaction(roomToken: token, roomId: roomId, messageId: messageId, emoji: emoji) }
    }
    public func markVisibleAsRead(roomId: String) {
        // One receipt for the latest message: the read cursor already covers everything before it.
        guard let last = messages.last else { return }
        let token = currentToken
        socket.markRead(roomId: roomId, messageId: last.id)
        Task { _ = await api.markRead(roomToken: token, roomId: roomId, messageId: last.id) }
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
    public enum UploadState: Equatable {
        case idle, uploading(filename: String), failed(filename: String, message: String)
    }
    @Published public var uploadState: UploadState = .idle
    private var uploadTask: URLSessionUploadTask?
    private var pendingUpload: (data: Data, filename: String, mime: String, kind: String, caption: String?)?
    private var uploadGen = 0
    /// init → PUT presigned → complete → send. Documented endpoints only; single-PUT
    /// (large multipart uploads remain future work and are refused client-side above 100MB).
    public func uploadAndSend(roomId: String, data: Data, filename: String, mime: String, kind: String, caption: String? = nil) {
        guard data.count <= 100 * 1024 * 1024 else {
            uploadState = .failed(filename: filename, message: "File exceeds the 100MB single-upload limit.")
            return
        }
        pendingUpload = (data, filename, mime, kind, caption)
        uploadState = .uploading(filename: filename)
        Task { await self.runUpload(roomId: roomId) }
    }
    public func cancelUpload() { uploadTask?.cancel(); uploadTask = nil; uploadState = .idle }
    public func retryUpload(roomId: String) {
        guard case .failed = uploadState, let p = pendingUpload else { return }
        let gen = uploadGen
        uploadState = .uploading(filename: p.filename)
        Task { guard gen == uploadGen else { uploadState = .failed(filename: p.filename, message: "Room changed."); return }; await self.runUpload(roomId: roomId) }
    }
    private func runUpload(roomId: String) async {
        guard let p = pendingUpload else { uploadState = .idle; return }
        // NEW-21: pin the room, token, and session for the whole pipeline. A room
        // switch or disconnect mid-upload aborts instead of mixing credentials.
        uploadGen += 1
        let gen = uploadGen
        let token = currentToken, room = roomId
        do {
            let initR = try await api.initAttachment(roomToken: token, roomId: room, filename: p.filename, mime: p.mime, byteSize: p.data.count)
            guard let putURL = URL(string: initR.upload_url), putURL.scheme?.lowercased() == "https" else {
                throw ApiException(message: "Invalid upload URL.", code: "bad_upload_url", httpStatus: nil)
            }
            var req = URLRequest(url: putURL)
            req.httpMethod = "PUT"
            req.setValue(p.mime, forHTTPHeaderField: "Content-Type")
            // Bridge to a retained task so cancelUpload() actually aborts the PUT.
            let resp: URLResponse = try await withCheckedThrowingContinuation { cont in
                let t = URLSession.shared.uploadTask(with: req, from: p.data) { _, r, e in
                    if let e { cont.resume(throwing: e) }
                    else if let r { cont.resume(returning: r) }
                    else { cont.resume(throwing: ApiException(message: "Upload failed.", code: "upload_failed", httpStatus: nil)) }
                }
                self.uploadTask = t
                t.resume()
            }
            self.uploadTask = nil
            try Task.checkCancellation()
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                throw ApiException(message: "Upload failed.", code: "upload_failed", httpStatus: (resp as? HTTPURLResponse)?.statusCode)
            }
            guard gen == uploadGen else { return } // room switched mid-upload: abort, don't mix rooms
            guard await api.completeAttachment(roomToken: token, roomId: room, attachmentId: initR.attachment_id) else {
                throw ApiException(message: "Attachment verification failed.", code: "complete_failed", httpStatus: nil)
            }
            guard gen == uploadGen else { return }
            var body: [String: AnyCodable] = ["mime": AnyCodable(p.mime), "filename": AnyCodable(p.filename)]
            if let c = p.caption { body["text"] = AnyCodable(c) }
            _ = try await api.sendMessage(roomToken: token, roomId: room, clientId: UUID().uuidString, kind: kindForMime(p.mime, requested: p.kind), body: body, attachments: [initR.attachment_id])
            guard gen == uploadGen else { return } // F-01: stale success must not clear a newer upload's state
            pendingUpload = nil
            uploadState = .idle
        } catch is CancellationError {
            guard gen == uploadGen else { return }
            uploadState = .idle
        } catch let e as URLError where e.code == .cancelled {
            uploadState = .idle // user-cancelled PUT: quiet, retryable via pendingUpload
        } catch {
            uploadState = .failed(filename: p.filename, message: error.localizedDescription)
        }
    }
    private func kindForMime(_ mime: String, requested: String) -> String {
        if mime.hasPrefix("image/") { return MessageKinds.image }
        if mime.hasPrefix("video/") { return MessageKinds.video }
        if mime.hasPrefix("audio/") { return MessageKinds.audio }
        return requested.isEmpty ? MessageKinds.file : requested
    }
    public func resolveAttachmentURL(attachmentId: String, roomId: String? = nil, roomToken: String? = nil) async -> URL? {
        if let u = attachmentURLs[attachmentId] {
            // F-04: presigned URLs expire; on failure the caller re-fetches (no stale cache reuse on error path).
            return u
        }
        // F-05: pin room+token at call time so a switch mid-fetch can't mix credentials.
        let room = roomId ?? currentRoom
        let token = roomToken ?? currentToken
        guard !room.isEmpty, !token.isEmpty else { return nil }
        let gen = joinGen
        guard let r = try? await api.downloadAttachment(roomToken: token, roomId: room, attachmentId: attachmentId),
              let u = URL(string: r.download_url),
              u.scheme?.lowercased() == "https" else { return nil } // S-05: presigned URLs must be https
        guard gen == joinGen else { return nil }
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

// MARK: - DraftStore (persist unsent text per room across switches)
@MainActor public final class DraftStore: ObservableObject {
    public static let shared = DraftStore()
    @Published public var drafts: [String: String] = [:]
    private let key = "chat_drafts_v1"
    public init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let m = try? JSONDecoder().decode([String: String].self, from: d) { drafts = m }
    }
    public func draft(for roomId: String) -> String { drafts[roomId] ?? "" }
    public func set(_ text: String, for roomId: String) {
        if text.isEmpty { drafts.removeValue(forKey: roomId) } else { drafts[roomId] = text }
        UserDefaults.standard.set(try? JSONEncoder().encode(drafts), forKey: key)
    }
    public func clear(roomId: String) { set("", for: roomId) }
}

// MARK: - AppSettings (notifications + app lock + theme basics)
@MainActor public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()
    @Published public var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "opt_notifications") }
    }
    @Published public var appLockEnabled: Bool {
        didSet { UserDefaults.standard.set(appLockEnabled, forKey: "opt_app_lock") }
    }
    @Published public var themeRaw: String {
        didSet { UserDefaults.standard.set(themeRaw, forKey: "opt_theme") }
    }
    @Published public var mutedRooms: [String: Bool] = [:] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(mutedRooms), forKey: "muted_rooms_v1") }
    }
    @Published public var roomAliases: [String: String] = [:] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(roomAliases), forKey: "room_alias_v1") }
    }
    public init() {
        notificationsEnabled = UserDefaults.standard.object(forKey: "opt_notifications") as? Bool ?? true
        appLockEnabled = UserDefaults.standard.object(forKey: "opt_app_lock") as? Bool ?? false
        themeRaw = UserDefaults.standard.string(forKey: "opt_theme") ?? "system"
        if let d = UserDefaults.standard.data(forKey: "muted_rooms_v1"),
           let m = try? JSONDecoder().decode([String: Bool].self, from: d) { mutedRooms = m }
        if let d = UserDefaults.standard.data(forKey: "room_alias_v1"),
           let m = try? JSONDecoder().decode([String: String].self, from: d) { roomAliases = m }
    }
    public func isMuted(roomId: String) -> Bool { mutedRooms[roomId] ?? false }
    public func setMuted(_ m: Bool, roomId: String) { mutedRooms[roomId] = m }
    public func alias(for roomId: String) -> String? { roomAliases[roomId] }
    public func setAlias(_ a: String, roomId: String) {
        if a.isEmpty { roomAliases.removeValue(forKey: roomId) } else { roomAliases[roomId] = a }
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
    private static let quarantineLock = NSLock()
    private static func quarantine(_ d: Data) {
        // Atomic check-and-write: the whole transaction holds one lock, so two
        // concurrent corruptions can never observe-and-claim the same key.
        quarantineLock.lock()
        defer { quarantineLock.unlock() }
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
