import SwiftUI
import UserNotifications

@MainActor
final class RelaySession: ObservableObject {
    enum State { case loading, disconnected, connected }
    @Published var state: State = .loading
    @Published var identity: RelayIdentity?
    @Published var conversations: [Conversation] = []
    @Published var settings = RelaySettings.defaults
    @Published var error: String?
    @Published private(set) var activityRevision = 0
    @Published private(set) var unreadCount = 0
    @Published var notificationPeer: String?
    @Published private(set) var unreadPeers: [String: Int] = [:]
    private var visiblePeer: String?
    private var displayedThrough: [String: Date] = [:]

    func isUnread(_ conversation: Conversation) -> Bool {
        (unreadPeers[conversation.peer] ?? 0) > 0
    }

    func setVisiblePeer(_ peer: String?) {
        visiblePeer = peer
        if let peer, let through = displayedThrough[peer] { Task { await markRead(peer, through: through) } }
    }
    func isViewing(_ peer: String) -> Bool { visiblePeer == peer }
    func notificationArrived() { activityRevision += 1 }
    private func updateBadge(_ state: UnreadState) {
        unreadCount = state.count; unreadPeers = state.peers
        let count = unreadCount
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
    }
    private func markRead(_ peer: String, through: Date) async {
        do {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let state: UnreadState = try await RelayAPI.shared.request("/v1/conversations/read", method: "PUT", body: ReadRequest(peer: peer, through: formatter.string(from: through)))
            updateBadge(state)
        } catch { /* Retried when this thread reloads. Do not falsify the badge locally. */ }
    }
    func registerPushDevice() async {
        guard RelayAPI.shared.token != nil, let token = Keychain.read("relay.apns.token") else { return }
        let id = Keychain.read("relay.apns.installation") ?? UUID().uuidString
        Keychain.save(id, key: "relay.apns.installation")
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        do {
            let _: EmptyResponse = try await RelayAPI.shared.request("/v1/mobile/push-device", method: "PUT", body: PushDeviceRequest(id: id, token: token, environment: environment))
        } catch { print("Push device registration will retry: \(error.localizedDescription)") }
    }
    let voice = VoiceManager()
    private var events: URLSessionWebSocketTask?
    private var eventHeartbeat: Task<Void, Never>?

