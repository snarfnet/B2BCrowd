import Foundation
import SwiftUI

// ゲームの進行。音楽の再生状態（TrackPlayer）とゲームの状態（phase）は別々に持つ。
// 盛り上がりは音源を解析せず、選曲の速さ・お題・連続成功・投票・LIKE・
// 公式メタデータ（ジャンル名・発売年）・履歴だけで決める。
@MainActor
@Observable
final class GameEngine {
    enum Phase: String, Equatable, Codable {
        case searchingTrack      // 1曲目をまだ選んでいない
        case playing
        case countdown           // 終わり10秒
        case waitingForNextDJ    // 曲が終わったのに次が無い
        case transition          // NEXT TRACK! 演出
        case paused
        case result
    }

    enum Banner: Equatable, Codable {
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
    private var failedIDs = Set<String>()
    private var aiVerdictDone = false
    private var nextAmbient: TimeInterval = 6
    private var reactionBudget: Double = 0
    private var decayLeft: Double = 0
    private var legendaryArmed = true
    private var bannerTask: Task<Void, Never>?

    // 2台対戦
    /// この iPhone で操作する DJ（nil = 1台を2人で回す）
    var localDJ: Int?
    /// 相手の iPhone で進むゲームを写すだけ（音も相手側で鳴る）
    let isMirror: Bool
    /// 写す側：操作を相手へ送る
    var sendCommand: ((LinkCommand) -> Void)?
    /// 鳴らす側：状態が変わるたびに相手へ送る
    var onTick: (() -> Void)?
    private var lastAutoPick: Date = .distantPast

    // AUTO DJ
    /// 曲を探す処理（音楽サービスを知っている AppModel が入れる）
    var autoPicker: ((GameEngine) async -> Track?)?
    private var autoPicking = false
    private var autoDelay: TimeInterval = 6

    init(config: SessionConfig, player: TrackPlayer, mirror: Bool = false) {
        self.config = config
        self.player = player
        self.isMirror = mirror
    }

    /// この iPhone の人が次の曲を選べるか（AUTO DJ の番は選べない）
    var canPickHere: Bool { (localDJ == nil || selector == localDJ) && !config.isAuto(selector) }
    func isAuto(_ dj: Int) -> Bool { config.isAuto(dj) }
    /// AUTO DJ が曲を探している
    var isAutoSearching: Bool { autoPicking }
    /// LIKE・お題の判定は、いま流れている曲の相手 DJ がする
    var canJudgeHere: Bool { localDJ == nil || currentOwner != localDJ }

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
        if isMirror { sendCommand?(.pick(t)); return }
        next = t
        selectedAt = selectionElapsed
        MusicAnalytics.shared.recordSelection(seconds: selectionElapsed, source: t.sourceKind)
        if t.sourceKind == .audius { MusicAnalytics.shared.count(.audiusPick) }
        SoundFX.shared.haptic(.light)
        switch phase {
        case .searchingTrack, .waitingForNextDJ:
            beginTransition()
        default:
            break
        }
    }

    func clearNext() {
        if isMirror { sendCommand?(.clearNext); return }
        guard phase != .transition else { return }
        next = nil
        selectedAt = nil
    }

    func pass() {
        if isMirror { sendCommand?(.pass); return }
        guard next == nil, phase != .transition, phase != .result else { return }
        add(-5, dj: selector, kind: .selection, label: "PASS")
        selector = 1 - selector
        selectionElapsed = 0
        timedOut = false
    }

    // MARK: 観客・相手DJ

    func like() {
        if isMirror { sendCommand?(.like); return }
        guard !likedThisRound, current != nil, phase == .playing || phase == .countdown else { return }
        likedThisRound = true
        add(3, dj: currentOwner, kind: .flow, label: "LIKE ♥ \(name(1 - currentOwner))")
        SoundFX.shared.play(.whistle)
    }

    func judge(_ ok: Bool) {
        if isMirror { sendCommand?(.judge(ok)); return }
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
        if isMirror { sendCommand?(.react(r.rawValue)); return }
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
        if isMirror { sendCommand?(.pause); return }
        guard phase != .paused, phase != .result, phase != .transition else { return }
        resumePhase = phase
        phase = .paused
        player.pause()
    }

    func resume() async {
        if isMirror { sendCommand?(.resume); return }
        guard phase == .paused else { return }
        if resumePhase == .playing || resumePhase == .countdown {
            await player.resume()
        }
        phase = resumePhase
    }

    func quit() { finish(.quit) }

    // MARK: 2台対戦

    /// 相手の iPhone から届いた操作。順番や立場が合わないものは無視する
    func handle(_ c: LinkCommand, from dj: Int) {
        switch c {
        case .pick(let t): if selector == dj { reserve(t) }
        case .clearNext: if selector == dj { clearNext() }
        case .pass: if selector == dj { pass() }
        case .like: if currentOwner != dj { like() }
        case .judge(let ok): if currentOwner != dj { judge(ok) }
        case .react(let r): if let r = Reaction(rawValue: r) { react(r) }
        case .pause: pause()
        case .resume: Task { await resume() }
        }
        onTick?()
    }

