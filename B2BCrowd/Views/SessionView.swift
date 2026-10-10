import SwiftUI

struct SessionView: View {
    let game: GameEngine

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSearch = false
    @State private var showHandoff = false
    @State private var confirmQuit = false
    @State private var isSplit = false

    var body: some View {
        GeometryReader { geo in
            Group {
            if useSplit(geo.size) {
                splitLayout(geo.size)
            } else {
                VStack(spacing: 10) {
                    topBar
                    EnergyMeter(energy: game.energy).padding(.horizontal)
                    floor
                    nowPlaying
                    nextPanel
                    interactions
                }
            }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { isSplit = useSplit(geo.size) }
            .onChange(of: geo.size) { _, s in isSplit = useSplit(s) }
        }
        .padding(.bottom, 8)
        .foregroundStyle(.white)
        .overlay { phaseOverlay }
        .overlay { if showHandoff { handoff } }
        .sheet(isPresented: $showSearch) {
            SearchView(game: game, initialTab: app.autoOpenSearchTab ?? 0) { game.reserve($0) }
        }
        .onAppear {
            if app.autoOpenSearchTab != nil { showSearch = true }
        }
        .task {
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let now = Date()
                game.tick(now.timeIntervalSince(last))
                last = now
            }
        }
        .onChange(of: game.phase) { _, p in
            if p == .result { app.finish(game) }
        }
        .onChange(of: scenePhase) { _, s in
            if s == .background { game.pause() }
        }
        .confirmationDialog(L.t("セッションを終了しますか？", "End this session?"), isPresented: $confirmQuit, titleVisibility: .visible) {
            Button(L.t("終了してリザルトへ", "End and see results"), role: .destructive) { game.quit() }
        }
    }

    // MARK: 左右分割（iPhone Duo を開いたとき）

    private func useSplit(_ size: CGSize) -> Bool {
        guard game.localDJ == nil, !game.isMirror else { return false }
        switch app.splitMode {
        case .on: return true
        case .off: return false
        case .auto: return size.width >= 560
        }
    }

