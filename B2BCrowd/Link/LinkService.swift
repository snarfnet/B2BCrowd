import Foundation
import MultipeerConnectivity

// iPhone 2台の対戦。近くの iPhone 同士を Wi‑Fi / Bluetooth で直接つなぐ（サーバーは使わない）。
// ホスト（DJ A）がゲームを進めて音を鳴らし、ゲスト（DJ B）は自分の iPhone で曲を探して送る。
// ゲストの画面はホストから届く状態をそのまま写す。

struct LinkError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

enum LinkCommand: Codable {
    case pick(Track), clearNext, pass, like, judge(Bool), react(String), pause, resume
}

struct LinkSnapshot: Codable {
    var phase: GameEngine.Phase
    var energy: Double
    var peakEnergy: Double
    var combo: Int
    var maxCombo: Int
    var scores: [ScoreCard]
    var rounds: [RoundRecord]
    var current: Track?
    var currentOwner: Int
    var next: Track?
    var selector: Int
    var selectionElapsed: TimeInterval
    var trackElapsed: TimeInterval
    var events: [FloatEvent]
    var reactions: [FloatEvent]
    var banner: GameEngine.Banner?
    var finishReason: FinishReason?
    var likedThisRound: Bool
    var judgedThisRound: Bool
    var playedIDs: [String]
}

enum LinkMessage: Codable {
    /// 名前とキャラを教え合う
    case hello(name: String, character: String)
    /// ホスト→ゲスト：この設定・この音源で始める
    case start(SessionConfig, demo: Bool, source: MusicSourceKind)
    case snapshot(LinkSnapshot)
    case command(LinkCommand)
    /// ホスト→ゲスト：ロビーに戻った
    case backToLobby
}

@MainActor
@Observable
final class LinkService: NSObject {
    enum Role { case none, host, guest }
    enum State { case idle, waiting, connecting, connected }

    struct Host: Identifiable {
        let peer: MCPeerID
        let name: String
        var id: String { peer.displayName + "\(peer.hash)" }
    }

    private(set) var role: Role = .none
    private(set) var state: State = .idle
    private(set) var hosts: [Host] = []
    private(set) var partnerName: String?
    private(set) var partnerCharacter: String?
    private(set) var lastError: String?

    var onMessage: ((LinkMessage) -> Void)?
    var onDisconnect: (() -> Void)?

    /// 自分の名前とキャラ（hello で送る）
    var myName = "DJ"
    var myCharacter = "c09"

    var isLinked: Bool { role != .none }
    var isConnected: Bool { state == .connected }

    private static let serviceType = "b2bcrowd"
    private var peer: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    // MARK: 始める・やめる

    func host(name: String, character: String) {
        stop()
        myName = name; myCharacter = character
        let p = makeSession(name)
        let a = MCNearbyServiceAdvertiser(peer: p, discoveryInfo: ["name": String(name.prefix(40))], serviceType: Self.serviceType)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a
        role = .host
        state = .waiting
    }

    func join(name: String, character: String) {
        stop()
        myName = name; myCharacter = character
        let p = makeSession(name)
        let b = MCNearbyServiceBrowser(peer: p, serviceType: Self.serviceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
        role = .guest
        state = .waiting
    }

    func connect(to h: Host) {
        guard let session, let browser else { return }
        state = .connecting
        browser.invitePeer(h.peer, to: session, withContext: nil, timeout: 20)
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil; browser = nil; session = nil; peer = nil
        role = .none
        state = .idle
        hosts = []
        partnerName = nil; partnerCharacter = nil
    }

    func send(_ m: LinkMessage) {
        guard let session, !session.connectedPeers.isEmpty, let d = try? JSONEncoder().encode(m) else { return }
        try? session.send(d, toPeers: session.connectedPeers, with: .reliable)
    }

    private func makeSession(_ name: String) -> MCPeerID {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let p = MCPeerID(displayName: String((trimmed.isEmpty ? "DJ" : trimmed).prefix(30)))
        let s = MCSession(peer: p, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        peer = p; session = s
        return p
    }

    // MARK: 届いたもの

    private func connected() {
        state = .connected
        lastError = nil
        // つながったら探す・待つのをやめる（3台目は入れない）
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        send(.hello(name: myName, character: myCharacter))
    }

    private func disconnected() {
        guard state == .connected || state == .connecting else { return }
        let wasConnected = state == .connected
        partnerName = nil; partnerCharacter = nil
        if role == .host {
            state = .waiting
            advertiser?.startAdvertisingPeer()
        } else {
            state = .waiting
            hosts = []
            browser?.startBrowsingForPeers()
        }
        if wasConnected {
            lastError = L.t("接続が切れました", "Connection lost")
            onDisconnect?()
        } else {
            lastError = L.t("つながりませんでした。もう一度試してください", "Couldn't connect. Try again.")
        }
    }

    private func received(_ m: LinkMessage) {
        if case .hello(let n, let c) = m {
            partnerName = n
            partnerCharacter = c
        }
        onMessage?(m)
    }
}

extension LinkService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            guard session === self.session else { return }
            switch state {
            case .connected: self.connected()
            case .notConnected: self.disconnected()
            case .connecting: self.state = .connecting
            @unknown default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let m = try? JSONDecoder().decode(LinkMessage.self, from: data) else { return }
        Task { @MainActor in
            guard session === self.session else { return }
            self.received(m)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension LinkService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            // 相手は1人だけ
            guard let session = self.session, session.connectedPeers.isEmpty else {
                invitationHandler(false, nil)
                return
            }
            invitationHandler(true, session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in self.lastError = error.localizedDescription }
    }
}

extension LinkService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let name = info?["name"] ?? peerID.displayName
        Task { @MainActor in
            guard browser === self.browser else { return }
            self.hosts.removeAll { $0.peer == peerID }
            self.hosts.append(Host(peer: peerID, name: name))
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.hosts.removeAll { $0.peer == peerID } }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in self.lastError = error.localizedDescription }
    }
}
