import Foundation
import SwiftUI

// ゲームの進行。音楽の再生状態（TrackPlayer）とゲームの状態（phase）は別々に持つ。
// 盛り上がりは音源を解析せず、選曲の速さ・お題・連続成功・投票・LIKE・
// 公式メタデータ（ジャンル名・発売年）・履歴だけで決める。
@MainActor
@Observable
final class GameEngine {
    enum Phase: Equatable {
        case searchingTrack      // 1曲目をまだ選んでいない
        case playing
        case countdown           // 終わり10秒
        case waitingForNextDJ    // 曲が終わったのに次が無い
        case transition          // NEXT TRACK! 演出
        case paused
        case result
    }

    enum Banner: Equatable {
        case combo(Int)
        case legendary
        case floorEmpty
        case timeUp(String)
        case notice(String)
    }

    // 設定
    let config: SessionConfig
    private let player: TrackPlayer

    // 状態
    private(set) var phase: Phase = .searchingTrack
    private var resumePhase: Phase = .playing
    private(set) var energy: Double = 50
    private(set) var peakEnergy: Double = 50
    private(set) var combo = 0
    private(set) var maxCombo = 0
    private(set) var scores = [ScoreCard(), ScoreCard()]
    private(set) var rounds: [RoundRecord] = []
    private(set) var current: Track?
    private(set) var currentOwner = 0
    private(set) var next: Track?
    private(set) var selector = 0             // いま次の曲を選ぶ DJ
    private(set) var selectionElapsed: TimeInterval = 0
    private(set) var trackElapsed: TimeInterval = 0
    private(set) var events: [FloatEvent] = []
    private(set) var reactions: [FloatEvent] = []
    private(set) var banner: Banner?
    private(set) var finishReason: FinishReason?
    private(set) var likedThisRound = false
    private(set) var judgedThisRound = false

    private var selectedAt: TimeInterval?
    private var timedOut = false
    private var playedIDs = Set<String>()
    private var aiVerdictDone = false
    private var nextAmbient: TimeInterval = 6
    private var reactionBudget: Double = 0
    private var decayLeft: Double = 0
    private var legendaryArmed = true
    private var bannerTask: Task<Void, Never>?

    init(config: SessionConfig, player: TrackPlayer) {
        self.config = config
        self.player = player
    }

    // MARK: 表示用

    var tier: EnergyTier { EnergyTier(energy) }
    var tracksPlayed: Int { rounds.count }
    var nextOwner: Int { selector }
    var isLastTrack: Bool { config.length > 0 && tracksPlayed >= config.length }

    var trackLength: TimeInterval {
        let full = current?.duration ?? 240
        return config.playLimit > 0 ? min(full, TimeInterval(config.playLimit)) : full
    }

    var remaining: TimeInterval { max(0, trackLength - trackElapsed) }

    var selectionTimeLeft: TimeInterval? {
        guard config.mode == .timeAttack, next == nil else { return nil }
        return max(0, TimeInterval(config.timeLimit) - selectionElapsed)
    }

    var needsJudge: Bool {
        (config.mode == .theme || config.mode == .shiritori) && current != nil
            && !judgedThisRound && rounds.count > (config.mode == .shiritori ? 1 : 0)
            && (phase == .playing || phase == .countdown)
    }

    var showsPad: Bool { config.crowd != .ai }

    func name(_ dj: Int) -> String { config.djNames[dj] }

    func wasPlayed(_ t: Track) -> Bool { playedIDs.contains(t.id) }

    // MARK: 選曲

    func reserve(_ t: Track) {
        next = t
        selectedAt = selectionElapsed
        SoundFX.shared.haptic(.light)
        switch phase {
        case .searchingTrack, .waitingForNextDJ:
            beginTransition()
        default:
            break
        }
    }

    func clearNext() {
        guard phase != .transition else { return }
        next = nil
        selectedAt = nil
    }

