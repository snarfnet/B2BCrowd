import SwiftUI
import MusicKit

struct TitleView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            CrowdView(energy: 72, venue: .tokyoNight, reactions: [], active: true)
                .ignoresSafeArea()
                .overlay(LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())

            VStack(spacing: 18) {
                Spacer()
                VStack(spacing: 6) {
                    LEDText(text: "B2B", size: 64, color: .pink)
                    LEDText(text: "CROWD", size: 52, color: .cyan)
                    Text(L.t("選曲だけでフロアを100%まで沸かせ", "Move the floor to 100% with selection alone"))
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
                    Label(L.t("DJ プロフィール", "DJ PROFILES"), systemImage: "person.2.fill")
                }
                .buttonStyle(NeonButtonStyle(color: .cyan, filled: false))
            }
            .padding(24)
        }
    }
}

// Apple Music の接続状態。使えなくてもアプリ自体はデモモードで遊べる。
struct MusicStatusCard: View {
    @Environment(MusicService.self) private var music
    @State private var showOffer = false

    var body: some View {
        @Bindable var music = music
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(statusText).font(.system(size: 14, weight: .bold))
                Spacer()
            }
            if let help = helpText {
                Text(help).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 10) {
                switch music.access {
                case .unknown, .notDetermined:
                    Button(L.t("Apple Music に接続", "Connect Apple Music")) {
                        Task { await music.requestAccess() }
                    }
                    .buttonStyle(.borderedProminent).tint(.pink)
                case .denied, .restricted:
                    Button(L.t("設定を開く", "Open Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.bordered)
                case .authorized:
                    if !music.canPlayCatalog && music.subscriptionChecked {
                        Button(L.t("Apple Music に登録", "Get Apple Music")) { showOffer = true }
                            .buttonStyle(.bordered)
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

    private var ready: Bool { music.access == .authorized && music.canPlayCatalog }

    private var icon: String {
        if music.demoMode { return "gamecontroller.fill" }
        return ready ? "checkmark.circle.fill" : "music.note"
    }

    private var color: Color {
        if music.demoMode { return .orange }
        return ready ? .green : .pink
    }

    private var statusText: String {
        if music.demoMode { return L.t("デモモード（音なし・架空の曲）", "Demo mode (silent, fictional tracks)") }
        switch music.access {
        case .authorized:
            if !music.subscriptionChecked { return L.t("Apple Music を確認中…", "Checking Apple Music…") }
            return music.canPlayCatalog ? L.t("Apple Music 接続済み", "Apple Music connected") : L.t("Apple Music の再生ができません", "Apple Music playback unavailable")
        case .denied: return L.t("Apple Music へのアクセスが拒否されています", "Apple Music access denied")
        case .restricted: return L.t("Apple Music が制限されています", "Apple Music is restricted")
        default: return L.t("Apple Music 未接続", "Apple Music not connected")
        }
    }

    private var helpText: String? {
        if music.demoMode { return L.t("流れとルールを試すモード。曲は再生されません。", "Try the rules and flow. No music plays.") }
        switch music.access {
        case .authorized where music.subscriptionChecked && !music.canPlayCatalog:
            return L.t("曲の再生には Apple Music のサブスクリプションが必要です。", "Playing songs requires an Apple Music subscription.")
        case .denied, .restricted:
            return L.t("設定アプリで「メディアと Apple Music」を許可するか、DEMO で遊べます。", "Allow Media & Apple Music in Settings, or play in DEMO.")
        default: return nil
        }
    }
}
