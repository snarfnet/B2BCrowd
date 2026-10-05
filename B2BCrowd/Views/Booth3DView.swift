import SwiftUI
import SceneKit

// 3D の DJ ブース。左が DJ A のデッキ、右が DJ B のデッキ、真ん中がミキサー。
// 2人の手がゲームの状態に合わせて機材を触る。見た目だけの演出で、
// 音の加工（ピッチ・スクラッチ・ミックス）は一切しない。
struct BoothState: Equatable {
    var owner: Int
    var currentID: String?
    var nextID: String?
    var nextHidden: Bool
    var phase: GameEngine.Phase
    var selector: Int
    var energy: Int
    var venue: Venue
    var current: Track?
    var next: Track?

    static func == (l: BoothState, r: BoothState) -> Bool {
        l.owner == r.owner && l.currentID == r.currentID && l.nextID == r.nextID && l.nextHidden == r.nextHidden
            && l.phase == r.phase && l.selector == r.selector && l.energy == r.energy && l.venue == r.venue
    }
}

struct Booth3DView: UIViewRepresentable {
    let state: BoothState

    func makeCoordinator() -> BoothScene { BoothScene() }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.scene = context.coordinator.scene
        v.pointOfView = context.coordinator.cameraNode
        v.backgroundColor = .clear
        v.isOpaque = false
        v.antialiasingMode = .multisampling4X
        v.rendersContinuously = true
        v.isPlaying = true
        v.isUserInteractionEnabled = false
        v.preferredFramesPerSecond = 30
        context.coordinator.apply(state)
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        context.coordinator.apply(state)
    }
}

// MARK: - 手

@MainActor
private final class HandRig {
    let root = SCNNode()        // 手首の位置
    let gesture = SCNNode()     // 動きのアニメーション用
    let yaw: Float
    var fingers: [[SCNNode]] = []   // 指ごとの関節 [付け根, 第二関節]
    var thumb: [SCNNode] = []
    var lastTarget: SCNVector3?
    var lastGesture: BoothScene.Gesture?

    init(skin: UIColor, sleeve: UIColor, isLeft: Bool, yaw: Float) {
        self.yaw = yaw
        root.addChildNode(gesture)
        let body = SCNNode()
        body.eulerAngles.y = yaw
        gesture.addChildNode(body)

        let skinM = BoothScene.mat(skin, rough: 0.55)
        let sleeveM = BoothScene.mat(sleeve, rough: 0.8)

        // 前腕（袖）。カメラ側（+z）へ斜め上に伸びて画面外へ
        let arm = SCNNode(geometry: SCNCylinder(radius: 0.03, height: 0.5))
        arm.geometry?.materials = [sleeveM]
        arm.eulerAngles.x = .pi / 2 - 0.38
        arm.position = SCNVector3(0, 0.09, 0.235)
        body.addChildNode(arm)
        let cuff = SCNNode(geometry: SCNCylinder(radius: 0.033, height: 0.03))
        cuff.geometry?.materials = [BoothScene.mat(.white.withAlphaComponent(0.9), rough: 0.6)]
        cuff.eulerAngles.x = .pi / 2 - 0.38
        cuff.position = SCNVector3(0, 0.0, 0.0)
        body.addChildNode(cuff)

        // 手のひら
        let palm = SCNNode(geometry: SCNBox(width: 0.078, height: 0.024, length: 0.088, chamferRadius: 0.011))
        palm.geometry?.materials = [skinM]
        palm.position = SCNVector3(0, -0.004, -0.045)
        body.addChildNode(palm)

        // 4本の指
        let xs: [Float] = [-0.028, -0.0095, 0.0095, 0.028]
        let lens: [Float] = [0.034, 0.039, 0.037, 0.029]
        for (i, x0) in xs.enumerated() {
            let x = isLeft ? -x0 : x0     // 小指が外側に来るように
            let len = lens[isLeft ? 3 - i : i]
            let j1 = SCNNode()
            j1.position = SCNVector3(x, -0.004, -0.086)
            body.addChildNode(j1)
            let s1 = BoothScene.capsule(r: 0.0085, len: len, m: skinM)
            j1.addChildNode(s1)
            let j2 = SCNNode()
            j2.position = SCNVector3(0, 0, -len)
            j1.addChildNode(j2)
            let s2 = BoothScene.capsule(r: 0.0078, len: len * 0.8, m: skinM)
            j2.addChildNode(s2)
            fingers.append([j1, j2])
        }
        // 親指（内側）
        let tj = SCNNode()
        tj.position = SCNVector3(isLeft ? 0.04 : -0.04, -0.006, -0.03)
        tj.eulerAngles.y = isLeft ? -0.75 : 0.75
        body.addChildNode(tj)
        tj.addChildNode(BoothScene.capsule(r: 0.0095, len: 0.034, m: skinM))
        let tj2 = SCNNode()
        tj2.position = SCNVector3(0, 0, -0.034)
        tj.addChildNode(tj2)
        tj2.addChildNode(BoothScene.capsule(r: 0.0088, len: 0.028, m: skinM))
        thumb = [tj, tj2]
    }

