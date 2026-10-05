import SwiftUI

struct ProfilesView: View {
    @Environment(AppModel.self) private var app
    @Environment(ProfileStore.self) private var store
    @State private var newName = ""

    private let icons = ["🎧", "🎛️", "💿", "🔥", "🌙", "⚡️", "👽", "🐉", "🦊", "🐼", "🤖", "👑"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { app.screen = .title } label: { Image(systemName: "chevron.left").font(.title3.bold()) }
                Spacer()
                LEDText(text: "DJ PROFILES", size: 18, color: .cyan)
                Spacer()
                Image(systemName: "chevron.left").opacity(0)
            }
            .padding()

            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        TextField("DJ NAME", text: $newName)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
                        Button(L.t("追加", "Add")) {
                            let n = newName.trimmingCharacters(in: .whitespaces)
                            guard !n.isEmpty, store.profile(named: n) == nil else { return }
                            store.upsert(DJProfile(name: n))
                            newName = ""
                        }
                        .buttonStyle(.borderedProminent).tint(.pink)
                    }

                    if store.profiles.isEmpty {
                        Text(L.t("セッションを遊ぶと DJ 名ごとに記録が残ります。", "Play a session and each DJ name keeps its own record."))
                            .font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(.top, 30)
                    }

                    ForEach(store.profiles) { p in card(p) }
                }
                .padding(.horizontal)
            }
        }
        .foregroundStyle(.white)
    }

    private func card(_ p: DJProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(icons, id: \.self) { i in
                        Button(i) { var q = p; q.icon = i; store.upsert(q) }
                    }
                } label: {
                    Text(p.icon).font(.system(size: 40))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.system(size: 20, weight: .black))
                    Text("LV \(p.level) · \(p.title)")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced)).foregroundStyle(.yellow)
                }
                Spacer()
                Button(role: .destructive) { store.delete(p) } label: { Image(systemName: "trash") }
                    .foregroundStyle(.red.opacity(0.8))
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { stat("SESSIONS", "\(p.sessions)"); stat("BEST ENERGY", "\(p.bestEnergy)") }
                GridRow { stat("BEST COMBO", "\(p.bestCombo)"); stat("BEST SCORE", "\(p.bestScore)") }
                GridRow { stat(L.t("好きなジャンル", "FAV GENRE"), p.favoriteGenre ?? "—"); Color.clear.frame(height: 1) }
            }
            if !p.achievements.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(p.achievements, id: \.self) { raw in
                            if let a = Achievement(rawValue: raw) {
                                Text(a.title).font(.system(size: 11, weight: .bold))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.yellow.opacity(0.2)))
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(k).font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            Text(v).font(.system(size: 15, weight: .bold)).lineLimit(1)
        }
    }
}
