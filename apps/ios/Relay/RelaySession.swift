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
    /// Unread count per line, for the line switcher.
    @Published private(set) var unreadLines: [String: Int] = [:]
    /// The chosen number: the inbox shown when not combining numbers, and the default caller ID for new calls and messages.
    @Published private(set) var selectedLine: String? = UserDefaults.standard.string(forKey: "relay.selectedLine")
    /// One combined inbox for every number (the default). Each conversation shows its number's icon.
    @Published private(set) var allLinesPreferred: Bool = UserDefaults.standard.object(forKey: "relay.allLines") as? Bool ?? true
    var lines: [PhoneLine] { identity?.lines ?? [] }
    var currentLine: PhoneLine? { lines.first { $0.e164 == selectedLine } ?? lines.first }
    var showingAllLines: Bool { allLinesPreferred && lines.count > 1 }
    /// Changes whenever the inbox being shown changes.
    var inboxKey: String { showingAllLines ? "all" : currentLine?.e164 ?? "" }
    func line(_ e164: String?) -> PhoneLine? { e164.flatMap { number in lines.first { $0.e164 == number } } }
    /// `line=` query fragment for the inbox being shown ("line=" means every number).
    private var lineQuery: String { showingAllLines ? "line=" : currentLine.map { "line=" + ($0.e164.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.e164) } ?? "" }
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
        unreadCount = state.count; unreadPeers = state.peers; unreadLines = state.lines ?? [:]
        let count = unreadCount
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
    }
    private func markRead(_ peer: String, through: Date) async {
        do {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let state: UnreadState = try await RelayAPI.shared.request("/v1/conversations/read", method: "PUT", body: ReadRequest(peer: peer, through: formatter.string(from: through), line: showingAllLines ? nil : currentLine?.e164))
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
            // Load the account first: the line list decides which inbox to fetch.
            let me: RelayIdentity = try await RelayAPI.shared.request("/v1/me")
            identity = me
            if let selectedLine, !me.lines.contains(where: { $0.e164 == selectedLine }) { self.selectedLine = nil }
            async let list: DataEnvelope<[Conversation]> = RelayAPI.shared.request("/v1/conversations?\(lineQuery)")
            async let preferences: DataEnvelope<RelaySettings> = RelayAPI.shared.request("/v1/settings")
            async let unread: UnreadState = RelayAPI.shared.request("/v1/unread?\(lineQuery)")
            let values = try await (list, preferences, unread)
            conversations = values.0.data; settings = values.1.data; voice.setRingsHere(settings.ringsOnThisDevice); state = .connected; error = nil
            updateBadge(values.2)
            voice.useLine(currentLine?.e164 ?? "")
            await voice.connect(api: .shared, ownNumber: currentLine?.e164 ?? "")
        } catch RelayAPIError.unauthorized {
            // The device token was revoked or expired: back to the sign-in screen.
            signOutLocally()
        } catch {
            if identity == nil { self.error = error.localizedDescription; state = .disconnected }
            else { state = .connected; if !isTransientNetworkError(error) { self.error = error.localizedDescription } }
        }
    }
    /// Shows one combined inbox for every number.
    func selectAllLines() async {
        guard !showingAllLines else { return }
        allLinesPreferred = true; UserDefaults.standard.set(true, forKey: "relay.allLines")
        conversations = []; unreadPeers = [:]
        activityRevision += 1
        await refresh()
    }
    /// Sets the caller ID for new calls and messages. Leaves the combined inbox as it is.
    func setDefaultLine(_ e164: String) async {
        guard showingAllLines else { await selectLine(e164); return }
        guard lines.contains(where: { $0.e164 == e164 }) else { return }
        selectedLine = e164; UserDefaults.standard.set(e164, forKey: "relay.selectedLine")
        voice.useLine(e164)
    }
    /// Switches inbox, unread dots, replies and keypad caller ID to another of the account's numbers.
    func selectLine(_ e164: String) async {
        guard e164 != currentLine?.e164 || showingAllLines, lines.contains(where: { $0.e164 == e164 }) else { return }
        allLinesPreferred = false; UserDefaults.standard.set(false, forKey: "relay.allLines")
        selectedLine = e164; UserDefaults.standard.set(e164, forKey: "relay.selectedLine")
        conversations = []; unreadPeers = [:]
        voice.useLine(e164)
        activityRevision += 1
        await refresh()
    }
    func signIn(email: String, password: String) async throws {
        let response: SignInResponse = try await RelayAPI.shared.request("/v1/auth/mobile/login", method: "POST", body: SignInRequest(email: email, password: password, deviceName: UIDevice.current.name))
        RelayAPI.shared.setToken(response.token)
        state = .loading
        await refresh()
        await registerPushDevice()
        if state == .connected { startEvents() }
    }
    /// Signs in with a passkey saved for the Relay website (iCloud Keychain / Passwords).
    func signInWithPasskey() async throws {
        let pending: PasskeyOptionsResponse = try await RelayAPI.shared.request("/v1/auth/login/options", method: "POST", body: EmptyBody())
        let credential = try await PasskeyAssertion().run(relyingParty: pending.options.rpId, challenge: pending.options.challenge)
        let response: SignInResponse = try await RelayAPI.shared.request("/v1/auth/mobile/passkey", method: "POST", body: PasskeySignInRequest(challengeId: pending.challengeId, credential: credential, deviceName: UIDevice.current.name))
        RelayAPI.shared.setToken(response.token)
        state = .loading
        await refresh()
        await registerPushDevice()
        if state == .connected { startEvents() }
    }
    func signOut() async {
        let installation = Keychain.read("relay.apns.installation")
        let _: EmptyResponse? = try? await RelayAPI.shared.request("/v1/auth/mobile/logout", method: "POST", body: SignOutRequest(installationId: installation))
        signOutLocally()
    }
    private func signOutLocally() {
        events?.cancel(with: .goingAway, reason: nil); events = nil; eventHeartbeat?.cancel(); eventHeartbeat = nil
        voice.disconnect()
        RelayAPI.shared.setToken(nil); Keychain.delete("relay.voice.jwt")
        identity = nil; conversations = []; unreadPeers = [:]; unreadLines = [:]; unreadCount = 0
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
        state = .disconnected
    }
    func addLine(e164: String, label: String) async throws {
        let _: EmptyResponse = try await RelayAPI.shared.request("/v1/admin/phone-number", method: "POST", body: AddLineRequest(e164: e164, label: label))
        await refresh()
    }
    func changePassword(_ password: String) async throws {
        let _: EmptyResponse = try await RelayAPI.shared.request("/v1/settings/password", method: "PUT", body: PasswordRequest(password: password))
    }
    func renameLine(e164: String, label: String, icon: String?) async throws {
        let _: EmptyResponse = try await RelayAPI.shared.request("/v1/phone-numbers/label", method: "PUT", body: LineUpdateRequest(e164: e164, label: label, icon: icon ?? ""))
        await refresh()
    }
    func resume() async {
        guard RelayAPI.shared.token != nil else { state = .disconnected; return }
        await refresh()
        await registerPushDevice()
        await voice.ensureConnected()
        if state == .connected { startEvents() }
    }
    func activity(peer: String) async throws -> [ActivityItem] {
        guard let normalized = peer.conversationPeer else { throw RelayAPIError.server("This conversation does not contain a valid phone number.") }
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? normalized
        let through = Date()
        let result: DataEnvelope<[ActivityItem]> = try await RelayAPI.shared.request("/v1/activity?peer=\(encoded)&\(lineQuery)")
        displayedThrough[normalized] = through
        if visiblePeer == peer { await markRead(peer, through: through) }
        return result.data
    }
    func searchConversations(query: String, archived: Bool) async throws -> [Conversation] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let result: DataEnvelope<[Conversation]> = try await RelayAPI.shared.request("/v1/conversations?q=\(q)&archived=\(archived)&\(lineQuery)")
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
    /// Sends from `from` (the conversation's own number) or, for a new conversation, the default number.
    func send(to: String, from: String? = nil, text: String, attachment: OutgoingAttachment? = nil) async throws {
        let encoded = attachment.map { MessageAttachmentRequest(name: $0.name, contentType: $0.contentType, base64: $0.data.base64EncodedString()) }
        let _: EmptyResponse = try await RelayAPI.shared.request("/v1/messages", method: "POST", body: MessageRequest(to: to, from: line(from)?.e164 ?? currentLine?.e164, text: text, attachment: encoded))
    }
    func deleteMessage(id: String) async throws { let _: EmptyResponse = try await RelayAPI.shared.request("/v1/messages/\(id)", method: "DELETE") }
    func deleteConversation(peer: String) async throws {
        guard let normalized = peer.conversationPeer else { throw RelayAPIError.server("This conversation does not contain a valid phone number.") }
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? normalized
        let _: EmptyResponse = try await RelayAPI.shared.request("/v1/conversations?peer=\(encoded)&\(lineQuery)", method: "DELETE")
        conversations.removeAll { $0.peer == normalized }
    }
    func loadVoicemails() async throws -> [VoicemailItem] {
        let result: DataEnvelope<[VoicemailItem]> = try await RelayAPI.shared.request("/v1/voicemails?\(lineQuery)")
        return result.data
    }
    func saveSettings(_ value: RelaySettings) async throws { let _: EmptyResponse = try await RelayAPI.shared.request("/v1/settings", method: "PUT", body: value); settings = value; voice.setRingsHere(value.ringsOnThisDevice) }
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
private struct MessageRequest: Encodable { let to: String; let from: String?; let text: String; let attachment: MessageAttachmentRequest? }
private struct SignInRequest: Encodable { let email: String; let password: String; let deviceName: String }
private struct SignInResponse: Decodable { let token: String }
private struct EmptyBody: Encodable {}
private struct PasskeyOptionsResponse: Decodable { struct Options: Decodable { let challenge: String; let rpId: String }; let challengeId: String; let options: Options }
private struct PasskeySignInRequest: Encodable { let challengeId: String; let credential: PasskeyAssertion.Credential; let deviceName: String }
private struct PasswordRequest: Encodable { let password: String }
private struct SignOutRequest: Encodable { let installationId: String? }
private struct AddLineRequest: Encodable { let e164: String; let label: String }
private struct LineUpdateRequest: Encodable { let e164: String; let label: String; let icon: String }
private struct EmptyResponse: Decodable {}
private struct ArchiveRequest: Encodable { let peer: String; let archived: Bool }
private struct MuteRequest: Encodable { let peer: String; let muted: Bool }
private struct UnreadState: Decodable { let count: Int; let peers: [String: Int]; let lines: [String: Int]? }
private struct ReadRequest: Encodable { let peer: String; let through: String; let line: String? }
private struct PushDeviceRequest: Encodable { let id: String; let token: String; let environment: String }
