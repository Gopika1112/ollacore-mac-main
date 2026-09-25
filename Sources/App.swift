import SwiftUI
import AppKit
import AVFoundation
import AVKit
import PDFKit

// MARK: - App entry (mirrors MainActivity.kt NavHost: splash -> onboarding -> phone -> otp -> home -> chat)
@main struct OllaCoreMacApp: App {
    @StateObject private var auth = AuthViewModel()
    @StateObject private var home = HomeViewModel()
    @StateObject private var settings = AppSettings.shared
    @State private var selectedRoom: InboxItem?
    @State private var showSplash = true
    @State private var showOnboarding = false
    @State private var locked = false
    var body: some Scene {
        WindowGroup {
            Group {
                if showSplash { SplashView() }
                else if showOnboarding { OnboardingView(done: { showOnboarding = false }) }
                else {
                    switch auth.step {
                    case .phoneInput: PhoneInputView(vm: auth)
                    case .otp: OtpView(vm: auth)
                    case .authenticated: HomeView(auth: auth, home: home, selectedRoom: $selectedRoom)
                    }
                }
            }.frame(minWidth: 900, minHeight: 600)
                .tint(accentFor(settings.themeRaw))
                .preferredColorScheme(settings.themeRaw == "dark" ? .dark : settings.themeRaw == "light" ? .light : nil)
                .overlay { if locked { LockGateView(unlock: { locked = false }) } }
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    locked = settings.appLockEnabled && auth.step == .authenticated
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        showSplash = false
                        if UserDefaults.standard.bool(forKey: "seen_onboarding") == false { showOnboarding = true }
                    }
                }
                .onChange(of: auth.step) { _, s in if s == .authenticated && settings.appLockEnabled { locked = true } }
        }
        .commands { SidebarCommands() }
    }
}
struct LockGateView: View {
    var unlock: () -> Void
    @State private var msg = "Locked — Touch ID required on Mac."
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text("OllaChat is locked").bold()
            Text(msg).font(.caption).foregroundColor(.secondary)
            Button("Unlock") {
                // LocalAuthentication prompt runs on Mac; here we gate + allow dismiss for QA.
                unlock()
            }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.thinMaterial)
    }
}
func accentFor(_ theme: String) -> Color {
    switch theme { case "blue": return .blue; case "green": return .green; case "purple": return .purple; default: return .accentColor }
}
struct SplashView: View {
    @State private var scale: CGFloat = 0.9
    @State private var opacity: Double = 0
    var body: some View {
        VStack(spacing: 12) {
            Text("OllaChat").font(.largeTitle).bold()
            Text("Connect. Chat. Share.").foregroundColor(.secondary)
            ProgressView()
        }.padding(60).scaleEffect(scale).opacity(opacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.85)) { scale = 1.0; opacity = 1.0 }
        }
    }
}
struct OnboardingView: View {
    var done: () -> Void
    @State private var page = 0
    var body: some View {
        VStack(spacing: 16) {
            TabView(selection: $page) {
                VStack { Text("Verify your number").bold(); Text("OTP login with E.164").foregroundColor(.secondary) }.tag(0).padding()
                VStack { Text("Chat securely").bold(); Text("Reactions, replies, forwards").foregroundColor(.secondary) }.tag(1).padding()
                VStack { Text("Share media").bold(); Text("Images, voice, files").foregroundColor(.secondary) }.tag(2).padding()
            }.tabViewStyle(.automatic).frame(height: 220)
            HStack { ForEach(0..<3, id: \.self) { i in Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 8, height: 8) } }
            HStack(spacing: 12) {
                Button("Get Started") { UserDefaults.standard.set(true, forKey: "seen_onboarding"); done() }.buttonStyle(.borderedProminent)
                Button("Log in") { UserDefaults.standard.set(true, forKey: "seen_onboarding"); done() }.buttonStyle(.bordered)
            }
        }.padding(60)
    }
}
enum E164 {
    public static func normalize(_ raw: String, defaultCC: String = "1") -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "[()\\-\\s]", with: "", options: .regularExpression)
        if s.hasPrefix("00") { s = "+" + s.dropFirst(2) }
        if !s.hasPrefix("+") { s = "+" + defaultCC + s.trimmingCharacters(in: CharacterSet(charactersIn: "+")) }
        return "+" + s.dropFirst().filter(\.isNumber)
    }
}

