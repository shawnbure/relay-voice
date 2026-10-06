import AVFoundation
import Contacts
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private let relayGreen = Color(red: 0.74, green: 0.96, blue: 0.29)
private let relayInk = Color(red: 0.09, green: 0.13, blue: 0.10)
private let relayAccent = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.74, green: 0.96, blue: 0.29, alpha: 1)
        : UIColor(red: 0.09, green: 0.22, blue: 0.12, alpha: 1)
})

private enum ConversationRoute: Hashable { case history(Conversation), message(Conversation) }

struct RootView: View {
    @EnvironmentObject private var session: RelaySession
    var body: some View {
        Group {
            switch session.state {
            case .loading: ProgressView("Opening Relay…")
            case .disconnected: ConnectView()
            case .connected: MainTabs()
            }
        }
        .tint(relayAccent)
        .alert("Relay", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) { Button("OK") { session.error = nil } } message: { Text(session.error ?? "") }
    }
}

private struct ConnectView: View {
    @EnvironmentObject private var session: RelaySession
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack { RoundedRectangle(cornerRadius: 28).fill(relayGreen).frame(width: 92, height: 92); Text("R").font(.system(size: 54, weight: .black)).foregroundStyle(relayInk) }
            VStack(spacing: 8) { Text("Relay").font(.largeTitle.bold()); Text("Owner access has not been installed on this device.").multilineTextAlignment(.center).foregroundStyle(.secondary) }
            Spacer()
            Button { Task { await session.restore() } } label: { Label("Retry", systemImage: "arrow.clockwise").frame(maxWidth: .infinity).padding() }.buttonStyle(.borderedProminent).tint(relayInk)
            Text("There is no account login. Relay is configured automatically when installed on your devices.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(28).background(Color(.systemGroupedBackground))
    }
}

private struct MainTabs: View {
    @EnvironmentObject private var voice: VoiceManager
    @EnvironmentObject private var session: RelaySession
    @State private var selectedTab = 0
    @State private var conversationPath: [ConversationRoute] = []
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $conversationPath) { ConversationsView(path: $conversationPath) }.tabItem { Label("Conversations", image: "CommunicationTab") }.badge(session.unreadCount).tag(0)
            NavigationStack { DialerView { number in
                conversationPath = [.message(Conversation(peer: number, displayName: number, body: "", direction: "outbound", status: "new", occurredAt: .now, kind: .message))]
                selectedTab = 0
            } }.tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }.tag(1)
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
        .toolbarBackground(.visible, for: .tabBar)
        .onChange(of: session.notificationPeer) { _, peer in
            guard let peer else { return }
            let conversation = session.conversations.first { $0.peer == peer } ?? Conversation(peer: peer, displayName: peer, body: "", direction: "inbound", status: "received", occurredAt: .now, kind: .message)
            selectedTab = 0; conversationPath = [.history(conversation)]; session.notificationPeer = nil
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { if voice.isInCall { CallBar().padding(.horizontal, 10).padding(.vertical, 6) } }
        .overlay { if voice.incoming { IncomingCallView() } }
    }
}

