import SwiftUI

// iPhone Duo を開いて2人で持つとき、画面の左半分・右半分がそれぞれの DJ の席。
// 自分の番は自分の半分で曲を探して選ぶ（相手の曲が流れている間に次を用意する）。
// 自分の曲が流れている間は、その曲と相手の様子、観客の反応ボタン。
struct SplitColumn: View {
    let game: GameEngine
    let dj: Int

    private var tint: Color { dj == 0 ? .pink : .cyan }
    /// 自分で選ぶ番（AUTO DJ の番は自動で選ぶので検索画面は出さない）
    private var myTurn: Bool { game.selector == dj && !game.isAuto(dj) }

    var body: some View {
        VStack(spacing: 6) {
            header
            if myTurn, game.current != nil, game.currentOwner != dj { judgeRow }
            ZStack {
                // 番でない間も検索の画面は残しておく（入力や結果が消えない）
                SearchView(game: game, embeddedDJ: dj) { t in
                    if game.selector == dj { game.reserve(t) }
                }
                .opacity(myTurn ? 1 : 0)
                .allowsHitTesting(myTurn)
                if !myTurn { waitingPanel }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if myTurn { nextRow }
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
    }

    // MARK: 上の名札

    private var header: some View {
        HStack(spacing: 6) {
            LEDText(text: dj == 0 ? "A" : "B", size: 16, color: tint)
            Text(game.name(dj)).font(.system(size: 13, weight: .black)).lineLimit(1)
            if game.isAuto(dj) { Text("AUTO").font(.system(size: 9, weight: .black, design: .monospaced)).foregroundStyle(.yellow) }
            Spacer(minLength: 2)
            if myTurn, let left = game.selectionTimeLeft {
                LEDText(text: formatTime(left), size: 13, color: left <= 10 ? .red : .yellow)
            }
            LEDText(text: status.0, size: 12, color: status.1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(myTurn ? 0.22 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(myTurn ? tint : .clear, lineWidth: 1.5))
    }

    private var status: (String, Color) {
        if myTurn {
            switch game.phase {
            case .searchingTrack: return ("OPENER", tint)
            case .waitingForNextDJ: return ("SILENCE!", .red)
            default: return (game.next == nil ? "YOUR PICK" : "READY", game.next == nil ? tint : .green)
            }
        }
        if game.current != nil, game.currentOwner == dj { return ("ON AIR", .green) }
        return ("WAIT", .gray)
    }

    // MARK: 相手の曲への LIKE・お題の判定

    private var judgeRow: some View {
        HStack(spacing: 6) {
            Button { game.like() } label: {
                Image(systemName: game.likedThisRound ? "heart.fill" : "heart")
            }
            .buttonStyle(.bordered).tint(.pink)
            .disabled(game.likedThisRound)
            if game.needsJudge {
                Text(game.config.mode == .shiritori ? L.t("繋がってる？", "Linked?") : L.t("お題に合ってる？", "Fits the theme?"))
                    .font(.system(size: 11, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Button { game.judge(true) } label: { Image(systemName: "checkmark") }.buttonStyle(.borderedProminent).tint(.green)
                Button { game.judge(false) } label: { Image(systemName: "xmark") }.buttonStyle(.borderedProminent).tint(.red)
            } else {
                Text("LIKE \(game.name(1 - dj))").font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 選んだ曲・PASS

    @ViewBuilder
    private var nextRow: some View {
        if let n = game.next {
            HStack(spacing: 8) {
                ArtworkView(track: n, hidden: false)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 1) {
                    Text("NEXT ▶").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(tint)
                    Text(n.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { game.clearNext() } label: { Image(systemName: "xmark") }.buttonStyle(.bordered).tint(.gray)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
        } else {
            Button("PASS") { game.pass() }
                .buttonStyle(NeonButtonStyle(color: .gray, filled: false))
                .disabled(game.phase == .searchingTrack)
        }
    }

    // MARK: 自分の番でない間

    private var waitingPanel: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if game.current != nil, game.currentOwner == dj {
                LEDText(text: "ON AIR", size: 18, color: .green)
                ArtworkView(track: game.current, size: .large)
                    .frame(width: 110, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: tint.opacity(0.6), radius: 14)
                Text(game.current?.title ?? "").font(.system(size: 14, weight: .bold)).lineLimit(1)
            }
            Text(game.isAuto(dj) && game.selector == dj
                 ? L.t("AUTO が曲を探しています…", "AUTO is digging for a track…")
                 : game.phase == .searchingTrack
                 ? L.t("\(game.name(1 - dj)) が1曲目を選んでいます", "\(game.name(1 - dj)) is picking the opener")
                 : L.t("\(game.name(1 - dj)) が次の曲を選んでいます", "\(game.name(1 - dj)) is picking next"))
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            if game.showsPad, game.current != nil {
                HStack(spacing: 4) {
                    ForEach(Reaction.allCases) { r in
                        Button { game.react(r) } label: { Text(r.rawValue).font(.system(size: 22)) }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.04))
    }
}
