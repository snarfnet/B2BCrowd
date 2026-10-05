import Foundation

// 個人情報を含まない回数だけを端末内に数える（外部には送らない）。
// Audius 検索・選曲・再生の成功/失敗と、選曲にかかった時間の平均を見られる。
@MainActor
final class MusicAnalytics {
    static let shared = MusicAnalytics()

    enum Counter: String, CaseIterable {
        case audiusSearch, audiusPick, playAttempt, playSuccess, playError
    }

    private let defaults = UserDefaults.standard
    private let prefix = "analytics.v1."

    func count(_ c: Counter) {
        defaults.set(defaults.integer(forKey: prefix + c.rawValue) + 1, forKey: prefix + c.rawValue)
    }

    func value(_ c: Counter) -> Int { defaults.integer(forKey: prefix + c.rawValue) }

    func recordSelection(seconds: TimeInterval, source: MusicSourceKind?) {
        let key = prefix + "selection." + (source?.rawValue ?? "demo")
        defaults.set(defaults.double(forKey: key + ".sum") + seconds, forKey: key + ".sum")
        defaults.set(defaults.integer(forKey: key + ".n") + 1, forKey: key + ".n")
    }

    func averageSelection(_ source: MusicSourceKind?) -> TimeInterval? {
        let key = prefix + "selection." + (source?.rawValue ?? "demo")
        let n = defaults.integer(forKey: key + ".n")
        return n > 0 ? defaults.double(forKey: key + ".sum") / Double(n) : nil
    }

    /// 再生成功率（0〜1）
    var playSuccessRate: Double? {
        let a = value(.playAttempt)
        return a > 0 ? Double(value(.playSuccess)) / Double(a) : nil
    }
}
