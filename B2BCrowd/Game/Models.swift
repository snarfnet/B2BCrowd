import Foundation
import MusicKit
import SwiftUI

// 言語の切り替え：端末の第一言語が日本語→日本語、中国語（簡体／繁体）→中国語、それ以外は英語。
// 中国語は L.t(日本語, 英語, hans:, hant:)（tools/loc_extract.py で差し込む）。無ければ英語。
enum L {
    enum Lang { case ja, en, hans, hant }
    static let lang: Lang = {
        let p = Locale.preferredLanguages.first ?? "en"
        if p.hasPrefix("ja") { return .ja }
        if p.hasPrefix("zh-Hant") || p.hasPrefix("zh-TW") || p.hasPrefix("zh-HK") || p.hasPrefix("zh-MO") { return .hant }
        if p.hasPrefix("zh") { return .hans }
        return .en
    }()
    static let isJA: Bool = lang == .ja
    static func t(_ ja: String, _ en: String, hans: String? = nil, hant: String? = nil) -> String {
        switch lang {
        case .ja: return ja
        case .en: return en
        case .hans: return hans ?? en
        case .hant: return hant ?? hans ?? en
        }
    }
}

// MARK: - Track

enum TrackSource {
    case appleMusic(Song)
    case audius(AudiusTrack)
    case demo(hue: Double)
    /// 2台対戦で相手の iPhone から届いた Apple Music の曲（id だけ。鳴らす側でカタログから引き直す）
    case appleMusicRef
}

// 選曲に使う音楽サービス。ゲーム側は Track と TrackPlayer だけを見るので、ここを増やせば別サービスも足せる。
enum MusicSourceKind: String, CaseIterable, Identifiable, Codable {
    case appleMusic, audius

    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleMusic: return "APPLE MUSIC"
        case .audius: return "AUDIUS"
        }
    }
}

struct Track: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let genres: [String]
    let releaseYear: Int?
    let duration: TimeInterval?
    let artworkURL: URL?
    let source: TrackSource

    static func == (l: Track, r: Track) -> Bool { l.id == r.id }

    var isDemo: Bool {
        if case .demo = source { return true }
        return false
    }

    var sourceKind: MusicSourceKind? {
        switch source {
        case .appleMusic, .appleMusicRef: return .appleMusic
        case .audius: return .audius
        case .demo: return nil
        }
    }

    /// 元サービスの曲ページ（Audius は帰属表示として必ず出す）
    var externalURL: URL? {
        if case .audius(let a) = source { return a.webURL }
        return nil
    }

    var audius: AudiusTrack? {
        if case .audius(let a) = source { return a }
        return nil
    }

    var demoHue: Double {
        if case .demo(let h) = source { return h }
        return Double(abs(id.hashValue) % 360) / 360
    }
}

extension Track {
    init(song: Song) {
        let ignored: Set<String> = ["Music", "ミュージック"]
        self.init(
            id: song.id.rawValue,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            genres: song.genreNames.filter { !ignored.contains($0) },
            releaseYear: song.releaseDate.map { Calendar.current.component(.year, from: $0) },
            duration: song.duration,
            artworkURL: song.artwork?.url(width: 600, height: 600),
            source: .appleMusic(song)
        )
    }
}

extension Track {
    init(audius a: AudiusTrack) {
        self.init(
            id: "audius:" + a.id,
            title: a.title,
            artist: a.user.name,
            album: "",
            genres: a.genre.map { [$0] } ?? [],
            releaseYear: a.releaseYear,
            duration: a.duration.map(TimeInterval.init),
            artworkURL: (a.artwork?.medium).flatMap(URL.init(string:)),
            source: .audius(a)
        )
    }
}

