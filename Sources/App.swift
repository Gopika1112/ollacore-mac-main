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
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedRoom) {
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
            .onChange(of: search) { q in
                if let room = selectedRoom, !q.isEmpty {
                    Task { await roomSearch.search(roomId: room.room_id, query: q, sessionToken: auth.session.sessionToken, deviceId: auth.session.deviceId) }
                }
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
                ChatDetailView(room: room, sessionToken: token, deviceId: auth.session.deviceId, ownId: auth.session.userId)
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
    @StateObject private var chat = ChatViewModel()
    @State private var draft = ""
    @State private var roomToken = ""
    @State private var wsUrl = ""
    init(room: InboxItem, sessionToken: String, deviceId: String, ownId: String? = nil) {
        self.room = room; self.sessionToken = sessionToken; self.deviceId = deviceId; self.ownId = ownId
    }
    var body: some View {
        VStack(spacing: 0) {
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
            ScrollView { LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(chat.messages) { m in
                    MessageBubble(message: m, roomId: room.room_id, chat: chat)
                }
            }.padding() }
            HStack {
                TextField("Message", text: $draft).textFieldStyle(.roundedBorder)
                Button("Send") { chat.send(roomId: room.room_id, text: draft); draft = "" }.buttonStyle(.borderedProminent)
            }.padding()
        }
        .navigationTitle(room.name ?? "Chat")
        .task {
            if let rt = try? await OllacoreAPI.shared.roomToken(token: sessionToken, roomId: room.room_id, deviceId: deviceId) {
                roomToken = rt.access_token; wsUrl = rt.chat_websocket_url
                await chat.join(roomToken: roomToken, roomId: room.room_id, wsUrl: wsUrl, ownId: ownId)
                chat.markVisibleAsRead(roomId: room.room_id)
            }
        }
        .onDisappear { chat.disconnect() }
    }
}

struct MessageBubble: View {
    var message: MessageResponse
    var roomId: String
    @ObservedObject var chat: ChatViewModel
    @State private var imageURL: URL?

    private var caption: String? { message.body["text"]?.value as? String }
    private var filename: String? { message.body["filename"]?.value as? String }
    private var mime: String? { message.body["mime"]?.value as? String }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        .padding(8).background(Color.accentColor.opacity(0.12)).cornerRadius(8)
        .contextMenu {
            ForEach(["👍", "❤️", "😂", "😮", "😢"], id: \.self) { emoji in
                Button("React \(emoji)") { chat.addReaction(roomId: roomId, messageId: message.id, emoji: emoji) }
            }
        }
    }
}
    }
}