    func restore() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        UIApplication.shared.registerForRemoteNotifications()
        if RelayAPI.shared.token == nil,
           let ownerToken = ProcessInfo.processInfo.environment["RELAY_OWNER_TOKEN"],
           ownerToken.hasPrefix("rly_") {
            RelayAPI.shared.setToken(ownerToken)
        }
        if RelayAPI.shared.token == nil {
            state = .disconnected
        } else {
            await refresh()
            await registerPushDevice()
            if state == .connected { startEvents() }
        }
    }
    func refresh() async {
        do {
            async let me: RelayIdentity = RelayAPI.shared.request("/v1/me")
            async let list: DataEnvelope<[Conversation]> = RelayAPI.shared.request("/v1/conversations")
            async let preferences: DataEnvelope<RelaySettings> = RelayAPI.shared.request("/v1/settings")
            async let unread: UnreadState = RelayAPI.shared.request("/v1/unread")
            let values = try await (me, list, preferences, unread)
            identity = values.0; conversations = values.1.data; settings = values.2.data; state = .connected; error = nil
            updateBadge(values.3)
            await voice.connect(api: .shared, ownNumber: values.0.phone?.e164 ?? "")
        } catch {
            if identity == nil { self.error = error.localizedDescription; state = .disconnected }
            else { state = .connected; if !isTransientNetworkError(error) { self.error = error.localizedDescription } }
        }
    }
    func resume() async {
        guard RelayAPI.shared.token != nil else { state = .disconnected; return }
        await refresh()
        await registerPushDevice()
        await voice.ensureConnected()
        if state == .connected { startEvents() }
    }
    func activity(peer: String) async throws -> [ActivityItem] {
        guard let normalized = peer.e164 else { throw RelayAPIError.server("This conversation does not contain a valid phone number.") }
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? normalized
        let through = Date()
        let result: DataEnvelope<[ActivityItem]> = try await RelayAPI.shared.request("/v1/activity?peer=\(encoded)")
        displayedThrough[normalized] = through
        if visiblePeer == peer { await markRead(peer, through: through) }
        return result.data
    }
    func searchConversations(query: String, archived: Bool) async throws -> [Conversation] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let result: DataEnvelope<[Conversation]> = try await RelayAPI.shared.request("/v1/conversations?q=\(q)&archived=\(archived)")
        return result.data
    }
    func archive(peer: String, archived: Bool) async throws {
        let _: EmptyResponse = try await RelayAPI.shared.request("/v1/conversations/archive", method: "PUT", body: ArchiveRequest(peer: peer, archived: archived))
        activityRevision += 1
        await refresh()
    }
    func mute(peer: String, muted: Bool) async throws {
        let _: EmptyResponse = try await RelayAPI.shared.request("/v1/conversations/mute", method: "PUT", body: MuteRequest(peer: peer, muted: muted))
        if let index = conversations.firstIndex(where: { $0.peer == peer }) { conversations[index].muted = muted }
        activityRevision += 1
    }
    func isMuted(_ peer: String) -> Bool { conversations.first(where: { $0.peer == peer })?.muted == true }
    func send(to: String, text: String, attachment: OutgoingAttachment? = nil) async throws {
        let encoded = attachment.map { MessageAttachmentRequest(name: $0.name, contentType: $0.contentType, base64: $0.data.base64EncodedString()) }
        let _: EmptyResponse = try await RelayAPI.shared.request("/v1/messages", method: "POST", body: MessageRequest(to: to, text: text, attachment: encoded))
    }
    func deleteMessage(id: String) async throws { let _: EmptyResponse = try await RelayAPI.shared.request("/v1/messages/\(id)", method: "DELETE") }
    func deleteConversation(peer: String) async throws {
        guard let normalized = peer.e164 else { throw RelayAPIError.server("This conversation does not contain a valid phone number.") }
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? normalized
        let _: EmptyResponse = try await RelayAPI.shared.request("/v1/conversations?peer=\(encoded)", method: "DELETE")
        conversations.removeAll { $0.peer == normalized }
    }
    func saveSettings(_ value: RelaySettings) async throws { let _: EmptyResponse = try await RelayAPI.shared.request("/v1/settings", method: "PUT", body: value); settings = value }
    func saveVoicemailGreeting(data: Data, contentType: String) async throws {
        try await RelayAPI.shared.upload("/v1/settings/voicemail-greeting", data: data, contentType: contentType)
        settings.hasVoicemailGreeting = true; settings.voicemailUpdatedAt = .now
    }
    private func startEvents() {
        guard events == nil else { return }
        var components = URLComponents(url: RelayAPI.shared.baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/events"; components.query = nil
        var request = URLRequest(url: components.url!); if let token = RelayAPI.shared.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        events = URLSession.shared.webSocketTask(with: request); events?.resume(); receiveEvent()
        eventHeartbeat?.cancel()
        eventHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let socket = self?.events else { return }
                socket.sendPing { _ in }
            }
        }
    }
    private func receiveEvent() { events?.receive { [weak self] result in Task { @MainActor in guard let self else { return }; if case .success = result { self.activityRevision += 1; await self.refresh(); self.receiveEvent() } else { self.events = nil; self.eventHeartbeat?.cancel(); self.eventHeartbeat = nil; try? await Task.sleep(for: .seconds(2)); self.startEvents() } } } }
    private func isTransientNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost].contains(urlError.code)
    }
}

private struct MessageAttachmentRequest: Encodable { let name: String; let contentType: String; let base64: String }
private struct MessageRequest: Encodable { let to: String; let text: String; let attachment: MessageAttachmentRequest? }
private struct EmptyResponse: Decodable {}
private struct ArchiveRequest: Encodable { let peer: String; let archived: Bool }
private struct MuteRequest: Encodable { let peer: String; let muted: Bool }
private struct UnreadState: Decodable { let count: Int; let peers: [String: Int] }
private struct ReadRequest: Encodable { let peer: String; let through: String }
private struct PushDeviceRequest: Encodable { let id: String; let token: String; let environment: String }
