import SwiftUI

@main
struct B2BCrowdApp: App {
    @State private var app = AppModel()

    init() {
        SoundFX.configureSession()
        ClubScene.preload()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.music)
                .environment(app.profiles)
                .environment(app.link)
                .preferredColorScheme(.dark)
                .task {
                    await app.music.refresh()
                    app.runShotScene()
                }
        }
    }
}

@MainActor
@Observable
final class AppModel {
    enum Screen {
        case title
        case lobby
        case session(GameEngine)
        case result(GameEngine)
        case profiles
    }

    var screen: Screen = .title
    var config: SessionConfig = AppModel.loadConfig()
    let music = MusicService()
    let profiles = ProfileStore()
    let link = LinkService()
    /// 画面を左右に分けて2人が同時に選曲（iPhone Duo を開いたとき）
    var splitMode: SplitMode = SplitMode(rawValue: UserDefaults.standard.string(forKey: "splitMode") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(splitMode.rawValue, forKey: "splitMode") }
    }
    /// 動作確認用：2台対戦でも自動で選曲する
    private var linkAutopilot = false

    init() {
        link.onMessage = { [weak self] m in self?.received(m) }
        link.onDisconnect = { [weak self] in self?.partnerLeft() }
    }
    var unlocked: [String: [Achievement]] = [:]
    /// スクショ用：セッション開始時に検索画面を開く（タブ番号）
    var autoOpenSearchTab: Int?

    func start() {
        Self.saveConfig(config)
        if link.role == .guest { return }
        var c = config
        if link.role == .host, link.isConnected {
            // DJ B は相手の iPhone の人
            c.djNames[1] = link.partnerName ?? c.djNames[1]
            if c.characters.count == 2, let pc = link.partnerCharacter { c.characters[1] = pc }
        }
        let engine = GameEngine(config: c, player: music.player)
        if link.role == .host, link.isConnected {
            engine.localDJ = 0
            engine.autopilot = linkAutopilot
            engine.onTick = { [weak self, weak engine] in
                guard let self, let engine else { return }
                self.link.send(.snapshot(engine.snapshot()))
            }
            link.send(.start(c, demo: music.demoMode, source: music.source))
        }
        screen = .session(engine)
    }

    func backToLobby() {
        if link.role == .host { link.send(.backToLobby) }
        screen = .lobby
    }

    func backToTitle() {
        link.stop()
        screen = .title
    }

    // MARK: 2台対戦

    private func received(_ m: LinkMessage) {
        switch m {
        case .hello:
            break
        case .start(let c, let demo, let source):
            guard link.role == .guest else { return }
            music.demoMode = demo
            if !demo { music.source = source }
            music.stopAll()
            let engine = GameEngine(config: c, player: music.demoPlayer, mirror: true)
            engine.localDJ = 1
            engine.autopilot = linkAutopilot
            engine.sendCommand = { [weak self] cmd in self?.link.send(.command(cmd)) }
            screen = .session(engine)
        case .snapshot(let s):
            if case .session(let g) = screen { g.apply(s) }
        case .command(let cmd):
            if case .session(let g) = screen, link.role == .host { g.handle(cmd, from: 1) }
        case .backToLobby:
            if link.role == .guest, case .result = screen { screen = .lobby }
        }
    }

    private func partnerLeft() {
        if case .session(let g) = screen { g.partnerLeft() }
    }

    func finish(_ engine: GameEngine) {
        // ゲストが途中でやめたら接続も切る（ホストは1台で続ける）
        if engine.isMirror, engine.finishReason == .quit, link.isConnected { link.stop() }
        unlocked = profiles.record(engine)
        screen = .result(engine)
    }

    /// 起動引数 `-shot <scene>` で決まった画面から始める（動作確認・スクショ用）
    func runShotScene() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-shot"), i + 1 < args.count else { return }
        music.demoMode = true
        switch args[i + 1] {
        case "linkhost", "linkguest":
            // 2台対戦の確認：シミュレーター2台でホストとゲストを立て、つながったら自動で回す
            linkAutopilot = true
            config.length = 4
            config.playLimit = 20
            config.mode = .free
            config.venue = .forestRave
            if args[i + 1] == "linkhost" {
                config.djNames[0] = "DJ HOST"
                link.host(name: "DJ HOST", character: "c09")
                screen = .lobby
                Task { @MainActor in
                    while !link.isConnected || link.partnerName == nil { try? await Task.sleep(for: .seconds(1)) }
                    try? await Task.sleep(for: .seconds(2))
                    start()
                }
            } else {
                link.join(name: "DJ GUEST", character: "c12")
                screen = .lobby
                Task { @MainActor in
                    while link.hosts.isEmpty { try? await Task.sleep(for: .seconds(1)) }
                    link.connect(to: link.hosts[0])
                }
            }
        case "split":
            splitMode = .on
            var c = SessionConfig()
            c.djNames = ["DJ KAORI", "DJ NEON"]
            c.mode = .free
            c.length = 20
            c.playLimit = 30
            c.crowd = .mix
            c.venue = .recordShop
            config = c
            let engine = GameEngine(config: c, player: music.player)
            engine.autopilot = true
            screen = .session(engine)
        case "audius", "audiussearch":
            // Audius の実ストリーミングで B2B を通す（TEST 1）／ TRENDING 検索画面
            music.demoMode = false
            music.source = .audius
            var c = SessionConfig()
            c.djNames = ["DJ KAORI", "DJ NEON"]
            c.mode = .timeAttack
            c.length = 4
            c.playLimit = 25
            c.crowd = .mix
            c.venue = .tokyoNight
            c.characters = ["c09", "c02"]
            config = c
            let engine = GameEngine(config: c, player: music.player)
            if args[i + 1] == "audiussearch" {
                autoOpenSearchTab = 1
                screen = .session(engine)
                return
            }
            engine.autopilot = true
            Task { @MainActor in
                let list = (try? await music.trendingAudius(AudiusTrendingCategory.all[1])) ?? []
                var pool: [Track] = []
                for t in list where await music.audiusPlayability(t).isPlayable { pool.append(t) }
                print("AUDIUS_SHOT pool=\(pool.count) of \(list.count)")
                engine.autopilotPool = pool.isEmpty ? DemoCatalog.tracks : pool
                screen = .session(engine)
            }
        case "lobby":
            screen = .lobby
        case "session", "result":
            var c = SessionConfig()
            c.djNames = ["DJ KAORI", "DJ NEON"]
            c.mode = args[i + 1] == "result" ? .free : .timeAttack
            c.length = args[i + 1] == "result" ? 3 : 20
            c.playLimit = 30
            c.crowd = .mix
            c.venue = .tokyoNight
            c.characters = args[i + 1] == "result" ? ["c09", "c02"] : ["r02", "c12"]
            config = c
            let engine = GameEngine(config: c, player: music.player)
            engine.autopilot = true
            screen = .session(engine)
        default:
            break
        }
    }

    private static let configKey = "sessionConfig.v1"

    private static func loadConfig() -> SessionConfig {
        guard let d = UserDefaults.standard.data(forKey: configKey),
              let c = try? JSONDecoder().decode(SessionConfig.self, from: d) else { return SessionConfig() }
        return c
    }

    private static func saveConfig(_ c: SessionConfig) {
        if let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: configKey) }
    }
}

enum SplitMode: String, CaseIterable, Identifiable {
    case auto, on, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "AUTO"
        case .on: return "ON"
        case .off: return "OFF"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch app.screen {
            case .title: TitleView()
            case .lobby: LobbyView()
            case .session(let g): SessionView(game: g)
            case .result(let g): ResultView(game: g)
            case .profiles: ProfilesView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: screenKey)
    }

    private var screenKey: Int {
        switch app.screen {
        case .title: return 0
        case .lobby: return 1
        case .session: return 2
        case .result: return 3
        case .profiles: return 4
        }
    }
}
