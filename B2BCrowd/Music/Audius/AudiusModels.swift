import Foundation

// Audius 公式 REST API（https://api.audius.co/v1）の track オブジェクト。
// フィールド名は公式 swagger（/v1/swagger.yaml の components.schemas.track）に合わせ、
// 実際に返ってくる値だけを読む。無い項目は nil のまま（勝手に補わない）。
struct AudiusTrack: Codable, Hashable {
    struct Artwork: Codable, Hashable {
        let small: String?      // 150x150
        let medium: String?     // 480x480
        let large: String?      // 1000x1000
        let mirrors: [String]?

        enum CodingKeys: String, CodingKey {
            case small = "150x150", medium = "480x480", large = "1000x1000", mirrors
        }
    }

    struct User: Codable, Hashable {
        let id: String
        let name: String
        let handle: String?
    }

    /// API を呼んだ人（ここでは匿名）が実際に再生・DL できるか
    struct Access: Codable, Hashable {
        let stream: Bool
        let download: Bool?
    }

    let id: String
    let title: String
    let user: User
    let duration: Int?
    let genre: String?
    let mood: String?
    let releaseDate: String?
    let permalink: String?
    let artwork: Artwork?

    // 権利・アクセス情報
    let license: String?
    let isStreamable: Bool?
    let isStreamGated: Bool?
    let streamConditions: JSONValue?
    let access: Access?
    let allowedApiKeys: [String]?
    let accessAuthorities: [String]?
    let isAvailable: Bool?
    let isDelete: Bool?
    let isUnlisted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, user, duration, genre, mood, permalink, artwork, license, access
        case releaseDate = "release_date"
        case isStreamable = "is_streamable"
        case isStreamGated = "is_stream_gated"
        case streamConditions = "stream_conditions"
        case allowedApiKeys = "allowed_api_keys"
        case accessAuthorities = "access_authorities"
        case isAvailable = "is_available"
        case isDelete = "is_delete"
        case isUnlisted = "is_unlisted"
    }

    var licenseStatus: AudiusLicense { AudiusLicense(license) }

    /// audius.co の曲ページ（帰属表示・Open in Audius 用）
    var webURL: URL? {
        guard let p = permalink, !p.isEmpty else { return nil }
        return URL(string: "https://audius.co" + (p.hasPrefix("/") ? p : "/" + p))
    }

    var releaseYear: Int? {
        guard let s = releaseDate, s.count >= 4 else { return nil }
        return Int(s.prefix(4))
    }

    /// 再生してよいかを API が返した情報だけで判断する。分からないものは「可」にしない。
    func playability(apiKey: String?) -> AudiusPlayability {
        if isDelete == true || isAvailable == false { return .blocked(.unavailable) }
        if isStreamable != true { return .blocked(.notStreamable) }
        if isStreamGated == true || streamConditions?.isNull == false { return .blocked(.gated) }
        if let a = accessAuthorities, !a.isEmpty { return .blocked(.gated) }
        if access?.stream == false { return .blocked(.accessRestricted) }
        if let keys = allowedApiKeys, !keys.isEmpty {
            guard let k = apiKey, keys.contains(k) else { return .blocked(.apiKeyRestricted) }
        }
        return .ok
    }
}

enum AudiusPlayability: Equatable {
    case ok
    case blocked(AudiusBlockReason)

    var isPlayable: Bool { self == .ok }
}

enum AudiusBlockReason: Equatable {
    case notStreamable, gated, accessRestricted, apiKeyRestricted, unavailable, licensePolicy

    var label: String {
        switch self {
        case .notStreamable: return L.t("ストリーム不可", "NOT STREAMABLE")
        case .gated: return L.t("限定公開", "GATED")
        case .accessRestricted: return L.t("アクセス制限", "RESTRICTED")
        case .apiKeyRestricted: return L.t("他アプリ専用", "APP-RESTRICTED")
        case .unavailable: return L.t("公開終了", "UNAVAILABLE")
        case .licensePolicy: return L.t("ライセンス対象外", "LICENSE FILTERED")
        }
    }
}

