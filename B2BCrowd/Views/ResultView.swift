import SwiftUI

struct ResultView: View {
    let game: GameEngine
    @Environment(AppModel.self) private var app
    @State private var shareImage: Image?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                LEDText(text: game.finishReason?.headline ?? "RESULT", size: 30,
                        color: game.finishReason == .floorEmpty ? .red : .yellow)
                    .padding(.top, 20)

                if let w = game.winner {
                    Text("WINNER · \(game.name(w))")
                        .font(.system(size: 20, weight: .black, design: .monospaced))
                        .foregroundStyle(w == 0 ? .pink : .cyan)
                } else {
                    Text("DRAW").font(.system(size: 20, weight: .black, design: .monospaced))
                }

                HStack(alignment: .top, spacing: 12) {
                    djColumn(0)
                    djColumn(1)
                }

                stats

                if !app.unlocked.values.flatMap({ $0 }).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L.t("新しい実績", "NEW ACHIEVEMENTS")).font(.system(size: 12, weight: .heavy, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                        ForEach(app.unlocked.keys.sorted(), id: \.self) { name in
                            ForEach(app.unlocked[name] ?? [], id: \.rawValue) { a in
                                Label("\(name) · \(a.title)", systemImage: "rosette").font(.system(size: 14, weight: .bold)).foregroundStyle(.yellow)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                setlist

                if let img = shareImage {
                    ShareLink(item: img, preview: SharePreview("B2B CROWD DUO", image: img)) {
                        Label(L.t("リザルトをシェア", "Share result"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(NeonButtonStyle(color: .cyan, filled: false))
                }

                if app.link.role != .guest {
                Button { app.start() } label: { Label(L.t("同じ設定でもう一回", "REMATCH"), systemImage: "arrow.clockwise") }
                    .buttonStyle(NeonButtonStyle(color: .pink))
                }
                Button { app.backToLobby() } label: { Text(L.t("設定を変える", "CHANGE SETUP")) }
                    .buttonStyle(NeonButtonStyle(color: .cyan, filled: false))
                Button { app.backToTitle() } label: { Text("TITLE") }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 30)
            }
            .padding(.horizontal)
        }
        .foregroundStyle(.white)
        .onAppear(perform: renderShare)
    }

    private func djColumn(_ dj: Int) -> some View {
        let tint: Color = dj == 0 ? .pink : .cyan
        let s = game.scores[dj]
        return VStack(spacing: 8) {
            Text(game.name(dj)).font(.system(size: 16, weight: .black)).lineLimit(1)
            LEDText(text: "\(s.total)", size: 30, color: tint)
            ForEach(ScoreKind.allCases, id: \.rawValue) { k in
                HStack {
                    Text(k.label).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("\(s[k])").font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
            Text(game.title(for: dj))
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(0.25)))
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.5)))
    }

    private var stats: some View {
        let best = game.bestRound
        return VStack(spacing: 8) {
            statRow("MAX CROWD ENERGY", "\(Int(game.peakEnergy.rounded()))", EnergyTier(game.peakEnergy).color)
            statRow("MAX COMBO", "\(game.maxCombo)", .orange)
            statRow("TOTAL TRACKS", "\(game.tracksPlayed)", .white)
            if let best, best.gained > 0 {
                statRow("BEST ROUND", "#\(best.number) \(best.track.title) · \(game.name(best.dj)) +\(Int(best.gained.rounded()))", .green)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
    }

    private func statRow(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack {
            Text(k).font(.system(size: 11, weight: .heavy, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(v).font(.system(size: 14, weight: .bold)).foregroundStyle(c).lineLimit(1)
        }
    }

    private var setlist: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SETLIST").font(.system(size: 12, weight: .heavy, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            ForEach(game.rounds) { r in
                HStack(spacing: 8) {
                    Text(String(format: "%02d", r.number)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                    Circle().fill(r.dj == 0 ? Color.pink : .cyan).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(r.track.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(r.track.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer()
                    let g = Int(r.gained.rounded())
                    Text(g >= 0 ? "+\(g)" : "\(g)").font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(g >= 0 ? .green : .red)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 曲の音源は含まない、文字と数字だけのカード
    private func renderShare() {
        let card = ShareCard(game: game).frame(width: 1080 / 3, height: 1350 / 3)
        let r = ImageRenderer(content: card)
        r.scale = 3
        if let ui = r.uiImage { shareImage = Image(uiImage: ui) }
    }
}

struct ShareCard: View {
    let game: GameEngine

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.02, blue: 0.18), .black], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                LEDText(text: "B2B CROWD DUO", size: 26, color: .pink)
                Text(game.config.mode.title + " · " + game.config.venue.title)
                    .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 18) {
                    ForEach(0..<2, id: \.self) { dj in
                        VStack(spacing: 4) {
                            Text(game.name(dj)).font(.system(size: 15, weight: .black)).foregroundStyle(.white)
                            LEDText(text: "\(game.scores[dj].total)", size: 28, color: dj == 0 ? .pink : .cyan)
                            Text(game.title(for: dj)).font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                VStack(spacing: 4) {
                    Text("MAX ENERGY \(Int(game.peakEnergy.rounded()))  ·  MAX COMBO \(game.maxCombo)")
                    Text("\(game.tracksPlayed) TRACKS")
                }
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.yellow)
                LEDText(text: EnergyTier(game.peakEnergy).label, size: 20, color: EnergyTier(game.peakEnergy).color)
            }
            .padding()
        }
    }
}
