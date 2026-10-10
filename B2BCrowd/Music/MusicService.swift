import Foundation
import MusicKit

// 再生の窓口。ゲーム側はこのプロトコルだけを見る。
// Apple Music の音源には触れず、MusicKit の公式プレイヤーに再生を任せる。
@MainActor
protocol TrackPlayer: AnyObject {
    func play(_ track: Track) async throws
    func stop()
    func pause()
    func resume() async
    /// 公式 API が返す再生位置（秒）
    var elapsed: TimeInterval { get }
    var isPlaying: Bool { get }
    /// 曲が最後まで行って止まった、または外から止められた
    var hasStopped: Bool { get }
    /// 着信などで中断された
    var isInterrupted: Bool { get }
}

@MainActor
final class MusicKitPlayer: TrackPlayer {
    private var player: ApplicationMusicPlayer { ApplicationMusicPlayer.shared }

    func play(_ track: Track) async throws {
        let song: Song
        switch track.source {
        case .appleMusic(let s):
            song = s
        case .appleMusicRef:
            // 相手の iPhone で選ばれた曲。こちらのカタログから id で引き直す
            let req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(track.id))
            guard let s = try await req.response().items.first else {
                throw LinkError(L.t("この曲はこちらの Apple Music で見つかりません", "This track isn't in this Apple Music storefront"))
            }
            song = s
        default:
            return
        }
        player.queue = ApplicationMusicPlayer.Queue(for: [song])
        try await player.prepareToPlay()
        try await player.play()
    }

    func stop() { player.stop() }
    func pause() { player.pause() }
    func resume() async { try? await player.play() }

    var elapsed: TimeInterval { player.playbackTime }
    var isPlaying: Bool { player.state.playbackStatus == .playing }
    var hasStopped: Bool { player.state.playbackStatus == .stopped }
    var isInterrupted: Bool { player.state.playbackStatus == .interrupted }
}

/// Apple Music が使えないときの練習用。音は鳴らさず、時計だけ進める。
@MainActor
final class DemoPlayer: TrackPlayer {
    private var startedAt: Date?
    private var banked: TimeInterval = 0
    private var stopped = true

    func play(_ track: Track) async throws {
        banked = 0
        startedAt = Date()
        stopped = false
    }

    func stop() {
        startedAt = nil
        stopped = true
    }

    func pause() {
        if let s = startedAt { banked += Date().timeIntervalSince(s) }
        startedAt = nil
    }

    func resume() async {
        if !stopped { startedAt = Date() }
    }

    var elapsed: TimeInterval { banked + (startedAt.map { Date().timeIntervalSince($0) } ?? 0) }
    var isPlaying: Bool { startedAt != nil }
    var hasStopped: Bool { stopped }
    var isInterrupted: Bool { false }
}

@MainActor
@Observable
final class MusicService {
    enum Access: Equatable {
        case unknown, notDetermined, denied, restricted, authorized
    }

    var access: Access = .unknown
    var canPlayCatalog: Bool = false
    var subscriptionChecked = false
    var demoMode = false
    var lastError: String?

    let musicKitPlayer = MusicKitPlayer()
    let audiusPlayer = AudiusPlayer()
    let demoPlayer = DemoPlayer()

    /// 選曲に使うサービス。切り替えるときは鳴っている方を必ず止めてから（2つを同時に鳴らさない）
    var source: MusicSourceKind = MusicService.loadSource() {
        didSet {
            guard source != oldValue else { return }
            stopAll()
            UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
        }
    }

    var player: TrackPlayer {
        if demoMode { return demoPlayer }
        switch source {
        case .appleMusic: return musicKitPlayer
        case .audius: return audiusPlayer
        }
    }

    /// Audius は登録不要・無料で聴けるので、ネットにつながれば常に使える
    var isReady: Bool {
        if demoMode { return true }
        switch source {
        case .appleMusic: return access == .authorized && canPlayCatalog
        case .audius: return true
        }
    }

    /// いま画面に出すサービス名
    var sourceLabel: String { demoMode ? "DEMO" : source.title }

    func stopAll() {
        musicKitPlayer.stop()
        audiusPlayer.stop()
        demoPlayer.stop()
    }

    private static let sourceKey = "musicSource.v1"
    private static func loadSource() -> MusicSourceKind {
        UserDefaults.standard.string(forKey: sourceKey).flatMap(MusicSourceKind.init(rawValue:)) ?? .appleMusic
    }

    func refresh() async {
        access = Self.map(MusicAuthorization.currentStatus)
        if access == .authorized { await checkSubscription() }
    }

    func requestAccess() async {
        let status = await MusicAuthorization.request()
        access = Self.map(status)
        if access == .authorized { await checkSubscription() }
    }

    private func checkSubscription() async {
        do {
            let sub = try await MusicSubscription.current
            canPlayCatalog = sub.canPlayCatalogContent
        } catch {
            canPlayCatalog = false
            lastError = error.localizedDescription
        }
        subscriptionChecked = true
    }

    private static func map(_ s: MusicAuthorization.Status) -> Access {
        switch s {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func search(_ term: String) async throws -> [Track] {
        if demoMode { return DemoCatalog.search(term) }
        let q = term.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        if source == .audius { return try await searchAudius(q) }
        var req = MusicCatalogSearchRequest(term: q, types: [Song.self])
        req.limit = 25
        let res = try await req.response()
        return res.songs.map(Track.init(song:))
    }

    func library() async throws -> [Track] {
        if demoMode { return DemoCatalog.tracks }
        var req = MusicLibraryRequest<Song>()
        req.limit = 50
        let res = try await req.response()
        return res.items.map(Track.init(song:))
    }

    // MARK: Audius

    func searchAudius(_ q: String, offset: Int = 0) async throws -> [Track] {
        MusicAnalytics.shared.count(.audiusSearch)
        return try await AudiusAPIClient.shared.search(q, offset: offset).map(Track.init(audius:))
    }

    func trendingAudius(_ c: AudiusTrendingCategory, offset: Int = 0) async throws -> [Track] {
        try await AudiusAPIClient.shared.trending(genre: c.genre, offset: offset).map(Track.init(audius:))
    }

    /// 再生できるか（API の権利・アクセス情報とアプリの方針で判定）
    func audiusPlayability(_ t: Track) async -> AudiusPlayability {
        guard let a = t.audius else { return .ok }
        return audiusPlayer.policy.check(a, apiKey: await AudiusAPIClient.shared.apiKey)
    }
}
