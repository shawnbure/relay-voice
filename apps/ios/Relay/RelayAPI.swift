import Foundation
import Security

enum RelayAPIError: LocalizedError {
    case invalidResponse, unauthorized, server(String)
    var errorDescription: String? { switch self { case .invalidResponse: "Relay returned an invalid response."; case .unauthorized: "Connect this iPhone to Relay again."; case .server(let message): message } }
}

@MainActor
final class RelayAPI {
    static let shared = RelayAPI()
    let baseURL: URL = {
        let configured = ProcessInfo.processInfo.environment["RELAY_API_BASE_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "RelayAPIBaseURL") as? String
        return URL(string: configured ?? "http://localhost:8787")!
    }()
    private(set) var token = Keychain.read("relay.mobile.token")
    func setToken(_ value: String?) {
        token = value
        if let value {
            Keychain.save(value, key: "relay.mobile.token")
        } else {
            Keychain.delete("relay.mobile.token")
        }
    }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: (any Encodable)? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!); request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(AnyEncodable(body)); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayAPIError.invalidResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw RelayAPIError.server((try? JSONDecoder().decode(APIErrorBody.self, from: data).error) ?? "Relay request failed (\(http.statusCode)).") }
        return try JSONDecoder.relay.decode(T.self, from: data)
    }
    func mediaRequest(_ path: String) -> URLRequest { var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!); if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }; return request }
}

private struct APIErrorBody: Decodable { let error: String }
private struct AnyEncodable: Encodable { let encodeValue: (Encoder) throws -> Void; init(_ value: any Encodable) { encodeValue = value.encode }; func encode(to encoder: Encoder) throws { try encodeValue(encoder) } }

enum Keychain {
    static func save(_ value: String, key: String) { delete(key); SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrAccount: key, kSecValueData: Data(value.utf8)] as CFDictionary, nil) }
    static func read(_ key: String) -> String? { var result: CFTypeRef?; guard SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrAccount: key, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }; return String(data: data, encoding: .utf8) }
    @discardableResult static func delete(_ key: String) -> Void? { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: key] as CFDictionary); return nil }
}