    func pass() {
        guard next == nil, phase != .transition, phase != .result else { return }
        add(-5, dj: selector, kind: .selection, label: "PASS")
        selector = 1 - selector
        selectionElapsed = 0
        timedOut = false
    }

    // MARK: 観客・相手DJ

    func like() {
        guard !likedThisRound, current != nil, phase == .playing || phase == .countdown else { return }
        likedThisRound = true
        add(3, dj: currentOwner, kind: .flow, label: "LIKE ♥ \(name(1 - currentOwner))")
        SoundFX.shared.play(.whistle)
    }

    func judge(_ ok: Bool) {
        guard needsJudge else { return }
        judgedThisRound = true
        let tag = config.mode == .shiritori ? L.t("繋がった", "LINKED") : L.t("テーマ一致", "THEME MATCH")
        if ok {
            add(8, dj: currentOwner, kind: .selection, label: tag)
            SoundFX.shared.play(.cheer)
        } else {
            add(-10, dj: currentOwner, kind: .selection, label: L.t("テーマ違反", "OFF THEME"))
            SoundFX.shared.play(.boo)
        }
    }

    func react(_ r: Reaction) {
        guard current != nil, phase == .playing || phase == .countdown else { return }
        reactions.append(FloatEvent(text: r.rawValue, value: 0))
        trimFeeds()
        switch r {
        case .fire: SoundFX.shared.play(.woo)
        case .heart: SoundFX.shared.play(.whistle)
        case .clap: SoundFX.shared.play(.applause)
        case .boo: SoundFX.shared.play(.boo)
        case .meh: break
        }
        // 連打で無限に上がらないよう、1曲あたりの上げ幅に上限
        var v = r.energy
        if v > 0 {
            v = min(v, max(0, 18 - reactionBudget))
            reactionBudget += v
        }
        if v != 0 { add(v, dj: currentOwner, kind: .crowd, label: nil) }
    }

    // MARK: 一時停止

    func pause() {
        guard phase != .paused, phase != .result, phase != .transition else { return }
        resumePhase = phase
        phase = .paused
        player.pause()
    }

    func resume() async {
        guard phase == .paused else { return }
        if resumePhase == .playing || resumePhase == .countdown {
            await player.resume()
        }
        phase = resumePhase
    }

    func quit() { finish(.quit) }

    // MARK: 進行

    /// 動作確認・スクショ用。デモ曲を自動で選び、観客も自動で反応する。
    var autopilot = false

    private func autopilotStep() {
        if next == nil, phase != .transition, phase != .paused, phase != .result,
           phase == .searchingTrack || phase == .waitingForNextDJ || selectionElapsed > 4 {
            if let t = DemoCatalog.tracks.filter({ !playedIDs.contains($0.id) }).randomElement() { reserve(t) }
        }
        guard phase == .playing || phase == .countdown else { return }
        if Int.random(in: 0..<5) == 0 { react([Reaction.fire, .heart, .clap].randomElement()!) }
        if needsJudge, trackElapsed > 3 { judge(true) }
        if !likedThisRound, trackElapsed > 5 { like() }
    }

    func tick(_ dt: TimeInterval) {
        if autopilot { autopilotStep() }
        SoundFX.shared.updateCrowd(energy: energy, active: phase != .paused && phase != .result)
        switch phase {
        case .playing, .countdown:
            if player.isInterrupted {
                pause()
                flash(.notice(L.t("中断されました。再開をタップ", "Interrupted. Tap resume.")))
                return
            }
            trackElapsed = player.elapsed
            let wasCountdown = phase == .countdown
            phase = remaining <= 10 ? .countdown : .playing
            if phase == .countdown, !wasCountdown { SoundFX.shared.play(.tick) }

            // ENERGY は放っておくと少しずつ落ちる（1曲ぶんで合計 decayLeft）
            let step = decayLeft * min(1, dt / max(1, remaining + dt))
            decayLeft -= step
            setEnergy(energy - step)

            aiCrowd()
            tickSelection(dt)

            let nearEnd = trackElapsed >= trackLength - 0.3
            let endedByItself = trackElapsed > 3 && player.hasStopped
            if nearEnd || endedByItself { endTrack() }

        case .waitingForNextDJ:
            setEnergy(energy - 1.2 * dt)
            tickSelection(dt)
            checkSurvival()

        default:
            break
        }
    }