    func snapshot() -> LinkSnapshot {
        LinkSnapshot(phase: phase, energy: energy, peakEnergy: peakEnergy, combo: combo, maxCombo: maxCombo,
                     scores: scores, rounds: rounds, current: current, currentOwner: currentOwner, next: next,
                     selector: selector, selectionElapsed: selectionElapsed, trackElapsed: trackElapsed,
                     events: events, reactions: reactions, banner: banner, finishReason: finishReason,
                     likedThisRound: likedThisRound, judgedThisRound: judgedThisRound, playedIDs: Array(playedIDs))
    }

    func apply(_ s: LinkSnapshot) {
        guard isMirror, phase != .result else { return }
        if s.phase == .transition, phase != .transition { SoundFX.shared.play(.drop) }
        energy = s.energy; peakEnergy = s.peakEnergy
        combo = s.combo; maxCombo = s.maxCombo
        scores = s.scores
        if rounds.count != s.rounds.count || rounds.last?.energyEnd != s.rounds.last?.energyEnd { rounds = s.rounds }
        if current?.id != s.current?.id { current = s.current }
        if next?.id != s.next?.id { next = s.next }
        currentOwner = s.currentOwner; selector = s.selector
        selectionElapsed = s.selectionElapsed; trackElapsed = s.trackElapsed
        if events.map(\.id) != s.events.map(\.id) { events = s.events }
        if reactions.map(\.id) != s.reactions.map(\.id) { reactions = s.reactions }
        banner = s.banner
        finishReason = s.finishReason
        likedThisRound = s.likedThisRound; judgedThisRound = s.judgedThisRound
        playedIDs = Set(s.playedIDs)
        phase = s.phase
    }

    /// 相手との接続が切れた
    func partnerLeft() {
        if isMirror {
            finish(.quit)
        } else {
            localDJ = nil
            flash(.notice(L.t("相手の接続が切れました。この iPhone で続けます", "Partner disconnected. Carry on with this iPhone.")), seconds: 4)
        }
    }

    func notice(_ text: String) { flash(.notice(text), seconds: 3) }

    private func mirrorAutopilot() {
        guard autopilot, canPickHere, next == nil, Date().timeIntervalSince(lastAutoPick) > 3,
              phase == .searchingTrack || phase == .waitingForNextDJ || (phase == .playing && selectionElapsed > 4) else { return }
        lastAutoPick = Date()
        if let t = DemoCatalog.tracks.filter({ !playedIDs.contains($0.id) }).randomElement() { reserve(t) }
        if Int.random(in: 0..<2) == 0 { react(.fire) }
    }

    // MARK: 進行

    /// 動作確認・スクショ用。デモ曲を自動で選び、観客も自動で反応する。
    var autopilot = false
    /// autopilot が選ぶ曲（空ならデモ曲）
    var autopilotPool: [Track] = []

    /// AUTO DJ の番：少し考えるふりをしてから（数秒〜十数秒）曲を探して予約する
    private func autoDJStep() {
        guard config.isAuto(selector), next == nil, !autoPicking, let autoPicker,
              phase == .searchingTrack || phase == .waitingForNextDJ || phase == .playing || phase == .countdown else { return }
        let urgent = phase != .playing
        guard urgent || selectionElapsed >= autoDelay else { return }
        autoPicking = true
        let who = selector
        Task { @MainActor in
            let t = await autoPicker(self)
            self.autoPicking = false
            self.autoDelay = Double.random(in: 5...14)
            guard self.selector == who, self.next == nil, self.phase != .result else { return }
            if let t {
                self.reserve(t)
            } else {
                self.flash(.notice(L.t("AUTO：候補の曲が見つかりません", "AUTO: no track found")))
                self.pass()
            }
        }
    }

    private func autopilotStep() {
        if next == nil, canPickHere, phase != .transition, phase != .paused, phase != .result,
           phase == .searchingTrack || phase == .waitingForNextDJ || selectionElapsed > 4 {
            let pool = autopilotPool.isEmpty ? DemoCatalog.tracks : autopilotPool
            if let t = pool.filter({ !playedIDs.contains($0.id) && !failedIDs.contains($0.id) }).randomElement() { reserve(t) }
        }
        guard phase == .playing || phase == .countdown else { return }
        if Int.random(in: 0..<5) == 0 { react([Reaction.fire, .heart, .clap].randomElement()!) }
        if needsJudge, canJudgeHere, trackElapsed > 3 { judge(true) }
        if !likedThisRound, canJudgeHere, trackElapsed > 5 { like() }
    }

    func tick(_ dt: TimeInterval) {
        if isMirror {
            // 音（曲・歓声）は鳴らす側の iPhone だけ
            mirrorAutopilot()
            return
        }
        defer { onTick?() }
        if autopilot { autopilotStep() }
        autoDJStep()
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

        MusicAnalytics.shared.count(.playAttempt)
        do {
            try await player.play(t)
        } catch {
            // 再生できない曲（地域制限・アクセス制限・通信エラーなど）は罰なしで選び直し。セッションは続ける
            MusicAnalytics.shared.count(.playError)
            failedIDs.insert(t.id)
            current = nil
            selector = owner
            selectionElapsed = 0
            timedOut = true
            phase = .waitingForNextDJ
            let reason = (error as? AudiusError)?.errorDescription ?? (error as? LinkError)?.errorDescription
            flash(.notice(reason ?? L.t("この曲は再生できません。選び直してください", "This track can't play. Pick another.")), seconds: 3.5)
            return
        }
        MusicAnalytics.shared.count(.playSuccess)

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
        onTick?()
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