// 2台対戦で送る形。Apple Music の Song は送れないので id と表示用の情報だけ。
extension Track: Codable {
    private enum K: String, CodingKey { case id, title, artist, album, genres, year, duration, art, kind, audius, hue }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let src: TrackSource
        switch try c.decode(String.self, forKey: .kind) {
        case "audius": src = .audius(try c.decode(AudiusTrack.self, forKey: .audius))
        case "demo": src = .demo(hue: try c.decode(Double.self, forKey: .hue))
        default: src = .appleMusicRef
        }
        self.init(id: try c.decode(String.self, forKey: .id),
                  title: try c.decode(String.self, forKey: .title),
                  artist: try c.decode(String.self, forKey: .artist),
                  album: try c.decode(String.self, forKey: .album),
                  genres: try c.decode([String].self, forKey: .genres),
                  releaseYear: try c.decodeIfPresent(Int.self, forKey: .year),
                  duration: try c.decodeIfPresent(TimeInterval.self, forKey: .duration),
                  artworkURL: try c.decodeIfPresent(URL.self, forKey: .art),
                  source: src)
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(album, forKey: .album)
        try c.encode(genres, forKey: .genres)
        try c.encodeIfPresent(releaseYear, forKey: .year)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(artworkURL, forKey: .art)
        switch source {
        case .audius(let a):
            try c.encode("audius", forKey: .kind)
            try c.encode(a, forKey: .audius)
        case .demo(let h):
            try c.encode("demo", forKey: .kind)
            try c.encode(h, forKey: .hue)
        case .appleMusic, .appleMusicRef:
            try c.encode("appleMusic", forKey: .kind)
        }
    }
}

// MARK: - Modes

enum GameMode: String, CaseIterable, Identifiable, Codable {
    case free, genre, theme, shiritori, secret, timeAttack, survival, challenge

    var id: String { rawValue }
    /// 設定画面での名前
    var label: String {
        switch self {
        case .free: return L.t("フリー B2B", "FREE B2B", hans: "自由 B2B", hant: "自由 B2B")
        case .genre: return L.t("ジャンル縛り", "GENRE BATTLE", hans: "风格限定", hant: "曲風限定")
        case .theme: return L.t("お題バトル", "THEME BATTLE", hans: "主题对决", hant: "主題對決")
        case .shiritori: return L.t("DJしりとり", "DJ SHIRITORI", hans: "DJ 接龙", hant: "DJ 接龍")
        case .secret: return L.t("シークレット", "SECRET TRACK", hans: "秘密曲目", hant: "秘密曲目")
        case .timeAttack: return L.t("タイムアタック", "TIME ATTACK", hans: "限时挑战", hant: "限時挑戰")
        case .survival: return L.t("サバイバル", "SURVIVAL", hans: "生存模式", hant: "生存模式")
        case .challenge: return L.t("100%チャレンジ", "100% CHALLENGE", hans: "100%挑战", hant: "100%挑戰")
        }
    }

    var title: String {
        switch self {
        case .free: return "FREE B2B"
        case .genre: return "GENRE BATTLE"
        case .theme: return "THEME BATTLE"
        case .shiritori: return "DJ SHIRITORI"
        case .secret: return "SECRET TRACK"
        case .timeAttack: return "TIME ATTACK"
        case .survival: return "SURVIVAL"
        case .challenge: return "100% CHALLENGE"
        }
    }

    var blurb: String {
        switch self {
        case .free: return L.t("縛りなし。好きな曲で返し合う。", "No rules. Answer each other with any track.", hans: "没有限制。用喜欢的歌互相接招。", hant: "沒有限制。用喜歡的歌互相接招。")
        case .genre: return L.t("決めたジャンルの曲だけで勝負。Apple Music のジャンル情報で判定。", "Stay inside one genre. Judged by Apple Music genre data.", hans: "只用选定风格的歌对决。根据 Apple Music 的风格信息判定。", hant: "只用選定曲風的歌對決。依 Apple Music 的曲風資訊判定。")
        case .theme: return L.t("お題に合う曲で返す。合ってるかは相手DJが判定。", "Pick tracks that fit the theme. Your partner judges.", hans: "用符合主题的歌接招。是否符合由对方 DJ 判定。", hant: "用符合主題的歌接招。是否符合由對方 DJ 判定。")
        case .shiritori: return L.t("前の曲から連想した曲で返す。繋がりは相手DJが判定。", "Answer with a track linked to the last one. Your partner judges.", hans: "用从上一首联想到的歌接招。关联由对方 DJ 判定。", hant: "用從上一首聯想到的歌接招。關聯由對方 DJ 判定。")
        case .secret: return L.t("次の曲は切り替わるまで相手に秘密。", "Your next track stays hidden until it drops.", hans: "下一首在切换前对对方保密。", hant: "下一首在切換前對對方保密。")
        case .timeAttack: return L.t("制限時間内に次の曲を決める。", "Lock in your next track before the timer runs out.", hans: "在限定时间内决定下一首。", hant: "在時限內決定下一首。")
        case .survival: return L.t("ENERGY が 0 になったらフロアが空っぽ。GAME OVER。", "If ENERGY hits 0, the floor empties. Game over.", hans: "ENERGY 归 0 时舞池就空了。GAME OVER。", hant: "ENERGY 歸 0 時舞池就空了。GAME OVER。")
        case .challenge: return L.t("選曲だけで ENERGY 100 を目指す。", "Push the floor to 100 with selection alone.", hans: "只靠选曲把 ENERGY 推到 100。", hant: "只靠選曲把 ENERGY 推到 100。")
        }
    }

