import AVFoundation
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
        .dynamicTypeSize(.xSmall ... .xxLarge)
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
    @State private var selectedTab = 0
    @State private var conversationPath: [ConversationRoute] = []
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $conversationPath) { ConversationsView(path: $conversationPath) }.tabItem { Label("Conversations", image: "CommunicationTab") }.tag(0)
            NavigationStack { DialerView { number in
                conversationPath = [.message(Conversation(peer: number, displayName: number, body: "", direction: "outbound", status: "new", occurredAt: .now, kind: .message))]
                selectedTab = 0
            } }.tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }.tag(1)
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
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
    @State private var pendingDelete: Conversation?
    private var conversations: [Conversation] { query.isEmpty ? session.conversations : session.conversations.filter { $0.displayName.localizedCaseInsensitiveContains(query) || $0.peer.phoneDigits.contains(query.phoneDigits) } }
    var body: some View {
        List(conversations) { conversation in
            HStack(spacing: 13) {
                Button { if conversation.kind == .message { path.append(.message(conversation)) } else { voice.start(number: conversation.peer) } } label: {
                    Circle().fill(relayGreen.opacity(0.45)).frame(width: 48, height: 48).overlay(Image(systemName: conversation.kind == .message ? "message.fill" : "phone.fill").foregroundStyle(relayInk))
                }.buttonStyle(.plain).disabled(conversation.kind != .message && !voice.canStartCall).accessibilityLabel(conversation.kind == .message ? "Message \(conversation.peer.displayPhone)" : "Call \(conversation.peer.displayPhone)")
                Button { path.append(.history(conversation)) } label: {
                    VStack(alignment: .leading, spacing: 5) { HStack { Text(conversation.displayName == conversation.peer ? conversation.peer.displayPhone : conversation.displayName).font(.headline); Spacer(); Text(conversation.occurredAt, style: .time).font(.caption).foregroundStyle(.secondary) }; Text(conversation.body).lineLimit(1).foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
            }.padding(.vertical, 4).swipeActions(edge: .trailing) { Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = conversation } }
        }.listStyle(.plain).navigationTitle("Relay").searchable(text: $query, prompt: "Names or phone numbers").navigationDestination(for: ConversationRoute.self) { route in switch route { case .history(let conversation): ThreadView(conversation: conversation, startComposing: false); case .message(let conversation): ThreadView(conversation: conversation, startComposing: true) } }.refreshable { await session.refresh() }.overlay { if conversations.isEmpty && query.isEmpty { ContentUnavailableView("No conversations", systemImage: "message", description: Text("Tap compose to message or call a new number.")) } }.toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { NewConversationView() } label: { Image(systemName: "square.and.pencil") } } }.confirmationDialog("Delete conversation?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) { Button("Delete all history", role: .destructive) { if let conversation = pendingDelete { Task { await delete(conversation) } }; pendingDelete = nil }; Button("Cancel", role: .cancel) { pendingDelete = nil } } message: { Text("This permanently deletes the messages, calls, and voicemails in this conversation from Relay.") }
    }
    private func delete(_ conversation: Conversation) async { do { try await session.deleteConversation(peer: conversation.peer) } catch { session.error = error.localizedDescription } }
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
    @FocusState private var composerFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in ScrollView { LazyVStack(spacing: 10) { ForEach(activity) { item in ActivityRow(item: item).id(item.id).contextMenu { if item.kind == .message { if !item.body.isEmpty { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.body } }; Button("Delete message", systemImage: "trash", role: .destructive) { Task { await delete(item) } } } } } }.padding() }.onChange(of: activity) { _, value in if let last = value.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } } }
            MessageComposer(draft: $draft, attachment: $attachment, photoItem: $photoItem, showingCamera: $showingCamera, showingFiles: $showingFiles, sending: sending, recording: recorder.isRecording, focused: $composerFocused, onRecord: recordAudio) { Task { await send() } }
        }.navigationTitle(conversation.displayName == conversation.peer ? conversation.peer.displayPhone : conversation.displayName).navigationBarTitleDisplayMode(.inline).toolbar { Button { voice.start(number: conversation.peer) } label: { Image(systemName: "phone") }.disabled(!voice.canStartCall) }.task { await load(); if startComposing { composerFocused = true } }.onChange(of: session.activityRevision) { _, _ in Task { await load() } }.onChange(of: photoItem) { _, item in Task { await loadPhoto(item) } }.sheet(isPresented: $showingCamera) { CameraPicker { image in if let data = image.jpegData(compressionQuality: 0.82) { attachment = OutgoingAttachment(name: "photo.jpg", contentType: "image/jpeg", data: data) } } }.fileImporter(isPresented: $showingFiles, allowedContentTypes: [.image, .audio, .movie, .pdf]) { result in loadFile(result) }
    }
    private func load() async { do { activity = try await session.activity(peer: conversation.peer) } catch { session.error = error.localizedDescription } }
    private func send() async { let text = draft.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty || attachment != nil else { return }; sending = true; do { try await session.send(to: conversation.peer, text: text, attachment: attachment); draft = ""; attachment = nil; photoItem = nil; await load() } catch { session.error = error.localizedDescription }; sending = false }
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
                    Button(action: onSend) { Image(systemName: "arrow.up").font(.headline.bold()).frame(width: 36, height: 36).background(canSend ? relayGreen : Color(.tertiarySystemFill)).foregroundStyle(canSend ? relayInk : Color.secondary).clipShape(Circle()) }.disabled(!canSend || sending).accessibilityLabel("Send")
                }
            }.padding(.horizontal, 10).padding(.bottom, 8)
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
    var body: some View {
        if item.kind == .message {
            HStack { if item.direction == "outbound" { Spacer(minLength: 42) }; VStack(alignment: .leading, spacing: 7) { if !item.body.isEmpty { Text(item.body) }; ForEach(Array(item.media.enumerated()), id: \.offset) { index, media in MessageAttachment(messageID: item.id, index: index, media: media) }; Text(item.occurredAt, style: .time).font(.caption2).opacity(0.62) }.foregroundStyle(item.direction == "outbound" ? relayInk : Color.primary).padding(12).background(item.direction == "outbound" ? relayGreen : Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 16)); if item.direction == "inbound" { Spacer(minLength: 42) } }
        } else {
            HStack { Image(systemName: item.kind.icon).frame(width: 35, height: 35).background(relayGreen.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading) { Text(item.kind == .call ? (item.direction == "inbound" ? "Incoming call" : "Outgoing call") : "Voicemail").font(.subheadline.bold()); Text([item.occurredAt.formatted(date: .omitted, time: .shortened), item.status, item.durationSeconds.map(formatDuration)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }; Spacer(); if item.kind == .voicemail && item.status == "ready" { VoicemailButton(id: item.id) } }.padding(12).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct VoicemailButton: View {
    let id: String; @State private var playing = false
    var body: some View { Button { Task { playing = await AudioPlayback.shared.toggle(path: "/v1/voicemails/\(id)/audio") } } label: { Image(systemName: playing ? "stop.fill" : "play.fill") } }
}

private struct MessageAttachment: View {
    let messageID: String; let index: Int; let media: MediaItem
    @State private var image: UIImage?
    private var path: String { "/v1/messages/\(messageID)/media/\(index)" }
    var body: some View {
        Group {
            if media.contentType.hasPrefix("image/") {
                if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 10)) } else { ProgressView().frame(width: 120, height: 90).task { await loadImage() } }
            } else if media.contentType.hasPrefix("audio/") { Button { Task { _ = await AudioPlayback.shared.toggle(path: path) } } label: { Label("Play audio", systemImage: "play.circle.fill") } }
            else { Label("Attachment", systemImage: "paperclip") }
        }
    }
    private func loadImage() async { if let (data, _) = try? await URLSession.shared.data(for: RelayAPI.shared.mediaRequest(path)) { image = UIImage(data: data) } }
}

