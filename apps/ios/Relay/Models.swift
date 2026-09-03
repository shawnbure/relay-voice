import Foundation

struct RelayIdentity: Decodable {
    struct User: Decodable {
        let displayName: String; let email: String; let tenantName: String; let role: String
        enum CodingKeys: String, CodingKey { case displayName = "display_name", email, tenantName = "tenant_name", role }
    }
    struct Phone: Decodable { let e164: String }
    let user: User; let phone: Phone?
}

enum ActivityKind: String, Decodable { case message, call, voicemail }
struct Conversation: Decodable, Identifiable, Hashable {
    var id: String { peer }
    let peer: String; let displayName: String; let body: String; let direction: String; let status: String; let occurredAt: Date; let kind: ActivityKind
    enum CodingKeys: String, CodingKey { case peer, displayName = "display_name", body, direction, status, occurredAt = "occurred_at", kind }
}
struct MediaItem: Decodable, Hashable { let key: String; let contentType: String; let size: Int? }
struct ActivityItem: Decodable, Identifiable, Hashable {
    let id: String; let kind: ActivityKind; let direction: String; let body: String; let status: String; let occurredAt: Date; let media: [MediaItem]; let durationSeconds: Int?
    enum CodingKeys: String, CodingKey { case id, kind, direction, body, status, occurredAt = "occurred_at", media, durationSeconds = "duration_seconds" }
}
struct RelaySettings: Codable {
    var receiveWeb: Bool; var receiveMobile: Bool; var voicemailEnabled: Bool; var hasVoicemailGreeting: Bool; var voicemailUpdatedAt: Date?
    static let defaults = Self(receiveWeb: true, receiveMobile: true, voicemailEnabled: true, hasVoicemailGreeting: false, voicemailUpdatedAt: nil)
}
struct DataEnvelope<T: Decodable>: Decodable { let data: T }
struct VoiceToken: Decodable { let token: String; let expiresIn: Int; let selfTarget: String }

extension JSONDecoder {
    static var relay: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        return decoder
    }
}
extension String {
    var phoneDigits: String { filter(\.isNumber) }
    var e164: String? { let d = phoneDigits; if d.count == 10 { return "+1" + d }; if d.count == 11 && d.first == "1" { return "+" + d }; return hasPrefix("+") && d.count >= 8 ? "+" + d : nil }
    var displayPhone: String { let d = phoneDigits; let n = d.count == 11 && d.first == "1" ? String(d.dropFirst()) : d; guard n.count == 10 else { return self }; return "(\(n.prefix(3))) \(n.dropFirst(3).prefix(3))-\(n.suffix(4))" }
}