private struct ConversationsView: View {
    @Binding var path: [ConversationRoute]
    @EnvironmentObject private var session: RelaySession
    @EnvironmentObject private var voice: VoiceManager
    @State private var query = ""
    @State private var localContactNames: [String: String] = [:]
    @State private var showingArchive = false
    @State private var searchResults: [Conversation] = []
    @State private var numberCopied = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    private var conversations: [Conversation] { query.isEmpty && !showingArchive ? session.conversations : searchResults }
    var body: some View {
        List {
            ForEach(conversations) { conversation in
            HStack(spacing: 12) {
                if session.isUnread(conversation) { Circle().fill(Color.blue).frame(width: 8, height: 8).accessibilityLabel("Unread") }
                Button { if conversation.kind == .message { path.append(.message(named(conversation))) } else { voice.start(number: conversation.peer) } } label: {
                    Circle().fill(relayGreen.opacity(0.48)).frame(width: 48, height: 48).overlay(Image(systemName: conversation.kind == .message ? "message.fill" : "phone.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(relayInk))
                }.buttonStyle(.plain).disabled(conversation.kind != .message && !voice.canStartCall).accessibilityLabel(conversation.kind == .message ? "Message \(conversation.peer.displayPhone)" : "Call \(conversation.peer.displayPhone)")
                Button { path.append(.history(named(conversation))) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(displayName(for: conversation)).font(.headline).foregroundStyle(.primary).lineLimit(1); if conversation.muted { Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Notifications silenced") }; Spacer(); Text(conversation.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        Label(conversation.body.isEmpty ? conversation.kind.summary : conversation.body, systemImage: conversation.kind.icon).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("Opens complete communication history")
            }.padding(.vertical, 5).swipeActions(edge: .leading) {
                Button(showingArchive ? "Restore" : "Archive", systemImage: "archivebox") { Task { do { try await session.archive(peer: conversation.peer, archived: !showingArchive); await search() } catch { session.error = error.localizedDescription } } }.tint(.indigo)
                Button(conversation.muted ? "Unmute" : "Silence", systemImage: conversation.muted ? "bell" : "bell.slash") { Task { await mute(conversation) } }.tint(conversation.muted ? .green : .orange)
            }.swipeActions(edge: .trailing) { Button("Delete", systemImage: "trash", role: .destructive) { Task { await delete(conversation) } } }
        }
        }
        .listStyle(.plain).navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                Text(session.identity?.phone?.e164.displayPhone ?? "Conversations")
                    .font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.75)
                    .contentShape(Rectangle()).highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                        if let number = session.identity?.phone?.e164 {
                            UIPasteboard.general.string = number.displayPhone
                            numberCopied = true
                            copyFeedbackTask?.cancel()
                            copyFeedbackTask = Task { @MainActor in
                                try? await Task.sleep(for: .seconds(2))
                                guard !Task.isCancelled else { return }
                                numberCopied = false
                            }
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            UIAccessibility.post(notification: .announcement, argument: "Phone number copied")
                        }
                    })
                    .accessibilityHint("Long press to copy your phone number")
                    .overlay(alignment: .bottomLeading) {
                        if numberCopied {
                            Label("Copied", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(Color.primary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                                .offset(y: 30).allowsHitTesting(false)
                        }
                    }.zIndex(1)
                    Spacer(minLength: 0)
                    NavigationLink { NewConversationView() } label: { Image(systemName: "square.and.pencil").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel("New conversation")
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search numbers and messages", text: $query).autocorrectionDisabled().textInputAutocapitalization(.never)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("Clear search") }
                }.padding(12).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
                Picker("Conversations", selection: $showingArchive) { Text("Inbox").tag(false); Text("Archived").tag(true) }.pickerStyle(.segmented)
            }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 14).background(.bar)
        }
        .navigationDestination(for: ConversationRoute.self) { route in switch route { case .history(let conversation): ThreadView(conversation: conversation, startComposing: false); case .message(let conversation): ThreadView(conversation: conversation, startComposing: true) } }
        .refreshable { await session.refresh() }
        .task { localContactNames = await loadLocalContactNames() }
        .task(id: "\(query)|\(showingArchive)|\(session.activityRevision)") { await search() }
        .overlay { if conversations.isEmpty { ContentUnavailableView(query.isEmpty ? "No conversations" : "No results", systemImage: query.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass", description: Text(query.isEmpty ? "Tap compose to call or message a new number." : "Try a different name or phone number.")) } }
        .toolbar(.hidden, for: .navigationBar)
    }
    private func displayName(for conversation: Conversation) -> String { conversation.displayName == conversation.peer ? localContactNames[conversation.peer] ?? conversation.peer.displayPhone : conversation.displayName }
    private func search() async {
        do {
            try await Task.sleep(for: .milliseconds(250))
            let result = try await session.searchConversations(query: query, archived: showingArchive)
            guard !Task.isCancelled else { return }
            searchResults = result
        } catch { if !Task.isCancelled { session.error = error.localizedDescription } }
    }
    private func named(_ conversation: Conversation) -> Conversation { Conversation(peer: conversation.peer, displayName: displayName(for: conversation), body: conversation.body, direction: conversation.direction, status: conversation.status, occurredAt: conversation.occurredAt, kind: conversation.kind, muted: conversation.muted) }
    private func mute(_ conversation: Conversation) async { do { try await session.mute(peer: conversation.peer, muted: !conversation.muted); await search() } catch { session.error = error.localizedDescription } }
    private func delete(_ conversation: Conversation) async { do { try await session.deleteConversation(peer: conversation.peer) } catch { session.error = error.localizedDescription } }
}

private func loadLocalContactNames() async -> [String: String] {
    let store = CNContactStore()
    do {
        guard try await store.requestAccess(for: .contacts) else { return [:] }
        let request = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor])
        var result: [String: String] = [:]
        try store.enumerateContacts(with: request) { contact, _ in
            let personName = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let name = personName.isEmpty ? contact.organizationName : personName
            guard !name.isEmpty else { return }
            for value in contact.phoneNumbers { if let number = value.value.stringValue.e164 { result[number] = name } }
        }
        return result
    } catch { return [:] }
}

private struct ThreadView: View {
    let conversation: Conversation
    let startComposing: Bool
    @EnvironmentObject private var session: RelaySession
    @EnvironmentObject private var voice: VoiceManager
    @State private var activity: [ActivityItem] = []; @State private var draft = ""; @State private var sending = false
    @State private var attachment: OutgoingAttachment?
    @State private var photoItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var showingFiles = false
    @StateObject private var recorder = MessageAudioRecorder()
    @State private var lastSendAt = Date.distantPast
    @FocusState private var composerFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if activity.isEmpty {
                            ContentUnavailableView("No history yet", systemImage: "bubble.left", description: Text("Send a message or tap the phone button to start.")).padding(.top, 90)
                        }
                        ForEach(activity) { item in
                            ActivityRow(item: item).id(item.id).contextMenu {
                                if item.kind == .message {
                                    if !item.body.isEmpty { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.body } }
                                    Button("Delete message", systemImage: "trash", role: .destructive) { Task { await delete(item) } }
                                }
                            }
                        }
                        Color.clear.frame(height: 20).id("thread-bottom")
                    }.padding(.horizontal, 16).padding(.top, 16)
                }
                .frame(maxHeight: .infinity)
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    withAnimation { proxy.scrollTo("thread-bottom", anchor: .bottom) }
                }
                .onChange(of: activity) { _, _ in
                    withAnimation { proxy.scrollTo("thread-bottom", anchor: .bottom) }
                }
            }
            MessageComposer(draft: $draft, attachment: $attachment, photoItem: $photoItem, showingCamera: $showingCamera, showingFiles: $showingFiles, sending: sending, recording: recorder.isRecording, focused: $composerFocused, onRecord: recordAudio, onSend: send)
        }.onDisappear { session.setVisiblePeer(nil) }.navigationTitle(conversation.displayName == conversation.peer ? conversation.peer.displayPhone : conversation.displayName).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar).toolbar { ToolbarItem(placement: .topBarTrailing) { Button { voice.start(number: conversation.peer) } label: { Image(systemName: "phone.fill") }.disabled(!voice.canStartCall).accessibilityLabel("Call") } }.task { await load(); if startComposing { composerFocused = true } }.onChange(of: session.activityRevision) { _, _ in Task { await load() } }.onChange(of: photoItem) { _, item in Task { await loadPhoto(item) } }.sheet(isPresented: $showingCamera) { CameraPicker { image in if let data = image.jpegData(compressionQuality: 0.82) { attachment = OutgoingAttachment(name: "photo.jpg", contentType: "image/jpeg", data: data) } } }.fileImporter(isPresented: $showingFiles, allowedContentTypes: [.image, .audio, .movie, .pdf]) { result in loadFile(result) }
    }
    private func load() async { do { activity = try await session.activity(peer: conversation.peer); session.setVisiblePeer(conversation.peer) } catch { session.error = error.localizedDescription } }
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingAttachment = attachment
        guard (!text.isEmpty || outgoingAttachment != nil), !sending, Date().timeIntervalSince(lastSendAt) >= 0.4 else { return }
        lastSendAt = .now; sending = true; draft = ""; attachment = nil; photoItem = nil
        let pending = ActivityItem(id: "pending-\(UUID().uuidString)", kind: .message, direction: "outbound", body: text, status: "sending", occurredAt: .now, deliveredAt: nil, media: [], durationSeconds: nil)
        activity.append(pending)
        Task {
            do { try await session.send(to: conversation.peer, text: text, attachment: outgoingAttachment); await load() }
            catch {
                activity.removeAll { $0.id == pending.id }
                session.error = error.localizedDescription
            }
            sending = false
        }
    }
    private func delete(_ item: ActivityItem) async { do { try await session.deleteMessage(id: item.id); activity.removeAll { $0.id == item.id }; await session.refresh() } catch { session.error = error.localizedDescription } }
    private func loadPhoto(_ item: PhotosPickerItem?) async { guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }; attachment = OutgoingAttachment(name: "photo.jpg", contentType: item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg", data: data) }
    private func loadFile(_ result: Result<URL, Error>) { do { let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }; let data = try Data(contentsOf: url); attachment = OutgoingAttachment(name: url.lastPathComponent, contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: data) } catch { session.error = error.localizedDescription } }
    private func recordAudio() { do { if let completed = try recorder.toggle() { attachment = completed } } catch { session.error = error.localizedDescription } }
}

