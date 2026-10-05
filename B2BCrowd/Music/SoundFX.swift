import AVFoundation
import UIKit

// 歓声や合図の効果音。録音素材は使わず、その場で波形を作る。
// Apple Music の音には一切触れない（別の AVAudioEngine で鳴らすだけ）。
@MainActor
final class SoundFX {
    static let shared = SoundFX()

    enum Cue { case cheer, bigCheer, whistle, tick, drop, boo }

    var enabled = true
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var started = false

    private init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.55
    }

    static func configureSession() {
        // 他の音（Apple Music の再生）を止めずに重ねる
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func play(_ cue: Cue) {
        guard enabled else { return }
        if !started {
            do { try engine.start(); started = true } catch { return }
        }
        let buf = buffer(cue)
        node.scheduleBuffer(buf, at: nil, options: .interrupts)
        if !node.isPlaying { node.play() }
    }

    func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func buffer(_ cue: Cue) -> AVAudioPCMBuffer {
        let key = "\(cue)"
        if let b = cache[key] { return b }
        let b: AVAudioPCMBuffer
        switch cue {
        case .cheer: b = crowd(seconds: 1.6, gain: 0.35)
        case .bigCheer: b = crowd(seconds: 3.2, gain: 0.55)
        case .boo: b = crowd(seconds: 1.0, gain: 0.25, low: true)
        case .whistle: b = tone(seconds: 0.7) { t in 2400 + 900 * sin(t * 9) }
        case .tick: b = tone(seconds: 0.07) { _ in 1320 }
        case .drop: b = tone(seconds: 0.9) { t in 140 - 90 * t }
        }
        cache[key] = b
        return b
    }

    private func make(_ seconds: Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        return b
    }

    // ざわざわした歓声：ノイズを少しこもらせて、ふくらんでしぼむ
    private func crowd(seconds: Double, gain: Float, low: Bool = false) -> AVAudioPCMBuffer {
        let b = make(seconds)
        let p = b.floatChannelData![0]
        let n = Int(b.frameLength)
        var lp: Float = 0
        let k: Float = low ? 0.04 : 0.18
        for i in 0..<n {
            let x = Float(i) / Float(n)
            let env = min(1, x * 6) * pow(1 - x, 1.3)
            let wobble = 0.75 + 0.25 * sin(Float(i) / 2200)
            lp += k * (Float.random(in: -1...1) - lp)
            p[i] = lp * env * wobble * gain * 3
        }
        return b
    }

    private func tone(seconds: Double, freq: (Double) -> Double) -> AVAudioPCMBuffer {
        let b = make(seconds)
        let p = b.floatChannelData![0]
        let n = Int(b.frameLength)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / format.sampleRate
            phase += 2 * .pi * freq(t / seconds) / format.sampleRate
            let x = Double(i) / Double(n)
            let env = min(1, x * 40) * (1 - x)
            p[i] = Float(sin(phase) * env * 0.4)
        }
        return b
    }
}