    private func splitLayout(_ size: CGSize) -> some View {
        VStack(spacing: 8) {
            topBar
            EnergyMeter(energy: game.energy).padding(.horizontal)
            floorView(height: size.height * 0.34)
            nowPlaying
            HStack(spacing: 0) {
                SplitColumn(game: game, dj: 0)
                // 真ん中（Duo の折り目）
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 2)
                SplitColumn(game: game, dj: 1)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: 上の LED バー

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { game.pause() } label: { Image(systemName: "pause.fill").font(.title3) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    LEDText(text: game.config.venue.title, size: 12, color: game.config.venue.palette.2)
                    Text(app.music.sourceLabel)
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .foregroundStyle(.white.opacity(0.75))
                }
                LEDText(text: game.config.mode.title, size: 15, color: .cyan)
            }
            Spacer()
            if game.combo >= 2 {
                LEDText(text: "COMBO x\(game.combo)", size: 15, color: game.combo >= 10 ? .yellow : .orange)
            }
            LEDText(text: trackCounter, size: 15, color: .pink)
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var trackCounter: String {
        let n = max(1, game.tracksPlayed)
        return game.config.length > 0 ? "TRACK \(n)/\(game.config.length)" : "TRACK \(n)"
    }

    // MARK: フロア

    private var floor: some View {
        Booth3DView(state: boothState)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 300, maxHeight: 420)
            .layoutPriority(1)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topTrailing) { eventFeed }
            .overlay { bannerView }
            .padding(.horizontal)
    }

    private func floorView(height: CGFloat) -> some View {
        Booth3DView(state: boothState)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topTrailing) { eventFeed }
            .overlay { bannerView }
            .padding(.horizontal)
    }

    private var boothState: BoothState {
        BoothState(owner: game.currentOwner, currentID: game.current?.id, nextID: game.next?.id,
                   nextHidden: game.config.isSecret && game.phase != .transition, phase: game.phase,
                   selector: game.selector, energy: Int(game.energy.rounded()), venue: game.config.venue,
                   current: game.current, next: game.next, characters: game.config.characters,
                   vjMode: game.config.vjMode, djName: game.name(game.currentOwner),
                   reactions: game.reactions.map { ($0.id, $0.text) })
    }

    private var eventFeed: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(game.events.suffix(4)) { e in
                Text(e.value == 0 ? e.text : "\(e.text) \(e.value > 0 ? "+" : "")\(e.value)")
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill((e.value >= 0 ? Color.green : Color.red).opacity(0.3)))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(8)
        .animation(.spring(duration: 0.35), value: game.events.map(\.id))
    }

    @ViewBuilder
    private var bannerView: some View {
        if let b = game.banner {
            Group {
                switch b {
                case .combo(let n):
                    LEDText(text: n >= 10 ? "\(n) COMBO!!!" : "\(n) COMBO!", size: n >= 10 ? 46 : 36, color: n >= 10 ? .yellow : .orange)
                case .legendary:
                    VStack {
                        LEDText(text: "LEGENDARY", size: 44, color: .yellow)
                        LEDText(text: "FLOOR", size: 44, color: .pink)
                    }
                case .floorEmpty:
                    LEDText(text: "FLOOR EMPTY", size: 40, color: .red)
                case .timeUp(let who):
                    LEDText(text: "TIME UP · \(who)", size: 28, color: .red)
                case .notice(let s):
                    Text(s).font(.system(size: 15, weight: .bold)).padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.75)))
                }
            }
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: いまの曲

    private var nowPlaying: some View {
        HStack(spacing: 14) {
            ArtworkView(track: game.current)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text("NOW · \(game.current == nil ? "—" : game.name(game.currentOwner))")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(game.currentOwner == 0 ? .pink : .cyan)
                Text(game.current?.title ?? L.t("まだ何も流れていない", "Nothing playing yet"))
                    .font(.system(size: 17, weight: .bold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(game.current?.artist ?? " ").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    if let url = game.current?.externalURL {
                        // 帰属表示：出典と元の曲ページ
                        Link(destination: url) {
                            Text("Audius ↗").font(.system(size: 10, weight: .heavy, design: .monospaced))
                        }
                        .foregroundStyle(.purple)
                    }
                }
                if game.current != nil {
                    ProgressView(value: min(game.trackElapsed, game.trackLength), total: max(1, game.trackLength))
                        .tint(game.phase == .countdown ? .red : .pink)
                    HStack {
                        Text(formatTime(game.trackElapsed))
                        Spacer()
                        Text("-" + formatTime(game.remaining))
                    }
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                }
            }
            if game.phase == .countdown {
                LEDText(text: "\(Int(ceil(game.remaining)))", size: 38, color: .red)
                    .frame(width: 50)
            }
        }
        .padding(.horizontal)
    }

    // MARK: 次の曲

    private var nextPanel: some View {
        let dj = game.selector
        let tint: Color = dj == 0 ? .pink : .cyan
        return VStack(spacing: 8) {
            HStack {
                LEDText(text: "NEXT ▶ \(game.name(dj))", size: 14, color: tint)
                Spacer()
                if let left = game.selectionTimeLeft {
                    LEDText(text: formatTime(left), size: 16, color: left <= 10 ? .red : .yellow)
                }
            }
            if !game.canPickHere && game.next == nil {
                HStack(spacing: 10) {
                    ProgressView().tint(tint)
                    Text(L.t("\(game.name(dj)) が相手の iPhone で選曲中…", "\(game.name(dj)) is picking on their iPhone…"))
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                }
                .frame(minHeight: 44)
            } else if let n = game.next {
                HStack(spacing: 10) {
                    ArtworkView(track: n, hidden: nextHidden)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading) {
                        Text(nextHidden ? "SECRET TRACK 🔒" : n.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                        Text(nextHidden ? L.t("切り替わるまで秘密", "Hidden until it drops") : n.artist)
                            .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    Spacer()
                    if game.canPickHere {
                        Button(L.t("変更", "Change")) { openSearch() }.buttonStyle(.bordered).tint(tint)
                        Button { game.clearNext() } label: { Image(systemName: "xmark") }.buttonStyle(.bordered).tint(.gray)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Button { openSearch() } label: {
                        Label(L.t("次の曲を選ぶ", "PICK NEXT TRACK"), systemImage: "magnifyingglass")
                    }
                    .buttonStyle(NeonButtonStyle(color: tint))
                    Button("PASS") { game.pass() }
                        .buttonStyle(NeonButtonStyle(color: .gray, filled: false))
                        .frame(width: 96)
                        .disabled(game.phase == .searchingTrack)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.4)))
        .padding(.horizontal)
    }

    /// SECRET TRACK。2台対戦なら自分で選んだ曲は自分の画面にだけ見せる
    private var nextHidden: Bool { game.config.isSecret && !(game.localDJ != nil && game.canPickHere) }

    private func openSearch() {
        guard game.canPickHere else { return }
        // 2台対戦なら自分の iPhone なので、隠すための受け渡し画面はいらない
        if game.config.isSecret && game.localDJ == nil { showHandoff = true } else { showSearch = true }
    }

    // MARK: 相手DJ・観客のリアクション

    private var interactions: some View {
        VStack(spacing: 8) {
            if game.needsJudge && game.canJudgeHere {
                HStack(spacing: 10) {
                    Text(game.config.mode == .shiritori
                         ? L.t("\(game.name(1 - game.currentOwner))：繋がってる？", "\(game.name(1 - game.currentOwner)): linked?")
                         : L.t("\(game.name(1 - game.currentOwner))：お題「\(game.config.theme)」に合ってる？", "\(game.name(1 - game.currentOwner)): fits “\(game.config.theme)”?"))
                        .font(.system(size: 12, weight: .bold)).lineLimit(2)
                    Spacer()
                    Button { game.judge(true) } label: { Image(systemName: "checkmark") }.buttonStyle(.borderedProminent).tint(.green)
                    Button { game.judge(false) } label: { Image(systemName: "xmark") }.buttonStyle(.borderedProminent).tint(.red)
                }
                .padding(.horizontal)
            }
            HStack(spacing: 8) {
                Button { game.like() } label: {
                    Label("LIKE", systemImage: game.likedThisRound ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .heavy))
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .layoutPriority(1)
                .tint(.pink)
                .disabled(game.likedThisRound || game.current == nil || !game.canJudgeHere)

                if game.showsPad {
                    ForEach(Reaction.allCases) { r in
                        Button { game.react(r) } label: { Text(r.rawValue).font(.system(size: 22)) }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Spacer()
                    Text("AI CROWD").font(.system(size: 11, weight: .heavy, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: 全画面の状態表示

    @ViewBuilder
    private var phaseOverlay: some View {
        switch game.phase {
        case .searchingTrack where !isSplit:
            overlayCard {
                LEDText(text: "OPENING", size: 30, color: .pink)
                Text(L.t("\(game.name(game.selector)) が1曲目を選ぶ", "\(game.name(game.selector)) picks the opener"))
                    .font(.headline)
                if game.canPickHere {
                    Button { openSearch() } label: { Label(L.t("1曲目を選ぶ", "PICK OPENER"), systemImage: "magnifyingglass") }
                        .buttonStyle(NeonButtonStyle(color: .pink))
                } else {
                    ProgressView().tint(.pink)
                }
            }
        case .waitingForNextDJ where !isSplit:
            VStack {
                Spacer()
                VStack(spacing: 6) {
                    LEDText(text: L.t("無音！", "SILENCE!"), size: 30, color: .red)
                    Text(L.t("\(game.name(game.selector)) 早く次の曲を！", "\(game.name(game.selector)), drop the next track!"))
                        .font(.headline)
                    if game.canPickHere {
                        Button { openSearch() } label: { Label(L.t("次の曲を選ぶ", "PICK NEXT TRACK"), systemImage: "magnifyingglass") }
                            .buttonStyle(NeonButtonStyle(color: .red))
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.88)))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.red, lineWidth: 2))
                .padding()
                Spacer().frame(height: 120)
            }
        case .transition:
            NextTrackReveal(track: game.next, dj: game.name(game.selector), tint: game.selector == 0 ? .pink : .cyan)
        case .paused:
            overlayCard {
                LEDText(text: "PAUSED", size: 34, color: .yellow)
                Button { Task { await game.resume() } } label: { Label(L.t("再開", "RESUME"), systemImage: "play.fill") }
                    .buttonStyle(NeonButtonStyle(color: .green))
                Button { confirmQuit = true } label: { Label(L.t("セッション終了", "END SESSION"), systemImage: "stop.fill") }
                    .buttonStyle(NeonButtonStyle(color: .red, filled: false))
            }
        default:
            EmptyView()
        }
    }

    private func overlayCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()
            VStack(spacing: 16) { content() }
                .padding(28)
                .frame(maxWidth: 360)
        }
    }

    private var handoff: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "eye.slash.fill").font(.system(size: 40)).foregroundStyle(.purple)
                LEDText(text: "SECRET TRACK", size: 26, color: .purple)
                Text(L.t("\(game.name(game.selector)) だけが画面を見てください", "Only \(game.name(game.selector)) should look now"))
                    .font(.headline).multilineTextAlignment(.center)
                Button(L.t("OK、選ぶ", "OK, pick")) {
                    showHandoff = false
                    showSearch = true
                }
                .buttonStyle(NeonButtonStyle(color: .purple))
                Button(L.t("やめる", "Cancel")) { showHandoff = false }.foregroundStyle(.white.opacity(0.7))
            }
            .padding(28)
            .frame(maxWidth: 360)
        }
    }
}

