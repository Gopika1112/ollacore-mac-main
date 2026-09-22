import SwiftUI

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
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .foregroundColor(.primary)
                .background(Color(nsColor: .textBackgroundColor))
                .focused($phoneFocused)
                .onAppear { phoneFocused = true }
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
            Button("Resend code") { Task { await vm.requestOtp() } }.buttonStyle(.link)
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
                ChatDetailView(room: room, sessionToken: token, deviceId: auth.session.deviceId)
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
    var room: InboxItem; var sessionToken: String; var deviceId: String
    @StateObject private var chat = ChatViewModel()
    @State private var draft = ""
    @State private var roomToken = ""
    @State private var wsUrl = ""
    init(room: InboxItem, sessionToken: String, deviceId: String) {
        self.room = room; self.sessionToken = sessionToken; self.deviceId = deviceId
    }
    var body: some View {
        VStack {
            ScrollView { LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(chat.messages) { m in
                    Text(m.body["text"]?.value as? String ?? "[\(m.kind)]")
                        .padding(8).background(Color.accentColor.opacity(0.12)).cornerRadius(8)
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
                await chat.join(roomToken: roomToken, roomId: room.room_id, wsUrl: wsUrl)
            }
        }
        .onDisappear { chat.disconnect() }
    }
}
