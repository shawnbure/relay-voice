import SwiftUI
import Foundation

struct RelayIdentity: Decodable {
    struct User: Decodable {
        let displayName: String; let email: String; let tenantName: String; let role: String
        enum CodingKeys: String, CodingKey { case displayName = "display_name", email, tenantName = "tenant_name", role }
    }
    struct Phone: Decodable { let e164: String }
    let user: User; let phone: Phone?; let phones: [PhoneLine]?
    /// Every number on the account, oldest first.
    var lines: [PhoneLine] { phones ?? (phone.map { [PhoneLine(e164: $0.e164, label: nil)] } ?? []) }
}

/// One of the account's own phone numbers.
struct PhoneLine: Decodable, Identifiable, Hashable {
    var id: String { e164 }
    let e164: String; var label: String?; var icon: String?
    var name: String { label.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? e164.displayPhone }
}

/// Icons a number can wear so the combined inbox shows which number each conversation is on.
enum LineIcon {
    static let choices: [(symbol: String, color: Color)] = [
        ("briefcase.fill", .blue), ("house.fill", .green), ("person.fill", .orange), ("building.2.fill", .purple),
        ("star.fill", .yellow), ("heart.fill", .pink), ("cart.fill", .teal), ("car.fill", .red),
        ("wrench.and.screwdriver.fill", .brown), ("globe.americas.fill", .indigo), ("bolt.fill", .mint), ("leaf.fill", .cyan),
    ]
    static func color(_ symbol: String) -> Color { choices.first { $0.symbol == symbol }?.color ?? .gray }
}

enum ActivityKind: String, Decodable { case message, call, voicemail }
struct Conversation: Decodable, Identifiable, Hashable {
    var id: String { peer }
    let peer: String; let displayName: String; let body: String; let direction: String; let status: String; let occurredAt: Date; let kind: ActivityKind; var muted = false; var line: String? = nil
    enum CodingKeys: String, CodingKey { case peer, displayName = "display_name", body, direction, status, occurredAt = "occurred_at", kind, muted, line }
}
struct VoicemailItem: Decodable, Identifiable, Hashable {
    let id: String; let peer: String; let line: String; let durationSeconds: Int?; let status: String; let occurredAt: Date; let displayName: String?
    enum CodingKeys: String, CodingKey { case id, peer, line, status, durationSeconds = "duration_seconds", occurredAt = "occurred_at", displayName = "display_name" }
}
struct MediaItem: Decodable, Hashable { let key: String; let contentType: String; let size: Int? }
struct ActivityItem: Decodable, Identifiable, Hashable {
    let id: String; let kind: ActivityKind; let direction: String; let body: String; let status: String; let occurredAt: Date; let deliveredAt: Date?; let media: [MediaItem]; let durationSeconds: Int?
    enum CodingKeys: String, CodingKey { case id, kind, direction, body, status, occurredAt = "occurred_at", deliveredAt = "delivered_at", media, durationSeconds = "duration_seconds" }
}
struct RelaySettings: Codable {
    var receiveWeb: Bool; var receiveMobile: Bool; var receiveDesktop: Bool; var voicemailEnabled: Bool; var hasVoicemailGreeting: Bool; var voicemailUpdatedAt: Date?
    static let defaults = Self(receiveWeb: true, receiveMobile: true, receiveDesktop: true, voicemailEnabled: true, hasVoicemailGreeting: false, voicemailUpdatedAt: nil)
    /// Whether this device (the iPhone app or the Mac app) should ring.
    var ringsOnThisDevice: Bool { ProcessInfo.processInfo.isMacCatalystApp ? receiveDesktop : receiveMobile }
}
extension RelaySettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        receiveWeb = try c.decode(Bool.self, forKey: .receiveWeb); receiveMobile = try c.decode(Bool.self, forKey: .receiveMobile)
        receiveDesktop = try c.decodeIfPresent(Bool.self, forKey: .receiveDesktop) ?? true
        voicemailEnabled = try c.decode(Bool.self, forKey: .voicemailEnabled); hasVoicemailGreeting = try c.decode(Bool.self, forKey: .hasVoicemailGreeting)
        voicemailUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .voicemailUpdatedAt)
    }
}
struct DataEnvelope<T: Decodable>: Decodable { let data: T }
struct VoiceToken: Decodable { let token: String; let expiresIn: Int; let selfTarget: String }
struct OutgoingAttachment {
    let name: String; let contentType: String; let data: Data
}

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
    /// A conversation peer: an E.164 number, or a carrier short code such as 39569.
    var conversationPeer: String? { e164 ?? ((3...8).contains(count) && allSatisfy(\.isNumber) ? self : nil) }
    var displayPhone: String { let d = phoneDigits; let n = d.count == 11 && d.first == "1" ? String(d.dropFirst()) : d; guard n.count == 10 else { return self }; return "(\(n.prefix(3))) \(n.dropFirst(3).prefix(3))-\(n.suffix(4))" }
}
