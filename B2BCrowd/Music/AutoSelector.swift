import Foundation

// AUTO DJ の選曲。音は解析せず、いまの曲のジャンル名・アーティスト・モードのルール（ジャンル／お題）だけで候補を集める。
// まだかけていない・再生できる曲から、流れが続きそうな曲（同じジャンルで別アーティスト）を優先して選ぶ。
@MainActor
enum AutoSelector {
    static func pick(for game: GameEngine, music: MusicService) async -> Track? {
        let pool = await candidates(game, music)
        let fresh = pool.filter { !game.wasPlayed($0) && $0.id != game.current?.id }
        guard !fresh.isEmpty else { return nil }
        return fresh.max { score($0, game) < score($1, game) }
    }

    /// 高いほど選ばれやすい。少しだけ揺らぎを入れて毎回同じにならないようにする
    private static func score(_ t: Track, _ game: GameEngine) -> Double {
        var s = Double.random(in: 0...1.5)
        let c = game.config
        if c.mode == .genre { s += c.genre.matches(t) ? 5 : -5 }
        if let cur = game.current {
            if !Set(cur.genres).isDisjoint(with: t.genres) { s += 2 }
            if cur.artist == t.artist { s -= 2 }
        }
        if let d = t.duration, d < 60 { s -= 1 }
        return s
    }

    private static func candidates(_ game: GameEngine, _ music: MusicService) async -> [Track] {
        let c = game.config
        if music.demoMode { return DemoCatalog.tracks }

        // 探す言葉：ジャンル縛り > お題 > いまの曲のジャンル > いまの曲のアーティスト
        var terms: [String] = []
        switch c.mode {
        case .genre: terms.append(c.genre.id)
        case .theme: terms.append(c.theme)
        case .shiritori: if let cur = game.current { terms.append(cur.artist) }
        default: break
        }
        if let g = game.current?.genres.first { terms.append(g) }
        if terms.isEmpty { terms.append(c.mode == .genre ? c.genre.id : "dance") }

        if music.source == .audius {
            let g = (game.current?.genres.first ?? (c.mode == .genre ? c.genre.id : "")).lowercased()
            let cat = AudiusTrendingCategory.all.first { $0.genre?.lowercased() == g || $0.title.lowercased() == g }
                ?? AudiusTrendingCategory.all[c.mode == .genre ? 0 : 1]
            var list = (try? await music.trendingAudius(cat)) ?? []
            if c.mode == .theme || c.mode == .shiritori, let q = terms.first {
                list = ((try? await music.searchAudius(q)) ?? []) + list
            }
            var ok: [Track] = []
            for t in list where await music.audiusPlayability(t).isPlayable { ok.append(t) }
            return ok
        }

        var all: [Track] = []
        for q in terms.prefix(2) {
            all += (try? await music.search(q)) ?? []
            if all.count >= 15 { break }
        }
        if all.isEmpty { all = (try? await music.library()) ?? [] }
        return all
    }
}
