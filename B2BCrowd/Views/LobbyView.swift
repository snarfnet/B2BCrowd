import SwiftUI

struct LobbyView: View {
    @Environment(AppModel.self) private var app
    @Environment(MusicService.self) private var music
    @Environment(ProfileStore.self) private var profiles
    @Environment(LinkService.self) private var link
    @State private var crowdSound = SoundFX.shared.enabled
    @State private var showMore = false
    @State private var wantLink = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { app.backToTitle() } label: { Image(systemName: "chevron.left").font(.title3.bold()) }
                Spacer()
                LEDText(text: L.t("セッションの準備", "SESSION SETUP", hans: "演出准备", hant: "演出準備"), size: 18, color: .cyan)
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
        VStack(alignment: .leading, spacing: 10) {
            switch link.role {
            case .none:
                Text(L.t("近くの iPhone とつないで、それぞれの iPhone で選曲。音はホストの iPhone から鳴ります（Wi‑Fi か Bluetooth をオン）。",
                         "Link with a nearby iPhone and pick tracks on your own phone. Music plays from the host (turn on Wi‑Fi or Bluetooth).", hans: "与附近的 iPhone 连接，各自在自己的 iPhone 上选曲。声音从主机的 iPhone 播放（请打开 Wi‑Fi 或蓝牙）。", hant: "與附近的 iPhone 連線，各自在自己的 iPhone 上選曲。聲音從主機的 iPhone 播放（請開啟 Wi‑Fi 或藍牙）。"))
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 10) {
                    Button {
                        link.host(name: app.config.djNames[0], character: app.config.characters.first ?? "c09")
                    } label: {
                        VStack(spacing: 2) {
                            Text(L.t("ホスト", "HOST", hans: "主机", hant: "主機")).font(.system(size: 15, weight: .black, design: .monospaced))
                            Text(L.t("音を鳴らす側・DJ A", "Plays music · DJ A", hans: "播放声音的一方 · DJ A", hant: "播放聲音的一方 · DJ A")).font(.system(size: 10, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(color: .pink, filled: false))
                    Button {
                        link.join(name: app.config.djNames[1], character: app.config.characters.count == 2 ? app.config.characters[1] : "c02")
                    } label: {
                        VStack(spacing: 2) {
                            Text(L.t("参加", "JOIN", hans: "加入", hant: "加入")).font(.system(size: 15, weight: .black, design: .monospaced))
                            Text(L.t("相手に参加・DJ B", "Join a host · DJ B", hans: "加入对方 · DJ B", hant: "加入對方 · DJ B")).font(.system(size: 10, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(color: .cyan, filled: false))
                }
                LinkHowTo()
            case .host:
                HStack(spacing: 10) {
                    if hostConnected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(L.t("接続中：\(link.partnerName ?? "…")（DJ B）", "Linked: \(link.partnerName ?? "…") (DJ B)", hans: "已连接：\(link.partnerName ?? "…")（DJ B）", hant: "已連線：\(link.partnerName ?? "…")（DJ B）"))
                            .font(.system(size: 14, weight: .bold))
                    } else {
                        ProgressView()
                        Text(L.t("相手の iPhone で「参加」を押してもらってください", "Ask your partner to tap JOIN on their iPhone", hans: "请对方在 iPhone 上点“加入”", hant: "請對方在 iPhone 上點「加入」"))
                            .font(.system(size: 13, weight: .bold))
                    }
                    Spacer()
                    Button(L.t("やめる", "Stop", hans: "停止", hant: "停止")) { link.stop() }.buttonStyle(.bordered).tint(.gray)
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
                    section(L.t("あなた（DJ B）", "YOU (DJ B)", hans: "你（DJ B）", hant: "你（DJ B）")) {
                        djField(1)
                        characterRow(1)
                    }
                    section(L.t("ホストにつなぐ", "CONNECT TO HOST", hans: "连接主机", hant: "連線主機")) {
                        guestStatus
                        if let e = link.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                    }
                    LinkHowTo()
                    MusicStatusCard()
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            Button { link.stop() } label: { Text(L.t("2台対戦をやめる", "Leave versus", hans: "退出双机对战", hant: "退出雙機對戰")) }
                .buttonStyle(NeonButtonStyle(color: .gray, filled: false))
                .padding()
        }
    }

    @ViewBuilder
    private var guestStatus: some View {
        if link.isConnected {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L.t("\(link.partnerName ?? "ホスト") につながりました", "Linked with \(link.partnerName ?? "host")", hans: "已连接到 \(link.partnerName ?? "host")", hant: "已連線到 \(link.partnerName ?? "host")"))
                    .font(.system(size: 15, weight: .bold))
            }
            Text(L.t("ホストがスタートを押すと始まります。音はホストの iPhone から鳴ります。",
                     "The session starts when the host taps START. Music plays from the host's iPhone.", hans: "主机按下“开始”后就会开始。声音从主机的 iPhone 播放。", hant: "主機按下「開始」後就會開始。聲音從主機的 iPhone 播放。"))
                .font(.caption).foregroundStyle(.white.opacity(0.7))
        } else if link.hosts.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text(L.t("近くのホストを探しています…", "Looking for a nearby host…", hans: "正在寻找附近的主机…", hant: "正在尋找附近的主機…")).font(.system(size: 13, weight: .bold))
            }
            Text(L.t("相手の iPhone で SESSION SETUP の「ホスト」を押してもらってください。", "Ask your partner to tap HOST in SESSION SETUP.", hans: "请对方在 iPhone 的“演出准备”中点“主机”。", hant: "請對方在 iPhone 的「演出準備」中點「主機」。"))
                .font(.caption).foregroundStyle(.white.opacity(0.7))
        } else {
            ForEach(link.hosts) { h in
                Button { link.connect(to: h) } label: {
                    HStack {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                        Text(h.name).font(.system(size: 15, weight: .bold))
                        Spacer()
                        if link.state == .connecting { ProgressView() } else { Text(L.t("つなぐ", "Connect", hans: "连接", hant: "連線")).font(.caption.bold()) }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.cyan.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .disabled(link.state == .connecting)
            }
        }
    }

    // だれと遊ぶか（設定画面のいちばん上）
    enum Opponent: CaseIterable { case duo, auto, watch, link }
    private var opponent: Opponent {
        if wantLink || link.role != .none { return .link }
        if app.config.isAuto(0) && app.config.isAuto(1) { return .watch }
        if app.config.isAuto(1) { return .auto }
        return .duo
    }
    private func setOpponent(_ o: Opponent) {
        wantLink = o == .link
        if o != .link, link.role != .none { link.stop() }
        switch o {
        case .duo, .link: app.config.autoDJ = [false, false]
        case .auto: app.config.autoDJ = [false, true]
        case .watch: app.config.autoDJ = [true, true]
        }
    }
    private func opponentCard(_ o: Opponent) -> some View {
        let on = opponent == o
        let (icon, title, sub): (String, String, String) = {
            switch o {
            case .duo: return ("person.2.fill", L.t("ふたりで交代", "2 DJs, 1 iPhone", hans: "两人轮流", hant: "兩人輪流"), L.t("この iPhone を回して B2B", "Pass this iPhone back and forth", hans: "轮流传递这台 iPhone 来 B2B", hant: "輪流傳遞這支 iPhone 來 B2B"))
            case .auto: return ("cpu", L.t("AUTO DJ と対戦", "VS AUTO DJ", hans: "对战 AUTO DJ", hant: "對戰 AUTO DJ"), L.t("相手は自動で曲を選ぶ", "Your partner picks by itself", hans: "对手自动选曲", hant: "對手自動選曲"))
            case .watch: return ("play.circle.fill", L.t("流しっぱなし", "Just play", hans: "持续播放", hant: "持續播放"), L.t("両方 AUTO で自動 DJ", "Both AUTO, sit back", hans: "两边都 AUTO，自动 DJ", hant: "兩邊都 AUTO，自動 DJ"))
            case .link: return ("iphone.radiowaves.left.and.right", L.t("iPhone 2台で対戦", "2 iPhones", hans: "两台 iPhone 对战", hant: "兩支 iPhone 對戰"), L.t("近くの iPhone とつなぐ", "Link a nearby iPhone", hans: "连接附近的 iPhone", hant: "連線附近的 iPhone"))
            }
        }()
        return Button { SoundFX.shared.ui(.tap); setOpponent(o) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title2).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(sub).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.65)).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Color.pink.opacity(0.3) : .white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Color.pink : .white.opacity(0.1), lineWidth: on ? 2 : 1))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func step(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.system(size: 13, weight: .black, design: .monospaced))
                .frame(width: 24, height: 24).background(Circle().fill(Color.pink)).foregroundStyle(.black)
            Text(title).font(.system(size: 16, weight: .heavy))
        }
    }

    private var hostLobby: some View {
        @Bindable var app = app
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    // 1 だれと遊ぶ
                    VStack(alignment: .leading, spacing: 10) {
                        step(1, L.t("だれと遊ぶ？", "Who's playing?", hans: "和谁一起玩？", hant: "和誰一起玩？"))
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(Opponent.allCases, id: \.self) { o in opponentCard(o) }
                        }
                        if opponent == .link { linkSection }
                    }

                    // 2 DJ（名前とキャラ）
                    VStack(alignment: .leading, spacing: 12) {
                        step(2, "DJ")
                        djField(0)
                        characterRow(0)
                        djField(1)
                        if hostConnected {
                            Text("B · \(link.partnerName ?? "") — \(DJCharacter.named(link.partnerCharacter ?? "c02").name)")
                                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.cyan)
                        } else {
                            characterRow(1)
                        }
                    }

                    // 3 会場
                    VStack(alignment: .leading, spacing: 10) {
                        step(3, L.t("会場", "Venue", hans: "场地", hant: "場地"))
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(Venue.selectable) { v in venueCard(v) }
                        }
                    }

                    // 4 遊び方
                    VStack(alignment: .leading, spacing: 10) {
                        step(4, L.t("遊び方", "Mode", hans: "玩法", hant: "玩法"))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(GameMode.allCases) { m in modeCard(m) }
                        }
                        Text(app.config.mode.blurb).font(.footnote).foregroundStyle(.white.opacity(0.75))
                        modeOptions
                    }

                    // 音楽（Apple Music / Audius / DEMO）
                    MusicStatusCard()

                    // そのほか（ふだんは閉じておく）
                    DisclosureGroup(isExpanded: $showMore) {
                        VStack(alignment: .leading, spacing: 22) {
                            section(L.t("曲数", "SESSION LENGTH", hans: "曲数", hant: "曲數")) {
                                Picker("", selection: $app.config.length) {
                                    Text("5").tag(5); Text("10").tag(10); Text("20").tag(20); Text(L.t("無制限", "ENDLESS", hans: "无限制", hant: "無限制")).tag(0)
                                }
                                .pickerStyle(.segmented)
                            }
                            section(L.t("1曲の再生時間", "PLAY TIME PER TRACK", hans: "每首播放时长", hant: "每首播放時間")) {
                                Picker("", selection: $app.config.playLimit) {
                                    Text(L.t("30秒", "30s", hans: "30秒", hant: "30秒")).tag(30); Text(L.t("60秒", "60s", hans: "60秒", hant: "60秒")).tag(60); Text(L.t("90秒", "90s", hans: "90秒", hant: "90秒")).tag(90); Text(L.t("最後まで", "FULL", hans: "完整播放", hant: "完整播放")).tag(0)
                                }
                                .pickerStyle(.segmented)
                                Text(L.t("時間が来たら次の曲へ切り替わります（曲同士を重ねるミックスはしません）。", "When time is up the next track starts. Tracks are never mixed together.", hans: "时间一到就切换到下一首（不会把歌曲混接在一起）。", hant: "時間一到就切換到下一首（不會把歌曲混接在一起）。"))
                                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                            }
                            section(L.t("シークレット", "SECRET TRACK", hans: "秘密曲目", hant: "秘密曲目")) {
                                Toggle(L.t("次の曲を相手に隠す", "Hide next track from partner", hans: "对对方隐藏下一首", hant: "對對方隱藏下一首"), isOn: $app.config.secret)
                                    .disabled(app.config.mode == .secret)
                                    .tint(.purple)
                            }
                            section(L.t("観客", "CROWD", hans: "观众", hant: "觀眾")) {
                                Picker("", selection: $app.config.crowd) {
                                    ForEach(CrowdMode.allCases) { Text($0.label).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                Text(crowdHelp).font(.caption).foregroundStyle(.white.opacity(0.6))
                                Toggle(L.t("歓声・指笛・拍手を鳴らす", "Cheers, whistles and applause", hans: "播放欢呼、口哨和掌声", hant: "播放歡呼、口哨和掌聲"), isOn: $crowdSound)
                                    .tint(.pink)
                                    .onChange(of: crowdSound) { _, v in SoundFX.shared.enabled = v }
                            }
                            section(L.t("VJ（画面の映像）", "VJ", hans: "VJ（画面影像）", hant: "VJ（畫面影像）")) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(VJMode.allCases) { m in
                                            Button(m.label) { app.config.vjMode = m }
                                                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                                                .padding(.horizontal, 12).padding(.vertical, 7)
                                                .background(Capsule().fill(app.config.vjMode == m ? Color.purple.opacity(0.45) : .white.opacity(0.08)))
                                                .overlay(Capsule().stroke(app.config.vjMode == m ? .purple : .clear))
                                                .buttonStyle(.plain)
                                        }
                                    }
                                }
                                Text(L.t("LED 画面の映像。曲のジャケットとタイトル、盛り上がりで変わります（音は解析しません）。",
                                         "Visuals on the LED screens, driven by artwork, title and crowd energy (no audio analysis).", hans: "LED 屏幕的影像。会随歌曲封面、标题和气氛变化（不分析音频）。", hant: "LED 螢幕的影像。會隨歌曲封面、標題和氣氛變化（不分析音訊）。"))
                                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                            }
                            if link.role == .none {
                                section(L.t("画面を2分割（iPhone Duo）", "SPLIT SCREEN (iPhone Duo)", hans: "分屏（iPhone Duo）", hant: "分割畫面（iPhone Duo）")) {
                                    Picker("", selection: $app.splitMode) {
                                        ForEach(SplitMode.allCases) { Text($0.label).tag($0) }
                                    }
                                    .pickerStyle(.segmented)
                                    Text(L.t("iPhone Duo を開くと画面が左右に分かれ、2人がそれぞれの半分で同時に選曲できます。AUTO は広い画面のときだけ分けます。",
                                             "On an open iPhone Duo the screen splits left and right so each DJ picks on their own half. AUTO splits only on wide screens.", hans: "打开 iPhone Duo 后画面会分为左右两半，两人可在各自那一半同时选曲。AUTO 只在宽屏时分屏。", hant: "打開 iPhone Duo 後畫面會分成左右兩半，兩人可在各自那一半同時選曲。AUTO 只在寬螢幕時分割。"))
                                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                                }
                            }
                        }
                        .padding(.top, 12)
                    } label: {
                        Text(L.t("そのほかの設定（曲数・再生時間・観客・VJ など）", "More settings (length, play time, crowd, VJ...)", hans: "更多设置（曲数、播放时长、观众、VJ 等）", hant: "更多設定（曲數、播放時間、觀眾、VJ 等）"))
                            .font(.system(size: 14, weight: .heavy))
                    }
                    .tint(.white)
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }

            Button {
                app.start()
            } label: {
                Label(music.isReady ? L.t("スタート · \(music.sourceLabel)", "START · \(music.sourceLabel)", hans: "开始 · \(music.sourceLabel)", hant: "開始 · \(music.sourceLabel)") : L.t("Apple Music に接続するか AUDIUS / DEMO を選ぶ", "Connect Apple Music, or pick AUDIUS / DEMO", hans: "连接 Apple Music，或选择 AUDIUS / DEMO", hant: "連結 Apple Music，或選擇 AUDIUS / DEMO"),
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
        case .ai: return L.t("観客はルールで反応。", "The crowd reacts by rules.", hans: "观众按规则反应。", hant: "觀眾依規則反應。")
        case .player: return L.t("周りの人が絵文字で反応。AI 観客は休み。", "People around you react with emoji. No AI crowd.", hans: "周围的人用表情符号反应。AI 观众休息。", hant: "身邊的人用表情符號反應。AI 觀眾休息。")
        case .mix: return L.t("AI 観客と周りの人の反応を混ぜる。", "Mix AI crowd and real reactions.", hans: "混合 AI 观众和周围人的反应。", hant: "混合 AI 觀眾和身邊的人的反應。")
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
                Text(L.t("60秒", "60s", hans: "60秒", hant: "60秒")).tag(60); Text(L.t("45秒", "45s", hans: "45秒", hant: "45秒")).tag(45); Text(L.t("30秒", "30s", hans: "30秒", hant: "30秒")).tag(30); Text(L.t("15秒", "15s", hans: "15秒", hant: "15秒")).tag(15)
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
                TextField(L.t("DJの名前", "DJ NAME", hans: "DJ 名称", hant: "DJ 名稱"), text: $app.config.djNames[i])
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
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
                            SoundFX.shared.ui(.tap)
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
            SoundFX.shared.ui(.tap)
            app.config.mode = m
        } label: {
            HStack(spacing: 8) {
                Image(systemName: m.symbol)
                Text(m.label).font(.system(size: 12, weight: .heavy, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
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
        // 森・レコード屋は専用の観客動画、ほかのクラブは共通の観客に会場の色
        let own = UIImage(named: "venue_\(v.rawValue).jpg") != nil   // venues with their own crowd video have their own photo
        let img = UIImage(named: own ? "venue_\(v.rawValue).jpg" : "venue_club.jpg")
        return Button {
            SoundFX.shared.ui(.tap)
            app.config.venue = v
        } label: {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let img { Image(uiImage: img).resizable().scaledToFill() } else { Color.black }
                }
                .frame(height: 78)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(own ? AnyView(Color.clear) : AnyView(LinearGradient(colors: [v.palette.2.opacity(0.45), v.palette.0.opacity(0.55)], startPoint: .top, endPoint: .bottom).blendMode(.multiply)))
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.label).font(.system(size: 13, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
                    if let sub = v.subtitle { Text(sub).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8)) }
                }
                .padding(7)
                if on {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.cyan)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(6)
                }
            }
            .frame(height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Color.cyan : Color.white.opacity(0.12), lineWidth: on ? 3 : 1))
            .foregroundStyle(.white)
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

