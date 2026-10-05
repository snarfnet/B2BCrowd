import Foundation

// Audius 公式 REST API の窓口。UI からは直接呼ばず、MusicService 経由で使う。
// - ホスト: https://api.audius.co/v1（公式 swagger の Production サーバー）
// - 認証: 公式 SDK と同じく、全リクエストのクエリに api_key（無ければ app_name）を付ける
// - 上限: Free プランは 10 req/s。連打しないよう最短間隔をあけ、同じ検索は短時間キャッシュする
// - 音源そのものは保存しない。キャッシュするのは曲名などのメタデータだけ
actor AudiusAPIClient {
    static let shared = AudiusAPIClient()

    let apiKey: String?
    private let appName = "B2BCrowd"
    private let base = URL(string: "https://api.audius.co/v1")!
    private let session: URLSession
    private var cache: [String: (at: Date, tracks: [AudiusTrack])] = [:]
    private var lastRequest = Date.distantPast
    private let minInterval: TimeInterval = 0.15
    private let cacheTTL: TimeInterval = 120

    init() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "AudiusAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // xcconfig が無いと "$(AUDIUS_API_KEY)" のまま残ることがあるので弾く
        apiKey = (key?.isEmpty == false && key?.hasPrefix("$(") == false) ? key : nil
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    // MARK: 曲

    func search(_ query: String, offset: Int = 0, limit: Int = 20) async throws -> [AudiusTrack] {
        try await tracks("tracks/search", [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    /// 公式 API の Trending（最大100曲）。genre は docs の Genre Values の文字列
    func trending(genre: String?, time: String = "week", offset: Int = 0, limit: Int = 20) async throws -> [AudiusTrack] {
        var q = [
            URLQueryItem(name: "time", value: time),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let genre { q.append(URLQueryItem(name: "genre", value: genre)) }
        return try await tracks("tracks/trending", q)
    }

    /// 再生用 URL。公式の /tracks/{id}/stream に no_redirect=true を付けると、
    /// リダイレクトせずに署名付きのストリーム URL を JSON で返す（音源は落とさない）。
    func streamURL(trackID: String) async throws -> URL {
        let data = try await get("tracks/\(trackID)/stream", [URLQueryItem(name: "no_redirect", value: "true")])
        guard let r = try? JSONDecoder().decode(AudiusStreamURLResponse.self, from: data),
              let url = URL(string: r.data) else { throw AudiusError.decoding }
        return url
    }

    // MARK: 共通

    private func tracks(_ path: String, _ items: [URLQueryItem]) async throws -> [AudiusTrack] {
        let key = path + "?" + items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < cacheTTL { return hit.tracks }
        let data = try await get(path, items)
        do {
            let list = try JSONDecoder().decode(AudiusListResponse.self, from: data).data
            cache[key] = (Date(), list)
            if cache.count > 60 { cache = cache.filter { Date().timeIntervalSince($0.value.at) < cacheTTL } }
            return list
        } catch {
            throw AudiusError.decoding
        }
    }

    private func get(_ path: String, _ items: [URLQueryItem]) async throws -> Data {
        // 10 req/s を超えないよう間隔をあける
        let wait = minInterval - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        lastRequest = Date()

        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var q = items
        if let apiKey { q.append(URLQueryItem(name: "api_key", value: apiKey)) }
        else { q.append(URLQueryItem(name: "app_name", value: appName)) }
        comps.queryItems = q
        var req = URLRequest(url: comps.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AudiusError.network
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return data
        case 401: throw AudiusError.authentication
        case 403: throw AudiusError.accessRestricted
        case 404, 410: throw AudiusError.trackUnavailable(.unavailable)
        case 429: throw AudiusError.rateLimited
        case 451: throw AudiusError.regionRestricted
        default: throw AudiusError.api(code)
        }
    }
}