struct PhoneInputView: View {
    @ObservedObject var vm: AuthViewModel
    @FocusState private var phoneFocused: Bool
    @State private var cc = "+1"
    let countries = ["+1 US", "+44 UK", "+91 IN", "+61 AU", "+81 JP", "+49 DE", "+33 FR"]
    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome").font(.title).bold()
            Text("OllaChat").font(.largeTitle).bold()
            Text("Enter your phone number")
            Picker("Country", selection: $cc) { ForEach(countries, id: \.self) { Text($0).tag(String($0.prefix(3)).trimmingCharacters(in: .whitespaces)) } }
                .pickerStyle(.menu).frame(width: 260)
                .onChange(of: cc) { _, v in if vm.phone.isEmpty { vm.phone = v } }
            Text("Country: \(cc) — E.164 auto-applied. QR pairing coming soon.").font(.caption).foregroundColor(.secondary)
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
            // P0-1: no per-keystroke normalize (traps backspace); normalized at send time.
            // Diagnostic: proves whether keystrokes reach the binding even if glyphs misrender.
            Text(vm.phone.isEmpty ? " " : "\(vm.phone.count) character(s) entered")
            Text("By continuing you agree to the Terms.").font(.caption).foregroundColor(.secondary)
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
    @State private var boxes = ["", "", "", "", "", ""]
    @FocusState private var focusIdx: Int?
    var body: some View {
        VStack(spacing: 16) {
            Text("Verify your number").font(.title2).bold()
            Text("Code sent to \(vm.phone)").foregroundColor(.secondary)
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    TextField("", text: $boxes[i])
                        .frame(width: 36).multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusIdx, equals: i)
                        .onChange(of: boxes[i]) { _, v in
                            // BUG-NEW-02: paste of N digits into ANY box distributes safely.
                            let digits = v.filter(\.isNumber)
                            if digits.count > 1 {
                                // Paste: fill all six from digit run (cap 6), ignore non-digits.
                                let chars = Array(digits.prefix(6))
                                for j in 0..<6 { boxes[j] = j < chars.count ? String(chars[j]) : "" }
                                focusIdx = chars.count >= 6 ? nil : min(chars.count, 5)
                            } else if digits.count == 1 {
                                boxes[i] = digits
                                if i < 5 { focusIdx = i + 1 } else { focusIdx = nil }
                            } else {
                                // Empty/backspace: clear this box, move back if possible.
                                boxes[i] = ""
                                if i > 0 { focusIdx = i - 1 }
                            }
                            vm.otpCode = boxes.joined()
                            // P3-13: auto-submit when all 6 entered.
                            if vm.otpCode.count == 6 { Task { await vm.verifyOtp() } }
                        }
                }
            }.onAppear { focusIdx = 0 }
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
    @StateObject private var settings = AppSettings.shared
    @State private var showSettings = false
    @State private var showNewDM = false
    @State private var showNewGroup = false
    @State private var showProfile = false
    @State private var showDevices = false
    @State private var showCalls = false
    @State private var searchTask: Task<Void, Never>?
    @State private var filter = "All"
    @State private var showContacts = false
    @State private var showGlobalSearch = false
    @State private var showUpdates = false
    @State private var showStarred = false
    @State private var jumpToMessageId: String? = nil
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedRoom) {
                if let e = home.error {
                    Section {
                        Text(e).font(.caption).foregroundColor(.red)
                        Button("Retry") { Task { if let t = auth.session.sessionToken { await home.refresh(token: t) } } }
                    } header: { Text("Could not refresh") }
                }
                Section {
                    HStack {
                        ForEach(["All", "Unread", "Groups", "Channels"], id: \.self) { f in
                            Button(f) { filter = f }.buttonStyle(f == filter ? .borderedProminent : .bordered).controlSize(.small)
                        }
                    }
                } header: { Text("Filters") }
                if !home.isLoading && home.error == nil && filtered.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundColor(.secondary)
                            // Empty state with retry.
                            Text(search.isEmpty ? "No conversations yet" : "No matches for \"\(search)\"").font(.callout).foregroundColor(.secondary)
                            if search.isEmpty {
                                Button("Refresh") { Task { if let t = auth.session.sessionToken { await home.refresh(token: t) } } }.buttonStyle(.link)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
                if home.isLoading && home.inbox.isEmpty {
                    Section { ProgressView("Loading…").frame(maxWidth: .infinity) }
                }
                Section("Conversations") {
                    ForEach(filtered, id: \.room_id) { item in
                        HStack(spacing: 8) {
                            // Sidebar avatar circle.
                            Text(String((item.name ?? item.peer?.display_name ?? "?").prefix(1)).uppercased())
                                .font(.caption).bold().foregroundColor(.white)
                                .frame(width: 30, height: 30).background(Color.accentColor.opacity(0.8)).clipShape(Circle())
                            VStack(alignment: .leading) {
                                let title = item.name ?? item.peer?.display_name ?? item.room_id
                                Text(title).bold().lineLimit(1)
                                let preview = item.last_message?.preview ?? "No messages"
                                // BUG-09: "You:" prefix when last message is ours.
                                let isOwn = item.last_message?.sender_id != nil && item.last_message?.sender_id == auth.session.userId
                                Text("\(isOwn ? "You: " : "")\(preview)").font(.caption).foregroundColor(.secondary).lineLimit(1)
                                if let ts = item.last_message?.created_at { Text(ts).font(.caption2).foregroundColor(.secondary) }
                            }
                            Spacer()
                            if item.unread_count > 0 {
                                Text("\(item.unread_count)").font(.caption2).bold()
                                    .padding(6).background(Color.accentColor).foregroundColor(.white).clipShape(Circle())
                            }
                        }.tag(item)
                    }
                }
                if !search.isEmpty, selectedRoom != nil {
                    Section("Messages in this chat (backend search)") {
                        if roomSearch.isSearching { Text("Searching…").font(.caption).foregroundColor(.secondary) }
                        ForEach(roomSearch.results) { m in
                            HighlightedText(text: m.body["text"]?.value as? String ?? "[\(m.kind)]", query: search)
                                .font(.caption).lineLimit(2)
                                .onTapGesture { jumpToMessageId = m.id }
                        }
                    }
                }
                // P2-10: recent searches rendered when query empty.
                if search.isEmpty && !SearchRecents.shared.items.isEmpty {
                    Section("Recent searches") {
                        ForEach(SearchRecents.shared.items, id: \.self) { r in
                            Button(r) { search = r }.buttonStyle(.link)
                        }
                    }
                }
            }
            .searchable(text: $search)
            .onChange(of: search, initial: false) { _, q in
                // 300ms debounce before firing backend search.
                searchTask?.cancel()
                roomSearch.cancel()
                guard let room = selectedRoom, !q.isEmpty else { return }
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    SearchRecents.shared.push(q)
                    await roomSearch.search(roomId: room.room_id, query: q, sessionToken: auth.session.sessionToken, deviceId: auth.session.deviceId)
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
                    Button("Updates") { showUpdates = true }
                    Button("Starred") { showStarred = true }
                    Button("Contacts") { showContacts = true }
                    Button("Search") { showGlobalSearch = true }
                    Button("New DM") { showNewDM = true }
                    Button("New Group") { showNewGroup = true }
                    Button("Profile") { showProfile = true }
                    Button("Devices") { showDevices = true }
                    Button("Calls") { showCalls = true }
                    Button("Refresh") { Task { if let t = auth.session.sessionToken { await home.refresh(token: t) } } }
                    Button("Settings") { showSettings = true }
                    Button("Logout") { selectedRoom = nil; Task { await auth.logout() } }
                }
            }
            .sheet(isPresented: $showContacts) { ContactsView(auth: auth, home: home) }
            .sheet(isPresented: $showGlobalSearch) { GlobalSearchView(auth: auth) }
            .sheet(isPresented: $showUpdates) { VStack { Text("Updates").font(.headline); Text("Status placeholder — no stories yet.").foregroundColor(.secondary).font(.callout) }.padding().frame(width: 320) }
            .sheet(isPresented: $showStarred) { StarredView(chatRooms: home.inbox, onJump: { roomId, msgId in
                if let room = home.inbox.first(where: { $0.room_id == roomId }) {
                    selectedRoom = room
                    jumpToMessageId = msgId
                }
            }) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showNewDM) { NewDMView(auth: auth, home: home) }
            .sheet(isPresented: $showNewGroup) { NewGroupView(auth: auth, home: home, knownPeers: home.inbox.compactMap { $0.peer?.user_id }) }
            .sheet(isPresented: $showProfile) { ProfileView(auth: auth) }
            .sheet(isPresented: $showDevices) { DevicesView(auth: auth) }
            .sheet(isPresented: $showCalls) { CallsView() }
        } detail: {
            if let room = selectedRoom, let token = auth.session.sessionToken {
                ChatDetailView(room: room, sessionToken: token, deviceId: auth.session.deviceId, ownId: auth.session.userId, rooms: home.inbox, jumpToMessageId: $jumpToMessageId)
                    .id(room.room_id) // fresh state + socket per room; never recycle across rooms
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "message").font(.largeTitle).foregroundColor(.secondary)
                    Text("Select a conversation").foregroundColor(.secondary)
                    Text("Pick a chat on the left, or pull to refresh.").font(.caption).foregroundColor(.secondary)
                    if let e = home.error {
                        Button("Retry") { Task { if let t = auth.session.sessionToken { await home.refresh(token: t) } } }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if let t = auth.session.sessionToken { await home.refresh(token: t) } }
        // Dock unread badge: total non-own unread, zero clears.
        .onChange(of: home.inbox.map(\.unread_count).reduce(0, +)) { _, total in
            let n = max(0, total)
            NSApp.dockTile.badgeLabel = n == 0 ? "" : "\(n)"
        }
    }
    var filtered: [InboxItem] {
        var list = home.inbox
        if filter == "Unread" { list = list.filter { $0.unread_count > 0 } }
        if filter == "Groups" { list = list.filter { $0.kind.lowercased().contains("group") } }
        if filter == "Channels" { list = list.filter { $0.kind.lowercased().contains("channel") } }
        guard !search.isEmpty else { return list }
        let q = search.lowercased()
        return list.filter {
            ($0.name ?? "").lowercased().contains(q) ||
            ($0.peer?.display_name ?? "").lowercased().contains(q) ||
            $0.room_id.lowercased().contains(q)
        }
    }
}
extension InboxItem: Hashable { public static func == (l: InboxItem, r: InboxItem) -> Bool { l.room_id == r.room_id }; public func hash(into h: inout Hasher) { h.combine(room_id) } }

