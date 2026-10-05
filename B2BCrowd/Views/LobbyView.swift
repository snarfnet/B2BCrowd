import SwiftUI

struct LobbyView: View {
    @Environment(AppModel.self) private var app
    @Environment(MusicService.self) private var music
    @Environment(ProfileStore.self) private var profiles
    @State private var crowdSound = SoundFX.shared.enabled

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack {
                Button { app.screen = .title } label: { Image(systemName: "chevron.left").font(.title3.bold()) }
                Spacer()
                LEDText(text: "SESSION SETUP", size: 18, color: .cyan)
                Spacer()
                Image(systemName: "chevron.left").opacity(0)
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("DJ") {
                        djField(0)
                        djField(1)
                    }

                    section(L.t("キャラ", "CHARACTER")) {
                        characterRow(0)
                        characterRow(1)
                    }

                    section("MODE") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(GameMode.allCases) { m in modeCard(m) }
                        }
                        Text(app.config.mode.blurb).font(.footnote).foregroundStyle(.white.opacity(0.75))
                        modeOptions
                    }

                    section("SESSION LENGTH") {
                        Picker("", selection: $app.config.length) {
                            Text("5").tag(5); Text("10").tag(10); Text("20").tag(20); Text("ENDLESS").tag(0)
                        }
                        .pickerStyle(.segmented)
                    }

                    section(L.t("1曲の再生時間", "PLAY TIME PER TRACK")) {
                        Picker("", selection: $app.config.playLimit) {
                            Text("30s").tag(30); Text("60s").tag(60); Text("90s").tag(90); Text("FULL").tag(0)
                        }
                        .pickerStyle(.segmented)
                        Text(L.t("時間が来たら次の曲へ切り替わります（曲同士を重ねるミックスはしません）。", "When time is up the next track starts. Tracks are never mixed together."))
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                    }

                    section("SECRET TRACK") {
                        Toggle(L.t("次の曲を相手に隠す", "Hide next track from partner"), isOn: $app.config.secret)
                            .disabled(app.config.mode == .secret)
                            .tint(.purple)
                    }

                    section("CROWD") {
                        Picker("", selection: $app.config.crowd) {
                            ForEach(CrowdMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text(crowdHelp).font(.caption).foregroundStyle(.white.opacity(0.6))
                    }

                    section(L.t("観客の声", "CROWD SOUND")) {
                        Toggle(L.t("歓声・指笛・拍手を鳴らす", "Cheers, whistles and applause"), isOn: $crowdSound)
                            .tint(.pink)
                            .onChange(of: crowdSound) { _, v in SoundFX.shared.enabled = v }
                    }

                    section("VENUE") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Venue.allCases) { v in venueCard(v) }
                            }
                        }
                    }

                    MusicStatusCard()
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }

            Button {
                app.start()
            } label: {
                Label(music.isReady ? "START" : L.t("Apple Music に接続するか DEMO を ON に", "Connect Apple Music or turn on DEMO"),
                      systemImage: "play.fill")
            }
            .buttonStyle(NeonButtonStyle(color: .pink))
            .disabled(!music.isReady)
            .opacity(music.isReady ? 1 : 0.5)
            .padding()
        }
        .foregroundStyle(.white)
    }

    private var crowdHelp: String {
        switch app.config.crowd {
        case .ai: return L.t("観客はルールで反応。", "The crowd reacts by rules.")
        case .player: return L.t("周りの人が絵文字で反応。AI 観客は休み。", "People around you react with emoji. No AI crowd.")
        case .mix: return L.t("AI 観客と周りの人の反応を混ぜる。", "Mix AI crowd and real reactions.")
        }
    }

    @ViewBuilder
    private var modeOptions: some View {
        @Bindable var app = app
        switch app.config.mode {
        case .genre:
            chips(GenreRule.all.map(\.id), selected: app.config.genreID) { app.config.genreID = $0 }
        case .theme:
            chips(Themes.all, selected: app.config.theme) { app.config.theme = $0 }
        case .timeAttack:
            Picker("", selection: $app.config.timeLimit) {
                Text("60s").tag(60); Text("45s").tag(45); Text("30s").tag(30); Text("15s").tag(15)
            }
            .pickerStyle(.segmented)
        default:
            EmptyView()
        }
    }

    private func djField(_ i: Int) -> some View {
        @Bindable var app = app
        return HStack {
            Text(i == 0 ? "A" : "B")
                .font(.system(size: 18, weight: .black, design: .monospaced))
                .foregroundStyle(i == 0 ? .pink : .cyan)
                .frame(width: 28)
            TextField("DJ NAME", text: $app.config.djNames[i])
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
            if !profiles.profiles.isEmpty {
                Menu {
                    ForEach(profiles.profiles) { p in
                        Button("\(p.icon) \(p.name)") { app.config.djNames[i] = p.name }
                    }
                } label: {
                    Image(systemName: "person.crop.circle").font(.title2)
                }
            }
        }
    }

    private func characterRow(_ dj: Int) -> some View {
        let tint: Color = dj == 0 ? .pink : .cyan
        let selected = app.config.characters.count == 2 ? app.config.characters[dj] : (dj == 0 ? "c09" : "c02")
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(dj == 0 ? "A" : "B") · \(app.config.djNames[dj]) — \(DJCharacter.named(selected).name)")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(tint)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DJCharacter.all) { c in
                        Button {
                            if app.config.characters.count != 2 { app.config.characters = ["c09", "c02"] }
                            app.config.characters[dj] = c.id
                        } label: {
                            VStack(spacing: 3) {
                                Group {
                                    if let img = UIImage(named: "char_\(c.id)") {
                                        Image(uiImage: img).resizable().scaledToFill()
                                    } else {
                                        Color.white.opacity(0.1)
                                    }
                                }
                                .frame(width: 66, height: 66)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(c.id == selected ? tint : .white.opacity(0.1), lineWidth: c.id == selected ? 3 : 1))
                                Text(c.name).font(.system(size: 9, weight: .bold, design: .monospaced)).lineLimit(1)
                                    .foregroundStyle(c.id == selected ? tint : .white.opacity(0.7))
                            }
                            .frame(width: 70)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func modeCard(_ m: GameMode) -> some View {
        let on = app.config.mode == m
        return Button {
            app.config.mode = m
        } label: {
            HStack(spacing: 8) {
                Image(systemName: m.symbol)
                Text(m.title).font(.system(size: 12, weight: .heavy, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Color.pink.opacity(0.35) : .white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? .pink : .white.opacity(0.1), lineWidth: on ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func venueCard(_ v: Venue) -> some View {
        let on = app.config.venue == v
        return Button {
            app.config.venue = v
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [v.palette.0, v.palette.1], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().fill(v.palette.2.opacity(0.6)).frame(width: 18).blur(radius: 4))
                    .frame(width: 96, height: 64)
                Text(v.title).font(.system(size: 10, weight: .heavy, design: .monospaced))
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 12).stroke(on ? .cyan : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func chips(_ items: [String], selected: String, pick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { s in
                    Button(s) { pick(s) }
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(s == selected ? Color.cyan.opacity(0.4) : .white.opacity(0.08)))
                        .overlay(Capsule().stroke(s == selected ? .cyan : .clear))
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .heavy, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
            content()
        }
    }
}