    var symbol: String {
        switch self {
        case .free: return "arrow.left.arrow.right"
        case .genre: return "square.stack.3d.up"
        case .theme: return "sparkles"
        case .shiritori: return "link"
        case .secret: return "eye.slash"
        case .timeAttack: return "timer"
        case .survival: return "heart.slash"
        case .challenge: return "flame"
        }
    }
}

struct GenreRule: Identifiable, Hashable {
    let id: String
    let keywords: [String]
    let years: ClosedRange<Int>?

    func matches(_ t: Track) -> Bool {
        if let years, let y = t.releaseYear { return years.contains(y) }
        if years != nil { return false }
        let g = t.genres.joined(separator: " ").lowercased()
        return keywords.contains { g.contains($0) }
    }

    static let all: [GenreRule] = [
        GenreRule(id: "TECHNO", keywords: ["techno", "テクノ"], years: nil),
        GenreRule(id: "HOUSE", keywords: ["house", "ハウス"], years: nil),
        GenreRule(id: "TRANCE", keywords: ["trance", "トランス"], years: nil),
        GenreRule(id: "PSYTRANCE", keywords: ["psy", "goa", "サイケ", "トランス", "trance"], years: nil),
        GenreRule(id: "ELECTRONIC", keywords: ["electronic", "dance", "エレクトロ", "ダンス"], years: nil),
        GenreRule(id: "HIP HOP", keywords: ["hip-hop", "hip hop", "rap", "ヒップホップ", "ラップ"], years: nil),
        GenreRule(id: "R&B", keywords: ["r&b", "soul", "ソウル"], years: nil),
        GenreRule(id: "ROCK", keywords: ["rock", "ロック"], years: nil),
        GenreRule(id: "METAL", keywords: ["metal", "メタル"], years: nil),
        GenreRule(id: "J-POP", keywords: ["j-pop", "jpop", "歌謡"], years: nil),
        GenreRule(id: "ANIME", keywords: ["anime", "アニメ"], years: nil),
        GenreRule(id: "DISCO", keywords: ["disco", "ディスコ"], years: nil),
        GenreRule(id: "80s", keywords: [], years: 1980...1989),
        GenreRule(id: "90s", keywords: [], years: 1990...1999),
        GenreRule(id: "00s", keywords: [], years: 2000...2009),
    ]
}

enum Themes {
    static var all: [String] {
        L.isJA
            ? ["夜", "夏", "冬", "失恋", "宇宙", "雨", "ドライブ", "ラスボス感", "朝帰り", "祭り"]
            : ["Night", "Summer", "Winter", "Heartbreak", "Space", "Rain", "Drive", "Final Boss", "Sunrise", "Festival"]
    }
}

enum CrowdMode: String, CaseIterable, Identifiable, Codable {
    case ai, player, mix
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ai: return L.t("AI 観客", "AI", hans: "AI 观众", hant: "AI 觀眾")
        case .player: return L.t("周りの人", "PLAYER", hans: "周围的人", hant: "身邊的人")
        case .mix: return L.t("両方", "MIX", hans: "混合", hant: "混合")
        }
    }
    var title: String {
        switch self {
        case .ai: return "AI"
        case .player: return "PLAYER"
        case .mix: return "MIX"
        }
    }
}

// MARK: - Venue

