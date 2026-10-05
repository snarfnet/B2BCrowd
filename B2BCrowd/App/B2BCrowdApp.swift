import SwiftUI

@main
struct B2BCrowdApp: App {
    @State private var app = AppModel()

    init() {
        SoundFX.configureSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.music)
                .environment(app.profiles)
                .preferredColorScheme(.dark)
                .task { await app.music.refresh() }
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