    private func tickSelection(_ dt: TimeInterval) {
        guard next == nil else { return }
        selectionElapsed += dt
        if config.mode == .timeAttack, !timedOut, selectionElapsed >= TimeInterval(config.timeLimit) {
            timeout()
        }
    }

    private func timeout() {
        timedOut = true
        add(-10, dj: selector, kind: .speed, label: "TIME UP")
        flash(.timeUp(name(selector)))
        SoundFX.shared.play(.boo)
    }

    private func endTrack() {
        closeRound()
        if phase == .result { return }
        if isLastTrack {
            finish(.complete)
            return
        }
        if next != nil {
            beginTransition()
        } else {
            player.stop()
            phase = .waitingForNextDJ
            if !timedOut { timeout() }
        }
    }

    private func closeRound() {
        guard var r = rounds.popLast() else { return }
        r.energyEnd = energy
        rounds.append(r)
        if r.gained >= 6 {
            combo += 1
            maxCombo = max(maxCombo, combo)
            if combo >= 2 {
                add(5, dj: r.dj, kind: .flow, label: "COMBO x\(combo)")
                flash(.combo(combo))
                SoundFX.shared.play(combo >= 10 ? .bigCheer : .cheer)
                SoundFX.shared.play(.applause)
                if combo >= 10 || combo % 5 == 0 { SoundFX.shared.play(.horn) }
                SoundFX.shared.haptic(combo >= 10 ? .heavy : .medium)
            }
        } else {
            combo = 0
        }
    }