struct ChatDetailView: View {
    var room: InboxItem; var sessionToken: String; var deviceId: String; var ownId: String?
    var rooms: [InboxItem] = []
    @StateObject private var chat = ChatViewModel()
    @StateObject private var drafts = DraftStore.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var recorder = VoiceRecorder()
    @State private var draft = ""
    @State private var roomToken = ""
    @State private var wsUrl = ""
    @State private var forwarding: MessageResponse?
    @State private var forwardDone: String?
    @State private var historyAttempt = 0
    @State private var roomTokenError: String?
    @State private var showInfo = false
    @State private var editing: MessageResponse?
    @State private var editText = ""
    @State private var wasTyping = false
    @State private var typingStopTask: Task<Void, Never>?
    @State private var focusRoomSearch = false
    @State private var roomQuery = ""
    @StateObject private var roomSearchInline = RoomSearchViewModel()
    @State private var showEmoji = false
    @State private var showPreview = false
    @State private var previewCaption = ""
    @State private var showAttachSheet = false
    @State private var cameraNote: String? = nil
    @State private var pendingPick: PendingPick? = nil
    @State private var previewLoadTask: Task<Void, Never>? = nil
    @Binding var jumpToMessageId: String?
    private var lastSeenText: String {
        // lastSeen unavailable from server; show stable placeholder from history.
        if let last = chat.messages.last?.created_at { return "last seen \(String(last.prefix(10)))" }
        return "last seen recently"
    }
    init(room: InboxItem, sessionToken: String, deviceId: String, ownId: String? = nil, rooms: [InboxItem] = [], jumpToMessageId: Binding<String?>? = nil) {
        self.room = room; self.sessionToken = sessionToken; self.deviceId = deviceId; self.ownId = ownId; self.rooms = rooms
        self._jumpToMessageId = jumpToMessageId ?? .constant(nil)
    }
    var body: some View {
        VStack(spacing: 0) {
            // Header presence line (DM-aware) with avatar icon.
            HStack(spacing: 8) {
                Text(String((room.name ?? room.peer?.display_name ?? "?").prefix(1)).uppercased())
                    .font(.callout).bold().foregroundColor(.white)
                    .frame(width: 28, height: 28).background(Color.accentColor).clipShape(Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(settings.alias(for: room.room_id) ?? room.name ?? "Chat").font(.callout).bold().lineLimit(1)
                    if !chat.typingUsers.isEmpty || !chat.presenceOnline.isEmpty {
                let isDM = room.kind.lowercased().contains("direct")
                let headerText: String = {
                    if !chat.typingUsers.isEmpty { return "\(chat.typingUsers.sorted().joined(separator: ", ")) typing…" }
                    if isDM {
                        let peerOnline = chat.presenceOnline.values.first(where: { $0 }) != nil
                        return peerOnline ? "Online" : "Offline"
                    }
                    let online = chat.presenceOnline.filter { $0.value }.count
                    return "\(online) online"
                }()
                Text(headerText).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    // lastSeen for offline DM peers.
                    if room.kind.lowercased().contains("direct"), chat.typingUsers.isEmpty, !chat.presenceOnline.values.contains(true) {
                        Text(lastSeenText).font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button { showInfo = true } label: { Image(systemName: "person.circle") }.help("Open info")
            }.padding(.horizontal, 8).padding(.top, 6)
            if focusRoomSearch {
                HStack {
                    TextField("Search this chat", text: $roomQuery).textFieldStyle(.roundedBorder)
                    Button("Go") {
                        Task { await roomSearchInline.search(roomId: room.room_id, query: roomQuery, sessionToken: sessionToken, deviceId: deviceId) }
                    }.buttonStyle(.bordered).controlSize(.small)
                    Button("Close") { focusRoomSearch = false; roomSearchInline.cancel(); roomSearchInline.results = [] }.buttonStyle(.link)
                }.padding(.horizontal, 8)
                if !roomSearchInline.results.isEmpty {
                    List(roomSearchInline.results.prefix(5)) { m in
                        Button(m.body["text"]?.value as? String ?? "[\(m.kind)]") { jumpToMessageId = m.id }
                    }.frame(height: 130)
                }
            }
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
            if !chat.typingUsers.isEmpty {
                Text("\(chat.typingUsers.sorted().joined(separator: ", ")) typing…").font(.caption).foregroundColor(.secondary).padding(.horizontal, 8)
            }
            // Offline banner (reactive via ChatViewModel.isConnected).
            if !chat.isConnected && chat.historyLoaded {
                Text("Offline — reconnecting…").font(.caption).foregroundColor(.orange).padding(.horizontal, 8)
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
            ScrollViewReader { proxy in
            ScrollView { LazyVStack(alignment: .leading, spacing: 8) {
                if chat.historyLoaded && chat.hasMoreHistory && !chat.messages.isEmpty {
                    if chat.isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Button("Load earlier messages") { Task { await chat.loadMore() } }
                            .font(.caption).buttonStyle(.link)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                ForEach(chat.messages) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        // Date chip: day separator when day changes.
                        DayChipIfNeeded(messages: chat.messages, current: m)
                        // System notice chip.
                        if m.kind == "system" || m.kind == "event" {
                            Text(m.body["text"]?.value as? String ?? "[system]").font(.caption).foregroundColor(.secondary)
                                .padding(6).background(Color.secondary.opacity(0.12)).cornerRadius(8)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                        MessageBubble(message: m, roomId: room.room_id, chat: chat,
                                      roomKind: room.kind, isOwn: m.sender_id == ownId,
                                      onReply: { chat.replyTo = m },
                                      onForward: { forwarding = m },
                                      onEdit: { editing = m })
                            .id(m.id)
                        }
                        if let replyId = m.reply_to {
                            Button("Jump to original") { withAnimation { proxy.scrollTo(replyId, anchor: .center) } }
                                .font(.caption2).buttonStyle(.link)
                        }
                        // Multi-attachment: render/open every id, not just [0].
                        if m.attachment_ids.count > 1 {
                            ForEach(m.attachment_ids.dropFirst(), id: \.self) { aid in
                                AttachmentRow(chat: chat, attachmentId: aid, filename: m.body["filename"]?.value as? String, roomId: room.room_id, roomToken: roomToken)
                            }
                        }
                        if m.edited_at != nil { Text("edited").font(.caption2).foregroundColor(.secondary) }
                        if let online = chat.presenceOnline[m.sender_id] {
                            Text(online ? "online" : "offline").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                if chat.historyLoaded && chat.messages.isEmpty && chat.failedDrafts.isEmpty && roomTokenError == nil && chat.historyError == nil {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left").font(.largeTitle).foregroundColor(.secondary)
                    Text("No messages yet. Say hello!").font(.callout).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 32)
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
                .background(DoodleBackground())
                .onChange(of: jumpToMessageId) { _, target in
                    guard let target, chat.messages.contains(where: { $0.id == target }) else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                }
            } // ScrollViewReader
            .onChange(of: chat.historyLoaded) { _, loaded in
                // Starred jump: open correct room + scroll if message present.
                if loaded, let target = jumpToMessageId,
                   chat.messages.contains(where: { $0.id == target }) {
                    // Scroll deferred one turn so LazyVStack has laid out.
                    DispatchQueue.main.async { jumpToMessageId = nil }
                } else if loaded { jumpToMessageId = nil } // deleted/unavailable: clear safely
            }
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
            switch chat.uploadState {
            case .uploading(let name):
                HStack {
                    ProgressView(value: chat.uploadProgress).controlSize(.small).frame(width: 120)
                    Text("Uploading \(name)… \(Int(chat.uploadProgress * 100))%").font(.caption)
                    Spacer()
                    Button("Cancel") { chat.cancelUpload() }
                }.padding(8).background(Color.secondary.opacity(0.12))
            case .failed(let name, let message):
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.red)
                    Text("\(name): \(message)").font(.caption).lineLimit(2)
                    Spacer()
                    Button("Retry") { chat.retryUpload(roomId: room.room_id) }
                    Button("Dismiss") { chat.cancelUpload() }
                }.padding(8).background(Color.red.opacity(0.1))
            case .idle:
                EmptyView()
            }
            HStack {
                Button { pickAndSend() } label: { Image(systemName: "paperclip") }
                    .help("Attach a file")
                Button { pickFileForPreview(); showPreview = true } label: { Image(systemName: "photo.on.rectangle") }.help("Preview + caption")
                Button { showEmoji.toggle() } label: { Image(systemName: "face.smiling") }.help("Emoji")
                Button { showAttachSheet = true } label: { Image(systemName: "plus.circle") }.help("More actions")
                // Mic/send swap: mic only when empty, send emphasized when typing.
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { recorder.isRecording ? stopAndSendVoice() : recorder.start() } label: {
                        Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.circle")
                    }.help("Record voice message")
                }
                TextField("Message", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .foregroundColor(.primary)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                    .onChange(of: draft) { _, v in
                        drafts.set(v, for: room.room_id)
                        // P1-7: typing send with 5s inactivity timeout.
                        let started = !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        if started != wasTyping {
                            wasTyping = started
                            chat.socket.sendTyping(roomId: room.room_id, started: started)
                        }
                        typingStopTask?.cancel()
                        if started {
                            typingStopTask = Task {
                                try? await Task.sleep(nanoseconds: 5_000_000_000)
                                guard !Task.isCancelled else { return }
                                wasTyping = false
                                chat.socket.sendTyping(roomId: room.room_id, started: false)
                            }
                        }
                    }
                Button("Send") {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    typingStopTask?.cancel(); wasTyping = false
                    chat.send(roomId: room.room_id, text: text); draft = ""; drafts.clear(roomId: room.room_id)
                }.buttonStyle(.borderedProminent).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding()
            if recorder.isRecording {
                HStack(spacing: 4) {
                    Image(systemName: "waveform").foregroundColor(.red)
                    // Animated recording bars.
                    RecordingBars()
                    Text("Recording \(recorder.seconds)s… tap stop to send").font(.caption).foregroundColor(.red)
                    Spacer()
                }.padding(.horizontal)
            }
            if showEmoji {
                HStack { ForEach(["😀", "👍", "❤️", "😂", "🎉", "🙏"], id: \.self) { e in Button(e) { draft += e } } }.padding(.horizontal)
            }
            if let verr = recorder.error { Text(verr).font(.caption).foregroundColor(.red).padding(.horizontal) }
        }
        .navigationTitle(settings.alias(for: room.room_id) ?? room.name ?? "Chat")
        .toolbar {
            ToolbarItemGroup {
                // Header avatar icon + presence handled in body; quick actions here.
                Button("Voice") { chat.activeCall = (callId: UUID().uuidString, initiator: ownId ?? "") }.help("Start voice call (UI stub — engine pending)")
                Button("Video") { chat.activeCall = (callId: UUID().uuidString, initiator: ownId ?? "") }.help("Start video call (UI stub — engine pending)")
                Button("Search") { focusRoomSearch = true }.help("Search in this conversation")
                Button("Info") { showInfo = true }
            }
        }
        .sheet(isPresented: $showInfo) { RoomInfoView(room: room, chat: chat) }
        .sheet(isPresented: $showAttachSheet) {
            VStack(spacing: 12) {
                Text("Share").font(.headline)
                HStack(spacing: 12) {
                    Button("Location") {
                        showAttachSheet = false
                        chat.sendLocation(roomId: room.room_id, lat: 12.9716, lon: 77.5946)
                    }.buttonStyle(.bordered)
                    Button("Contact") {
                        showAttachSheet = false
                        chat.sendContact(roomId: room.room_id, name: "Demo Contact", phone: "+10000000000")
                    }.buttonStyle(.bordered)
                    Button("Camera") {
                        showAttachSheet = false
                        cameraNote = "Camera capture needs Mac camera permission — use Attach for now."
                    }.buttonStyle(.bordered)
                }
                if let n = cameraNote { Text(n).font(.caption).foregroundColor(.secondary) }
                Button("Close") { showAttachSheet = false }
            }.padding().frame(width: 360)
        }
        .sheet(isPresented: $showPreview) {
            // Genuine preview: file picked FIRST, shown here, uploaded only on Send.
            VStack(spacing: 12) {
                Text("Send attachment").font(.headline)
                if let pick = pendingPick {
                    if pick.kind == MessageKinds.image, let img = NSImage(data: pick.data) {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 220).cornerRadius(8)
                    } else if pick.kind == MessageKinds.video, let u = pick.fileURL {
                        CachedVideoPlayer(url: u).frame(height: 180)
                    } else {
                        Label("\(pick.filename) (\(pick.mime))", systemImage: "doc.fill").font(.callout)
                    }
                    Text("\(pick.data.count / 1024) KB").font(.caption2).foregroundColor(.secondary)
                    TextField("Caption (optional)", text: $previewCaption).textFieldStyle(.roundedBorder)
                    if let err = pick.error { Text(err).font(.caption).foregroundColor(.red) }
                    HStack {
                        Button("Cancel") { previewLoadTask?.cancel(); pendingPick = nil; previewCaption = ""; showPreview = false }
                        Button("Send") {
                            let p = pick; let cap = previewCaption
                            pendingPick = nil; previewCaption = ""; showPreview = false
                            // uploadGen-protected path; room pinned inside runUpload.
                            chat.uploadAndSend(roomId: room.room_id, data: p.data, filename: p.filename, mime: p.mime, kind: p.kind, caption: cap.isEmpty ? nil : cap)
                        }.buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("No file selected").foregroundColor(.secondary).font(.callout)
                    HStack {
                        Button("Pick file") { pickFileForPreview() }
                        Button("Cancel") { showPreview = false }
                    }
                }
            }.padding().frame(width: 380)
        }
        .sheet(item: $editing) { msg in
            VStack(spacing: 12) {
                Text("Edit message").font(.headline)
                TextField("Text", text: $editText).textFieldStyle(.roundedBorder)
                    .onAppear { editText = msg.body["text"]?.value as? String ?? "" }
                HStack {
                    Button("Cancel") { editing = nil }
                    Button("Save") { chat.editMessage(roomId: room.room_id, messageId: msg.id, text: editText); editing = nil }.buttonStyle(.borderedProminent)
                }
            }.padding().frame(width: 340)
        }
        .onAppear { draft = drafts.draft(for: room.room_id) }
        .task(id: historyAttempt) {
            // 4401 recovery: re-mint the room token and reconnect through the same path.
            chat.onTokenExpired = { historyAttempt += 1 }
            do {
                let rt = try await OllacoreAPI.shared.roomToken(token: sessionToken, roomId: room.room_id, deviceId: deviceId)
                roomTokenError = nil
                roomToken = rt.access_token; wsUrl = rt.chat_websocket_url
                await chat.join(roomToken: roomToken, roomId: room.room_id, wsUrl: wsUrl, ownId: ownId, expiresAt: rt.expires_at)
                if chat.historyError == nil { chat.markVisibleAsRead(roomId: room.room_id) }
            } catch is CancellationError {
                // View left or superseded: stay silent, never stain the UI.
            } catch let e as URLError where e.code == .cancelled {
                // URLSession surfaces cancellation this way, not as CancellationError.
            } catch {
                // NEW-08: token failures (401, timeout, malformed) surface with retry.
                roomTokenError = error.localizedDescription
            }
        }
        .onDisappear { previewLoadTask?.cancel(); typingStopTask?.cancel(); chat.disconnect() }
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

    private func stopAndSendVoice() {
        guard let url = recorder.stop() else { return }
        guard let data = try? Data(contentsOf: url) else { recorder.discardConsumed(url); return }
        chat.uploadAndSend(roomId: room.room_id, data: data, filename: "voice-\(Int(Date().timeIntervalSince1970)).m4a", mime: "audio/mp4", kind: MessageKinds.audio)
        recorder.discardConsumed(url)
    }

    private func pickFileForPreview() {
        // Main actor: panel only. Heavy I/O goes to Task.detached below.
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        previewLoadTask?.cancel()
        let roomIdAtPick = room.room_id
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        pendingPick = PendingPick(data: Data(), filename: filename, mime: "", kind: "", fileURL: nil, error: "Loading…")
        previewLoadTask = Task {
            // Single read off-main; classify + thumbnail prep here, no upload.
            let loaded: (data: Data?, tooBig: Bool) = await Task.detached(priority: .userInitiated) { () -> (Data?, Bool) in
                guard let d = try? Data(contentsOf: url) else { return (nil, false) }
                if d.count > 100 * 1024 * 1024 { return (nil, true) }
                return (d, false)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard room.room_id == roomIdAtPick else { return } // stale: room switched
                if let data = loaded.data {
                    // Tier1: magic-byte validation first, extension fallback second.
                    if let v = MimeValidator.validate(filename: filename, data: data), v.blocked {
                        pendingPick = PendingPick(data: Data(), filename: filename, mime: "", kind: "", fileURL: nil, error: "Blocked file type.")
                        return
                    }
                    let mime: String; let kind: String
                    switch ext {
                    case "png": mime = "image/png"; kind = MessageKinds.image
                    case "jpg", "jpeg": mime = "image/jpeg"; kind = MessageKinds.image
                    case "gif": mime = "image/gif"; kind = MessageKinds.image
                    case "mp4", "mov": mime = "video/mp4"; kind = MessageKinds.video
                    case "mp3", "m4a", "wav", "ogg": mime = "audio/mpeg"; kind = MessageKinds.audio
                    case "pdf": mime = "application/pdf"; kind = MessageKinds.file
                    default: mime = "application/octet-stream"; kind = MessageKinds.file
                    }
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                    try? data.write(to: tmp)
                    pendingPick = PendingPick(data: data, filename: filename, mime: mime, kind: kind, fileURL: tmp, error: nil)
                } else if loaded.tooBig {
                    pendingPick = PendingPick(data: Data(), filename: filename, mime: "", kind: "", fileURL: nil, error: "File exceeds 100MB limit.")
                } else {
                    pendingPick = PendingPick(data: Data(), filename: filename, mime: "", kind: "", fileURL: nil, error: "Could not read file.")
                }
            }
        }
    }

    private func pickAndSendWithCaption(_ caption: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task.detached {
            guard let data = try? Data(contentsOf: url) else { return }
            // Preserve real MIME/kind from extension (was octet-stream).
            let ext = url.pathExtension.lowercased()
            let mime: String; let kind: String
            switch ext {
            case "png": mime = "image/png"; kind = MessageKinds.image
            case "jpg", "jpeg": mime = "image/jpeg"; kind = MessageKinds.image
            case "gif": mime = "image/gif"; kind = MessageKinds.image
            case "mp4", "mov": mime = "video/mp4"; kind = MessageKinds.video
            case "mp3", "m4a", "wav", "ogg": mime = "audio/mpeg"; kind = MessageKinds.audio
            case "pdf": mime = "application/pdf"; kind = MessageKinds.file
            default: mime = "application/octet-stream"; kind = MessageKinds.file
            }
            await MainActor.run { chat.uploadAndSend(roomId: room.room_id, data: data, filename: url.lastPathComponent, mime: mime, kind: kind, caption: caption.isEmpty ? nil : caption) }
        }
    }

    private func pickAndSend() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // BUG-06: read file off the main thread.
        Task.detached {
            guard let data = try? Data(contentsOf: url) else { return }
            let ext = url.pathExtension.lowercased()
            let mime: String
            let kind: String
            switch ext {
            case "png": mime = "image/png"; kind = MessageKinds.image
            case "jpg", "jpeg": mime = "image/jpeg"; kind = MessageKinds.image
            case "gif": mime = "image/gif"; kind = MessageKinds.image
            case "mp4", "mov": mime = "video/mp4"; kind = MessageKinds.video
            case "mp3", "m4a", "wav", "ogg": mime = "audio/mpeg"; kind = MessageKinds.audio
            case "pdf": mime = "application/pdf"; kind = MessageKinds.file
            default: mime = "application/octet-stream"; kind = MessageKinds.file
            }
            await MainActor.run { chat.uploadAndSend(roomId: room.room_id, data: data, filename: url.lastPathComponent, mime: mime, kind: kind) }
        }
    }
}

struct MessageBubble: View {
    var message: MessageResponse
    var roomId: String
    var roomKind: String = "direct"
    var isOwn: Bool = false
    @ObservedObject var chat: ChatViewModel
    var onReply: () -> Void = {}
    var onForward: () -> Void = {}
    var onEdit: () -> Void = {}
    @State private var imageURL: URL?
    @State private var showFullImage = false
    @State private var opening = false
    @State private var showDoc = false
    @State private var docFile: URL? = nil

    private var caption: String? { message.body["text"]?.value as? String }
    private func shareImage() {
        guard let u = imageURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
    }
    private var senderColor: Color {
        let h = abs(message.sender_id.hashValue)
        return [Color.blue, Color.green, Color.purple, Color.orange, Color.pink][h % 5]
    }
    private var filename: String? { message.body["filename"]?.value as? String }
    private var mime: String? { message.body["mime"]?.value as? String }

    /// Downloads via the presigned URL and opens with the default app (or Save panel).
    private func openAttachment(savePanel: Bool = false) {
        guard !opening, let aid = message.attachment_ids.first else { return }
        opening = true
        // BUG G-01: use pinned room/token via chat's current context (view passes roomId).
        let rId = roomId
        Task {
            defer { opening = false }
            guard let url = await chat.resolveAttachmentURL(attachmentId: aid, roomId: rId),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            let dest: URL
            if savePanel {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = filename ?? aid
                guard panel.runModal() == .OK, let chosen = panel.url else { return }
                dest = chosen
            } else {
                dest = FileManager.default.temporaryDirectory.appendingPathComponent(filename ?? aid)
            }
            try? data.write(to: dest)
            // In-app PDF: present sheet for pdf, external otherwise.
            if (filename ?? aid).lowercased().hasSuffix(".pdf") || mime == "application/pdf" {
                docFile = dest; showDoc = true
            } else {
                NSWorkspace.shared.open(dest)
            }
        }
    }

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
            // P2-12: avatar circle only for group incoming messages.
            if roomKind != "direct" && !isOwn {
                Text(String(message.sender_id.prefix(1)).uppercased())
                    .font(.caption2).bold().foregroundColor(.white)
                    .frame(width: 22, height: 22).background(senderColor).clipShape(Circle())
            }
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
                    ZoomableImage(url: u)
                        .frame(maxWidth: 320).cornerRadius(8)
                    .onTapGesture { showFullImage = true }
                    .sheet(isPresented: $showFullImage) {
                        VStack {
                            ZoomableImage(url: u).frame(maxWidth: 800, maxHeight: 600)
                            HStack {
                                Button("Share") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(u.absoluteString, forType: .string)
                                }
                                Button("Close") { showFullImage = false }.padding()
                            }
                        }.padding()
                    }
                } else {
                    Label("Image", systemImage: "photo").foregroundColor(.secondary)
                        .task { imageURL = await chat.resolveAttachmentURL(attachmentId: message.attachment_ids.first ?? "", roomId: roomId) }
                }
                HStack(spacing: 6) {
                    Button("Share") { shareImage() }.font(.caption).buttonStyle(.link)
                    if let c = caption, !c.isEmpty { Text(c) }
                }
            case MessageKinds.video:
                // P0-4: cached player per URL so re-renders don't reset playback.
                if let u = imageURL { CachedVideoPlayer(url: u).frame(height: 220).cornerRadius(8) }
                else {
                    Button { openAttachment() } label: {
                        Label(filename ?? "Video (tap to open)", systemImage: "video.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain).disabled(opening)
                    .task { imageURL = await chat.resolveAttachmentURL(attachmentId: message.attachment_ids.first ?? "", roomId: roomId) }
                }
                if let c = caption { Text(c).font(.caption) }
            case MessageKinds.audio:
                // P0-4: dedicated audio UI, no black VideoPlayer box.
                if let u = imageURL { AudioPlayerRow(url: u, filename: filename) }
                else {
                    Button { Task { imageURL = await chat.resolveAttachmentURL(attachmentId: message.attachment_ids.first ?? "", roomId: roomId) } } label: {
                        Label("Voice message (tap to load)", systemImage: "waveform").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            case MessageKinds.file:
                Button { openAttachment() } label: {
                    Label(filename ?? "Document (tap to open)", systemImage: "doc.fill").foregroundColor(.secondary)
                }.buttonStyle(.plain).disabled(opening)
                if let m = mime, m != "application/pdf" { Text(m).font(.caption).foregroundColor(.secondary) }
                .sheet(isPresented: $showDoc) {
                    VStack {
                        if let f = docFile, f.pathExtension.lowercased() == "pdf" {
                            PDFDocView(fileURL: f).frame(maxWidth: 700, maxHeight: 550)
                            if let doc = PDFDocument(url: f) {
                                Text("\(doc.pageCount) pages").font(.caption2).foregroundColor(.secondary)
                            }
                        } else {
                            Text(filename ?? "Document").font(.headline)
                            Text("Preview not available — opened externally.").font(.caption).foregroundColor(.secondary)
                        }
                        HStack {
                            Button("Share") {
                                if let f = docFile {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(f.absoluteString, forType: .string)
                                }
                            }
                            Button("Close") { showDoc = false }.padding()
                        }
                    }.padding()
                }
                if let m = mime { Text(m).font(.caption).foregroundColor(.secondary) }
            case MessageKinds.location:
                let lat = message.body["lat"]?.value
                let lon = message.body["lon"]?.value ?? message.body["lng"]?.value
                Label("\(lat.map { "\($0)" } ?? "?"), \(lon.map { "\($0)" } ?? "?")", systemImage: "mappin").foregroundColor(.secondary)
                if let c = caption { Text(c).font(.caption) }
            case "contact":
                let nm = message.body["name"]?.value as? String ?? "Contact"
                let ph = message.body["phone"]?.value as? String ?? ""
                Label("\(nm) • \(ph)", systemImage: "person.crop.circle").foregroundColor(.secondary)
            default:
                LinkifiedText(caption ?? "[\(message.kind)]")
                LinkPreviewCard(text: caption ?? "")
            }
            HStack(spacing: 6) {
                // Star indicator (observed so toggles re-render).
                StarBadge(messageId: message.id)
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
                Text(String(message.created_at.prefix(16)).replacingOccurrences(of: "T", with: " ")).font(.caption2).foregroundColor(.secondary)
            }
            }
        }
        .padding(8).background(Color.accentColor.opacity(0.12)).cornerRadius(8)
        .onTapGesture {
            if chat.selectionMode { chat.toggleSelect(id: message.id) }
        }
        .contextMenu {
            Button("Reply") { onReply() }
            Button("Edit…") { onEdit() }
            Button("Save attachment…") { openAttachment(savePanel: true) }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.body["text"]?.value as? String ?? "", forType: .string)
            }
            Button("Forward…") { onForward() }
            Button(chat.selectionMode ? "Deselect" : "Select") {
                chat.selectionMode = true; chat.toggleSelect(id: message.id)
            }
            Button("Delete", role: .destructive) { chat.deleteMessage(roomId: roomId, messageId: message.id) }
            Button(StarStore.shared.ids.contains(message.id) ? "Unstar" : "Star") {
                let info = StarredInfo(id: message.id, sender: message.sender_id,
                    text: message.body["text"]?.value as? String ?? "[\(message.kind)]",
                    roomId: roomId, roomName: "", timestamp: message.created_at)
                StarStore.shared.toggle(message.id, info: info)
            }
            ForEach(["👍", "❤️", "😂", "😮", "😢"], id: \.self) { emoji in
                Button("React \(emoji)") { chat.addReaction(roomId: roomId, messageId: message.id, emoji: emoji) }
                Button("Remove \(emoji)", role: .destructive) { chat.removeReaction(roomId: roomId, messageId: message.id, emoji: emoji) }
            }
        }
    }
}

// MARK: - Settings (notifications + app lock + theme)
struct SettingsView: View {
    @StateObject private var s = AppSettings.shared
    @State private var showPrivacy = false
    @State private var showStorage = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)
            Toggle("Notifications", isOn: $s.notificationsEnabled)
            Toggle("Message notifications", isOn: $s.notifyMessages)
            Toggle("Call notifications", isOn: $s.notifyCalls)
            Toggle("Mentions only", isOn: $s.notifyMentionsOnly)
            Toggle("App lock on launch", isOn: $s.appLockEnabled)
            Button("Unlock test (Touch ID)") { _ = s.requestUnlock() }.buttonStyle(.link)
            Button("Privacy & Security") { showPrivacy = true }.buttonStyle(.link)
            Button("Storage & Cache") { showStorage = true }.buttonStyle(.link)
            .sheet(isPresented: $showPrivacy) { VStack { Text("Privacy & Security").font(.headline); Text("Disappearing messages TTL: server-gated (not yet available).").font(.caption).foregroundColor(.secondary); Text("E2EE: models decoded; crypto engine pending.").font(.caption).foregroundColor(.secondary) }.padding().frame(width: 340) }
            .sheet(isPresented: $showStorage) { StorageView() }
            Picker("Theme", selection: $s.themeRaw) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                Text("Blue").tag("blue"); Text("Green").tag("green"); Text("Purple").tag("purple")
            }.pickerStyle(.segmented)
            Text("Stored locally in UserDefaults; no server call.").font(.caption).foregroundColor(.secondary)
        }.padding().frame(width: 340)
    }
}

