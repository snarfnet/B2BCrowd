import Foundation

struct DJProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var icon: String = "🎧"
    var xp = 0
    var sessions = 0
    var bestEnergy = 0
    var bestCombo = 0
    var bestScore = 0
    var genreCounts: [String: Int] = [:]
    var achievements: [String] = []

    var level: Int { xp / 400 + 1 }
    var favoriteGenre: String? { genreCounts.max { $0.value < $1.value }?.key }

    var title: String {
        if achievements.contains(Achievement.legend.rawValue) { return "FLOOR LEGEND" }
        if bestEnergy >= 90 { return "CROWD MASTER" }
        if sessions >= 10 { return "B2B MASTER" }
        if bestEnergy >= 70 { return "FLOOR MAKER" }
        if sessions >= 1 { return "SELECTOR" }
        return "BEGINNER DJ"
    }
}

enum Achievement: String, CaseIterable {
    case firstSession, combo5, combo10, legend, survivor, quickHands, tenSessions

    var title: String {
        switch self {
        case .firstSession: return L.t("初B2B", "First B2B")
        case .combo5: return "5 COMBO"
        case .combo10: return "10 COMBO"
        case .legend: return "LEGENDARY FLOOR"
        case .survivor: return L.t("生還者（SURVIVAL完走）", "Survivor")
        case .quickHands: return L.t("早撃ち（TIME ATTACK完走）", "Quick Hands")
        case .tenSessions: return L.t("10セッション", "10 Sessions")
        }
    }
}

@MainActor
@Observable
final class ProfileStore {
    private(set) var profiles: [DJProfile] = []
    private let key = "djProfiles.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let p = try? JSONDecoder().decode([DJProfile].self, from: d) {
            profiles = p
        }
    }

    func profile(named name: String) -> DJProfile? {
        profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func upsert(_ p: DJProfile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) {
            profiles[i] = p
        } else {
            profiles.append(p)
        }
        save()
    }

    func delete(_ p: DJProfile) {
        profiles.removeAll { $0.id == p.id }
        save()
    }

    /// セッション終了時に両 DJ の記録を更新し、新しく取れた実績を返す
    @discardableResult
    func record(_ game: GameEngine) -> [String: [Achievement]] {
        var unlocked: [String: [Achievement]] = [:]
        for dj in 0..<2 {
            let name = game.name(dj)
            var p = profile(named: name) ?? DJProfile(name: name)
            let before = Set(p.achievements)
            let score = game.scores[dj].total
            p.sessions += 1
            let myTracks: Int = game.rounds.filter { $0.dj == dj }.count
            let gainedXP: Int = score / 2 + myTracks * 30
            p.xp += max(50, gainedXP)
            p.bestEnergy = max(p.bestEnergy, Int(game.peakEnergy.rounded()))
            p.bestCombo = max(p.bestCombo, game.maxCombo)
            p.bestScore = max(p.bestScore, score)
            for r in game.rounds where r.dj == dj {
                for g in r.track.genres { p.genreCounts[g, default: 0] += 1 }
            }
            var got: [Achievement] = [.firstSession]
            if game.maxCombo >= 5 { got.append(.combo5) }
            if game.maxCombo >= 10 { got.append(.combo10) }
            if game.peakEnergy >= 99.5 { got.append(.legend) }
            if game.config.mode == .survival, game.finishReason == .complete { got.append(.survivor) }
            if game.config.mode == .timeAttack, game.finishReason == .complete { got.append(.quickHands) }
            if p.sessions >= 10 { got.append(.tenSessions) }
            for a in got where !before.contains(a.rawValue) { p.achievements.append(a.rawValue) }
            unlocked[name] = got.filter { !before.contains($0.rawValue) }
            upsert(p)
        }
        return unlocked
    }

    private func save() {
        if let d = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
}
