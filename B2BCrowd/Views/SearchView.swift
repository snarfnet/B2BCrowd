import SwiftUI

// 次の曲を1曲選ぶ。Apple Music はカタログ検索とライブラリ、Audius は検索・TRENDING・最近選んだ曲。
// 結果の行から直接 SELECT できる（プレビュー画面は挟まない）。選んでいる間も TIME ATTACK の時計は進む。
struct SearchView: View {
    let game: GameEngine
    var initialTab = 0
    let onPick: (Track) -> Void

    @Environment(MusicService.self) private var music
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var source = 0
    @State private var trending = AudiusTrendingCategory.all[0]
    @State private var results: [Track] = []
    @State private var loading = false
    @State private var error: String?
    @State private var canLoadMore = false
    @State private var blocked: [String: AudiusBlockReason] = [:]

    private var isAudius: Bool { !music.demoMode && music.source == .audius }
    private var loadKey: String { "\(music.sourceLabel)|\(source)|\(query)|\(trending.id)" }
    private let pageSize = 20

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                timerBar
                header
                tabs
                List {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(results) { t in
                        row(t)
                            .listRowBackground(Color.white.opacity(0.04))
                            .onAppear { if t.id == results.last?.id { Task { await loadMore() } } }
                    }
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                    }
                    if isAudius { attribution.listRowBackground(Color.clear) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .background(Color.black)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: isAudius ? "Search Audius" : L.t("曲名・アーティスト", "Song or artist"))
            .navigationTitle("NEXT TRACK · \(game.name(game.selector))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("閉じる", "Close")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(music.sourceLabel)
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(isAudius ? .purple : .pink)
                }
            }
            .task(id: loadKey) {
                // 前回と同じ検索ならそのまま見せる（開き直しても結果が消えない）
                if let m = SearchMemory.last, m.key == loadKey, !m.results.isEmpty {
                    results = m.results; blocked = m.blocked; canLoadMore = m.canLoadMore; error = nil
                    return
                }
                await load()
            }
            .onAppear {
                if let m = SearchMemory.last, m.source == music.sourceLabel {
                    query = m.query; source = m.tab; trending = m.trending
                    results = m.results; blocked = m.blocked; canLoadMore = m.canLoadMore
                } else if initialTab != 0 {
                    source = initialTab
                }
            }
            .onChange(of: results.map(\.id)) { _, _ in remember() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 上の帯

    /// TIME ATTACK の残り時間（検索中も止まらない）
    @ViewBuilder
    private var timerBar: some View {
        if game.config.mode == .timeAttack {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                if let left = game.selectionTimeLeft {
                    HStack {
                        LEDText(text: "NEXT TRACK", size: 13, color: .cyan)
                        Spacer()
                        LEDText(text: formatTime(left), size: 18, color: left <= 10 ? .red : .yellow)
                    }
                    .padding(.horizontal).padding(.vertical, 6)
                    .background(Color.white.opacity(0.05))
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        let c = game.config
        let rule: String? = {
            switch c.mode {
            case .genre: return "GENRE: \(c.genre.id)"
            case .theme: return "THEME: \(c.theme)"
            case .shiritori:
                if let cur = game.current { return L.t("「\(cur.title)」から連想する曲", "Link from “\(cur.title)”") }
                return nil
            default: return nil
            }
        }()
        if let rule {
            Text(rule)
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(.yellow)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(Color.yellow.opacity(0.12))
        }
    }

    @ViewBuilder
    private var tabs: some View {
        VStack(spacing: 6) {
            Picker("", selection: $source) {
                if isAudius {
                    Text("SEARCH").tag(0)
                    Text("TRENDING").tag(1)
                    Text("RECENT").tag(2)
                } else {
                    Text(L.t("カタログ", "Catalog")).tag(0)
                    Text(L.t("ライブラリ", "Library")).tag(1)
                }
            }
            .pickerStyle(.segmented)
            if isAudius && source == 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(AudiusTrendingCategory.all) { c in
                            Button(c.title) { trending = c }
                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(trending == c ? Color.purple.opacity(0.5) : .white.opacity(0.08)))
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    // MARK: 行

    private func row(_ t: Track) -> some View {
        let reason = blocked[t.id]
        return HStack(spacing: 12) {
            ArtworkView(track: t, size: .small)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Text(t.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if let d = t.duration { tag(formatTime(d), .gray) }
                    if let g = t.genres.first { tag(g, .gray) }
                    if !isAudius, let y = t.releaseYear { tag("\(y)", .gray) }
                    if game.config.mode == .genre {
                        game.config.genre.matches(t) ? tag("✓ \(game.config.genre.id)", .green) : tag("✗ \(game.config.genre.id)", .red)
                    }
                    if game.wasPlayed(t) { tag(L.t("再生済み", "PLAYED"), .orange) }
                    if let a = t.audius, a.licenseStatus == .unknown { tag("LICENSE ?", .gray) }
                    if let reason { tag(reason.label, .red) }
                }
            }
            Spacer(minLength: 4)
            if let url = t.externalURL {
                // 帰属表示：Audius の曲ページへ
                Link(destination: url) { Image(systemName: "arrow.up.right.square").font(.system(size: 17)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Button("SELECT") { pick(t) }
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .buttonStyle(.borderedProminent)
                .tint(game.selector == 0 ? .pink : .cyan)
                .disabled(reason != nil)
        }
        .foregroundStyle(.white)
        .opacity(reason == nil ? 1 : 0.45)
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 10, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.25)))
            .foregroundStyle(c == .gray ? .white.opacity(0.7) : c)
    }

    private var attribution: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
            Text(L.t("音源・メタデータ提供: Audius（アーティストの公式アップロード）", "Music & metadata: Audius (uploaded by the artists)"))
            Spacer()
            Link("audius.co", destination: URL(string: "https://audius.co")!)
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.55))
    }

    // MARK: 読み込み

    private func load() async {
        error = nil
        canLoadMore = false
        if isAudius {
            await loadAudius(reset: true)
            return
        }
        if source == 0 {
            let q = query
            if !music.demoMode {
                try? await Task.sleep(for: .milliseconds(350))   // 入力中の連続検索を間引く
                if Task.isCancelled { return }
                if q.trimmingCharacters(in: .whitespaces).isEmpty { results = []; return }
            }
            loading = true
            defer { loading = false }
            do {
                results = try await music.search(q)
                if results.isEmpty, !q.isEmpty { error = L.t("見つかりませんでした", "No results") }
            } catch {
                if !Task.isCancelled { self.error = L.t("検索できませんでした（通信を確認してください）", "Search failed. Check your connection.") }
            }
        } else {
            loading = true
            defer { loading = false }
            do {
                let all = try await music.library()
                let q = query.lowercased()
                results = q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
            } catch {
                self.error = L.t("ライブラリを読めませんでした", "Couldn't read your library")
            }
        }
    }

    private func loadMore() async {
        guard isAudius, canLoadMore, !loading else { return }
        await loadAudius(reset: false)
    }

    private func loadAudius(reset: Bool) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        if reset {
            if source == 0 {
                try? await Task.sleep(for: .milliseconds(400))   // 入力が止まってから1回だけ検索
                if Task.isCancelled { return }
            }
            results = []
        }
        let offset = reset ? 0 : results.count
        var page: [Track] = []
        loading = true
        defer { loading = false }
        do {
            switch source {
            case 0:
                if q.isEmpty { return }
                page = try await music.searchAudius(q, offset: offset)
            case 1:
                guard offset < 100 else { return }   // Trending は公式に上位100曲まで
                page = try await music.trendingAudius(trending, offset: offset)
            default:
                let recent = RecentAudiusPicks.load()
                page = q.isEmpty ? recent : recent.filter { $0.title.lowercased().contains(q.lowercased()) || $0.artist.lowercased().contains(q.lowercased()) }
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                self.error = (error as? AudiusError)?.errorDescription ?? L.t("Audius を読めませんでした", "Couldn't reach Audius")
            }
            return
        }
        if Task.isCancelled { return }
        for t in page {
            if case .blocked(let r) = await music.audiusPlayability(t) { blocked[t.id] = r }
        }
        let known = Set(results.map(\.id))
        results += page.filter { !known.contains($0.id) }
        canLoadMore = source != 2 && page.count >= pageSize
        if results.isEmpty, source != 2 || !q.isEmpty {
            error = L.t("見つかりませんでした", "No results")
        } else if results.isEmpty {
            error = L.t("まだ Audius から選んだ曲はありません", "No Audius picks yet")
        }
    }

    private func remember() {
        SearchMemory.last = SearchMemory(key: loadKey, source: music.sourceLabel, query: query, tab: source,
                                         trending: trending, results: results, blocked: blocked, canLoadMore: canLoadMore)
    }

    private func pick(_ t: Track) {
        if t.audius != nil { RecentAudiusPicks.add(t) }
        onPick(t)
        dismiss()
    }
}

/// Audius から最近選んだ曲（メタデータだけを端末に残す。音源は保存しない）
enum RecentAudiusPicks {
    private static let key = "audius.recent.v1"

    static func load() -> [Track] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([AudiusTrack].self, from: d) else { return [] }
        return list.map(Track.init(audius:))
    }

    static func add(_ t: Track) {
        guard let a = t.audius else { return }
        var list = load().compactMap(\.audius).filter { $0.id != a.id }
        list.insert(a, at: 0)
        if let d = try? JSONEncoder().encode(Array(list.prefix(30))) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// 直前の検索（画面を閉じても次に開いたとき同じ結果を出す）。メタデータだけをメモリに持つ
struct SearchMemory {
    let key: String
    let source: String
    let query: String
    let tab: Int
    let trending: AudiusTrendingCategory
    let results: [Track]
    let blocked: [String: AudiusBlockReason]
    let canLoadMore: Bool

    @MainActor static var last: SearchMemory?
}