private struct MessageComposer: View {
    @Binding var draft: String
    @Binding var attachment: OutgoingAttachment?
    @Binding var photoItem: PhotosPickerItem?
    @Binding var showingCamera: Bool
    @Binding var showingFiles: Bool
    let sending: Bool
    let recording: Bool
    let focused: FocusState<Bool>.Binding
    let onRecord: () -> Void
    let onSend: () -> Void
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil }
    var body: some View {
        VStack(spacing: 8) {
            if let attachment {
                HStack(spacing: 10) {
                    Image(systemName: attachment.contentType.hasPrefix("image/") ? "photo.fill" : attachment.contentType.hasPrefix("audio/") ? "waveform" : "doc.fill").frame(width: 34, height: 34).background(relayGreen).foregroundStyle(relayInk).clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) { Text(attachment.name).font(.subheadline.weight(.semibold)).lineLimit(1); Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)).font(.caption2).foregroundStyle(.secondary) }
                    Spacer(); Button { self.attachment = nil; photoItem = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.title3) }.accessibilityLabel("Remove attachment")
                }.padding(.horizontal, 12).padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    PhotosPicker(selection: $photoItem, matching: .images) { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    Button { showingCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                    Button { showingFiles = true } label: { Label("Choose File", systemImage: "folder") }
                } label: { Image(systemName: "plus").font(.headline).frame(width: 34, height: 34).background(Color(.tertiarySystemFill)).clipShape(Circle()) }.accessibilityLabel("Add attachment")
                TextField("Message", text: $draft, axis: .vertical)
                    .focused(focused).lineLimit(1...6).padding(.horizontal, 13).padding(.vertical, 9)
                    .foregroundStyle(Color.primary).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 19))
                    .overlay(RoundedRectangle(cornerRadius: 19).stroke(Color(.separator).opacity(0.55), lineWidth: 0.5))
                if draft.isEmpty && attachment == nil {
                    Button(action: onRecord) { Image(systemName: recording ? "stop.fill" : "waveform").font(.headline).frame(width: 36, height: 36).background(recording ? Color.red : Color(.tertiarySystemFill)).foregroundStyle(recording ? .white : Color.primary).clipShape(Circle()) }.accessibilityLabel(recording ? "Stop voice message" : "Record voice message")
                } else {
                    Button(action: onSend) { Group { if sending { ProgressView().tint(relayInk) } else { Image(systemName: "arrow.up").font(.headline.bold()) } }.frame(width: 36, height: 36).background(canSend || sending ? relayGreen : Color(.tertiarySystemFill)).foregroundStyle(canSend || sending ? relayInk : Color.secondary).clipShape(Circle()) }.disabled(!canSend || sending).accessibilityLabel(sending ? "Sending" : "Send")
                }
            }.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 8)
        }.background(.bar)
    }
}