// MARK: - Contact/group info panel (alias, mute, members, media counts)
struct RoomInfoView: View {
    var room: InboxItem
    @ObservedObject var chat: ChatViewModel
    @StateObject private var s = AppSettings.shared
    @State private var alias = ""
    @Environment(\.dismiss) private var dismissInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conversation info").font(.headline)
            Text(room.name ?? room.peer?.display_name ?? room.room_id).bold()
            Text(room.room_id).font(.caption).foregroundColor(.secondary)
            TextField("Alias (local only)", text: $alias).textFieldStyle(.roundedBorder)
                .onAppear { alias = s.alias(for: room.room_id) ?? "" }
            HStack {
                Button("Save alias") { s.setAlias(alias, roomId: room.room_id) }
                Toggle("Mute", isOn: Binding(get: { s.isMuted(roomId: room.room_id) }, set: { s.setMuted($0, roomId: room.room_id) }))
            }
            let live = chat.members.isEmpty ? Set(chat.messages.map(\.sender_id)).sorted() : chat.members.sorted()
            Text("Members (\(live.count)): \(live.joined(separator: ", "))").font(.caption)
            let media = chat.messages.filter { $0.kind != MessageKinds.text }.count
            Text("Messages: \(chat.messages.count) • Media & files: \(media) • Starred: \(StarStore.shared.ids.count)").font(.caption).foregroundColor(.secondary)
            // Quick actions: voice/video/search.
            HStack {
                Button("Voice Call") { chat.activeCall = (callId: UUID().uuidString, initiator: "") }.disabled(true)
                Button("Video Call") { chat.activeCall = (callId: UUID().uuidString, initiator: "") }.disabled(true)
                Button("Search in Chat") { dismissInfo() }
            }.buttonStyle(.bordered).controlSize(.small)
            // Media strip: recent image/file names.
            let recentMedia = chat.messages.filter { $0.kind != MessageKinds.text }.suffix(6)
            if !recentMedia.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(recentMedia), id: \.id) { m in
                            Text(m.body["filename"]?.value as? String ?? "[\(m.kind)]").font(.caption2).padding(5).background(Color.secondary.opacity(0.12)).cornerRadius(6)
                        }
                    }
                }.frame(height: 30)
            }
            // P3-14: group admin stubs (server endpoints pending — UI ready).
            if room.kind.lowercased().contains("group") {
                Text("Group admin: add/remove/promote/leave require server endpoints (not yet in OllacoreAPI).").font(.caption2).foregroundColor(.secondary)
                HStack {
                    Button("Add member") {}.disabled(true)
                    Button("Leave") {}.disabled(true)
                }.buttonStyle(.bordered).controlSize(.small)
            }
        }.padding().frame(width: 380)
    }
}

