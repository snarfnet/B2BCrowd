import AVFoundation
import Foundation

// Audius の曲を公式ストリーム URL で再生する。音源は加工・保存しない（AVPlayer にそのまま渡すだけ）。
// 1曲ずつ再生し、曲同士を重ねない。
@MainActor
final class AudiusPlayer: TrackPlayer {
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var interruptObserver: NSObjectProtocol?
    private var stopped = true
    private var interrupted = false
    var policy = AudiusPolicy()

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        interruptObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.interrupted = type == .began
            }
        }
    }

    func play(_ track: Track) async throws {
        guard case .audius(let a) = track.source else { return }
        stop()
        let apiKey = await AudiusAPIClient.shared.apiKey
        if case .blocked(let r) = policy.check(a, apiKey: apiKey) { throw AudiusError.trackUnavailable(r) }

        let url = try await AudiusAPIClient.shared.streamURL(trackID: a.id)
        let item = AVPlayerItem(url: url)
        observe(item)
        player.replaceCurrentItem(with: item)
        stopped = false
        interrupted = false
        player.play()

        // 読み込みに失敗したら呼び出し側（GameEngine）へ投げて選び直してもらう
        let deadline = Date().addingTimeInterval(15)
        while item.status == .unknown, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        if item.status != .readyToPlay {
            stop()
            throw AudiusError.streamFailed
        }
    }

    private func observe(_ item: AVPlayerItem) {
        clearObservers()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopped = true }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopped = true }
        }
    }

    private func clearObservers() {
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        if let o = failObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        failObserver = nil
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        clearObservers()
        stopped = true
        interrupted = false
    }

    func pause() { player.pause() }

    func resume() async {
        guard !stopped else { return }
        interrupted = false
        player.play()
    }

    var elapsed: TimeInterval {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }
    var isPlaying: Bool { player.timeControlStatus == .playing }
    var hasStopped: Bool { stopped }
    var isInterrupted: Bool { interrupted }
}