@MainActor private final class MessageAudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?
    func toggle() throws -> OutgoingAttachment? {
        if isRecording {
            recorder?.stop(); isRecording = false
            guard let outputURL else { return nil }
            let data = try Data(contentsOf: outputURL)
            return OutgoingAttachment(name: "voice-message.m4a", contentType: "audio/mp4", data: data)
        }
        let granted = AVAudioApplication.shared.recordPermission == .granted
        guard granted else { AVAudioApplication.requestRecordPermission { _ in }; throw RelayAPIError.server("Allow microphone access, then tap the voice-message button again.") }
        let session = AVAudioSession.sharedInstance(); try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP]); try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString).m4a")
        recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 32_000, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]); recorder?.record(); outputURL = url; isRecording = true
        return nil
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController { let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker; init(parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { if let image = info[.originalImage] as? UIImage { parent.onImage(image) }; parent.dismiss() }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

private struct ActivityRow: View {
    let item: ActivityItem
    private static let messageDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yy h:mm a"
        return formatter
    }()
    var body: some View {
        if item.kind == .message {
            HStack { if item.direction == "outbound" { Spacer(minLength: 42) }; VStack(alignment: .leading, spacing: 7) { if !item.body.isEmpty { Text(item.body) }; ForEach(Array(item.media.enumerated()), id: \.offset) { index, media in MessageAttachment(messageID: item.id, index: index, media: media) }; Text(messageTiming).font(.caption2).opacity(0.62) }.foregroundStyle(item.direction == "outbound" ? relayInk : Color.primary).padding(12).background(item.direction == "outbound" ? relayGreen : Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 16)); if item.direction == "inbound" { Spacer(minLength: 42) } }
        } else {
            HStack { Image(systemName: item.kind.icon).frame(width: 35, height: 35).background(relayGreen.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading) { Text(item.kind == .call ? (item.direction == "inbound" ? "Incoming call" : "Outgoing call") : "Voicemail").font(.subheadline.bold()); Text([item.occurredAt.formatted(date: .omitted, time: .shortened), item.status, item.durationSeconds.map(formatDuration)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }; Spacer(); if item.kind == .voicemail && item.status == "ready" { VoicemailButton(id: item.id) } }.padding(12).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
    private var messageTiming: String {
        let occurred = Self.messageDateTimeFormatter.string(from: item.occurredAt)
        if item.direction == "inbound" { return "Received \(occurred)" }
        if let deliveredAt = item.deliveredAt { return "Delivered \(Self.messageDateTimeFormatter.string(from: deliveredAt))" }
        if item.status.contains("failed") { return "Failed \(occurred)" }
        return "Sent \(occurred)"
    }
}

private struct VoicemailButton: View {
    let id: String; @State private var playing = false
    var body: some View { Button { Task { playing = await AudioPlayback.shared.toggle(path: "/v1/voicemails/\(id)/audio") } } label: { Image(systemName: playing ? "stop.fill" : "play.fill") } }
}

private struct MessageAttachment: View {
    let messageID: String; let index: Int; let media: MediaItem
    @State private var image: UIImage?
    @State private var loading = false
    @State private var failed = false
    @State private var showingPreview = false
    private var path: String { "/v1/messages/\(messageID)/media/\(index)" }
    var body: some View {
        Group {
            if media.contentType.hasPrefix("image/") {
                if let image { Button { showingPreview = true } label: { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain).accessibilityLabel("Open image full screen") }
                else if failed { Button { Task { await loadImage() } } label: { Label("Tap to retry image", systemImage: "arrow.clockwise") }.buttonStyle(.bordered) }
                else { ProgressView().frame(width: 120, height: 90).task { await loadImage() } }
            } else if media.contentType.hasPrefix("audio/") { Button { Task { _ = await AudioPlayback.shared.toggle(path: path) } } label: { Label("Play audio", systemImage: "play.circle.fill") } }
            else { Label("Attachment", systemImage: "paperclip") }
        }
        .fullScreenCover(isPresented: $showingPreview) { if let image { ImagePreview(image: image) } }
    }
    private func loadImage() async {
        guard !loading else { return }
        loading = true; failed = false
        defer { loading = false }
        do {
            let (data, response) = try await URLSession.shared.data(for: RelayAPI.shared.mediaRequest(path))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let decoded = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            image = decoded
        } catch { failed = true }
    }
}

private struct ImagePreview: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var showingShare = false
    @State private var saved = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image).resizable().scaledToFit().scaleEffect(scale)
                    .gesture(MagnifyGesture().onChanged { value in scale = min(max(lastScale * value.magnification, 1), 5) }.onEnded { _ in lastScale = scale })
                    .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2; lastScale = scale } }
            }
            .navigationTitle("Photo").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar).toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { save() } label: { Image(systemName: saved ? "checkmark" : "square.and.arrow.down") }.accessibilityLabel(saved ? "Saved to Photos" : "Save to Photos")
                    Button { showingShare = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share image")
                }
            }
        }
        .sheet(isPresented: $showingShare) { ActivityShare(items: [image]) }
    }
    private func save() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) } completionHandler: { success, _ in
                if success { Task { @MainActor in saved = true; UINotificationFeedbackGenerator().notificationOccurred(.success) } }
            }
        }
    }
}

