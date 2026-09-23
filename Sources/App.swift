import SwiftUI
import AppKit

// MARK: - App entry (mirrors MainActivity.kt NavHost: splash -> onboarding -> phone -> otp -> home -> chat)
@main struct OllaCoreMacApp: App {
    @StateObject private var auth = AuthViewModel()
    @StateObject private var home = HomeViewModel()
    @State private var selectedRoom: InboxItem?
    var body: some Scene {
        WindowGroup {
            Group {
                switch auth.step {
                case .phoneInput: PhoneInputView(vm: auth)
                case .otp: OtpView(vm: auth)
                case .authenticated: HomeView(auth: auth, home: home, selectedRoom: $selectedRoom)
                }
            }.frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    // Ensure our window takes keyboard focus when launched from Terminal.
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .commands { SidebarCommands() }
    }
}

struct PhoneInputView: View {
    @ObservedObject var vm: AuthViewModel
    @FocusState private var phoneFocused: Bool
    var body: some View {
        VStack(spacing: 16) {
            Text("OllaChat").font(.largeTitle).bold()
            Text("Enter your phone number")
            TextField("+1 5550001111", text: $vm.phone)
                .textFieldStyle(.plain)
                .frame(width: 260)
                .padding(8)
                .foregroundColor(.primary)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                .focused($phoneFocused)
                .onAppear { phoneFocused = true }
            // Diagnostic: proves whether keystrokes reach the binding even if glyphs misrender.
            Text(vm.phone.isEmpty ? " " : "\(vm.phone.count) character(s) entered")
            if let e = vm.error { Text(e).foregroundColor(.red).font(.caption) }
            Button(vm.isLoading ? "Sending…" : "Continue") { Task { await vm.requestOtp() } }.buttonStyle(.borderedProminent).disabled(vm.isLoading)
            #if DEBUG
            Text("Test numbers: +15550001111 (QA1), +15550002222 (QA2)").font(.caption).foregroundColor(.secondary)
            #endif
        }.padding(60)
    }
}
struct OtpView: View {
    @ObservedObject var vm: AuthViewModel
    var body: some View {
        VStack(spacing: 16) {
            Text("Verify your number").font(.title2).bold()
            Text("Code sent to \(vm.phone)").foregroundColor(.secondary)
            TextField("6-digit code", text: $vm.otpCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .foregroundColor(.primary)
                .background(Color(nsColor: .textBackgroundColor))
            if let e = vm.error { Text(e).foregroundColor(.red).font(.caption) }
            Button(vm.isLoading ? "Verifying…" : "Verify") { Task { await vm.verifyOtp() } }.buttonStyle(.borderedProminent).disabled(vm.isLoading)
            Button(vm.canResend() ? "Resend code" : "Resend in \(vm.resendRemaining())s") { Task { await vm.requestOtp() } }
                .buttonStyle(.link).disabled(!vm.canResend() || vm.isLoading)
        }.padding(60)
    }
}

// MARK: - Home (Sidebar chats + detail chat; mirrors HomeScreen + ChatScreen)
struct HomeView: View {
    @ObservedObject var auth: AuthViewModel
    @ObservedObject var home: HomeViewModel
    @Binding var selectedRoom: InboxItem?
    @State private var search = ""
    @StateObject private var roomSearch = RoomSearchViewModel()
    @State private var searchTask: Task<Void, Never>?
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedRoom) {
                if let e = home.error {
                    Section {
                        Text(e).font(.caption).foregroundColor(.red)
                        Button("Retry") { Task { if let t = auth.session.sessionToken { await home.refresh(token: t) } } }
                    } header: { Text("Could not refresh") }
                }
                Section("Conversations") {
                    ForEach(filtered, id: \.room_id) { item in
                        VStack(alignment: .leading) {
                            Text(item.name ?? item.peer?.display_name ?? item.room_id).bold().lineLimit(1)
                            Text(item.last_message?.preview ?? "No messages").font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }.tag(item)
                    }
                }
                if !search.isEmpty, selectedRoom != nil {
                    Section("Messages in this chat (backend search)") {
                        if roomSearch.isSearching { Text("Searching…").font(.caption).foregroundColor(.secondary) }
                        ForEach(roomSearch.results) { m in
                            Text(m.body["text"]?.value as? String ?? "[\(m.kind)]").font(.caption).lineLimit(2)
                        }
                    }
                }
            }
            .searchable(text: $search)
            .onChange(of: search, initial: false) { _, q in
                searchTask?.cancel()
                roomSearch.cancel()
                if let room = selectedRoom, !q.isEmpty {
                    searchTask = Task { await roomSearch.search(roomId: room.room_id, query: q, sessionToken: auth.session.sessionToken, deviceId: auth.session.deviceId) }
                }
            }
            .onChange(of: selectedRoom) {
                // New room, stale search: cancel in-flight work and drop its results.
                searchTask?.cancel()
                roomSearch.cancel()
                roomSearch.results = []
            }
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItemGroup {
                    Button("Refresh") { Task { if let t = auth.session.sessionToken { await home.refresh(token: t) } } }
                    Button("Logout") { selectedRoom = nil; Task { await auth.logout() } }
                }
            }
        } detail: {
            if let room = selectedRoom, let token = auth.session.sessionToken {
                ChatDetailView(room: room, sessionToken: token, deviceId: auth.session.deviceId, ownId: auth.session.userId, rooms: home.inbox)
                    .id(room.room_id) // fresh state + socket per room; never recycle across rooms
            } else {
                Text("Select a conversation").foregroundColor(.secondary)
            }
        }
        .task { if let t = auth.session.sessionToken { await home.refresh(token: t) } }
    }
    var filtered: [InboxItem] {
        search.isEmpty ? home.inbox : home.inbox.filter { ($0.name ?? "").localizedCaseInsensitiveContains(search) }
    }
}
extension InboxItem: Hashable { public static func == (l: InboxItem, r: InboxItem) -> Bool { l.room_id == r.room_id }; public func hash(into h: inout Hasher) { h.combine(room_id) } }

