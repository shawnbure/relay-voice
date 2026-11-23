import AuthenticationServices
import UIKit

/// Runs the system passkey sheet for the Relay website and returns the assertion in WebAuthn JSON form,
/// which the server verifies exactly like a browser passkey sign-in.
@MainActor
final class PasskeyAssertion: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Credential: Encodable {
        struct Response: Encodable { let clientDataJSON: String; let authenticatorData: String; let signature: String; let userHandle: String? }
        let id: String; let rawId: String; let type = "public-key"; let authenticatorAttachment = "platform"
        let response: Response; let clientExtensionResults: [String: String] = [:]
    }
    private var continuation: CheckedContinuation<Credential, Error>?
    private var keepAlive: PasskeyAssertion?

    func run(relyingParty: String, challenge: String) async throws -> Credential {
        guard let challengeData = Data(base64URL: challenge) else { throw RelayAPIError.server("Relay sent an invalid passkey request.") }
        let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingParty).createCredentialAssertionRequest(challenge: challengeData)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self; controller.presentationContextProvider = self
        keepAlive = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            Task { @MainActor in self.finish(.failure(RelayAPIError.server("That sign-in method is not supported."))) }; return
        }
        let id = assertion.credentialID.base64URL
        let credential = Credential(id: id, rawId: id, response: .init(clientDataJSON: assertion.rawClientDataJSON.base64URL, authenticatorData: assertion.rawAuthenticatorData.base64URL, signature: assertion.signature.base64URL, userHandle: assertion.userID.isEmpty ? nil : assertion.userID.base64URL))
        Task { @MainActor in self.finish(.success(credential)) }
    }
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let canceled = (error as? ASAuthorizationError)?.code == .canceled
        let message = canceled ? "Passkey sign-in was canceled." : "No Relay passkey is available on this device. \(error.localizedDescription)"
        Task { @MainActor in self.finish(.failure(RelayAPIError.server(message))) }
    }
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first.map { UIWindow(windowScene: $0) } ?? ASPresentationAnchor()
        }
    }
    private func finish(_ result: Result<Credential, Error>) { continuation?.resume(with: result); continuation = nil; keepAlive = nil }
}

extension Data {
    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