@MainActor private final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback(); var player: AVAudioPlayer?
    func toggle(path: String) async -> Bool { if player?.isPlaying == true { player?.stop(); return false }; do { let (data, _) = try await URLSession.shared.data(for: RelayAPI.shared.mediaRequest(path)); player = try AVAudioPlayer(data: data); player?.delegate = self; player?.play(); return true } catch { return false } }
}

private struct NewConversationView: View {
    @State private var number = ""
    @State private var showingContacts = false
    @EnvironmentObject private var session: RelaySession
    @EnvironmentObject private var voice: VoiceManager
    private var destination: String? { number.e164 }
    private var conversation: Conversation? { destination.map { Conversation(peer: $0, displayName: $0, body: "", direction: "outbound", status: "new", occurredAt: .now, kind: .message) } }
    var body: some View {
        Form {
            Section("Phone number") {
                HStack {
                    TextField("10-digit phone number", text: $number).keyboardType(.phonePad).textContentType(.telephoneNumber).font(.title3)
                    if !number.isEmpty { Button { number = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear number") }
                }
                Button { showingContacts = true } label: { Label("Choose from Contacts", systemImage: "person.crop.circle") }
                HStack {
                    Button { if let value = destination { UIPasteboard.general.string = value } } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(destination == nil)
                    Spacer()
                    Button { if let value = UIPasteboard.general.string?.e164 { number = value } } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                }
            }
            if destination == nil && !number.isEmpty { Text("Enter a complete 10-digit US phone number.").font(.footnote).foregroundStyle(.secondary) }
        }
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
        .navigationTitle("New communication")
        .sheet(isPresented: $showingContacts) { ContactPhonePicker { number = $0 } }
    }
}

private extension ActivityKind { var icon: String { switch self { case .message: "message"; case .call: "phone"; case .voicemail: "waveform" } } }
private func formatDuration(_ seconds: Int) -> String { "\(seconds / 60):\(String(format: "%02d", seconds % 60))" }