struct ChatDetailView: View {
    var room: InboxItem; var sessionToken: String; var deviceId: String; var ownId: String?
    var rooms: [InboxItem] = []
    @StateObject private var chat = ChatViewModel()
    @State private var draft = ""
    @State private var roomToken = ""
    @State private var wsUrl = ""
    @State private var forwarding: MessageResponse?
    @State private var forwardDone: String?
    @State private var historyAttempt = 0
    @State private var roomTokenError: String?
    init(room: InboxItem, sessionToken: String, deviceId: String, ownId: String? = nil, rooms: [InboxItem] = []) {
        self.room = room; self.sessionToken = sessionToken; self.deviceId = deviceId; self.ownId = ownId; self.rooms = rooms
    }
    var body: some View {
        VStack(spacing: 0) {
            if chat.accessRevoked {
                Text("You no longer have access to this conversation.").font(.callout).foregroundColor(.red).padding(8)
            }
            if let connErr = chat.connectionError {
                HStack {
                    Text(connErr).font(.callout).foregroundColor(.orange)
                    Spacer()
                    Button("Reconnect") { historyAttempt += 1; chat.connectionError = nil }
                }.padding(8).background(Color.orange.opacity(0.12))
            }
            if let call = chat.activeCall {
                HStack {
                    Image(systemName: "phone.fill").foregroundColor(.green)
                    Text("Incoming call… (voice/video UI not built yet)").font(.callout)
                    Spacer()
                    Button("Dismiss") { chat.dismissCall() }
                }
                .padding(8).background(Color.green.opacity(0.12))
                .accessibilityIdentifier("call_banner_\(call.callId)")
            }
            if chat.selectionMode {
                HStack {
                    Text("\(chat.selectedIds.count) selected").font(.callout)
                    Spacer()
                    Button("Delete") { chat.deleteSelected(roomId: room.room_id) }
                    Button("Clear") { chat.clearSelection() }
                }.padding(8).background(Color.secondary.opacity(0.12))
            }
            if let terr = roomTokenError {
                VStack(spacing: 8) {
                    Text("Couldn't open conversation: \(terr)").font(.callout).foregroundColor(.red)
                    Button("Retry") { roomTokenError = nil; historyAttempt += 1 }
                }.padding()
            }
            if let herr = chat.historyError {
                VStack(spacing: 8) {
                    Text("Couldn't load messages: \(herr)").font(.callout).foregroundColor(.red)
                    Button("Retry") { historyAttempt += 1 }
                }.padding()
            }
            ScrollView { LazyVStack(alignment: .leading, spacing: 8) {
                if chat.historyLoaded && !chat.messages.isEmpty {
                    Button("Load earlier messages") { Task { await chat.loadMore() } }
                        .font(.caption).buttonStyle(.link)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                ForEach(chat.messages) { m in
                    MessageBubble(message: m, roomId: room.room_id, chat: chat,
                                  onReply: { chat.replyTo = m },
                                  onForward: { forwarding = m })
                }
                if !chat.failedDrafts.isEmpty {
                    Section {
                        ForEach(chat.failedDrafts) { d in
                            HStack {
                                Image(systemName: "exclamationmark.triangle").foregroundColor(.red)
                                Text(d.text).lineLimit(2)
                                Spacer()
                                Button("Retry") { chat.retryDraft(roomId: room.room_id, draft: d) }
                            }.padding(8).background(Color.red.opacity(0.1)).cornerRadius(8)
                        }
                    } header: { Text("Not sent").font(.caption).foregroundColor(.red) }
                }
            }.padding() }
            if let reply = chat.replyTo {
                HStack {
                    Text("↩ \(reply.body["text"]?.value as? String ?? "[\(reply.kind)]")").font(.caption).lineLimit(1)
                    Spacer()
                    Button("Cancel") { chat.replyTo = nil }
                }.padding(8).background(Color.secondary.opacity(0.12))
            }
            if chat.sendingCount > 0 {
                Text("Sending…").font(.caption2).foregroundColor(.secondary).padding(.horizontal)
            }
            HStack {
                TextField("Message", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .foregroundColor(.primary)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                Button("Send") {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    chat.send(roomId: room.room_id, text: text); draft = ""
                }.buttonStyle(.borderedProminent).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding()
        }
        .navigationTitle(room.name ?? "Chat")
        .task(id: historyAttempt) {
            // 4401 recovery: re-mint the room token and reconnect through the same path.
            chat.onTokenExpired = { historyAttempt += 1 }
            do {
                let rt = try await OllacoreAPI.shared.roomToken(token: sessionToken, roomId: room.room_id, deviceId: deviceId)
                roomTokenError = nil
                roomToken = rt.access_token; wsUrl = rt.chat_websocket_url
                await chat.join(roomToken: roomToken, roomId: room.room_id, wsUrl: wsUrl, ownId: ownId, expiresAt: rt.expires_at)
                if chat.historyError == nil { chat.markVisibleAsRead(roomId: room.room_id) }
            } catch {
                // NEW-08: token failures (401, timeout, malformed) surface with retry.
                roomTokenError = error.localizedDescription
            }
        }
        .onDisappear { chat.disconnect() }
        .sheet(item: $forwarding) { msg in
            VStack(spacing: 12) {
                Text("Forward message").font(.headline)
                Text(msg.body["text"]?.value as? String ?? "[\(msg.kind)]").font(.caption).lineLimit(3)
                List(rooms.filter { $0.room_id != room.room_id }, id: \.room_id) { r in
                    Button(r.name ?? r.room_id) {
                        Task {
                            forwardDone = await chat.forwardMessage(msg, toRoomId: r.room_id, sessionToken: sessionToken, deviceId: deviceId)
                                ? "Forwarded to \(r.name ?? r.room_id)" : "Forward failed"
                        }
                    }
                    .disabled(forwardDone != nil)
                }.frame(minHeight: 200)
                if let done = forwardDone { Text(done).font(.caption).foregroundColor(.secondary) }
                Button(forwardDone == nil ? "Cancel" : "Done") { forwarding = nil; forwardDone = nil }
            }.padding().frame(width: 340)
        }
    }
}

struct MessageBubble: View {
    var message: MessageResponse
    var roomId: String
    @ObservedObject var chat: ChatViewModel
    var onReply: () -> Void = {}
    var onForward: () -> Void = {}
    @State private var imageURL: URL?

    private var caption: String? { message.body["text"]?.value as? String }
    private var filename: String? { message.body["filename"]?.value as? String }
    private var mime: String? { message.body["mime"]?.value as? String }

    var body: some View {
        Group {
            if chat.deletedIds.contains(message.id) {
                Text("This message was deleted").italic().foregroundColor(.secondary)
                    .padding(8).background(Color.secondary.opacity(0.1)).cornerRadius(8)
            } else {
                bubbleContent
            }
        }
    }

    private var bubbleContent: some View {
        HStack(alignment: .top, spacing: 6) {
            if chat.selectionMode {
                Image(systemName: chat.selectedIds.contains(message.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(.accentColor)
                    .onTapGesture { chat.toggleSelect(id: message.id) }
            }
            VStack(alignment: .leading, spacing: 4) {
            if let replyId = message.reply_to {
                let quoted = chat.messages.first(where: { $0.id == replyId })
                Text("↩ \(quoted?.body["text"]?.value as? String ?? "original message")")
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
                    .padding(4).background(Color.secondary.opacity(0.12)).cornerRadius(4)
            }
            switch message.kind {
            case MessageKinds.image:
                if let u = imageURL {
                    AsyncImage(url: u) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFit().frame(maxWidth: 320).cornerRadius(8)
                        case .failure: Label("Image unavailable", systemImage: "photo")
                        default: ProgressView().frame(width: 200, height: 120)
                        }
                    }
                } else {
                    Label("Image", systemImage: "photo").foregroundColor(.secondary)
                        .task { imageURL = await chat.resolveAttachmentURL(attachmentId: message.attachment_ids.first ?? "") }
                }
                if let c = caption { Text(c) }
            case MessageKinds.video:
                Label(filename ?? "Video", systemImage: "video.fill").foregroundColor(.secondary)
                if let c = caption { Text(c).font(.caption) }
            case MessageKinds.audio:
                Label("Voice message", systemImage: "waveform").foregroundColor(.secondary)
            case MessageKinds.file:
                Label(filename ?? "Document", systemImage: "doc.fill").foregroundColor(.secondary)
                if let m = mime { Text(m).font(.caption).foregroundColor(.secondary) }
            case MessageKinds.location:
                let lat = message.body["lat"]?.value
                let lon = message.body["lon"]?.value ?? message.body["lng"]?.value
                Label("\(lat.map { "\($0)" } ?? "?"), \(lon.map { "\($0)" } ?? "?")", systemImage: "mappin").foregroundColor(.secondary)
                if let c = caption { Text(c).font(.caption) }
            default:
                Text(caption ?? "[\(message.kind)]")
            }
            HStack(spacing: 6) {
                if let reacts = chat.reactions[message.id], !reacts.isEmpty {
                    ForEach(reacts.sorted(by: { $0.key < $1.key }), id: \.key) { emoji, count in
                        Text(count > 1 ? "\(emoji) \(count)" : emoji)
                            .font(.caption).padding(4).background(Color.secondary.opacity(0.15)).cornerRadius(6)
                    }
                }
                if message.sender_id == chat.currentSenderId {
                    Text(chat.receiptLabel(for: message.id))
                        .font(.caption2).foregroundColor(chat.receiptColor(for: message.id))
                }
            }
            }
        }
        .padding(8).background(Color.accentColor.opacity(0.12)).cornerRadius(8)
        .onTapGesture {
            if chat.selectionMode { chat.toggleSelect(id: message.id) }
        }
        .contextMenu {
            Button("Reply") { onReply() }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.body["text"]?.value as? String ?? "", forType: .string)
            }
            Button("Forward…") { onForward() }
            Button(chat.selectionMode ? "Deselect" : "Select") {
                chat.selectionMode = true; chat.toggleSelect(id: message.id)
            }
            Button("Delete", role: .destructive) { chat.deleteMessage(roomId: roomId, messageId: message.id) }
            ForEach(["👍", "❤️", "😂", "😮", "😢"], id: \.self) { emoji in
                Button("React \(emoji)") { chat.addReaction(roomId: roomId, messageId: message.id, emoji: emoji) }
            }
        }
    }
}
