import AVFoundation
import CallKit
import Foundation
import PushKit
import UIKit
@preconcurrency import TelnyxRTC

@MainActor
final class VoiceManager: NSObject, ObservableObject {
    enum Status: Equatable { case offline, connecting, ready, ringing, active, held, ending, failed(String) }
    @Published var status: Status = .offline
    @Published var remoteNumber = ""
    @Published var startedAt: Date?
    @Published var muted = false
    @Published var speaker = false
    @Published private(set) var incoming = false
    @Published private(set) var hasCall = false

    var isInCall: Bool { hasCall }
    var isCallActive: Bool { status == .active || status == .held }
    var canStartCall: Bool { status == .ready && !hasCall }

    private let client = TxClient()
    private let provider: CXProvider
    private let callController = CXCallController()
    private var registry: PKPushRegistry?
    private var call: Call?
    private var ownNumber = ""
    private var selfTarget = ""
    private var api: RelayAPI?
    private var pushToken = Keychain.read("relay.voip.token")
    private var reportedIncomingCalls = Set<UUID>()
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 2

    override init() {
        let configuration = CXProviderConfiguration(localizedName: "Relay")
        configuration.supportsVideo = false; configuration.maximumCallGroups = 1; configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber, .generic]
        configuration.includesCallsInRecents = true
        configuration.iconTemplateImageData = Self.callKitIconData()
        provider = CXProvider(configuration: configuration)
        super.init()
        client.delegate = self; provider.setDelegate(self, queue: .main)
        let registry = PKPushRegistry(queue: .main); registry.delegate = self; registry.desiredPushTypes = [.voIP]; self.registry = registry
    }

    func connect(api: RelayAPI, ownNumber: String) async {
        guard status == .offline else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        self.api = api; self.ownNumber = ownNumber; status = .connecting
        do {
            let voice: VoiceToken = try await api.request("/v1/voice/token", method: "POST", body: EmptyBody())
            selfTarget = voice.selfTarget
            Keychain.save(voice.token, key: "relay.voice.jwt")
            let config = TxConfig(token: voice.token, pushDeviceToken: pushToken, pushEnvironment: pushEnvironment, enableMissedCallNotifications: true, reconnectClient: true, pushWhenActive: true)
            try client.connect(txConfig: config)
        } catch { status = .failed(error.localizedDescription); scheduleReconnect() }
    }
    func disconnect() { reconnectTask?.cancel(); reconnectTask = nil; client.disconnect(); call = nil; hasCall = false; incoming = false; status = .offline }
    func ensureConnected() async {
        guard call == nil, status != .ready, status != .connecting, let api, !ownNumber.isEmpty else { return }
        reconnectTask?.cancel(); reconnectTask = nil; status = .offline
        await connect(api: api, ownNumber: ownNumber)
    }
    func start(number: String) {
        guard canStartCall, let destination = number.e164 else { return }
        remoteNumber = destination; hasCall = true; incoming = false; status = .connecting
        let action = CXStartCallAction(call: UUID(), handle: CXHandle(type: .phoneNumber, value: destination))
        request(CXTransaction(action: action))
    }
    func answer() { guard let id = call?.callInfo?.callId else { return }; request(CXTransaction(action: CXAnswerCallAction(call: id))) }
    func hangup() { guard let id = call?.callInfo?.callId else { return }; status = .ending; request(CXTransaction(action: CXEndCallAction(call: id))) }
    func sendDTMF(_ digit: String) {
        guard hasCall, digit.count == 1, "0123456789*#".contains(digit) else { return }
        call?.dtmf(dtmf: digit)
    }
    func toggleMute() { muted.toggle(); muted ? call?.muteAudio() : call?.unmuteAudio() }
    func toggleSpeaker() { speaker.toggle(); try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none) }
    func toggleHold() { guard let call else { return }; if status == .held { call.unhold() } else { call.hold() } }

    private var pushEnvironment: PushEnvironment {
        #if DEBUG
        return .debug
        #else
        return .production
        #endif
    }
    private func request(_ transaction: CXTransaction) { callController.request(transaction) { [weak self] error in if let error { Task { @MainActor in self?.hasCall = self?.call != nil; self?.status = .failed(error.localizedDescription) } } } }
    private func finish() { call = nil; hasCall = false; incoming = false; reportedIncomingCalls.removeAll(); remoteNumber = ""; startedAt = nil; muted = false; speaker = false; status = .ready }
    private func reportIncomingCall(id: UUID, number: String) {
        guard reportedIncomingCalls.insert(id).inserted else { return }
        let update = CXCallUpdate(); update.remoteHandle = CXHandle(type: .phoneNumber, value: number); update.localizedCallerName = number.e164?.displayPhone ?? number; update.hasVideo = false; update.supportsDTMF = true; update.supportsHolding = true; update.supportsGrouping = false; update.supportsUngrouping = false
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in if error != nil { Task { @MainActor in self?.reportedIncomingCalls.remove(id) } } }
    }
    private static func callKitIconData() -> Data? {
        guard let source = UIImage(named: "CommunicationTab")?.withRenderingMode(.alwaysTemplate) else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.opaque = false; format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format).image { _ in
            source.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 4, y: 4, width: 32, height: 32))
        }.pngData()
    }
    private func reconnectForPushToken() async {
        guard call == nil, let api, !ownNumber.isEmpty else { return }
        client.disconnect(); status = .offline
        await connect(api: api, ownNumber: ownNumber)
    }
    private func scheduleReconnect() {
        guard call == nil, api != nil, !ownNumber.isEmpty, reconnectTask == nil else { return }
        let delay = reconnectDelay; reconnectDelay = min(reconnectDelay * 2, 30)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let api = self.api else { return }
            self.reconnectTask = nil; self.status = .offline
            await self.connect(api: api, ownNumber: self.ownNumber)
        }
    }
}