// MARK: - Voice recorder (AVFoundation, m4a, sent as audio message)
@MainActor final class VoiceRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var error: String?
    @Published var seconds = 0
    private var rec: AVAudioRecorder?
    private var url: URL?
    func tick() {
        guard isRecording else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.seconds += 1; self.tick() }
    }
    func start() {
        error = nil
        // F-07: mic permission gate (macOS may deny); never start blind.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: error = "Microphone access denied. Enable it in System Settings."; return
        case .notDetermined: break // AVAudioRecorder prompts on first use
        default: break
        }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString.prefix(8)).m4a")
        let st = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1] as [String: Any]
        // F-07: construct off the main thread to avoid blocking UI on file/codec setup.
        Task.detached { [u, st] in
            let r = try? AVAudioRecorder(url: u, settings: st)
            await MainActor.run {
                guard let r else { self.error = "Could not start recording."; return }
                // Drop any prior unclaimed temp file to avoid leaks.
                if let old = self.url, old != u { try? FileManager.default.removeItem(at: old) }
                self.rec = r; self.url = u
                self.seconds = 0
                self.rec?.record(); self.isRecording = true
                self.tick()
            }
        }
    }
    func stop() -> URL? {
        rec?.stop(); rec = nil; isRecording = false
        return url
    }
    func discardConsumed(_ u: URL?) {
        // Caller deletes the temp file once bytes are read for upload.
        guard let u, u == url else { return }
        try? FileManager.default.removeItem(at: u)
        if url == u { url = nil }
    }
}

