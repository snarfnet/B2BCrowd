import SwiftUI
import MusicKit

struct TitleView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Booth3DView(state: BoothState(owner: 0, currentID: "title", nextID: nil, nextHidden: false, phase: .playing,
                                          selector: 1, energy: 72, venue: .tokyoNight,
                                          current: DemoCatalog.tracks.first, next: nil))
                .ignoresSafeArea()
                .overlay(LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())

            VStack(spacing: 18) {
                Spacer()
                VStack(spacing: 6) {
                    LEDText(text: "B2B", size: 64, color: .pink)
                    LEDText(text: "CROWD", size: 52, color: .cyan)
                    LEDText(text: "DUO", size: 34, color: .purple)
                    Text(L.t("選曲だけでフロアを100%まで沸かせ", "Move the floor to 100% with selection alone", hans: "只靠选曲把舞池嗨到 100%", hant: "只靠選曲把舞池炒熱到 100%"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.top, 6)
                }
                Spacer()
                MusicStatusCard()
                Button {
                    app.screen = .lobby
                } label: {
                    Label("START B2B", systemImage: "play.fill")
                }
                .buttonStyle(NeonButtonStyle(color: .pink))

                Button {
                    app.screen = .profiles
                } label: {
                    Label(L.t("DJ プロフィール", "DJ PROFILES", hans: "DJ 资料", hant: "DJ 檔案"), systemImage: "person.2.fill")
                }
                .buttonStyle(NeonButtonStyle(color: .cyan, filled: false))
            }
            .padding(24)
        }
    }
}

// 音楽ソースの選択と接続状態。使えなくてもアプリ自体はデモモードで遊べる。
struct MusicStatusCard: View {
    @Environment(MusicService.self) private var music
    @State private var showOffer = false

    var body: some View {
        @Bindable var music = music
        VStack(alignment: .leading, spacing: 10) {
            Text(L.t("音楽", "MUSIC SOURCE", hans: "音乐", hant: "音樂")).font(.system(size: 11, weight: .heavy, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            Picker("", selection: $music.source) {
                ForEach(MusicSourceKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(music.demoMode)
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(statusText).font(.system(size: 14, weight: .bold))
                Spacer()
            }
            if let help = helpText {
                Text(help).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 10) {
                if music.source == .audius {
                    Link(destination: URL(string: "https://audius.co")!) {
                        Label("audius.co", systemImage: "arrow.up.right.square")
                    }
                    .font(.caption)
                } else {
                switch music.access {
                case .unknown, .notDetermined:
                    Button(L.t("Apple Music に接続", "Connect Apple Music", hans: "连接 Apple Music", hant: "連結 Apple Music")) {
                        Task { await music.requestAccess() }
                    }
                    .buttonStyle(.borderedProminent).tint(.pink)
                case .denied, .restricted:
                    Button(L.t("設定を開く", "Open Settings", hans: "打开设置", hant: "開啟設定")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.bordered)
                case .authorized:
                    if !music.canPlayCatalog && music.subscriptionChecked {
                        Button(L.t("Apple Music に登録", "Get Apple Music", hans: "订阅 Apple Music", hant: "訂閱 Apple Music")) { showOffer = true }
                            .buttonStyle(.bordered)
                    }
                }
                }
                Spacer()
                Toggle(isOn: $music.demoMode) {
                    Text("DEMO").font(.system(size: 12, weight: .heavy, design: .monospaced))
                }
                .fixedSize()
                .tint(.orange)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
        .musicSubscriptionOffer(isPresented: $showOffer)
        .onChange(of: showOffer) { _, shown in
            if !shown { Task { await music.refresh() } }
        }
    }

    private var ready: Bool { music.isReady }

    private var icon: String {
        if music.demoMode { return "gamecontroller.fill" }
        return ready ? "checkmark.circle.fill" : "music.note"
    }

    private var color: Color {
        if music.demoMode { return .orange }
        return ready ? .green : .pink
    }

    private var statusText: String {
        if music.demoMode { return L.t("デモモード（音なし・架空の曲）", "Demo mode (silent, fictional tracks)", hans: "演示模式（无声、虚构曲目）", hant: "示範模式（無聲、虛構曲目）") }
        if music.source == .audius { return L.t("Audius（無料・登録不要）", "Audius (free, no sign-in)", hans: "Audius（免费、无需注册）", hant: "Audius（免費、免註冊）") }
        switch music.access {
        case .authorized:
            if !music.subscriptionChecked { return L.t("Apple Music を確認中…", "Checking Apple Music…", hans: "正在检查 Apple Music…", hant: "正在檢查 Apple Music…") }
            return music.canPlayCatalog ? L.t("Apple Music 接続済み", "Apple Music connected", hans: "Apple Music 已连接", hant: "Apple Music 已連結") : L.t("Apple Music の再生ができません", "Apple Music playback unavailable", hans: "无法播放 Apple Music", hant: "無法播放 Apple Music")
        case .denied: return L.t("Apple Music へのアクセスが拒否されています", "Apple Music access denied", hans: "Apple Music 访问被拒绝", hant: "Apple Music 存取遭拒")
        case .restricted: return L.t("Apple Music が制限されています", "Apple Music is restricted", hans: "Apple Music 受到限制", hant: "Apple Music 受到限制")
        default: return L.t("Apple Music 未接続", "Apple Music not connected", hans: "Apple Music 未连接", hant: "Apple Music 未連結")
        }
    }

    private var helpText: String? {
        if music.demoMode { return L.t("流れとルールを試すモード。曲は再生されません。", "Try the rules and flow. No music plays.", hans: "试玩流程和规则的模式。不会播放歌曲。", hant: "試玩流程和規則的模式。不會播放歌曲。") }
        if music.source == .audius {
            return L.t("アーティストが Audius に公開している曲を公式 API でストリーミングします。ネット接続が必要です。",
                       "Streams tracks artists publish on Audius through the official API. Needs a connection.", hans: "通过官方 API 串流播放艺人在 Audius 上发布的歌曲。需要网络连接。", hant: "透過官方 API 串流播放藝人在 Audius 上發布的歌曲。需要網路連線。")
        }
        switch music.access {
        case .authorized where music.subscriptionChecked && !music.canPlayCatalog:
            return L.t("曲の再生には Apple Music のサブスクリプションが必要です。", "Playing songs requires an Apple Music subscription.", hans: "播放歌曲需要订阅 Apple Music。", hant: "播放歌曲需要訂閱 Apple Music。")
        case .denied, .restricted:
            return L.t("設定アプリで「メディアと Apple Music」を許可するか、DEMO で遊べます。", "Allow Media & Apple Music in Settings, or play in DEMO.", hans: "请在“设置”App 中允许“媒体与 Apple Music”，或用 DEMO 来玩。", hant: "請在「設定」App 中允許「媒體與 Apple Music」，或用 DEMO 來玩。")
        default: return nil
        }
    }
}
