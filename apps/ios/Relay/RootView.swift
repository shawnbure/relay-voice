import AVFoundation
import SwiftUI

private let relayGreen = Color(red: 0.74, green: 0.96, blue: 0.29)
private let relayInk = Color(red: 0.09, green: 0.13, blue: 0.10)
private let relayAccent = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.74, green: 0.96, blue: 0.29, alpha: 1)
        : UIColor(red: 0.09, green: 0.22, blue: 0.12, alpha: 1)
})

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
    @State private var conversationPath: [Conversation] = []
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $conversationPath) { ConversationsView() }.tabItem { Label("Conversations", image: "CommunicationTab") }.tag(0)
            NavigationStack { DialerView { number in
                conversationPath = [Conversation(peer: number, displayName: number, body: "", direction: "outbound", status: "new", occurredAt: .now, kind: .message)]
                selectedTab = 0
            } }.tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }.tag(1)
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { if voice.isInCall { CallBar().padding(.horizontal, 10).padding(.vertical, 6) } }
        .overlay { if voice.incoming { IncomingCallView() } }
    }
}

private struct ConversationsView: View {
    @EnvironmentObject private var session: RelaySession
    @State private var query = ""
    @State private var pendingDelete: Conversation?
    private var conversations: [Conversation] { query.isEmpty ? session.conversations : session.conversations.filter { $0.displayName.localizedCaseInsensitiveContains(query) || $0.peer.phoneDigits.contains(query.phoneDigits) } }
    var body: some View {
        List(conversations) { conversation in
            NavigationLink(value: conversation) {
                HStack(spacing: 13) {
                    Circle().fill(relayGreen.opacity(0.45)).frame(width: 48, height: 48).overlay(Image(systemName: conversation.kind.icon).foregroundStyle(relayInk))
                    VStack(alignment: .leading, spacing: 5) { HStack { Text(conversation.displayName == conversation.peer ? conversation.peer.displayPhone : conversation.displayName).font(.headline); Spacer(); Text(conversation.occurredAt, style: .time).font(.caption).foregroundStyle(.secondary) }; Text(conversation.body).lineLimit(1).foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
            }.swipeActions(edge: .trailing) { Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = conversation } }
        }.listStyle(.plain).navigationTitle("Relay").searchable(text: $query, prompt: "Names or phone numbers").navigationDestination(for: Conversation.self) { ThreadView(conversation: $0) }.refreshable { await session.refresh() }.overlay { if conversations.isEmpty && query.isEmpty { ContentUnavailableView("No conversations", systemImage: "message", description: Text("Tap compose to message or call a new number.")) } }.toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { NewConversationView() } label: { Image(systemName: "square.and.pencil") } } }.confirmationDialog("Delete conversation?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) { Button("Delete all history", role: .destructive) { if let conversation = pendingDelete { Task { await delete(conversation) } }; pendingDelete = nil }; Button("Cancel", role: .cancel) { pendingDelete = nil } } message: { Text("This permanently deletes the messages, calls, and voicemails in this conversation from Relay.") }
    }
    private func delete(_ conversation: Conversation) async { do { try await session.deleteConversation(peer: conversation.peer) } catch { session.error = error.localizedDescription } }
}

private struct ThreadView: View {
    let conversation: Conversation
    @EnvironmentObject private var session: RelaySession
    @EnvironmentObject private var voice: VoiceManager
    @State private var activity: [ActivityItem] = []; @State private var draft = ""; @State private var sending = false
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in ScrollView { LazyVStack(spacing: 10) { ForEach(activity) { item in ActivityRow(item: item).id(item.id).contextMenu { if item.kind == .message { Button("Delete message", systemImage: "trash", role: .destructive) { Task { await delete(item) } } } } } }.padding() }.onChange(of: activity) { _, value in if let last = value.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } } }
            HStack(alignment: .bottom, spacing: 10) { TextField("Message \(conversation.peer.displayPhone)…", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder).submitLabel(.send).onSubmit { Task { await send() } }; Button { Task { await send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending) }.padding().background(.bar)
        }.navigationTitle(conversation.displayName == conversation.peer ? conversation.peer.displayPhone : conversation.displayName).navigationBarTitleDisplayMode(.inline).toolbar { Button { voice.start(number: conversation.peer) } label: { Image(systemName: "phone") }.disabled(!voice.canStartCall) }.task { await load() }.onChange(of: session.activityRevision) { _, _ in Task { await load() } }
    }
    private func load() async { do { activity = try await session.activity(peer: conversation.peer) } catch { session.error = error.localizedDescription } }
    private func send() async { let text = draft.trimmingCharacters(in: .whitespacesAndNewlines); sending = true; do { try await session.send(to: conversation.peer, text: text); draft = ""; await load() } catch { session.error = error.localizedDescription }; sending = false }
    private func delete(_ item: ActivityItem) async { do { try await session.deleteMessage(id: item.id); activity.removeAll { $0.id == item.id }; await session.refresh() } catch { session.error = error.localizedDescription } }
}

private struct ActivityRow: View {
    let item: ActivityItem
    var body: some View {
        if item.kind == .message {
            HStack { if item.direction == "outbound" { Spacer(minLength: 42) }; VStack(alignment: .leading, spacing: 7) { if !item.body.isEmpty { Text(item.body) }; ForEach(Array(item.media.enumerated()), id: \.offset) { index, media in MessageAttachment(messageID: item.id, index: index, media: media) }; Text(item.occurredAt, style: .time).font(.caption2).foregroundStyle(.secondary) }.padding(12).background(item.direction == "outbound" ? relayGreen : Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 16)); if item.direction == "inbound" { Spacer(minLength: 42) } }
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
    @EnvironmentObject private var session: RelaySession
    @EnvironmentObject private var voice: VoiceManager
    var body: some View { Form { Section("Phone number") { TextField("10-digit phone number", text: $number).keyboardType(.phonePad).font(.title3) }; if let e164 = number.e164 { Section { NavigationLink(value: Conversation(peer: e164, displayName: e164, body: "", direction: "outbound", status: "new", occurredAt: .now, kind: .message)) { Label("Message \(e164.displayPhone)", systemImage: "message.fill") }; Button { voice.start(number: e164) } label: { Label("Call \(e164.displayPhone)", systemImage: "phone.fill") }.disabled(!voice.canStartCall || e164 == session.identity?.phone?.e164) } } }.navigationTitle("New communication") }
}

private extension ActivityKind { var icon: String { switch self { case .message: "message"; case .call: "phone"; case .voicemail: "waveform" } } }
private func formatDuration(_ seconds: Int) -> String { "\(seconds / 60):\(String(format: "%02d", seconds % 60))" }
