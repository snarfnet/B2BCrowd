import SwiftUI

// 次の曲を1曲選ぶ。カタログ検索とライブラリ。
struct SearchView: View {
    let game: GameEngine
    let onPick: (Track) -> Void

    @Environment(MusicService.self) private var music
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var source = 0
    @State private var results: [Track] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Picker("", selection: $source) {
                    Text(L.t("カタログ", "Catalog")).tag(0)
                    Text(L.t("ライブラリ", "Library")).tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)

                List {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                    ForEach(results) { t in
                        Button { pick(t) } label: { row(t) }
                            .listRowBackground(Color.white.opacity(0.04))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .background(Color.black)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: L.t("曲名・アーティスト", "Song or artist"))
            .navigationTitle("NEXT TRACK · \(game.name(game.selector))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("閉じる", "Close")) { dismiss() }
                }
            }
            .task(id: "\(source)|\(query)") { await load() }
        }
        .preferredColorScheme(.dark)
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

    private func row(_ t: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(track: t)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Text(t.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if let g = t.genres.first { tag(g, .gray) }
                    if let y = t.releaseYear { tag("\(y)", .gray) }
                    if game.config.mode == .genre {
                        game.config.genre.matches(t) ? tag("✓ \(game.config.genre.id)", .green) : tag("✗ \(game.config.genre.id)", .red)
                    }
                    if game.wasPlayed(t) { tag(L.t("再生済み", "PLAYED"), .orange) }
                }
            }
            Spacer()
            if let d = t.duration {
                Text(formatTime(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.25)))
            .foregroundStyle(c == .gray ? .white.opacity(0.7) : c)
    }

    private func load() async {
        error = nil
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

    private func pick(_ t: Track) {
        onPick(t)
        dismiss()
    }
}