private struct ActivityShare: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@MainActor final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback(); var player: AVAudioPlayer?
    func toggle(path: String) async -> Bool { if player?.isPlaying == true { player?.stop(); return false }; do { let (data, _) = try await URLSession.shared.data(for: RelayAPI.shared.mediaRequest(path)); player = try AVAudioPlayer(data: data); player?.delegate = self; player?.play(); return true } catch { return false } }
}

private struct NewConversationView: View {
    @State private var number = ""
    @State private var showingContacts = false
    @EnvironmentObject private var session: RelaySession
    @EnvironmentObject private var voice: VoiceManager
    @FocusState private var numberFocused: Bool
    private var destination: String? { number.e164 }
    private var conversation: Conversation? { destination.map { Conversation(peer: $0, displayName: $0, body: "", direction: "outbound", status: "new", occurredAt: .now, kind: .message) } }
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "phone.badge.plus").font(.system(size: 34, weight: .medium)).foregroundStyle(relayAccent).padding(.top, 28)
                Text("Who would you like to reach?").font(.title3.bold())
                Text("Enter a phone number or choose a contact.").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                TextField("Phone number", text: $number).keyboardType(.phonePad).textContentType(.telephoneNumber).font(.title3).focused($numberFocused)
                if !number.isEmpty { Button { number = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("Clear number") }
            }.padding(.horizontal, 16).frame(height: 58).background(Color(.secondarySystemGroupedBackground)).clipShape(RoundedRectangle(cornerRadius: 16))
            Button { showingContacts = true } label: { Label("Choose from Contacts", systemImage: "person.crop.circle").fontWeight(.semibold).frame(maxWidth: .infinity).frame(height: 50) }.buttonStyle(.bordered)
            if destination == nil && !number.isEmpty { Label("Enter a complete 10-digit US phone number", systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.horizontal, 20)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                if let conversation {
                    NavigationLink { ThreadView(conversation: conversation, startComposing: true) } label: { Label("Message", systemImage: "message.fill").frame(maxWidth: .infinity).frame(height: 50) }.buttonStyle(.borderedProminent).tint(relayInk)
                } else {
                    Label("Message", systemImage: "message.fill").frame(maxWidth: .infinity).frame(height: 50).foregroundStyle(.secondary).background(Color(.tertiarySystemFill)).clipShape(RoundedRectangle(cornerRadius: 13))
                }
                Button { if let destination { voice.start(number: destination) } } label: { Label("Call", systemImage: "phone.fill").frame(maxWidth: .infinity).frame(height: 50) }.buttonStyle(.borderedProminent).tint(relayGreen).foregroundStyle(relayInk).disabled(destination == nil || !voice.canStartCall)
            }.padding(.horizontal).padding(.vertical, 10).background(.bar)
        }
        .navigationTitle("New").toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { numberFocused = false } } }
        .task { numberFocused = true }
        .sheet(isPresented: $showingContacts) { ContactPhonePicker { number = $0 } }
    }
}

private extension ActivityKind {
    var icon: String { switch self { case .message: "message"; case .call: "phone"; case .voicemail: "waveform" } }
    var summary: String { switch self { case .message: "Message"; case .call: "Call"; case .voicemail: "Voicemail" } }
}
private func formatDuration(_ seconds: Int) -> String { "\(seconds / 60):\(String(format: "%02d", seconds % 60))" }