enum Venue: String, CaseIterable, Identifiable, Codable {
    case smallClub, underground, warehouse, rooftop, beach, tokyoNight, cyberClub, megaFestival, spaceClub, forestRave, recordShop, shibuyaStreet, cruiseDeck
    var id: String { rawValue }
    var label: String {
        switch self {
        case .smallClub: return L.t("小さなクラブ", "SMALL CLUB", hans: "小型俱乐部", hant: "小型夜店")
        case .underground: return L.t("地下クラブ", "UNDERGROUND", hans: "地下俱乐部", hant: "地下夜店")
        case .warehouse: return L.t("倉庫レイヴ", "WAREHOUSE", hans: "仓库锐舞", hant: "倉庫派對")
        case .rooftop: return L.t("屋上", "ROOFTOP", hans: "屋顶", hant: "屋頂")
        case .beach: return L.t("ビーチ", "BEACH", hans: "海滩", hant: "海灘")
        case .tokyoNight: return L.t("東京の夜", "TOKYO NIGHT", hans: "东京之夜", hant: "東京之夜")
        case .cyberClub: return L.t("サイバークラブ", "CYBER CLUB", hans: "赛博俱乐部", hant: "賽博夜店")
        case .megaFestival: return L.t("巨大フェス", "MEGA FESTIVAL", hans: "超大音乐节", hant: "超大音樂祭")
        case .spaceClub: return L.t("宇宙クラブ", "SPACE CLUB", hans: "太空俱乐部", hant: "太空夜店")
        case .forestRave: return L.t("森のレイヴ", "FOREST RAVE", hans: "森林锐舞", hant: "森林派對")
        case .recordShop: return L.t("レコード屋", "RECORD SHOP", hans: "唱片店", hant: "唱片行")
        case .shibuyaStreet: return L.t("渋谷の路上", "SHIBUYA STREET", hans: "涩谷街头", hant: "澀谷街頭")
        case .cruiseDeck: return L.t("豪華客船", "CRUISE DECK", hans: "豪华邮轮", hant: "豪華郵輪")
        }
    }

    var title: String {
        switch self {
        case .smallClub: return "SMALL CLUB"
        case .underground: return "UNDERGROUND"
        case .warehouse: return "WAREHOUSE"
        case .rooftop: return "ROOFTOP"
        case .beach: return "BEACH"
        case .tokyoNight: return "TOKYO NIGHT"
        case .cyberClub: return "CYBER CLUB"
        case .megaFestival: return "MEGA FESTIVAL"
        case .spaceClub: return "SPACE CLUB"
        case .forestRave: return "FOREST RAVE"
        case .recordShop: return "RECORD SHOP"
        case .shibuyaStreet: return "SHIBUYA STREET"
        case .cruiseDeck: return "CRUISE DECK"
        }
    }

    /// 会場カードの一言（専用の観客がいる会場）
    var subtitle: String? {
        switch self {
        case .forestRave: return L.t("森の野外レイヴ", "Outdoor forest rave", hans: "森林户外锐舞", hant: "森林戶外派對")
        case .recordShop: return L.t("レコード屋の店内", "Inside a record shop", hans: "唱片店内", hant: "唱片行店內")
        case .shibuyaStreet: return L.t("夜の交差点でストリートパーティー", "Night street party at the crossing", hans: "夜晚路口的街头派对", hant: "夜晚路口的街頭派對")
        case .cruiseDeck: return L.t("夜の海を行く船のデッキ", "A ship's deck on the night sea", hans: "夜海航行的邮轮甲板", hant: "夜海航行的郵輪甲板")
        default: return nil
        }
    }

