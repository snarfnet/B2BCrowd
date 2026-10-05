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
        guard case .appleMusic(let song) = track.source else { return }
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
    let demoPlayer = DemoPlayer()

    var player: TrackPlayer { demoMode ? demoPlayer : musicKitPlayer }
    var isReady: Bool { demoMode || (access == .authorized && canPlayCatalog) }

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
}
