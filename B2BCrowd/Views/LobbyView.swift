import SwiftUI

struct LobbyView: View {
    @Environment(AppModel.self) private var app
    @Environment(MusicService.self) private var music
    @Environment(ProfileStore.self) private var profiles
    @Environment(LinkService.self) private var link
    @State private var crowdSound = SoundFX.shared.enabled

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { app.backToTitle() } label: { Image(systemName: "chevron.left").font(.title3.bold()) }
                Spacer()
                LEDText(text: "SESSION SETUP", size: 18, color: .cyan)
                Spacer()
                Image(systemName: "chevron.left").opacity(0)
            }
            .padding()

            if link.role == .guest {
                guestLobby
            } else {
                hostLobby
            }
        }
        .foregroundStyle(.white)
        .onChange(of: app.config.djNames) { _, _ in sendHello() }
        .onChange(of: app.config.characters) { _, _ in sendHello() }
    }

    /// つながった後に名前・キャラを変えたら相手にも知らせる
    private func sendHello() {
        guard link.isConnected else { return }
        let me = link.role == .guest ? 1 : 0
        link.myName = app.config.djNames[me]
        link.myCharacter = app.config.characters.count == 2 ? app.config.characters[me] : "c09"
        link.send(.hello(name: link.myName, character: link.myCharacter))
    }

    private var hostConnected: Bool { link.role == .host && link.isConnected }

    // MARK: 2台対戦

    private var linkSection: some View {
        section(L.t("iPhone 2台で対戦", "VERSUS ON 2 iPHONES")) {
            switch link.role {
            case .none:
                Text(L.t("近くの iPhone とつないで、それぞれの iPhone で選曲。音はホストの iPhone から鳴ります（Wi‑Fi か Bluetooth をオン）。",
                         "Link with a nearby iPhone and pick tracks on your own phone. Music plays from the host (turn on Wi‑Fi or Bluetooth)."))
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 10) {
                    Button {
                        link.host(name: app.config.djNames[0], character: app.config.characters.first ?? "c09")
                    } label: {
                        VStack(spacing: 2) {
                            Text("HOST").font(.system(size: 15, weight: .black, design: .monospaced))
                            Text(L.t("音を鳴らす側・DJ A", "Plays music · DJ A")).font(.system(size: 10, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(color: .pink, filled: false))
                    Button {
                        link.join(name: app.config.djNames[1], character: app.config.characters.count == 2 ? app.config.characters[1] : "c02")
                    } label: {
                        VStack(spacing: 2) {
                            Text("JOIN").font(.system(size: 15, weight: .black, design: .monospaced))
                            Text(L.t("相手に参加・DJ B", "Join a host · DJ B")).font(.system(size: 10, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(color: .cyan, filled: false))
                }
            case .host:
                HStack(spacing: 10) {
                    if hostConnected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(L.t("接続中：\(link.partnerName ?? "…")（DJ B）", "Linked: \(link.partnerName ?? "…") (DJ B)"))
                            .font(.system(size: 14, weight: .bold))
                    } else {
                        ProgressView()
                        Text(L.t("相手の iPhone で「JOIN」を押してもらってください", "Ask your partner to tap JOIN on their iPhone"))
                            .font(.system(size: 13, weight: .bold))
                    }
                    Spacer()
                    Button(L.t("やめる", "Stop")) { link.stop() }.buttonStyle(.bordered).tint(.gray)
                }
                if let e = link.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
            case .guest:
                EmptyView()
            }
        }
    }

    private var guestLobby: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(L.t("あなた（DJ B）", "YOU (DJ B)")) {
                        djField(1)
                        characterRow(1)
                    }
                    section(L.t("ホストにつなぐ", "CONNECT TO HOST")) {
                        guestStatus
                        if let e = link.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                    }
                    Text(L.t("曲はこの iPhone で探して送ります。ホストが Apple Music のときは、この iPhone でも Apple Music の許可が必要です。",
                             "You search on this iPhone. If the host uses Apple Music, allow Apple Music on this iPhone too."))
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                    MusicStatusCard()
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            Button { link.stop() } label: { Text(L.t("2台対戦をやめる", "Leave versus")) }
                .buttonStyle(NeonButtonStyle(color: .gray, filled: false))
                .padding()
        }
    }

    @ViewBuilder
    private var guestStatus: some View {
        if link.isConnected {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L.t("\(link.partnerName ?? "ホスト") につながりました", "Linked with \(link.partnerName ?? "host")"))
                    .font(.system(size: 15, weight: .bold))
            }
            Text(L.t("ホストが START を押すと始まります。音はホストの iPhone から鳴ります。",
                     "The session starts when the host taps START. Music plays from the host's iPhone."))
                .font(.caption).foregroundStyle(.white.opacity(0.7))
        } else if link.hosts.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text(L.t("近くのホストを探しています…", "Looking for a nearby host…")).font(.system(size: 13, weight: .bold))
            }
            Text(L.t("相手の iPhone で SESSION SETUP の「HOST」を押してもらってください。", "Ask your partner to tap HOST in SESSION SETUP."))
                .font(.caption).foregroundStyle(.white.opacity(0.7))
        } else {
            ForEach(link.hosts) { h in
                Button { link.connect(to: h) } label: {
                    HStack {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                        Text(h.name).font(.system(size: 15, weight: .bold))
                        Spacer()
                        if link.state == .connecting { ProgressView() } else { Text(L.t("つなぐ", "Connect")).font(.caption.bold()) }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.cyan.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .disabled(link.state == .connecting)
            }
        }
    }

    private var hostLobby: some View {
        @Bindable var app = app
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    linkSection

                    section("DJ") {
                        djField(0)
                        djField(1)
                        Text(L.t("AUTO にした DJ は、自分の番になると今の曲やモードに合う曲を自動で選びます。", "An AUTO DJ picks a track that fits the current one and the mode when it's their turn."))
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                    }

                    section(L.t("キャラ", "CHARACTER")) {
                        characterRow(0)
                        if hostConnected {
                            Text("B · \(link.partnerName ?? "") — \(DJCharacter.named(link.partnerCharacter ?? "c02").name)")
                                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.cyan)
                        } else {
                            characterRow(1)
                        }
                    }

                    if link.role == .none {
                        section(L.t("画面を2分割（iPhone Duo）", "SPLIT SCREEN (iPhone Duo)")) {
                            Picker("", selection: $app.splitMode) {
                                ForEach(SplitMode.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            Text(L.t("iPhone Duo を開くと画面が左右に分かれ、2人がそれぞれの半分で同時に選曲できます。AUTO は広い画面のときだけ分けます。",
                                     "On an open iPhone Duo the screen splits left and right so each DJ picks on their own half. AUTO splits only on wide screens."))
                                .font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
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

                    section("VJ") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(VJMode.allCases) { m in
                                    Button(m.title) { app.config.vjMode = m }
                                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Capsule().fill(app.config.vjMode == m ? Color.purple.opacity(0.45) : .white.opacity(0.08)))
                                        .overlay(Capsule().stroke(app.config.vjMode == m ? .purple : .clear))
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                        Text(L.t("LED 画面の映像。曲のジャケットとタイトル、盛り上がりで変わります（音は解析しません）。",
                                 "Visuals on the LED screens, driven by artwork, title and crowd energy (no audio analysis)."))
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
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
                Label(music.isReady ? "START · \(music.sourceLabel)" : L.t("Apple Music に接続するか AUDIUS / DEMO を選ぶ", "Connect Apple Music, or pick AUDIUS / DEMO"),
                      systemImage: "play.fill")
            }
            .buttonStyle(NeonButtonStyle(color: .pink))
            .disabled(!music.isReady)
            .opacity(music.isReady ? 1 : 0.5)
            .padding()
        }
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
            if i == 1 && hostConnected {
                // DJ B は相手の iPhone の人
                Text(link.partnerName ?? "")
                    .font(.system(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.12)))
                Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(.cyan)
            } else {
                TextField("DJ NAME", text: $app.config.djNames[i])
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
            }
            if link.role != .guest, !(i == 1 && hostConnected) {
                // AUTO DJ：この DJ の番は自動で選曲（1人で AUTO と対戦、両方 AUTO で流しっぱなしも）
                Button {
                    var a = app.config.autoDJ ?? [false, false]
                    if a.count != 2 { a = [false, false] }
                    a[i].toggle()
                    app.config.autoDJ = a
                } label: {
                    Text("AUTO").font(.system(size: 11, weight: .black, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Capsule().fill(app.config.isAuto(i) ? Color.yellow.opacity(0.35) : .white.opacity(0.08)))
                        .overlay(Capsule().stroke(app.config.isAuto(i) ? .yellow : .clear))
                        .foregroundStyle(app.config.isAuto(i) ? .yellow : .white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            if !profiles.profiles.isEmpty, !(i == 1 && hostConnected) {
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
                                    if let img = UIImage(named: "char_\(c.id).jpg") {
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