// NEXT TRACK! 切り替え演出。SECRET TRACK もここで初めて見える。
struct NextTrackReveal: View {
    let track: Track?
    let dj: String
    let tint: Color
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            VStack(spacing: 18) {
                LEDText(text: "NEXT TRACK!", size: 40, color: tint)
                    .scaleEffect(shown ? 1 : 2.2)
                    .opacity(shown ? 1 : 0)
                ArtworkView(track: track, size: .large)
                    .frame(width: 230, height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: tint.opacity(0.8), radius: 30)
                    .scaleEffect(shown ? 1 : 0.3)
                    .rotation3DEffect(.degrees(shown ? 0 : 180), axis: (x: 0, y: 1, z: 0))
                VStack(spacing: 4) {
                    Text(track?.title ?? "").font(.system(size: 22, weight: .heavy)).multilineTextAlignment(.center)
                    Text(track?.artist ?? "").font(.system(size: 16)).foregroundStyle(.white.opacity(0.75))
                    if track?.sourceKind == .audius {
                        Text("Source: Audius").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.purple)
                    }
                    LEDText(text: "by \(dj)", size: 16, color: tint).padding(.top, 6)
                }
                .opacity(shown ? 1 : 0)
            }
            .padding()
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.65)) { shown = true }
        }
    }
}