    /// 指先がこの点に来る手首の位置
    func wrist(for tip: SCNVector3) -> SCNVector3 {
        let reach: Float = 0.15
        let dx = -sin(yaw) * reach
        let dz = -cos(yaw) * reach
        return SCNVector3(tip.x - dx, tip.y + 0.032, tip.z - dz)
    }

    /// curls: [人差し指, 中指, 薬指, 小指]（マイナスで曲がる）
    func setCurl(_ curls: [CGFloat], thumbCurl: CGFloat, duration: TimeInterval = 0.3) {
        for (i, f) in fingers.enumerated() {
            let c = curls[min(i, curls.count - 1)]
            f[0].runAction(.rotateTo(x: c, y: 0, z: 0, duration: duration, usesShortestUnitArc: true))
            f[1].runAction(.rotateTo(x: c * 1.2, y: 0, z: 0, duration: duration, usesShortestUnitArc: true))
        }
        thumb[1].runAction(.rotateTo(x: thumbCurl, y: 0, z: 0, duration: duration, usesShortestUnitArc: true))
    }
}

// MARK: - シーン

@MainActor
final class BoothScene {
    enum Gesture: Equatable { case idle, jog, twist, tap(Double), hold }

    let scene = SCNScene()
    let cameraNode = SCNNode()

    private var platters: [SCNNode] = []
    private var screens: [SCNNode] = []
    private var playLEDs: [SCNNode] = []
    private var cueLEDs: [SCNNode] = []
    private var knobs: [[SCNNode]] = [[], []]
    private var channelCaps: [SCNNode] = []
    private var crossCap = SCNNode()
    private var meters: [[SCNNode]] = [[], []]
    private var neon: [SCNNode] = []
    private var rimLight = SCNNode()
    private var hands: [[HandRig]] = []     // [DJ][外側, 内側]

    private var last: BoothState?
    private var artCache: [String: UIImage] = [:]
    private var loading: Set<String> = []

    // 機材の配置
    private let deckX: [Float] = [-0.47, 0.47]
    private let deckTop: Float = 0.045
    private let mixerTop: Float = 0.06
    private let knobZ: [Float] = [-0.17, -0.125, -0.08, -0.035]
    private let chX: [Float] = [-0.07, 0.07]

    init() {
        build()
    }

    // MARK: 素材

    static func mat(_ c: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.5, emission: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = c
        m.specular.contents = UIColor(white: 0.15 + metal * 0.6 * (1 - rough), alpha: 1)
        m.shininess = 0.2 + (1 - rough) * 0.6
        if let emission { m.emission.contents = emission }
        return m
    }

    static func capsule(r: CGFloat, len: Float, m: SCNMaterial) -> SCNNode {
        let n = SCNNode(geometry: SCNCapsule(capRadius: r, height: CGFloat(len) + r * 2))
        n.geometry?.materials = [m]
        n.eulerAngles.x = .pi / 2
        n.position = SCNVector3(0, 0, -len / 2)
        return n
    }