    private func beginTransition() {
        guard next != nil else { return }
        phase = .transition
        SoundFX.shared.play(.drop)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            await self.startNext()
        }
    }

    private func startNext() async {
        guard phase == .transition, let t = next else { return }
        let owner = selector
        next = nil
        current = t
        currentOwner = owner
        trackElapsed = 0
        likedThisRound = false
        judgedThisRound = false
        aiVerdictDone = false
        reactionBudget = 0
        nextAmbient = 5
        decayLeft = 6 + energy * 0.1

        do {
            try await player.play(t)
        } catch {
            // 再生できない曲（地域制限・カタログ削除など）は罰なしで選び直し
            current = nil
            selector = owner
            selectionElapsed = 0
            timedOut = true
            phase = .waitingForNextDJ
            flash(.notice(L.t("この曲は再生できません。選び直してください", "This track can't play. Pick another.")))
            return
        }

        rounds.append(RoundRecord(number: rounds.count + 1, dj: owner, track: t, energyStart: energy, energyEnd: energy))
        scoreSelection(t, owner: owner)
        playedIDs.insert(t.id)

        selector = 1 - owner
        selectionElapsed = 0
        selectedAt = nil
        timedOut = false
        phase = .playing
    }

    private func scoreSelection(_ t: Track, owner: Int) {
        let prev = rounds.dropLast().last?.track

        if playedIDs.contains(t.id) {
            add(-20, dj: owner, kind: .selection, label: L.t("同じ曲", "REPEAT"))
            return
        }
        if config.mode == .genre {
            if config.genre.matches(t) {
                add(8, dj: owner, kind: .selection, label: config.genre.id)
            } else {
                add(-10, dj: owner, kind: .selection, label: L.t("ジャンル違い", "OFF GENRE"))
            }
        }
        if let at = selectedAt, prev != nil, at <= 20 {
            add(3, dj: owner, kind: .speed, label: "QUICK PICK")
        }
        if let prev {
            if prev.artist == t.artist {
                add(-3, dj: owner, kind: .flow, label: L.t("同じアーティスト", "SAME ARTIST"))
            } else if config.mode != .genre, !Set(prev.genres).isDisjoint(with: t.genres) {
                add(4, dj: owner, kind: .flow, label: "FLOW")
            }
        }
    }

    // ルールで動く AI 観客。生成 AI は使わない。
    private func aiCrowd() {
        guard config.crowd != .player, let r = rounds.last else { return }
        let progress = trackElapsed / max(1, trackLength)

        if trackElapsed >= nextAmbient {
            nextAmbient = trackElapsed + Double.random(in: 4...8)
            let mood = (energy - 40) / 60 + Double(combo) * 0.05
            let pick: Reaction = mood > 0.6 ? .fire : mood > 0.3 ? .heart : mood > 0 ? .clap : .meh
            reactions.append(FloatEvent(text: pick.rawValue, value: 0))
            trimFeeds()
        }

        guard !aiVerdictDone, progress >= 0.5 else { return }
        aiVerdictDone = true
        var s = 0.5
        s += min(0.2, (energy - r.energyStart) / 40)
        s += min(0.15, Double(combo) * 0.04)
        if likedThisRound { s += 0.1 }
        if playedIDs.contains(r.track.id) && rounds.filter({ $0.track.id == r.track.id }).count > 1 { s -= 0.3 }
        s += Double.random(in: -0.22...0.22)
        let weight = config.crowd == .mix ? 0.6 : 1.0
        if s > 0.62 {
            add(10 * weight, dj: r.dj, kind: .crowd, label: L.t("観客高評価", "CROWD LOVES IT"))
            SoundFX.shared.play(.cheer)
        } else if s < 0.32 {
            add(-6 * weight, dj: r.dj, kind: .crowd, label: L.t("観客が冷めた", "CROWD COOLING"))
            SoundFX.shared.play(.boo)
        } else {
            add(3 * weight, dj: r.dj, kind: .crowd, label: L.t("観客ノリノリ", "CROWD GROOVING"))
            SoundFX.shared.play(.woo)
        }
    }

    // MARK: ENERGY とスコア

    private func add(_ v: Double, dj: Int, kind: ScoreKind, label: String?) {
        scores[dj][kind] += Int((v * 10).rounded())
        setEnergy(energy + v)
        if let label {
            events.append(FloatEvent(text: label, value: Int(v.rounded())))
            trimFeeds()
        }
        checkSurvival()
    }

    private func setEnergy(_ e: Double) {
        energy = min(100, max(0, e))
        peakEnergy = max(peakEnergy, energy)
        if energy >= 99.5, legendaryArmed {
            legendaryArmed = false
            flash(.legendary, seconds: 4)
            SoundFX.shared.play(.horn)
            SoundFX.shared.play(.bigCheer)
            SoundFX.shared.success()
            if config.mode == .challenge {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    self.finish(.legendary)
                }
            }
        } else if energy < 90 {
            legendaryArmed = true
        }
    }

    private func checkSurvival() {
        guard config.mode == .survival, energy <= 0, phase != .result else { return }
        flash(.floorEmpty, seconds: 3)
        finish(.floorEmpty)
    }

    private func flash(_ b: Banner, seconds: Double = 2.2) {
        banner = b
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self.banner = nil }
        }
    }

    private func trimFeeds() {
        let now = Date()
        events.removeAll { now.timeIntervalSince($0.born) > 3 }
        reactions.removeAll { now.timeIntervalSince($0.born) > 3 }
    }

    private func finish(_ reason: FinishReason) {
        guard phase != .result else { return }
        if let r = rounds.last, r.energyEnd == r.energyStart, current != nil {
            rounds[rounds.count - 1].energyEnd = energy
        }
        player.stop()
        SoundFX.shared.stopCrowd()
        finishReason = reason
        phase = .result
    }

    // MARK: リザルト

    var bestRound: RoundRecord? { rounds.max { $0.gained < $1.gained } }

    func title(for dj: Int) -> String {
        DJTitle.forPeak(peakEnergy, score: scores[dj].total)
    }

    var winner: Int? {
        if scores[0].total == scores[1].total { return nil }
        return scores[0].total > scores[1].total ? 0 : 1
    }
}