    // 背景上・背景下・照明色
    var palette: (Color, Color, Color) {
        switch self {
        case .smallClub: return (Color(red: 0.10, green: 0.03, blue: 0.10), Color(red: 0.02, green: 0.01, blue: 0.03), .pink)
        case .underground: return (Color(red: 0.05, green: 0.05, blue: 0.06), Color(red: 0.01, green: 0.01, blue: 0.01), .red)
        case .warehouse: return (Color(red: 0.09, green: 0.08, blue: 0.06), Color(red: 0.02, green: 0.02, blue: 0.02), .orange)
        case .rooftop: return (Color(red: 0.12, green: 0.08, blue: 0.25), Color(red: 0.03, green: 0.02, blue: 0.06), .purple)
        case .beach: return (Color(red: 0.95, green: 0.45, blue: 0.30), Color(red: 0.10, green: 0.05, blue: 0.15), .yellow)
        case .tokyoNight: return (Color(red: 0.05, green: 0.04, blue: 0.18), Color(red: 0.01, green: 0.01, blue: 0.05), Color(red: 1, green: 0.2, blue: 0.6))
        case .cyberClub: return (Color(red: 0.0, green: 0.10, blue: 0.14), Color(red: 0.0, green: 0.02, blue: 0.04), .cyan)
        case .megaFestival: return (Color(red: 0.08, green: 0.10, blue: 0.30), Color(red: 0.02, green: 0.02, blue: 0.06), .green)
        case .spaceClub: return (Color(red: 0.02, green: 0.0, blue: 0.08), .black, Color(red: 0.6, green: 0.5, blue: 1))
        case .forestRave: return (Color(red: 0.03, green: 0.08, blue: 0.05), Color(red: 0.01, green: 0.02, blue: 0.01), Color(red: 0.5, green: 1, blue: 0.4))
        case .recordShop: return (Color(red: 0.14, green: 0.08, blue: 0.04), Color(red: 0.03, green: 0.02, blue: 0.01), Color(red: 1, green: 0.7, blue: 0.35))
        case .shibuyaStreet: return (Color(red: 0.08, green: 0.04, blue: 0.16), Color(red: 0.02, green: 0.01, blue: 0.04), Color(red: 1, green: 0.3, blue: 0.7))
        case .cruiseDeck: return (Color(red: 0.03, green: 0.06, blue: 0.16), Color(red: 0.01, green: 0.02, blue: 0.05), Color(red: 1, green: 0.85, blue: 0.5))
        }
    }

    var crowdSize: Int {
        switch self {
        case .smallClub, .underground, .recordShop: return 26
        case .forestRave, .shibuyaStreet, .cruiseDeck: return 38
        case .warehouse, .rooftop, .beach, .tokyoNight, .cyberClub: return 38
        case .megaFestival, .spaceClub: return 52
        }
    }
}

// MARK: - Session config / score

// VJ の映像の種類（音は解析しない。曲の情報と ENERGY だけで動く）
enum VJMode: String, CaseIterable, Identifiable, Codable {
    case auto, tunnel, kaleido, artwork, plasma, typo, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return L.t("おまかせ", "AUTO", hans: "自动", hant: "自動")
        case .tunnel: return L.t("トンネル", "TUNNEL", hans: "隧道", hant: "隧道")
        case .kaleido: return L.t("万華鏡", "KALEIDO", hans: "万花筒", hant: "萬花筒")
        case .artwork: return L.t("ジャケット", "ARTWORK", hans: "专辑封面", hant: "專輯封面")
        case .plasma: return L.t("プラズマ", "PLASMA", hans: "等离子", hant: "電漿")
        case .typo: return L.t("文字", "TYPO", hans: "文字", hant: "文字")
        case .off: return L.t("なし", "OFF", hans: "无", hant: "無")
        }
    }
    var title: String {
        switch self {
        case .auto: return "AUTO"
        case .tunnel: return "TUNNEL"
        case .kaleido: return "KALEIDO"
        case .artwork: return "ARTWORK"
        case .plasma: return "PLASMA"
        case .typo: return "TYPO"
        case .off: return "OFF"
        }
    }
    /// シェーダーでの番号
    var index: Float {
        switch self {
        case .tunnel: return 0
        case .kaleido: return 1
        case .artwork: return 2
        case .plasma: return 3
        case .typo: return 4
        default: return 0
        }
    }
}

// DJ として選べるキャラ（3D モデル名と表示名）
struct DJCharacter: Identifiable, Hashable {
    let id: String
    let name: String
    let isRobot: Bool

    static let all: [DJCharacter] = [
        DJCharacter(id: "c09", name: "SAKI", isRobot: false),
        DJCharacter(id: "c02", name: "LEO", isRobot: false),
        DJCharacter(id: "c12", name: "KOFI", isRobot: false),
        DJCharacter(id: "c16", name: "MEI", isRobot: false),
        DJCharacter(id: "c05", name: "ZURI", isRobot: false),
        DJCharacter(id: "c07", name: "MR. FEDORA", isRobot: false),
        DJCharacter(id: "c13", name: "HARU", isRobot: false),
        DJCharacter(id: "r01", name: "CHROME-X", isRobot: true),
        DJCharacter(id: "r02", name: "ANDROID 7", isRobot: true),
        DJCharacter(id: "r03", name: "RETRO-BOT", isRobot: true),
    ]

