import AVFoundation

// タイトル・設定画面の BGM（Stable Audio 3 で作ったオリジナルのダンス曲、Resources/Sounds/bgm_title.m4a）。
// セッションが始まったらフェードアウト（ゲームでは Apple Music / Audius の曲だけを鳴らす）。
@MainActor
final class TitleMusic {
    static let shared = TitleMusic()
    private var player: AVAudioPlayer?
    private var fade: Timer?
    private let level: Float = 0.55

    func play() {
        if player == nil, let url = Bundle.main.url(forResource: "bgm_title", withExtension: "m4a") {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.prepareToPlay()
        }
        guard let p = player else { return }
        if !p.isPlaying { p.volume = 0; p.play() }
        ramp(to: level, over: 1.2, stopAtEnd: false)
    }

    func stop(over seconds: Double = 0.8) {
        guard let p = player, p.isPlaying else { return }
        ramp(to: 0, over: seconds, stopAtEnd: true)
    }

    // a fixed-rate fade driven on the main actor (no captured mutable state)
    private var fadeFrom: Float = 0, fadeTo: Float = 0, fadeStep = 0, fadeSteps = 1, fadeStops = false
    private func ramp(to target: Float, over seconds: Double, stopAtEnd: Bool) {
        fade?.invalidate()
        guard let p = player else { return }
        fadeFrom = p.volume; fadeTo = target; fadeStep = 0; fadeSteps = max(1, Int(seconds / 0.05)); fadeStops = stopAtEnd
        fade = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in TitleMusic.shared.tickFade() }
        }
    }
    private func tickFade() {
        guard let p = player, fade != nil else { return }
        fadeStep += 1
        p.volume = fadeFrom + (fadeTo - fadeFrom) * Float(fadeStep) / Float(fadeSteps)
        if fadeStep >= fadeSteps {
            fade?.invalidate(); fade = nil
            if fadeStops { p.pause(); p.currentTime = 0 }
        }
    }
}