    private func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, chamfer: CGFloat = 0.004) -> SCNNode {
        let n = SCNNode(geometry: SCNBox(width: w, height: h, length: l, chamferRadius: chamfer))
        n.geometry?.materials = [m]
        return n
    }

    private func cyl(_ r: CGFloat, _ h: CGFloat, _ m: SCNMaterial) -> SCNNode {
        let n = SCNNode(geometry: SCNCylinder(radius: r, height: h))
        n.geometry?.materials = [m]
        return n
    }

    // MARK: 組み立て

    private func build() {
        scene.background.contents = UIColor.clear

        let cam = SCNCamera()
        cam.fieldOfView = 40
        cam.zNear = 0.01
        cam.zFar = 10
        cam.wantsHDR = false
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, 0.82, 0.98)
        cameraNode.look(at: SCNVector3(0, 0.0, -0.06))
        scene.rootNode.addChildNode(cameraNode)

        let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient; amb.light?.intensity = 420
        scene.rootNode.addChildNode(amb)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 1000
        key.eulerAngles = SCNVector3(-1.0, 0.25, 0)
        scene.rootNode.addChildNode(key)
        rimLight.light = SCNLight(); rimLight.light?.type = .omni; rimLight.light?.intensity = 220
        rimLight.position = SCNVector3(0, 0.5, -0.9)
        scene.rootNode.addChildNode(rimLight)

        // 台
        let tableM = BoothScene.mat(UIColor(white: 0.07, alpha: 1), metal: 0.2, rough: 0.6)
        let table = box(1.6, 0.06, 0.66, tableM, chamfer: 0.01)
        table.position = SCNVector3(0, -0.03, 0.0)
        scene.rootNode.addChildNode(table)
        let front = box(1.6, 0.6, 0.03, tableM, chamfer: 0)
        front.position = SCNVector3(0, -0.33, -0.33)
        scene.rootNode.addChildNode(front)
        for z: Float in [-0.335] {
            let strip = box(1.6, 0.012, 0.012, BoothScene.mat(.black, emission: .magenta), chamfer: 0)
            strip.position = SCNVector3(0, -0.004, z)
            scene.rootNode.addChildNode(strip)
            neon.append(strip)
        }

        for d in 0..<2 { buildDeck(d) }
        buildMixer()

        // 手：DJ A はピンクの袖、DJ B は水色の袖
        let skins = [UIColor(red: 0.93, green: 0.76, blue: 0.64, alpha: 1), UIColor(red: 0.72, green: 0.52, blue: 0.38, alpha: 1)]
        let sleeves = [UIColor(red: 0.95, green: 0.2, blue: 0.55, alpha: 1), UIColor(red: 0.1, green: 0.75, blue: 0.95, alpha: 1)]
        for d in 0..<2 {
            let outerLeft = d == 0
            let outer = HandRig(skin: skins[d], sleeve: sleeves[d], isLeft: outerLeft, yaw: outerLeft ? -0.3 : 0.3)
            let inner = HandRig(skin: skins[d], sleeve: sleeves[d], isLeft: !outerLeft, yaw: outerLeft ? -0.75 : 0.75)
            for h in [outer, inner] { scene.rootNode.addChildNode(h.root) }
            hands.append([outer, inner])
            outer.root.position = outer.wrist(for: restTip(d, outer: true))
            inner.root.position = inner.wrist(for: restTip(d, outer: false))
        }
    }

    private func buildDeck(_ d: Int) {
        let g = SCNNode()
        g.position = SCNVector3(deckX[d], 0, 0)
        scene.rootNode.addChildNode(g)

        let body = box(0.36, 0.045, 0.48, BoothScene.mat(UIColor(white: 0.13, alpha: 1), metal: 0.7, rough: 0.35))
        body.position = SCNVector3(0, 0.0225, 0)
        g.addChildNode(body)
        let topPlate = box(0.34, 0.002, 0.46, BoothScene.mat(UIColor(white: 0.05, alpha: 1), metal: 0.3, rough: 0.5))
        topPlate.position = SCNVector3(0, deckTop + 0.001, 0)
        g.addChildNode(topPlate)

        let ring = cyl(0.148, 0.008, BoothScene.mat(UIColor(white: 0.75, alpha: 1), metal: 1, rough: 0.25))
        ring.position = SCNVector3(0, deckTop + 0.004, 0.04)
        g.addChildNode(ring)
        let platter = cyl(0.138, 0.012, BoothScene.mat(.black, rough: 0.35))
        platter.position = SCNVector3(0, deckTop + 0.01, 0.04)
        platter.geometry?.materials = [
            BoothScene.mat(UIColor(white: 0.1, alpha: 1), metal: 0.5, rough: 0.4),
            BoothScene.mat(.black, rough: 0.3),
            BoothScene.mat(UIColor(white: 0.1, alpha: 1), rough: 0.4),
        ]
        g.addChildNode(platter)
        platters.append(platter)
        setPlatterImage(d, vinylImage(nil))

        // 画面（曲名を表示するだけ）
        let screen = SCNNode(geometry: SCNPlane(width: 0.2, height: 0.075))
        let sm = SCNMaterial()
        sm.lightingModel = .constant
        screen.geometry?.materials = [sm]
        screen.eulerAngles.x = -.pi / 2 + 0.12
        screen.position = SCNVector3(0, deckTop + 0.006, -0.175)
        g.addChildNode(screen)
        screens.append(screen)
        setScreen(d, title: nil, mode: "STANDBY", color: .gray)

        // CUE / PLAY ボタン（手前の角）
        let side: Float = d == 0 ? -1 : 1
        let cue = cyl(0.019, 0.01, BoothScene.mat(.black, emission: UIColor.orange.withAlphaComponent(0.2)))
        cue.position = SCNVector3(side * 0.13, deckTop + 0.006, 0.13)
        g.addChildNode(cue)
        cueLEDs.append(cue)
        let play = cyl(0.019, 0.01, BoothScene.mat(.black, emission: UIColor.green.withAlphaComponent(0.2)))
        play.position = SCNVector3(side * 0.13, deckTop + 0.006, 0.185)
        g.addChildNode(play)
        playLEDs.append(play)
    }

    private func buildMixer() {
        let g = SCNNode()
        scene.rootNode.addChildNode(g)
        let body = box(0.3, 0.06, 0.48, BoothScene.mat(UIColor(white: 0.1, alpha: 1), metal: 0.6, rough: 0.4))
        body.position = SCNVector3(0, 0.03, 0)
        g.addChildNode(body)

        let knobM = BoothScene.mat(UIColor(white: 0.18, alpha: 1), metal: 0.3, rough: 0.5)
        let markM = BoothScene.mat(.white, emission: .white)
        for ch in 0..<2 {
            for (i, z) in knobZ.enumerated() {
                let k = cyl(0.013, 0.02, knobM)
                k.position = SCNVector3(chX[ch], mixerTop + 0.01, z)
                let mark = box(0.002, 0.003, 0.011, markM, chamfer: 0)
                mark.position = SCNVector3(0, 0.011, -0.006)
                k.addChildNode(mark)
                if i == 3 {   // いちばん手前は色付き（フィルター風）
                    k.geometry?.materials = [BoothScene.mat(ch == 0 ? .systemPink : .systemTeal, metal: 0.2, rough: 0.4)]
                }
                g.addChildNode(k)
                knobs[ch].append(k)
            }
            // チャンネルフェーダー
            let slot = box(0.008, 0.002, 0.11, BoothScene.mat(.black), chamfer: 0)
            slot.position = SCNVector3(chX[ch], mixerTop + 0.001, 0.08)
            g.addChildNode(slot)
            let cap = box(0.03, 0.016, 0.013, BoothScene.mat(UIColor(white: 0.85, alpha: 1), metal: 0.4, rough: 0.3))
            cap.position = SCNVector3(chX[ch], mixerTop + 0.009, 0.12)
            g.addChildNode(cap)
            channelCaps.append(cap)
        }
        // クロスフェーダー
        let xslot = box(0.13, 0.002, 0.008, BoothScene.mat(.black), chamfer: 0)
        xslot.position = SCNVector3(0, mixerTop + 0.001, 0.195)
        g.addChildNode(xslot)
        crossCap = box(0.014, 0.016, 0.03, BoothScene.mat(UIColor(white: 0.85, alpha: 1), metal: 0.4, rough: 0.3))
        crossCap.position = SCNVector3(-0.045, mixerTop + 0.009, 0.195)
        g.addChildNode(crossCap)

        // CROWD ENERGY 表示（観客の盛り上がりを光らせるだけ。音の測定ではない）
        for c in 0..<2 {
            for i in 0..<10 {
                let led = box(0.012, 0.004, 0.014, BoothScene.mat(.black, emission: UIColor(white: 0.1, alpha: 1)), chamfer: 0.001)
                led.position = SCNVector3(c == 0 ? -0.014 : 0.014, mixerTop + 0.002, 0.03 - Float(i) * 0.021)
                g.addChildNode(led)
                meters[c].append(led)
            }
        }
    }

    // MARK: 状態の反映

    func apply(_ s: BoothState) {
        let prev = last
        last = s

        if prev?.energy != s.energy || prev == nil { updateMeters(s.energy) }
        if prev?.venue != s.venue || prev == nil {
            let c = UIColor(s.venue.palette.2)
            for n in neon { n.geometry?.firstMaterial?.emission.contents = c }
            rimLight.light?.color = c
        }

        let poseChanged = prev == nil || prev!.owner != s.owner || prev!.currentID != s.currentID
            || prev!.nextID != s.nextID || prev!.phase != s.phase || prev!.selector != s.selector
            || prev!.nextHidden != s.nextHidden
        guard poseChanged else { return }

        updateDecks(s)
        updatePoses(s)
    }

    private func updateMeters(_ e: Int) {
        let lit = Int((Double(e) / 10).rounded())
        for c in 0..<2 {
            for (i, led) in meters[c].enumerated() {
                let color: UIColor = i < 5 ? .green : i < 8 ? .yellow : .red
                led.geometry?.firstMaterial?.emission.contents = i < lit ? color : UIColor(white: 0.08, alpha: 1)
            }
        }
    }

    private func isLive(_ p: GameEngine.Phase) -> Bool { p == .playing || p == .countdown }

    private func updateDecks(_ s: BoothState) {
        for d in 0..<2 {
            let playingHere = s.current != nil && s.owner == d && (isLive(s.phase))
            let loadedHere = s.next != nil && s.selector == d
            let platter = platters[d]
            if playingHere {
                if platter.action(forKey: "spin") == nil {
                    platter.runAction(.repeatForever(.rotateBy(x: 0, y: -.pi * 2, z: 0, duration: 1.8)), forKey: "spin")
                }
            } else {
                platter.removeAction(forKey: "spin")
            }

            // 盤面のジャケット・画面
            if s.owner == d, let t = s.current, !(loadedHere) {
                setPlatterImage(d, vinylImage(art(for: t)))
                setScreen(d, title: t.title, mode: playingHere ? "ON AIR" : "LOADED", color: playingHere ? .green : .orange)
            } else if loadedHere, let n = s.next {
                setPlatterImage(d, vinylImage(s.nextHidden ? nil : art(for: n)))
                setScreen(d, title: s.nextHidden ? "SECRET TRACK" : n.title, mode: "CUE", color: .orange)
            } else if s.selector == d {
                setPlatterImage(d, vinylImage(nil))
                setScreen(d, title: nil, mode: "BROWSING", color: .cyan)
            } else if s.owner == d, let t = s.current {
                setPlatterImage(d, vinylImage(art(for: t)))
                setScreen(d, title: t.title, mode: playingHere ? "ON AIR" : "LOADED", color: .green)
            } else {
                setPlatterImage(d, vinylImage(nil))
                setScreen(d, title: nil, mode: "STANDBY", color: .gray)
            }

            playLEDs[d].geometry?.firstMaterial?.emission.contents = playingHere ? UIColor.green : UIColor.green.withAlphaComponent(0.15)
            let cue = cueLEDs[d]
            cue.removeAction(forKey: "blink")
            if loadedHere {
                let on = SCNAction.run { n in n.geometry?.firstMaterial?.emission.contents = UIColor.orange }
                let off = SCNAction.run { n in n.geometry?.firstMaterial?.emission.contents = UIColor.orange.withAlphaComponent(0.15) }
                cue.runAction(.repeatForever(.sequence([on, .wait(duration: 0.4), off, .wait(duration: 0.4)])), forKey: "blink")
            } else {
                cue.geometry?.firstMaterial?.emission.contents = UIColor.orange.withAlphaComponent(0.15)
            }
        }

        // フェーダー：流れている側が上がる。切り替え時は次の人の側へ
        let mixTo: Int = s.phase == .transition ? s.selector : s.owner
        let dur: TimeInterval = s.phase == .transition ? 1.6 : 0.6
        for ch in 0..<2 {
            let up = (ch == mixTo) || (ch == s.owner && s.current != nil && s.phase != .transition && isLive(s.phase))
            var p = channelCaps[ch].position
            p.z = up ? 0.04 : 0.12
            channelCaps[ch].runAction(.move(to: p, duration: dur), forKey: "f")
        }
        var cp = crossCap.position
        cp.x = mixTo == 0 ? -0.045 : 0.045
        crossCap.runAction(.move(to: cp, duration: dur), forKey: "x")
    }

    // MARK: 手のポーズ

    private func restTip(_ d: Int, outer: Bool) -> SCNVector3 {
        let x = deckX[d]
        if outer { return SCNVector3(x + (d == 0 ? -0.08 : 0.08), deckTop + 0.01, 0.2) }
        return SCNVector3(d == 0 ? -0.2 : 0.2, deckTop + 0.01, 0.22)
    }

    private func platterEdge(_ d: Int) -> SCNVector3 {
        SCNVector3(deckX[d] + (d == 0 ? -0.07 : 0.07), deckTop + 0.022, 0.09)
    }

    private func screenTip(_ d: Int) -> SCNVector3 { SCNVector3(deckX[d] + (d == 0 ? -0.02 : 0.02), deckTop + 0.02, -0.15) }
    private func cueTip(_ d: Int) -> SCNVector3 { SCNVector3(deckX[d] + (d == 0 ? -0.13 : 0.13), deckTop + 0.022, 0.13) }
    private func playTip(_ d: Int) -> SCNVector3 { SCNVector3(deckX[d] + (d == 0 ? -0.13 : 0.13), deckTop + 0.022, 0.185) }
    private func knobTip(_ ch: Int, _ i: Int) -> SCNVector3 { SCNVector3(chX[ch], mixerTop + 0.03, knobZ[i] + 0.012) }

    private func faderTip(_ ch: Int, up: Bool) -> SCNVector3 {
        SCNVector3(chX[ch], mixerTop + 0.026, up ? 0.05 : 0.13)
    }

    private func crossTip(to side: Int) -> SCNVector3 {
        SCNVector3(side == 0 ? -0.045 : 0.045, mixerTop + 0.026, 0.205)
    }

    private func updatePoses(_ s: BoothState) {
        let live = isLive(s.phase)
        for d in 0..<2 {
            let outer = hands[d][0], inner = hands[d][1]
            let isOwner = s.owner == d && s.current != nil
            let isSelector = s.selector == d

            switch s.phase {
            case .transition where isSelector:
                // 次の人：クロスフェーダーを自分側へ、PLAY を押す
                pose(inner, crossTip(to: d), .hold, moveTime: 1.6)
                pose(outer, playTip(d), .tap(1.5))
            case .transition:
                pose(inner, faderTip(d, up: false), .hold, moveTime: 1.4)
                pose(outer, restTip(d, outer: true), .idle)
            case .waitingForNextDJ where isSelector:
                pose(outer, screenTip(d), .tap(3))      // 大慌てで探す
                pose(inner, cueTip(d), .tap(2))
            case .searchingTrack where isSelector:
                pose(outer, screenTip(d), .tap(1.2))
                pose(inner, restTip(d, outer: false), .idle)
            default:
                if live && isOwner {
                    pose(outer, platterEdge(d), .jog)
                    let knob = s.phase == .countdown ? 3 : (abs((s.currentID ?? "").hashValue) % 3)
                    pose(inner, knobTip(d, knob), .twist)
                    spinKnob(d, knob)
                } else if live && isSelector {
                    if s.next != nil {
                        pose(outer, cueTip(d), .tap(1))
                        pose(inner, restTip(d, outer: false), .idle)
                    } else {
                        pose(outer, screenTip(d), .tap(1.3))
                        pose(inner, restTip(d, outer: false), .idle)
                    }
                } else {
                    pose(outer, restTip(d, outer: true), .idle)
                    pose(inner, restTip(d, outer: false), .idle)
                }
            }
            if !(live && isOwner) { stopKnobs(d) }
        }
    }

    private func spinKnob(_ ch: Int, _ i: Int) {
        for (k, n) in knobs[ch].enumerated() where k != i { n.removeAction(forKey: "twist") }
        let n = knobs[ch][i]
        guard n.action(forKey: "twist") == nil else { return }
        n.runAction(.repeatForever(.sequence([
            .rotateBy(x: 0, y: 0.9, z: 0, duration: 0.7),
            .rotateBy(x: 0, y: -0.9, z: 0, duration: 0.7),
        ])), forKey: "twist")
    }

    private func stopKnobs(_ ch: Int) {
        for n in knobs[ch] { n.removeAction(forKey: "twist") }
    }

    private func pose(_ h: HandRig, _ tip: SCNVector3, _ g: Gesture, moveTime: TimeInterval = 0.5) {
        let w = h.wrist(for: tip)
        if h.lastTarget.map({ $0.x != w.x || $0.y != w.y || $0.z != w.z }) ?? true {
            let mv = SCNAction.move(to: w, duration: moveTime)
            mv.timingMode = .easeInEaseOut
            h.root.runAction(mv, forKey: "move")
            h.lastTarget = w
        }
        guard h.lastGesture != g else { return }
        h.lastGesture = g

        h.gesture.removeAllActions()
        h.gesture.position = SCNVector3Zero
        h.gesture.eulerAngles = SCNVector3Zero

        switch g {
        case .idle:
            h.setCurl([-0.45, -0.5, -0.55, -0.6], thumbCurl: -0.2)
            h.gesture.runAction(.repeatForever(.sequence([
                .moveBy(x: 0, y: 0.006, z: 0, duration: 1.3),
                .moveBy(x: 0, y: -0.006, z: 0, duration: 1.3),
            ])))
        case .jog:
            // ジョグに指先を添えて、ゆっくり押したり戻したり（見た目だけ）
            h.setCurl([-0.2, -0.22, -0.28, -0.35], thumbCurl: -0.1)
            h.gesture.runAction(.repeatForever(.sequence([
                .group([.rotateBy(x: 0, y: 0.12, z: 0, duration: 0.5), .moveBy(x: 0.01, y: 0, z: -0.006, duration: 0.5)]),
                .group([.rotateBy(x: 0, y: -0.12, z: 0, duration: 0.5), .moveBy(x: -0.01, y: 0, z: 0.006, duration: 0.5)]),
            ])))
        case .twist:
            // つまみをつまんでひねる
            h.setCurl([-0.75, -1.1, -1.25, -1.3], thumbCurl: -0.7)
            h.gesture.runAction(.repeatForever(.sequence([
                .rotateBy(x: 0, y: 0, z: 0.35, duration: 0.7),
                .rotateBy(x: 0, y: 0, z: -0.35, duration: 0.7),
            ])))
        case .tap(let speed):
            // 人差し指だけ伸ばしてトントン
            h.setCurl([-0.05, -1.25, -1.35, -1.4], thumbCurl: -0.8)
            let t = 0.11 / speed
            h.gesture.runAction(.repeatForever(.sequence([
                .moveBy(x: 0, y: -0.016, z: 0, duration: t),
                .moveBy(x: 0, y: 0.016, z: 0, duration: t),
                .wait(duration: 0.35 / speed),
            ])))
        case .hold:
            // フェーダーのつまみを握る
            h.setCurl([-0.9, -1.0, -1.15, -1.25], thumbCurl: -0.9)
        }
    }

    // MARK: テクスチャ

    private func setPlatterImage(_ d: Int, _ img: UIImage) {
        guard let mats = platters[d].geometry?.materials, mats.count > 1 else { return }
        mats[1].diffuse.contents = img
    }

    private func art(for t: Track) -> UIImage? {
        if let img = artCache[t.id] { return img }
        if let url = t.artworkURL {
            if !loading.contains(t.id) {
                loading.insert(t.id)
                Task { [weak self] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: data) else { return }
                    await MainActor.run {
                        guard let self else { return }
                        self.artCache[t.id] = img
                        if let s = self.last { self.updateDecks(s) }
                    }
                }
            }
            return nil
        }
        // デモ曲は色で
        let r = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        let img = r.image { ctx in
            let c1 = UIColor(hue: t.demoHue, saturation: 0.8, brightness: 0.95, alpha: 1)
            let c2 = UIColor(hue: (t.demoHue + 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.9, brightness: 0.35, alpha: 1)
            let g = CGGradient(colorsSpace: nil, colors: [c1.cgColor, c2.cgColor] as CFArray, locations: nil)!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 256, y: 256), options: [])
            let s = NSAttributedString(string: String(t.title.prefix(1)), attributes: [
                .font: UIFont.systemFont(ofSize: 120, weight: .black), .foregroundColor: UIColor.white.withAlphaComponent(0.85)])
            let sz = s.size()
            s.draw(at: CGPoint(x: (256 - sz.width) / 2, y: (256 - sz.height) / 2))
        }
        artCache[t.id] = img
        return img
    }

    /// レコード盤の上面。真ん中のラベルにジャケット。
    private func vinylImage(_ art: UIImage?) -> UIImage {
        let size: CGFloat = 512
        let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return r.image { ctx in
            let cg = ctx.cgContext
            UIColor(white: 0.04, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: size, height: size))
            cg.setLineWidth(1.2)
            var rad: CGFloat = 100
            while rad < size / 2 - 6 {
                UIColor(white: 0.13 + (rad.truncatingRemainder(dividingBy: 14) < 7 ? 0.03 : 0), alpha: 1).setStroke()
                cg.strokeEllipse(in: CGRect(x: size / 2 - rad, y: size / 2 - rad, width: rad * 2, height: rad * 2))
                rad += 7
            }
            let label = CGRect(x: size / 2 - 96, y: size / 2 - 96, width: 192, height: 192)
            cg.saveGState()
            cg.addEllipse(in: label)
            cg.clip()
            if let art {
                art.draw(in: label)
            } else {
                UIColor(white: 0.2, alpha: 1).setFill()
                cg.fill(label)
            }
            cg.restoreGState()
            UIColor.black.setFill()
            cg.fillEllipse(in: CGRect(x: size / 2 - 7, y: size / 2 - 7, width: 14, height: 14))
            // 回転が分かるように白い目印
            UIColor.white.withAlphaComponent(0.8).setFill()
            cg.fill(CGRect(x: size / 2 - 3, y: 8, width: 6, height: 70))
        }
    }

    private func setScreen(_ d: Int, title: String?, mode: String, color: UIColor) {
        let w: CGFloat = 400, h: CGFloat = 150
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { _ in
            UIColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: w, height: h))
            let head = NSAttributedString(string: "DECK \(d == 0 ? "A" : "B")  ·  \(mode)", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 26, weight: .heavy), .foregroundColor: color])
            head.draw(at: CGPoint(x: 16, y: 14))
            let t = NSAttributedString(string: title ?? "—", attributes: [
                .font: UIFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: UIColor.white])
            t.draw(with: CGRect(x: 16, y: 62, width: w - 32, height: 70), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
        screens[d].geometry?.firstMaterial?.diffuse.contents = img
    }
}
