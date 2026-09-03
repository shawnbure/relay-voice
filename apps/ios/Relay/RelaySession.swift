import SwiftUI

@MainActor
final class RelaySession: ObservableObject {
    enum State { case loading, disconnected, connected }
    @Published var state: State = .loading
    @Published var identity: RelayIdentity?
    @Published var conversations: [Conversation] = []
    @Published var settings = RelaySettings.defaults
    @Published var error: String?
    @Published private(set) var activityRevision = 0
    let voice = VoiceManager()
    private var events: URLSessionWebSocketTask?

    func restore() async {
        if RelayAPI.shared.token == nil,
           let ownerToken = ProcessInfo.processInfo.environment["RELAY_OWNER_TOKEN"],
           ownerToken.hasPrefix("rly_") {
            RelayAPI.shared.setToken(ownerToken)
        }
        if RelayAPI.shared.token == nil {
            state = .disconnected
        } else {
            await refresh()
        }
    }
    func refresh() async {
        do {
            async let me: RelayIdentity = RelayAPI.shared.request("/v1/me")
            async let list: DataEnvelope<[Conversation]> = RelayAPI.shared.request("/v1/conversations")
            async let preferences: DataEnvelope<RelaySettings> = RelayAPI.shared.request("/v1/settings")
            let values = try await (me, list, preferences)
            identity = values.0; conversations = values.1.data; settings = values.2.data; state = .connected; error = nil
            await voice.connect(api: .shared, ownNumber: values.0.phone?.e164 ?? "")
            startEvents()
        } catch { self.error = error.localizedDescription; state = identity == nil ? .disconnected : .connected }
    }
    func resume() async {
        guard RelayAPI.shared.token != nil else { state = .disconnected; return }
        if identity == nil { await refresh() } else { await voice.ensureConnected() }
    }
    func activity(peer: String) async throws -> [ActivityItem] {
        guard let normalized = peer.e164 else { throw RelayAPIError.server("This conversation does not contain a valid phone number.") }
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? normalized
        let result: DataEnvelope<[ActivityItem]> = try await RelayAPI.shared.request("/v1/activity?peer=\(encoded)")
        return result.data
    }
    func send(to: String, text: String) async throws { let _: EmptyResponse = try await RelayAPI.shared.request("/v1/messages", method: "POST", body: MessageRequest(to: to, text: text)); await refresh() }
    func deleteMessage(id: String) async throws { let _: EmptyResponse = try await RelayAPI.shared.request("/v1/messages/\(id)", method: "DELETE") }
    func deleteConversation(peer: String) async throws {
        guard let normalized = peer.e164 else { throw RelayAPIError.server("This conversation does not contain a valid phone number.") }
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? normalized
        let _: EmptyResponse = try await RelayAPI.shared.request("/v1/conversations?peer=\(encoded)", method: "DELETE")
        conversations.removeAll { $0.peer == normalized }
    }
    func saveSettings(_ value: RelaySettings) async throws { let _: EmptyResponse = try await RelayAPI.shared.request("/v1/settings", method: "PUT", body: value); settings = value }
    private func startEvents() {
        events?.cancel()
        var components = URLComponents(url: RelayAPI.shared.baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/events"; components.query = nil
        var request = URLRequest(url: components.url!); if let token = RelayAPI.shared.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        events = URLSession.shared.webSocketTask(with: request); events?.resume(); receiveEvent()
    }
    private func receiveEvent() { events?.receive { [weak self] result in Task { @MainActor in guard let self else { return }; if case .success = result { self.activityRevision += 1; await self.refresh(); self.receiveEvent() } else { try? await Task.sleep(for: .seconds(2)); self.startEvents() } } } }
}

private struct MessageRequest: Encodable { let to: String; let text: String }
private struct EmptyResponse: Decodable {}