/// track.license の文字列をそのまま保持し、分類だけする。null は UNKNOWN（勝手に許諾ありとしない）。
enum AudiusLicense: Hashable {
    case unknown
    case allRightsReserved
    case creativeCommons(String)
    case other(String)

    init(_ raw: String?) {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { self = .unknown; return }
        let l = raw.lowercased()
        if l.contains("all rights reserved") { self = .allRightsReserved }
        else if l.contains("creative commons") || l.hasPrefix("cc ") || l.hasPrefix("cc-") { self = .creativeCommons(raw) }
        else { self = .other(raw) }
    }

    var badge: String {
        switch self {
        case .unknown: return "LICENSE: UNKNOWN"
        case .allRightsReserved: return "© ALL RIGHTS RESERVED"
        case .creativeCommons: return "CC"
        case .other(let s): return s.uppercased()
        }
    }
}

/// どのトラックを候補から外すか。初期値は「API が再生不可と言うものだけ外す」。
/// ライセンス不明の曲を外したい運用になったら excludeUnknownLicense を true にする。
struct AudiusPolicy {
    var excludeUnknownLicense = false

    func check(_ t: AudiusTrack, apiKey: String?) -> AudiusPlayability {
        let p = t.playability(apiKey: apiKey)
        guard p.isPlayable else { return p }
        if excludeUnknownLicense, t.licenseStatus == .unknown { return .blocked(.licensePolicy) }
        return .ok
    }
}

struct AudiusListResponse: Decodable {
    let data: [AudiusTrack]
}

struct AudiusStreamURLResponse: Decodable {
    let data: String
}

/// stream_conditions のように形が決まっていない JSON をそのまま持つ
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var isNull: Bool { self == .null }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

enum AudiusError: LocalizedError, Equatable {
    case network
    case api(Int)
    case rateLimited
    case authentication
    case trackUnavailable(AudiusBlockReason)
    case streamFailed
    case regionRestricted
    case accessRestricted
    case decoding

    var errorDescription: String? {
        switch self {
        case .network: return L.t("通信できませんでした。接続を確認してください", "Network error. Check your connection.")
        case .api(let code): return L.t("Audius の応答エラー（\(code)）", "Audius API error (\(code))")
        case .rateLimited: return L.t("リクエストが多すぎます。少し待ってください", "Too many requests. Wait a moment.")
        case .authentication: return L.t("Audius の認証に失敗しました（API キーを確認）", "Audius authentication failed (check the API key).")
        case .trackUnavailable(let r): return L.t("この曲は現在 B2B で再生できません（\(r.label)）", "This track can't play in B2B right now (\(r.label)).")
        case .streamFailed: return L.t("ストリーミングを開始できませんでした。別の曲を選んでください", "Couldn't start the stream. Pick another track.")
        case .regionRestricted: return L.t("この地域では再生できない曲です", "This track isn't available in your region.")
        case .accessRestricted: return L.t("この曲はアクセスが制限されています", "Access to this track is restricted.")
        case .decoding: return L.t("Audius の応答を読めませんでした", "Couldn't read the Audius response.")
        }
    }
}

/// Trending の分類。公式 API の genre パラメータに渡せる値（docs の Genre Values）だけを使う。
struct AudiusTrendingCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let genre: String?

    static let all: [AudiusTrendingCategory] = [
        .init(id: "all", title: "TRENDING", genre: nil),
        .init(id: "electronic", title: "ELECTRONIC", genre: "Electronic"),
        .init(id: "hiphop", title: "HIP-HOP", genre: "Hip-Hop/Rap"),
        .init(id: "house", title: "HOUSE", genre: "House"),
        .init(id: "techno", title: "TECHNO", genre: "Techno"),
        .init(id: "dnb", title: "DRUM & BASS", genre: "Drum & Bass"),
        .init(id: "dubstep", title: "DUBSTEP", genre: "Dubstep"),
        .init(id: "trance", title: "TRANCE", genre: "Trance"),
        .init(id: "pop", title: "POP", genre: "Pop"),
        .init(id: "lofi", title: "LO-FI", genre: "Lo-Fi"),
    ]
}