    static func named(_ id: String) -> DJCharacter { all.first { $0.id == id } ?? all[0] }
}

struct SessionConfig: Codable {
    var djNames: [String] = ["DJ A", "DJ B"]
    var characters: [String] = ["c09", "c02"]
    var vjMode: VJMode = .auto
    var mode: GameMode = .free
    var genreID: String = "TECHNO"
    var theme: String = Themes.all[0]
    var length: Int = 10            // 0 = ENDLESS
    var secret: Bool = false
    var crowd: CrowdMode = .mix
    var timeLimit: Int = 45         // TIME ATTACK の秒数
    var playLimit: Int = 90         // 1曲の再生上限（0 = 最後まで）
    var venue: Venue = .smallClub
    /// AUTO DJ（その DJ の番になったら自動で選曲）。古い保存データに無いので省略可
    var autoDJ: [Bool]? = nil

    func isAuto(_ dj: Int) -> Bool { (autoDJ ?? []).indices.contains(dj) && autoDJ![dj] }

    var isSecret: Bool { secret || mode == .secret }
    var genre: GenreRule { GenreRule.all.first { $0.id == genreID } ?? GenreRule.all[0] }
}

enum EnergyTier: Int {
    case dead, warming, good, hot, insane, legendary

    init(_ e: Double) {
        switch e {
        case ..<20.5: self = .dead
        case ..<40.5: self = .warming
        case ..<60.5: self = .good
        case ..<80.5: self = .hot
        case ..<99.5: self = .insane
        default: self = .legendary
        }
    }

    var label: String {
        switch self {
        case .dead: return "DEAD FLOOR"
        case .warming: return "WARMING UP"
        case .good: return "GOOD VIBE"
        case .hot: return "FLOOR IS HOT"
        case .insane: return "INSANE"
        case .legendary: return "LEGENDARY FLOOR"
        }
    }

    var color: Color {
        switch self {
        case .dead: return Color(white: 0.5)
        case .warming: return .cyan
        case .good: return .green
        case .hot: return .orange
        case .insane: return .red
        case .legendary: return .yellow
        }
    }
}

enum ScoreKind: Int, CaseIterable { case selection, flow, speed, crowd
    var label: String {
        switch self {
        case .selection: return "SELECTION"
        case .flow: return "FLOW"
        case .speed: return "SPEED"
        case .crowd: return "CROWD"
        }
    }
}

struct ScoreCard: Codable {
    var parts: [Int] = [0, 0, 0, 0]
    var total: Int { parts.reduce(0, +) }
    subscript(_ k: ScoreKind) -> Int {
        get { parts[k.rawValue] }
        set { parts[k.rawValue] = newValue }
    }
}

struct RoundRecord: Identifiable, Codable {
    var id = UUID()
    let number: Int
    let dj: Int
    let track: Track
    let energyStart: Double
    var energyEnd: Double
    var gained: Double { energyEnd - energyStart }
}

struct FloatEvent: Identifiable, Codable {
    var id = UUID()
    let text: String
    let value: Int
    var born = Date()
}

enum Reaction: String, CaseIterable, Identifiable {
    case fire = "🔥", heart = "❤️", clap = "👏", meh = "😐", boo = "👎"
    var id: String { rawValue }
    var energy: Double {
        switch self {
        case .fire: return 3
        case .heart: return 2
        case .clap: return 1
        case .meh: return -1
        case .boo: return -3
        }
    }
}

enum FinishReason: String, Codable {
    case complete, floorEmpty, legendary, quit
    var headline: String {
        switch self {
        case .complete: return "SESSION COMPLETE"
        case .floorEmpty: return "FLOOR EMPTY"
        case .legendary: return "LEGENDARY FLOOR"
        case .quit: return "SESSION END"
        }
    }
}

enum DJTitle {
    static func forPeak(_ peak: Double, score: Int) -> String {
        if peak >= 99.5 { return "FLOOR LEGEND" }
        if peak >= 90 { return "CROWD MASTER" }
        if peak >= 80 { return "B2B MASTER" }
        if peak >= 65 { return "FLOOR MAKER" }
        if score > 0 { return "SELECTOR" }
        return "BEGINNER DJ"
    }
}