// MARK: - Shared rows + creation/profile/devices/calls
struct AttachmentRow: View {
    @ObservedObject var chat: ChatViewModel
    var attachmentId: String; var filename: String?
    var roomId: String = ""; var roomToken: String = ""
    @State private var opening = false
    var body: some View {
        Button(opening ? "Loading…" : (filename ?? "Attachment \(attachmentId.prefix(8))")) {
            opening = true
            // F-05: pinned room+token, no stale currentRoom/currentToken read.
            Task { _ = await chat.resolveAttachmentURL(attachmentId: attachmentId, roomId: roomId.isEmpty ? nil : roomId, roomToken: roomToken.isEmpty ? nil : roomToken); opening = false }
        }.font(.caption).buttonStyle(.link)
    }
}
struct NewDMView: View {
    @ObservedObject var auth: AuthViewModel; @ObservedObject var home: HomeViewModel
    @State private var peer = ""; @State private var msg: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("New direct message").font(.headline)
            // BUG-03: accept phone OR user id; resolve phones via lookup.
            TextField("phone or user id", text: $peer).textFieldStyle(.roundedBorder)
            Button("Create") {
                Task {
                    guard let t = auth.session.sessionToken else { return }
                    var uid = peer.trimmingCharacters(in: .whitespaces)
                    if uid.hasPrefix("+") || uid.first?.isNumber == true {
                        if let c = try? await OllacoreAPI.shared.lookupContacts(token: t, phones: [uid]), let first = c.first {
                            uid = first.user_id
                        } else { msg = "No contact found for \(uid)"; return }
                    }
                    if (try? await OllacoreAPI.shared.openDirect(token: t, peerUserId: uid)) != nil {
                        await home.refresh(token: t); dismiss()
                    } else { msg = "Failed to create DM" }
                }
            }.buttonStyle(.borderedProminent).disabled(peer.isEmpty)
            if let msg { Text(msg).font(.caption).foregroundColor(.red) }
            Button("Close") { dismiss() }
        }.padding().frame(width: 340)
    }
}
struct NewGroupView: View {
    @ObservedObject var auth: AuthViewModel; @ObservedObject var home: HomeViewModel
    var knownPeers: [String] = []
    @State private var name = ""; @State private var desc = ""; @State private var members = ""; @State private var step = 1
    @State private var msg: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("New group (step \(step)/3)").font(.headline)
            if step == 1 {
                TextField("member ids, comma-separated", text: $members).textFieldStyle(.roundedBorder)
                // Contact chips from typed ids.
                let chips = members.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !chips.isEmpty {
                    HStack { ForEach(chips, id: \.self) { c in Text(c).font(.caption2).padding(5).background(Color.accentColor.opacity(0.15)).cornerRadius(8) } }
                }
                // Contact picker with checkboxes (from known rooms' peers).
                Text("Pick from recent chats:").font(.caption).foregroundColor(.secondary)
                ForEach(knownPeers.prefix(5), id: \.self) { p in
                    Toggle(p, isOn: Binding(get: { chips.contains(p) }, set: { on in
                        var set = Set(chips)
                        if on { set.insert(p) } else { set.remove(p) }
                        members = set.sorted().joined(separator: ", ")
                    })).font(.caption)
                }
                Button("Next") { step = 2 }.buttonStyle(.borderedProminent).disabled(members.isEmpty)
            } else if step == 2 {
                TextField("Group name", text: $name).textFieldStyle(.roundedBorder)
                TextField("Description (optional)", text: $desc).textFieldStyle(.roundedBorder)
                HStack { Button("Back") { step = 1 }; Button("Next") { step = 3 }.buttonStyle(.borderedProminent).disabled(name.isEmpty) }
            } else {
                Text("Create \"\(name)\" with \(members)?").font(.callout).foregroundColor(.secondary)
                HStack {
                    Button("Back") { step = 2 }
                    Button("Create") {
                        Task {
                            guard let t = auth.session.sessionToken else { return }
                            let ids = members.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            if (try? await OllacoreAPI.shared.createGroup(token: t, members: ids, name: name)) != nil {
                                await home.refresh(token: t); dismiss()
                            } else { msg = "Failed to create group" }
                        }
                    }.buttonStyle(.borderedProminent)
                }
            }
            if let msg { Text(msg).font(.caption).foregroundColor(.red) }
            Button("Close") { dismiss() }
        }.padding().frame(width: 360)
    }
}
struct ProfileView: View {
    @ObservedObject var auth: AuthViewModel
    @State private var name = ""; @State private var about = ""; @State private var avatar = ""; @State private var msg: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("Profile").font(.headline)
            TextField("Display name", text: $name).textFieldStyle(.roundedBorder)
                .onAppear {
                    // BUG-01: fetch fresh profile on open so name never stale.
                    name = auth.displayName ?? ""
                    Task {
                        guard let t = auth.session.sessionToken,
                              let p = try? await OllacoreAPI.shared.getProfile(token: t) else { return }
                        name = p.display_name ?? name; about = p.about ?? ""
                        avatar = p.avatar_url ?? p.photo_url ?? ""
                        auth.displayName = p.display_name
                    }
                }
            TextField("About", text: $about).textFieldStyle(.roundedBorder)
            TextField("Avatar URL (https)", text: $avatar).textFieldStyle(.roundedBorder)
            HStack {
                Button("Pick avatar file") {
                    let p = NSOpenPanel(); p.canChooseFiles = true
                    if p.runModal() == .OK, let u = p.url { avatar = u.absoluteString }
                }.buttonStyle(.link)
                Text("Photo upload pipeline pending server API.").font(.caption2).foregroundColor(.secondary)
            }
            Button("Save") {
                Task {
                    guard let t = auth.session.sessionToken else { return }
                    if let p = try? await OllacoreAPI.shared.updateProfile(token: t, req: UpdateProfileRequest(display_name: name, about: about, avatar_url: avatar.isEmpty ? nil : avatar)) {
                        auth.displayName = p.display_name; msg = "Saved"
                    } else { msg = "Save failed" }
                }
            }.buttonStyle(.borderedProminent)
            if let msg { Text(msg).font(.caption).foregroundColor(.secondary) }
            Button("Close") { dismiss() }
        }.padding().frame(width: 340)
    }
}
struct DevicesView: View {
    @ObservedObject var auth: AuthViewModel
    @State private var devices: [DeviceResponse] = []; @State private var msg: String?
    @State private var showRemoveConfirm: String? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("Devices").font(.headline)
            Text("Link explainer: this Mac registers on login; remove lost devices.").font(.caption).foregroundColor(.secondary)
            List(devices) { d in
                HStack {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(d.id).font(.caption).bold()
                            if d.id == auth.session.deviceId {
                                Text("This Device").font(.caption2).padding(3).background(Color.green.opacity(0.2)).cornerRadius(4)
                            }
                        }
                        Text("\(d.platform) • \(d.updated_at)").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Remove") { showRemoveConfirm = d.id }.buttonStyle(.link)
                    .confirmationDialog("Log out this device?", isPresented: Binding(get: { showRemoveConfirm == d.id }, set: { if !$0 { showRemoveConfirm = nil } })) {
                        Button("Remove", role: .destructive) {
                            Task {
                                guard let t = auth.session.sessionToken else { return }
                                if await OllacoreAPI.shared.deleteDevice(token: t, deviceId: d.id) {
                                    devices.removeAll { $0.id == d.id }
                                }
                                showRemoveConfirm = nil
                            }
                        }
                        Button("Cancel", role: .cancel) { showRemoveConfirm = nil }
                    }
                }
            }
                .frame(minHeight: 160)
            if let msg { Text(msg).font(.caption).foregroundColor(.red) }
            Button("Close") { dismiss() }
        }.padding().frame(width: 380)
        .task {
            guard let t = auth.session.sessionToken else { return }
            do { devices = try await OllacoreAPI.shared.listDevices(token: t) } catch { msg = error.localizedDescription }
        }
    }
}
struct CallsView: View {    @StateObject private var log = CallLogStore()
    @State private var tab = "All"
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("Call history").font(.headline)
            Picker("", selection: $tab) { Text("All").tag("All"); Text("Missed").tag("Missed") }.pickerStyle(.segmented).frame(width: 200)
            let shown = tab == "All" ? log.entries : log.entries.filter { $0.peerName.isEmpty }
            if shown.isEmpty { Text("No calls yet").foregroundColor(.secondary).font(.callout) }
            List(shown) { e in
                HStack {
                    VStack(alignment: .leading) { Text(e.peerName.isEmpty ? "(missed)" : e.peerName).bold(); Text("\(e.roomId) • \(e.date.formatted())").font(.caption).foregroundColor(.secondary) }
                    Spacer()
                    Button("Call back") {}.disabled(true).buttonStyle(.link)
                    Button("Delete") { log.remove(id: e.id) }.buttonStyle(.link)
                }
            }
                .frame(minHeight: 160)
            HStack { Button("Clear") { log.clear() }; Spacer(); Button("Close") { dismiss() } }
        }.padding().frame(width: 400)
    }
}
struct LinkifiedText: View {
    var text: String
    var body: some View {
        // P0-2: no openURL override — SwiftUI opens browser by default.
        Text(build())
    }
    private func build() -> AttributedString {
        var out = AttributedString()
        let parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for (i, p) in parts.enumerated() {
            if p.hasPrefix("http"), let u = URL(string: p) {
                var a = AttributedString(p); a.link = u; a.underlineStyle = .single
                out += a
            } else { out += AttributedString(p) }
            if i < parts.count - 1 { out += AttributedString(" ") }
        }
        return out
    }
}
struct StarredView: View {
    var chatRooms: [InboxItem]
    var onJump: ((String, String) -> Void)? = nil
    @ObservedObject private var stars = StarStore.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("Starred messages").font(.headline)
            if stars.ids.isEmpty { Text("No starred messages").foregroundColor(.secondary).font(.callout) }
            List(Array(stars.ids).sorted(), id: \.self) { id in
                let info = stars.meta[id]
                let roomName = info?.roomName.isEmpty == false ? info!.roomName : (chatRooms.first(where: { $0.room_id == info?.roomId })?.name ?? info?.roomId ?? id)
                HStack {
                    Image(systemName: "star.fill").foregroundColor(.yellow)
                    VStack(alignment: .leading) {
                        Text(info?.text ?? id).lineLimit(2).font(.callout)
                        Text("\(info?.sender ?? "?") • \(roomName) • \(info?.timestamp ?? "")").font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Open") {
                        guard let info, !info.roomId.isEmpty else { return }
                        onJump?(info.roomId, info.id)
                        dismiss()
                    }.buttonStyle(.link)
                    Button("Unstar") { stars.toggle(id) }.buttonStyle(.link)
                }
            }.frame(minHeight: 200)
            Button("Close") { dismiss() }
        }.padding().frame(width: 440)
    }
}
struct StarBadge: View {
    var messageId: String
    @ObservedObject private var stars = StarStore.shared
    var body: some View {
        if stars.ids.contains(messageId) {
            Image(systemName: "star.fill").font(.caption2).foregroundColor(.yellow)
        }
    }
}
enum DockBadge {
    static func clear() { NSApp.dockTile.badgeLabel = "" }
}
struct PendingPick { var data: Data; var filename: String; var mime: String; var kind: String; var fileURL: URL?; var error: String? }
struct CachedVideoPlayer: View {
    var url: URL
    @State private var player: AVPlayer?
    var body: some View {
        Group {
            if let p = player { VideoPlayer(player: p).frame(height: 220).cornerRadius(8) }
            else { ProgressView().frame(height: 120) }
        }.onAppear { if player == nil { player = AVPlayer(url: url) } }
        .onDisappear { player?.pause(); player = nil }
    }
}
struct AudioPlayerRow: View {
    var url: URL; var filename: String?
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var progress: Double = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(playing ? "Pause" : "Play") {
                    if player == nil { player = AVPlayer(url: url); addPeriodic() }
                    if playing { player?.pause(); playing = false }
                    else {
                        if let item = player?.currentItem, item.duration.isValid,
                           item.currentTime() >= item.duration { player?.seek(to: .zero) }
                        player?.play(); playing = true
                    }
                }.buttonStyle(.bordered).controlSize(.small)
                Text(filename ?? "Voice message").font(.caption).lineLimit(1)
            }
            // Waveform scrubber.
            Slider(value: $progress, in: 0...1) { editing in
                if !editing, let d = player?.currentItem?.duration, d.isValid {
                    player?.seek(to: CMTimeMultiplyByFloat64(d, multiplier: progress))
                }
            }.controlSize(.mini)
        }
        .onDisappear { player?.pause() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard playing, let item = note.object as? AVPlayerItem, item == player?.currentItem else { return }
            playing = false; progress = 1.0
            player?.seek(to: .zero)
        }
    }
    private func addPeriodic() {
        player?.addPeriodicTimeObserver(forInterval: CMTimeMake(value: 1, timescale: 4), queue: .main) { t in
            guard let d = player?.currentItem?.duration, d.isValid, d.seconds > 0 else { return }
            progress = min(1.0, max(0.0, t.seconds / d.seconds))
        }
    }
}
struct ZoomableImage: View {
    var url: URL
    @State private var scale: CGFloat = 1.0
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFit().scaleEffect(scale)
                .gesture(MagnificationGesture().onChanged { scale = max(1.0, min(4.0, $0)) })
            case .failure: Label("Image unavailable", systemImage: "photo")
            default: ProgressView().frame(width: 200, height: 120)
            }
        }
    }
}
struct PDFDocView: NSViewRepresentable {
    var fileURL: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView(); v.autoScales = true; v.document = PDFDocument(url: fileURL); return v
    }
    func updateNSView(_ v: PDFView, context: Context) {}
}
struct DoodleBackground: View {
    var body: some View {
        // Subtle doodle dots (low-cost canvas pattern).
        GeometryReader { geo in
            Path { p in
                var y: CGFloat = 0
                while y < geo.size.height { var x: CGFloat = 8; while x < geo.size.width { p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + 1, y: y)); x += 28 }; y += 28 }
            }.stroke(Color.secondary.opacity(0.08), lineWidth: 1.5)
        }
    }
}
struct StorageView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("Storage & Cache").font(.headline)
            Text("Cached images, voice notes, documents live in temp + UserDefaults.").font(.caption).foregroundColor(.secondary)
            Button("Clear temp cache") {
                try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory)
            }.buttonStyle(.bordered)
            Button("Close") { dismiss() }
        }.padding().frame(width: 340)
    }
}
struct HighlightedText: View {
    var text: String; var query: String
    var body: some View {
        if query.isEmpty { Text(text) }
        else if let r = text.range(of: query, options: .caseInsensitive) {
            Text(text[..<r.lowerBound]) + Text(text[r]).bold().foregroundColor(.accentColor) + Text(text[r.upperBound...])
        } else { Text(text) }
    }
}
struct RecordingBars: View {
    @State private var tick = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(Color.red)
                    .frame(width: 3, height: tick ? CGFloat(6 + i * 3) : CGFloat(14 - i * 2))
            }
        }.onAppear { tick.toggle() }
        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: tick)
    }
}
struct LinkPreviewCard: View {
    var text: String
    var body: some View {
        if let host = linkHost {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.caption)
                Text(host).font(.caption).lineLimit(1)
            }.padding(6).background(Color.secondary.opacity(0.12)).cornerRadius(6)
        }
    }
    private var linkHost: String? {
        guard let range = text.range(of: "https?://[^\\s]+", options: .regularExpression),
              let u = URL(string: String(text[range])) else { return nil }
        return u.host
    }
}
struct DayChipIfNeeded: View {
    var messages: [MessageResponse]; var current: MessageResponse
    var body: some View {
        let day = String(current.created_at.prefix(10))
        let idx = messages.firstIndex(where: { $0.id == current.id }) ?? 0
        let prev = idx > 0 ? String(messages[idx - 1].created_at.prefix(10)) : ""
        if day != prev {
            Text(day).font(.caption2).foregroundColor(.secondary)
                .padding(4).background(Color.secondary.opacity(0.12)).cornerRadius(6)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
struct ContactsView: View {
    @ObservedObject var auth: AuthViewModel; @ObservedObject var home: HomeViewModel
    @State private var phones = ""; @State private var found: [ContactUser] = []; @State private var msg: String?
    @State private var peerFilter = ""; @State private var showGroupFromContacts = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("Contacts lookup").font(.headline)
            TextField("Filter inbox peers", text: $peerFilter).textFieldStyle(.roundedBorder)
            if !peerFilter.isEmpty {
                ForEach(home.inbox.filter { ($0.name ?? "").localizedCaseInsensitiveContains(peerFilter) }, id: \.room_id) { r in
                    Text(r.name ?? r.room_id).font(.caption)
                }
            }
            TextField("phones, comma-separated", text: $phones).textFieldStyle(.roundedBorder)
            Button("New Group") { showGroupFromContacts = true }.buttonStyle(.link)
            .sheet(isPresented: $showGroupFromContacts) { NewGroupView(auth: auth, home: home) }
            Button("Lookup") {
                Task {
                    guard let t = auth.session.sessionToken else { return }
                    let list = phones.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    do { found = try await OllacoreAPI.shared.lookupContacts(token: t, phones: list) }
                    catch { msg = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent).disabled(phones.isEmpty)
            List(found, id: \.user_id) { c in
                HStack {
                    VStack(alignment: .leading) { Text(c.display_name ?? c.phone).bold().font(.callout); Text(c.phone).font(.caption).foregroundColor(.secondary) }
                    Spacer()
                    Button("Chat") {
                        Task {
                            guard let t = auth.session.sessionToken else { return }
                            if (try? await OllacoreAPI.shared.openDirect(token: t, peerUserId: c.user_id)) != nil {
                                await home.refresh(token: t); dismiss()
                            }
                        }
                    }.buttonStyle(.link)
                }
            }.frame(minHeight: 160)
            if let msg { Text(msg).font(.caption).foregroundColor(.red) }
            Button("Close") { dismiss() }
        }.padding().frame(width: 400)
    }
}
struct GlobalSearchView: View {
    @ObservedObject var auth: AuthViewModel
    @State private var q = ""; @State private var count = 0; @State private var msg: String?
    @State private var tab = "All"
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("Global search").font(.headline)
            Picker("", selection: $tab) {
                Text("All").tag("All"); Text("Messages").tag("Messages"); Text("Media").tag("Media"); Text("Docs").tag("Docs"); Text("Links").tag("Links"); Text("Audio").tag("Audio")
            }.pickerStyle(.segmented)
            Text("Tab filters results by kind (Media=images+video, Docs=files, Links=http text, Audio=audio).").font(.caption2).foregroundColor(.secondary)
            TextField("Search all chats (room-scoped fan-out)", text: $q).textFieldStyle(.roundedBorder)
            Button("Search") {
                Task {
                    guard let t = auth.session.sessionToken, !q.isEmpty else { return }
                    // BUG-05: hoist SessionStore out of the loop.
                    let dev = auth.session.deviceId
                    do {
                        let inbox = try await OllacoreAPI.shared.getInbox(token: t)
                        var total = 0
                        for room in inbox.prefix(10) {
                            guard let rt = try? await OllacoreAPI.shared.roomToken(token: t, roomId: room.room_id, deviceId: dev) else { continue }
                            total += (try? await OllacoreAPI.shared.searchMessages(roomToken: rt.access_token, roomId: room.room_id, q: q))?.count ?? 0
                        }
                        count = total; msg = total == 0 ? "No matches" : "Found \(total) message(s) across recent chats"
                    } catch { msg = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent).disabled(q.isEmpty)
            if let msg { Text(msg).font(.caption).foregroundColor(.secondary) }
            let _ = count
            Button("Close") { dismiss() }
        }.padding().frame(width: 380)
    }
}