// 2台対戦の遊び方。開くと手順と注意が出る
struct LinkHowTo: View {
    @State private var open = false

    private var items: [(String, String)] {
        [
            ("iphone.gen3", L.t("2台ともこのアプリを入れてください。", "Both iPhones need this app installed.", hans: "两台都需要安装这个应用。", hant: "兩支都需要安裝這個 App。")),
            ("hand.tap", L.t("1台目は「ホスト」、2台目は「参加」を押して、出てきた相手の名前をタップするとつながります。", "Tap HOST on one iPhone and JOIN on the other, then tap the host's name.", hans: "第一台点“主机”，第二台点“加入”，再点出现的对方名称即可连接。", hant: "第一支點「主機」，第二支點「加入」，再點出現的對方名稱即可連線。")),
            ("antenna.radiowaves.left.and.right", L.t("近くにいるときだけ使えます。Wi‑Fi か Bluetooth をオンに。初めてのときに出る「ローカルネットワーク」の確認は「許可」を押してください。", "Works only nearby. Turn on Wi‑Fi or Bluetooth, and tap Allow when asked about the local network.", hans: "只能在附近使用。请打开 Wi‑Fi 或蓝牙。首次出现“本地网络”确认时请点“允许”。", hant: "只能在附近使用。請開啟 Wi‑Fi 或藍牙。第一次出現「區域網路」確認時請點「允許」。")),
            ("speaker.wave.2", L.t("音はホストの iPhone からだけ鳴ります。会場・観客・DJ の画面は2台とも同じものが映ります。", "Music plays only from the host. Both iPhones show the same venue, crowd and DJs.", hans: "声音只从主机的 iPhone 播放。两台都会显示相同的场地、观众和 DJ 画面。", hant: "聲音只從主機的 iPhone 播放。兩支都會顯示相同的場地、觀眾和 DJ 畫面。")),
            ("music.note", L.t("ホストが Apple Music のときは、JOIN 側の iPhone でも曲を探すために Apple Music の許可が必要です。AUDIUS か DEMO なら Apple Music は無くても遊べます。", "If the host uses Apple Music, the JOIN side also needs Apple Music access to search. With AUDIUS or DEMO, no Apple Music is needed.", hans: "主机使用 Apple Music 时，JOIN 一方的 iPhone 也需要 Apple Music 授权才能搜索歌曲。使用 AUDIUS 或 DEMO 则没有 Apple Music 也能玩。", hant: "主機使用 Apple Music 時，JOIN 端的 iPhone 也需要 Apple Music 授權才能搜尋歌曲。使用 AUDIUS 或 DEMO 就算沒有 Apple Music 也能玩。")),
            ("exclamationmark.triangle", L.t("ホスト側の Apple Music に無い曲は流せません。そのときは選び直しになります。", "Tracks missing from the host's Apple Music can't play; pick another.", hans: "主机的 Apple Music 里没有的歌无法播放，这时需要重新选择。", hant: "主機的 Apple Music 沒有的歌無法播放，這時需要重新選擇。")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                    Text(L.t("2台で遊ぶには", "How to play on 2 iPhones", hans: "两台 iPhone 怎么玩", hant: "兩支 iPhone 怎麼玩")).font(.system(size: 13, weight: .bold))
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption)
                }
                .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)
            if open {
                ForEach(items, id: \.1) { icon, text in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon).frame(width: 20).foregroundStyle(.white.opacity(0.7))
                        Text(text).font(.caption).foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
