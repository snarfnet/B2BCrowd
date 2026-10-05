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
    var unlocked: [String: [Achievement]] = [:]

    func start() {
        Self.saveConfig(config)
        let engine = GameEngine(config: config, player: music.player)
        screen = .session(engine)
    }

    func finish(_ engine: GameEngine) {
        unlocked = profiles.record(engine)
        screen = .result(engine)
    }

    /// 起動引数 `-shot <scene>` で決まった画面から始める（動作確認・スクショ用）
    func runShotScene() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-shot"), i + 1 < args.count else { return }
        music.demoMode = true
        switch args[i + 1] {
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