extension VoiceManager: TxClientDelegate {
    nonisolated func onSocketConnected() {}
    nonisolated func onSocketDisconnected() { Task { @MainActor in if self.call == nil { self.status = .offline; self.scheduleReconnect() } } }
    nonisolated func onClientError(error: Error) { Task { @MainActor in self.status = .failed(error.localizedDescription); self.scheduleReconnect() } }
    nonisolated func onClientReady() { Task { @MainActor in self.reconnectTask?.cancel(); self.reconnectTask = nil; self.reconnectDelay = 2; if !self.hasCall { self.status = .ready } } }
    nonisolated func onPushDisabled(success: Bool, message: String) {}
    nonisolated func onSessionUpdated(sessionId: String) {}
    nonisolated func onCallStateUpdated(callState: CallState, callId: UUID) {
        Task { @MainActor in
            switch callState {
            case .ACTIVE:
                self.hasCall = true; self.incoming = false; self.status = .active; self.startedAt = self.startedAt ?? Date(); self.provider.reportOutgoingCall(with: callId, connectedAt: Date())
            case .RINGING:
                self.hasCall = true; self.status = .ringing
            case .HELD:
                self.hasCall = true; self.status = .held
            case .DONE, .DROPPED:
                self.provider.reportCall(with: callId, endedAt: Date(), reason: .remoteEnded); self.finish()
            case .NEW, .CONNECTING, .RECONNECTING:
                self.hasCall = true; self.status = .connecting
            }
        }
    }
    nonisolated func onIncomingCall(call: Call) {
        Task { @MainActor in
            self.call = call; self.hasCall = true; self.incoming = true; self.remoteNumber = call.callInfo?.callerNumber ?? "Unknown"; self.status = .ringing
            guard let id = call.callInfo?.callId else { return }
            self.reportIncomingCall(id: id, number: self.remoteNumber)
        }
    }
    nonisolated func onRemoteCallEnded(callId: UUID, reason: CallTerminationReason?) { Task { @MainActor in self.reportedIncomingCalls.remove(callId); self.provider.reportCall(with: callId, endedAt: Date(), reason: .remoteEnded); self.finish() } }
    nonisolated func onPushCall(call: Call) { onIncomingCall(call: call) }
}

extension VoiceManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) { Task { @MainActor in self.call?.hangup(); self.finish() } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            do {
                let requested = action.handle.value.e164
                let destination = requested == self.ownNumber ? self.selfTarget : action.handle.value.phoneDigits
                guard !destination.isEmpty else { throw RelayAPIError.server("Self-test calling is still connecting.") }
                self.call = try self.client.newCall(callerName: "Relay", callerNumber: self.ownNumber.phoneDigits, destinationNumber: destination, callId: action.callUUID)
                self.hasCall = true; self.provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date()); action.fulfill()
            }
            catch { self.hasCall = false; self.status = .failed(error.localizedDescription); action.fail() }
        }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) { Task { @MainActor in self.call?.answer(); action.fulfill() } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) { Task { @MainActor in self.call?.hangup(); self.finish(); action.fulfill() } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) { Task { @MainActor in self.sendDTMF(action.digits); action.fulfill() } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) { Task { @MainActor in if action.isOnHold { self.call?.hold() } else { self.call?.unhold() }; action.fulfill() } }
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) { Task { @MainActor in self.client.enableAudioSession(audioSession: audioSession) } }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) { Task { @MainActor in self.client.disableAudioSession(audioSession: audioSession) } }
}

extension VoiceManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            guard token != self.pushToken else { return }
            self.pushToken = token; Keychain.save(token, key: "relay.voip.token")
            await self.reconnectForPushToken()
        }
    }
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) { Task { @MainActor in self.pushToken = nil; Keychain.delete("relay.voip.token") } }
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        Task { @MainActor in
            defer { completion() }
            guard let jwt = Keychain.read("relay.voice.jwt") else { return }
            let rawPayload = payload.dictionaryPayload
            let payloadStrings: [String: Any] = rawPayload.reduce(into: [:]) { result, item in
                if let key = item.key as? String { result[key] = item.value }
            }
            let metadata = (rawPayload["metadata"] as? [String: Any]) ?? payloadStrings
            if let rawID = metadata["call_id"] as? String, let id = UUID(uuidString: rawID) {
                let caller = (metadata["caller_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (metadata["caller_number"] as? String) ?? "Unknown caller"
                self.remoteNumber = caller; self.incoming = true; self.hasCall = true; self.status = .ringing
                self.reportIncomingCall(id: id, number: caller)
            }
            let config = TxConfig(token: jwt, pushDeviceToken: self.pushToken, pushEnvironment: self.pushEnvironment, enableMissedCallNotifications: true, reconnectClient: true)
            let server = TxServerConfiguration(pushMetaData: metadata)
            try? self.client.processVoIPNotification(txConfig: config, serverConfiguration: server, pushMetaData: metadata)
        }
    }
}

private struct EmptyBody: Encodable {}
