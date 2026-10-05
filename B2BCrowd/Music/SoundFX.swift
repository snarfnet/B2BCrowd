import AVFoundation
import UIKit

// 観客の声（歓声・指笛・拍手・ブーイングなど）と、合図の音。
// 声の素材は Stable Audio 3 で作った効果音（Resources/Sounds）。音楽は含まない。
// Apple Music の音には一切触れず、別の AVAudioEngine で重ねて鳴らすだけ。
@MainActor
final class SoundFX {
    static let shared = SoundFX()

    enum Cue { case cheer, bigCheer, whistle, woo, applause, boo, horn, tick, drop }

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "crowdSound")
            if !enabled { stopCrowd() }
        }
    }

    private let engine = AVAudioEngine()
    private var shots: [AVAudioPlayerNode] = []
    private var nextShot = 0
    private let ambLow = AVAudioPlayerNode()
    private let ambHigh = AVAudioPlayerNode()
    private var files: [String: AVAudioPCMBuffer] = [:]
    private var synth: [String: AVAudioPCMBuffer] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private var started = false
    private var crowdOn = false
    private var lastPlayed: [String: Date] = [:]
    private var nextRandomWhistle = Date()

    private init() {
        enabled = UserDefaults.standard.object(forKey: "crowdSound") as? Bool ?? true
        for _ in 0..<8 {
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: format)
            shots.append(n)
        }
        for n in [ambLow, ambHigh] {
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: format)
            n.volume = 0
        }
        engine.mainMixerNode.outputVolume = 0.8
        for name in ["cheer_small", "cheer_small2", "cheer_big", "whistle", "whistle2", "woo", "woo2",
                     "applause", "boo", "horn", "amb_low", "amb_high"] {
            if let b = load(name) { files[name] = b }
        }
    }

    static func configureSession() {
        // 他の音（Apple Music の再生）を止めずに重ねる
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func load(_ name: String) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "m4a"),
              let file = try? AVAudioFile(forReading: url),
              let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: src)) != nil else { return nil }
        if src.format == format { return src }
        // エンジンの形式（44.1kHz ステレオ）にそろえる
        guard let conv = AVAudioConverter(from: src.format, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(src.frameLength) * format.sampleRate / src.format.sampleRate) + 1024) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        return err == nil ? out : nil
    }

    private func start() -> Bool {
        if started { return true }
        do { try engine.start(); started = true } catch { return false }
        return true
    }

    // MARK: 単発

    func play(_ cue: Cue) {
        guard enabled, start() else { return }
        switch cue {
        case .cheer:
            shot(["cheer_small", "cheer_small2"].randomElement()!, volume: 0.8)
            if Bool.random() { shot(whistleName(), volume: 0.55, delay: 0.25) }
        case .bigCheer:
            shot("cheer_big", volume: 1.0)
            shot(whistleName(), volume: 0.7, delay: 0.35)
            shot(["woo", "woo2"].randomElement()!, volume: 0.6, delay: 0.8)
            shot(whistleName(), volume: 0.5, delay: 1.4)
        case .whistle: shot(whistleName(), volume: 0.7, minGap: 0.6)
        case .woo: shot(["woo", "woo2"].randomElement()!, volume: 0.6, minGap: 0.9)
        case .applause: shot("applause", volume: 0.7, minGap: 2.0)
        case .boo: shot("boo", volume: 0.7, minGap: 1.5)
        case .horn: shot("horn", volume: 0.6, minGap: 1.0)
        case .tick: synthShot("tick") { t in 1320 }
        case .drop: synthShot("drop") { t in 140 - 90 * t }
        }
    }

    private func whistleName() -> String { ["whistle", "whistle2"].randomElement()! }

    private func shot(_ name: String, volume: Float, delay: Double = 0, minGap: Double = 0) {
        guard let buf = files[name] else { return }
        if minGap > 0, let last = lastPlayed[name], Date().timeIntervalSince(last) < minGap { return }
        lastPlayed[name] = Date()
        let node = shots[nextShot]
        nextShot = (nextShot + 1) % shots.count
        node.volume = volume
        let when: AVAudioTime? = delay > 0
            ? AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay))
            : nil
        node.scheduleBuffer(buf, at: when, options: .interrupts)
        if !node.isPlaying { node.play() }
    }

    // MARK: 観客のざわめき（ENERGY でしゃべり声 ↔ 歓声を混ぜる）

    func updateCrowd(energy: Double, active: Bool) {
        guard enabled, active else { stopCrowd(); return }
        guard start(), let low = files["amb_low"], let high = files["amb_high"] else { return }
        if !crowdOn {
            crowdOn = true
            for (n, b) in [(ambLow, low), (ambHigh, high)] {
                n.scheduleBuffer(b, at: nil, options: .loops)
                n.play()
            }
        }
        let e = Float(max(0, min(100, energy)) / 100)
        let lowGoal = 0.32 * (1 - e) + 0.05
        let highGoal = max(0, (e - 0.35) / 0.65) * 0.42
        ambLow.volume += (lowGoal - ambLow.volume) * 0.15
        ambHigh.volume += (highGoal - ambHigh.volume) * 0.15
        // 盛り上がっていると、ときどきどこかで指笛
        if e > 0.7, Date() > nextRandomWhistle {
            nextRandomWhistle = Date().addingTimeInterval(Double.random(in: 5...12) * Double(1.3 - e))
            shot(whistleName(), volume: 0.25 + 0.3 * e, minGap: 1.5)
        }
    }

    func stopCrowd() {
        guard crowdOn else { return }
        crowdOn = false
        ambLow.stop()
        ambHigh.stop()
        ambLow.volume = 0
        ambHigh.volume = 0
    }

    // MARK: 振動

    func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: 合図の音（その場で作る）

    private func synthShot(_ key: String, freq: (Double) -> Double) {
        guard enabled, start() else { return }
        let buf: AVAudioPCMBuffer
        if let b = synth[key] {
            buf = b
        } else {
            let seconds = key == "tick" ? 0.07 : 0.9
            let frames = AVAudioFrameCount(seconds * format.sampleRate)
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            b.frameLength = frames
            var phase = 0.0
            for i in 0..<Int(frames) {
                let x = Double(i) / Double(frames)
                phase += 2 * .pi * freq(x) / format.sampleRate
                let v = Float(sin(phase) * min(1, x * 40) * (1 - x) * 0.4)
                b.floatChannelData![0][i] = v
                b.floatChannelData![1][i] = v
            }
            synth[key] = b
            buf = b
        }
        let node = shots[nextShot]
        nextShot = (nextShot + 1) % shots.count
        node.volume = 0.6
        node.scheduleBuffer(buf, at: nil, options: .interrupts)
        if !node.isPlaying { node.play() }
    }
}
