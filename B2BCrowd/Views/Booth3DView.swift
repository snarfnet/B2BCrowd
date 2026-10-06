import AVFoundation
import SwiftUI
import SceneKit
import simd

// フロア全体の 3D。DJ の後ろから、デッキ・ミキサー・2人の手・その先の観客を見る。
// 観客と手の動きはゲームの状態から決める演出で、音源の解析はしない。
// 機材・人物は ArtSource/blender で作った DAE、観客の動きは crowd_clips.json（骨ごとの回転差分）。
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
    var characters: [String] = ["c09", "c02"]
    var vjMode: VJMode = .auto
    var djName: String = ""
    var reactions: [(id: UUID, text: String)] = []   // 観客の反応（フロアのパーティクル演出になる）

    static func == (l: BoothState, r: BoothState) -> Bool {
        l.owner == r.owner && l.currentID == r.currentID && l.nextID == r.nextID && l.nextHidden == r.nextHidden
            && l.phase == r.phase && l.selector == r.selector && l.energy == r.energy && l.venue == r.venue
            && l.vjMode == r.vjMode && l.reactions.last?.id == r.reactions.last?.id
    }
}

struct Booth3DView: UIViewRepresentable {
    let state: BoothState

    func makeCoordinator() -> ClubScene { ClubScene(venue: state.venue, characters: state.characters) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        let club = context.coordinator
        club.view = v
        // シェーダーの準備を裏で済ませてから表示（起動直後に固まらないように）
        v.prepare([club.scene]) { _ in
            DispatchQueue.main.async { v.scene = club.scene }
        }
        v.pointOfView = club.cameraNode
        v.delegate = club
        v.backgroundColor = .black
        v.antialiasingMode = .multisampling4X
        v.rendersContinuously = true
        v.isPlaying = true
        v.isUserInteractionEnabled = false
        v.preferredFramesPerSecond = 30
        club.apply(state)
        club.startWatchdog()
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        context.coordinator.apply(state)
    }

    static func dismantleUIView(_ v: SCNView, coordinator: ClubScene) {
        coordinator.stopWatchdog()
    }
}

// MARK: - 観客の動き（JSON）

struct CrowdClip {
    let frames: Int
    let bones: [String: [simd_quatf]]
    let hips: [SIMD3<Float>]     // SceneKit 空間（y 上）の腰のずれ
}

enum CrowdClips {
    static let fps: Float = 30
    private static let source: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "crowd_clips", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root
    }()

    static let bindOrientations: [String: simd_quatf] = {
        var result: [String: simd_quatf] = [:]
        for (name, q) in (source["rest"] as? [String: [Double]]) ?? [:] where q.count == 4 {
            result[name] = simd_quatf(ix: Float(q[0]), iy: Float(q[1]), iz: Float(q[2]), r: Float(q[3])).normalized
        }
        return result
    }()

    static func space(for bone: SCNNode, in root: SCNNode, name: String) -> simd_quatf {
        guard let reference = bindOrientations[name] else { return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)) }
        let bind = root.simdWorldOrientation.inverse * bone.simdWorldOrientation
        return bind.inverse * reference
    }

    static let all: [String: CrowdClip] = {
        guard let clips = source["clips"] as? [String: [String: Any]] else { return [:] }
        var out: [String: CrowdClip] = [:]
        for (name, c) in clips {
            let frames = c["frames"] as? Int ?? 1
            var bones: [String: [simd_quatf]] = [:]
            for (b, arr) in (c["bones"] as? [String: [Double]]) ?? [:] {
                var qs: [simd_quatf] = []
                qs.reserveCapacity(frames)
                var i = 0
                while i + 3 < arr.count {
                    let q = simd_quatf(ix: Float(arr[i]), iy: Float(arr[i + 1]), iz: Float(arr[i + 2]), r: Float(arr[i + 3]))
                    qs.append(simd_length(q.vector) > 1e-5 ? q.normalized : simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
                    i += 4
                }
                bones[b] = qs
            }
            var hips: [SIMD3<Float>] = []
            let h = (c["hips"] as? [Double]) ?? []
            var i = 0
            while i + 2 < h.count {
                // Blender のキャラ空間 (x, y=背中, z=上) → SceneKit (x, y=上, z=手前)
                hips.append(SIMD3(Float(h[i]), Float(h[i + 2]), -Float(h[i + 1])))
                i += 3
            }
            out[name] = CrowdClip(frames: frames, bones: bones, hips: hips)
        }
        return out
    }()
}

private final class Person {
    let root: SCNNode
    var bones: [(node: SCNNode, name: String, bind: simd_quatf, space: simd_quatf)] = []
    var hips: SCNNode?
    var hipsBind = SIMD3<Float>(repeating: 0)
    var clip = "idle"
    var prevClip: String?
    var blend: Float = 1
    var phase: Float
    var speed: Float
    var clock: Float
    let bias: Double
    var phoneLight: SCNNode?
    let special: Int          // 0 普通 / 1 絶対踊らない / 2 辛口評論家 / 3 何でも盛り上がる / 4 ダンスキング / 5 伝説
    let phoneUser: Bool

    init(root: SCNNode, phase: Float, speed: Float, bias: Double, special: Int, phoneUser: Bool) {
        self.root = root
        self.phase = phase
        self.speed = speed
        self.clock = phase
        self.bias = bias
        self.special = special
        self.phoneUser = phoneUser
    }
}

// MARK: - DJ の手

private final class ArmRig {
    let arm: SCNNode, fore: SCNNode, hand: SCNNode
    let qArm0: simd_quatf, qFore0: simd_quatf, qHand0: simd_quatf    // バインド時のワールド向き
    let armDir0: SIMD3<Float>, foreDir0: SIMD3<Float>
    let l1: Float, l2: Float
    let handDir0: SIMD3<Float>, palm0: SIMD3<Float>
    var fingers: [(node: SCNNode, bind: simd_quatf, axis: SIMD3<Float>, sign: Float, finger: Int, joint: Int)] = []
    var tip = SIMD3<Float>(0, 0, 0)
    var curl: [Float] = [0.5, 0.5, 0.5, 0.5, 0.3]   // 人差し指・中指・薬指・小指・親指
    let handLength: Float
    let side: Float            // 画面右側の手なら +1、左側なら -1

    init?(model: SCNNode, prefix: String, side: Float) {
        func n(_ s: String) -> SCNNode? {
            model.childNode(withName: "mixamorig:\(prefix)\(s)", recursively: true)
                ?? model.childNode(withName: "rig_mixamorig_\(prefix)\(s)", recursively: true)
        }
        guard let a = n("Arm"), let f = n("ForeArm"), let h = n("Hand"),
              let mid = n("HandMiddle1"), let idx = n("HandIndex1"), let pinky = n("HandPinky1") else { return nil }
        arm = a; fore = f; hand = h
        self.side = side
        qArm0 = a.simdWorldOrientation
        qFore0 = f.simdWorldOrientation
        qHand0 = h.simdWorldOrientation
        let pa = a.simdWorldPosition, pf = f.simdWorldPosition, ph = h.simdWorldPosition
        armDir0 = simd_normalize(pf - pa)
        foreDir0 = simd_normalize(ph - pf)
        l1 = simd_length(pf - pa)
        l2 = simd_length(ph - pf)
        handDir0 = simd_normalize(mid.simdWorldPosition - ph)
        let across = simd_normalize(idx.simdWorldPosition - pinky.simdWorldPosition)
        var palm = simd_normalize(simd_cross(handDir0, across))
        // 親指の付け根は手のひら側にある
        if let th = n("HandThumb1"), simd_dot(th.simdWorldPosition - ph, palm) < 0 { palm = -palm }
        palm0 = palm
        let indexLast = n("HandIndex3") ?? idx
        let indexPrevious = n("HandIndex2") ?? idx
        let fingertip = indexLast.childNodes.first?.simdWorldPosition
            ?? (indexLast.simdWorldPosition + (indexLast.simdWorldPosition - indexPrevious.simdWorldPosition) * 0.75)
        handLength = max(0.035, simd_length(fingertip - ph))

        let names = [("Index", 0), ("Middle", 1), ("Ring", 2), ("Pinky", 3), ("Thumb", 4)]
        for (fname, fi) in names {
            for j in 1...3 {
                guard let node = n("Hand\(fname)\(j)") else { continue }
                let qw = node.simdWorldOrientation
                let axisWorld = fi == 4 ? handDir0 : across
                let axisLocal = simd_normalize(qw.inverse.act(axisWorld))
                let child = node.childNodes.first
                let dirW = child.map { simd_normalize($0.simdWorldPosition - node.simdWorldPosition) } ?? handDir0
                let turned = simd_quatf(angle: 0.3, axis: axisWorld).act(dirW)
                let sign: Float = simd_dot(turned, palm) > simd_dot(dirW, palm) ? 1 : -1
                fingers.append((node, node.simdOrientation, axisLocal, sign, fi, j - 1))
            }
        }
    }

    /// ワールドでの向きを、親に対するローカルの向きに直して入れる（位置・拡大率は骨の階層に任せる）
    private func orient(_ n: SCNNode, _ world: simd_quatf) {
        let parent = n.parent?.simdWorldOrientation ?? simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        n.simdOrientation = parent.inverse * world
    }

    /// 指先が tip に来るように肩から先を曲げる
    func solve(tip: SIMD3<Float>, handDir: SIMD3<Float>, palm: SIMD3<Float>) {
        let hd = simd_normalize(handDir)
        var pn = palm - hd * simd_dot(palm, hd)
        pn = simd_length(pn) < 1e-4 ? SIMD3(0, -1, 0) : simd_normalize(pn)
        let wrist = tip - hd * handLength - pn * (handLength * 0.10)
        let shoulder = arm.simdWorldPosition

        // 2本の骨の IK（肘は外側やや下・後ろへ）
        let delta = wrist - shoulder
        let rawDistance = simd_length(delta)
        let dir = rawDistance > 1e-5 ? delta / rawDistance : SIMD3<Float>(0, -1, 0)
        let minReach = abs(l1 - l2) + 0.004
        let maxReach = max(minReach, l1 + l2 - 0.004)
        let dist = max(minReach, min(maxReach, rawDistance))
        let d = dir * dist
        let a = (l1 * l1 - l2 * l2 + dist * dist) / (2 * dist)
        let h = sqrt(max(0, l1 * l1 - a * a))
        var pole = SIMD3<Float>(side * 0.7, -0.6, 0.4)
        pole -= dir * simd_dot(pole, dir)
        if simd_length(pole) < 1e-4 { pole = simd_cross(dir, SIMD3<Float>(0, 0, 1)) }
        if simd_length(pole) < 1e-4 { pole = simd_cross(dir, SIMD3<Float>(1, 0, 0)) }
        pole = simd_normalize(pole)
        let elbow = shoulder + dir * a + pole * h
        let w = shoulder + d

        // 3本の骨を「骨の向き＋手のひらの向き」でそろえる
        func frame(_ y: SIMD3<Float>, _ ref: SIMD3<Float>) -> simd_float3x3 {
            var r = ref - y * simd_dot(ref, y)
            if simd_length(r) < 1e-4 { r = simd_cross(y, SIMD3<Float>(1, 0, 0)) }
            if simd_length(r) < 1e-4 { r = simd_cross(y, SIMD3<Float>(0, 0, 1)) }
            r = simd_normalize(r)
            return simd_float3x3(columns: (y, r, simd_normalize(simd_cross(y, r))))
        }
        func aim(_ q0: simd_quatf, _ y0: SIMD3<Float>, _ y1: SIMD3<Float>) -> simd_quatf {
            simd_quatf(frame(y1, pn) * frame(y0, palm0).transpose) * q0
        }
        orient(arm, simd_quatf(from: armDir0, to: simd_normalize(elbow - shoulder)) * qArm0)
        orient(fore, simd_quatf(from: foreDir0, to: simd_normalize(w - elbow)) * qFore0)
        orient(hand, aim(qHand0, handDir0, hd))

        for f in fingers {
            let weight: Float = f.finger == 4
                ? (f.joint == 0 ? 0.45 : f.joint == 1 ? 0.65 : 0.4)
                : (f.joint == 0 ? 0.72 : f.joint == 1 ? 1.0 : 0.55)
            let c = min(1.3, max(0, curl[f.finger] * weight))
            f.node.simdOrientation = f.bind * simd_quatf(angle: c * f.sign, axis: f.axis)
        }
    }
}

// MARK: - シーン

final class ClubScene: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    enum Gesture: Equatable { case idle, jog, twist, tap(Float), hold }

    let scene = SCNScene()
    let cameraNode = SCNNode()
    weak var view: SCNView?

    private let lock = NSLock()
    private var st = BoothState(owner: 0, currentID: nil, nextID: nil, nextHidden: false, phase: .searchingTrack,
                                selector: 0, energy: 50, venue: .smallClub, current: nil, next: nil)
    private let venue: Venue
    private let characters: [String]

    private let gear = SCNNode()
    private var platters: [SCNNode] = []
    private var platterAxis: [SIMD3<Float>] = []
    private var platterBind: [simd_quatf] = []
    private var platterAngle: [Float] = [0, 0]
    private var screens: [SCNNode] = []
    private var playLEDs: [SCNNode] = []
    private var cueLEDs: [SCNNode] = []
    private var knobs: [[SCNNode]] = [[], []]
    private var faders: [SCNNode] = []
    private var faderBase: [SIMD3<Float>] = []
    private var faderPos: [Float] = [1, 0]
    private var xfader: SCNNode?
    private var xBase = SIMD3<Float>(0, 0, 0)
    private var xPos: Float = -1
    private var meters: [[SCNNode]] = [[], []]
    private var boothLED: SCNNode?

    private var people: [Person] = []
    private var arms: [[ArmRig]] = []        // [DJ][外側, 内側]
    private var gestures: [[Gesture]] = [[.idle, .idle], [.idle, .idle], [.tap(1.2), .twist]]
    private var targets: [[SIMD3<Float>]] = [[SIMD3(-0.59, 0, 0.3), SIMD3(-0.33, 0, 0.3)], [SIMD3(0.59, 0, 0.3), SIMD3(0.33, 0, 0.3)],
                                             [SIMD3(-2.75, 0.24, -3.2), SIMD3(-2.4, 0.24, -3.18)]]
    private var faderGoal: [Float] = [1, 0]
    private var xGoal: Float = -1

    private var movers: [SCNNode] = []
    private var lasers: [SCNNode] = []
    private let ambient = SCNNode()
    private var confetti: SCNParticleSystem?
    private var ledWall: SCNNode?
    private var hazes: [SCNNode] = []
    private var seenReactions = Set<UUID>()
    /// シーンへの変更は描画スレッドでまとめて行う（メインと描画が同時に触ると実機で描画が止まることがある）
    private var pending: [() -> Void] = []
    private var lastFrameAt: CFTimeInterval = 0
    private var watchdog: Timer?

    private func onRender(_ f: @escaping () -> Void) {
        lock.lock(); pending.append(f); lock.unlock()
    }

    @MainActor
    func stopWatchdog() { watchdog?.invalidate(); watchdog = nil }

    /// 描画が 2 秒以上止まったら SCNView を起こし直す
    @MainActor
    func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let v = self.view, v.window != nil,
                      UIApplication.shared.applicationState == .active else { return }
                self.lock.lock(); let last = self.lastFrameAt; self.lock.unlock()
                guard last > 0, CACurrentMediaTime() - last > 2 else { return }
                NSLog("CLUB watchdog: render stalled %.1fs, restarting", CACurrentMediaTime() - last)
                v.scene?.isPaused = false
                v.isPlaying = false
                v.isPlaying = true
                v.rendersContinuously = true
                self.lock.lock(); self.lastFrameAt = CACurrentMediaTime(); self.lock.unlock()
            }
        }
    }
    private let fxLight = SCNNode()
    private var fxFlash: Float = 0

    // MARK: 観客の実写動画
    // 観客は 3D ではなく、盛り上がりの段階（CROWD ENERGY の6段階）ごとの実写風ループ動画を
    // カメラの奥に貼って見せる。手前のブース・DJ・手・パーティクルは 3D のまま重なる。
    /// 会場専用の動画（crowd_<会場>_t0..5）があればそれ、無ければクラブの共通動画（crowd_t0..5）
    static func crowdVideoURLs(for venue: Venue) -> [URL] {
        let own = (0..<6).compactMap { Bundle.main.url(forResource: "crowd_\(venue.rawValue)_t\($0)", withExtension: "mp4") }
        if own.count == 6 { return own }
        return (0..<6).compactMap { Bundle.main.url(forResource: "crowd_t\($0)", withExtension: "mp4") }
    }
    static let videoMode = crowdVideoURLs(for: .smallClub).count == 6 && !ProcessInfo.processInfo.arguments.contains("-crowd3d")
    private lazy var videoURLs = Self.crowdVideoURLs(for: venue)
    private let videoDistance: Float = 6
    private let videoAspect: Float = 704.0 / 1280.0
    private var videoNodes: [SCNNode] = []
    private var videoTop = 0
    private var videoTierShown = -1
    private var videoWant = -1
    private var videoWantSince: TimeInterval = 0
    private var videoSwitching = false
    private var videoLayoutAspect: Float = 0
    private var videoPlayers: [Int: (player: AVQueuePlayer, looper: AVPlayerLooper)] = [:]
    // VJ 卓（フロア左手前の台の上）
    private let vjDesk = SIMD3<Float>(-2.6, 0.22, -3.25)   // 卓の天板の中心
    private var laptopMat: SCNMaterial?
    // VJ
    private var vjMaterials: [SCNMaterial] = []
    private var vjModeNow: Float = 0
    private var vjOn = true
    private var vjCutAt: Float = -10
    private var vjTimeNow: Float = 0
    private var vjAutoIndex = 0

    private var lastTime: TimeInterval = 0
    private var ready = false   // 機材と人物の読み込みが終わったら true
    private var camBase = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var smoke: SCNParticleSystem?
    private var artCache: [String: UIImage] = [:]
    private var loading: Set<String> = []
    private var lastApplied: BoothState?

    init(venue: Venue, characters: [String] = ["c09", "c02"]) {
        self.venue = venue
        self.characters = characters.count == 2 ? characters : ["c09", "c02"]
        super.init()
        build()
    }

    // MARK: 組み立て

    private func build() {
        let cam = SCNCamera()
        cam.fieldOfView = 60
        cam.zNear = 0.02
        cam.zFar = 60
        cam.wantsHDR = true
        cam.bloomIntensity = 0.32
        cam.bloomThreshold = 1.25
        cam.bloomBlurRadius = 6
        cam.vignettingIntensity = 0.3
        cam.vignettingPower = 1.2
        cam.screenSpaceAmbientOcclusionIntensity = 0.55
        cam.screenSpaceAmbientOcclusionRadius = 0.18
        cam.wantsExposureAdaptation = false
        cam.exposureOffset = -0.55
        cam.saturation = 1.0
        cam.wantsDepthOfField = false
        cam.focusDistance = 2.0
        cam.fStop = 9
        cam.apertureBladeCount = 6
        cam.motionBlurIntensity = 0
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, 1.3, 1.45)
        cameraNode.look(at: SCNVector3(0, -0.3, -1.9))
        camBase = cameraNode.simdOrientation
        if ProcessInfo.processInfo.arguments.contains("-boothcam") {   // 手元の確認用
            cameraNode.position = SCNVector3(0.1, 0.95, 1.1)
            cameraNode.look(at: SCNVector3(0, 0, -0.1))
        }
        if ProcessInfo.processInfo.arguments.contains("-vjcam") {   // VJ 卓の確認用
            cameraNode.position = SCNVector3(-1.4, 1.2, -1.4)
            cameraNode.look(at: SCNVector3(-2.6, 0.1, -3.3))
        }
        camBase = cameraNode.simdOrientation
        scene.rootNode.addChildNode(cameraNode)

        scene.lightingEnvironment.contents = Self.environmentImage(venue)
        scene.lightingEnvironment.intensity = 0.38
        scene.background.contents = UIColor.black
        scene.fogColor = UIColor(venue.palette.1)
        scene.fogStartDistance = 7
        scene.fogEndDistance = 22
        scene.fogDensityExponent = 1.4

        let before = Set(scene.rootNode.childNodes.map(ObjectIdentifier.init))
        buildVenue()
        buildLights()
        if Self.videoMode {
            // 床・壁・LED・スモーク・光の筋は動画に写っているので隠す（照明そのものはブースを照らすので残す）
            for n in scene.rootNode.childNodes where !before.contains(ObjectIdentifier(n)) && n.light == nil && n !== fxLight {
                n.isHidden = true
            }
            for m in movers { m.childNode(withName: "beam", recursively: false)?.isHidden = true }
            for l in lasers { l.isHidden = true }
            setupCrowdVideo()
        }
        // 機材と人物は重いので裏で読み込み、できたらまとめて足す（画面が固まらないように）
        Self.buildQueue.async { [self] in
            buildGear()
            let root = SCNNode()
            let crowd = buildCrowd(into: root)
            let (djs, rigs) = buildArms(into: root)
            let attach = { [self] in
                scene.rootNode.addChildNode(gear)
                scene.rootNode.addChildNode(root)
                lock.lock()
                people = crowd + djs
                arms = rigs
                let d = vjDesk
                if targets.count < 3 { targets.append([]) }
                targets[2] = [SIMD3(d.x - 0.15, d.y + 0.02, d.z + 0.06), SIMD3(d.x + 0.2, d.y + 0.03, d.z + 0.05)]
                ready = true
                lock.unlock()
                if let s = lastApplied {
                    lastApplied = nil
                    apply(s)
                }
            }
            // 足す前にシェーダーを裏で用意
            DispatchQueue.main.async { [self] in
                if let v = view {
                    v.prepare([gear, root]) { _ in DispatchQueue.main.async { attach() } }
                } else {
                    attach()
                }
            }
        }
    }

    /// 読み込みと組み立ては必ずこの1本の列で行う（同じ型紙を同時に複製すると SceneKit が落ちる）
    static let buildQueue = DispatchQueue(label: "club.build", qos: .userInitiated)

    static let debugTilt = ProcessInfo.processInfo.arguments.contains("-shot")

    static let nearNames = ["c01", "c02", "c03", "c05", "c06", "c09", "c12", "c16"]

    /// アプリ起動時に人物を先に読んでおく（起動の邪魔をしないよう少し待ってから）
    static func preload() {
        buildQueue.asyncAfter(deadline: .now() + 1.5) {
            if videoMode {
                for c in DJCharacter.all { _ = template(c.id, lod: false) }
                return
            }
            for n in nearNames { _ = template(n, lod: false) }
            for c in DJCharacter.all where !nearNames.contains(c.id) { _ = template(c.id, lod: false) }
            for i in 1...18 { _ = template(String(format: "c%02d", i), lod: true) }
        }
    }

    private func pbr(_ m: SCNMaterial, rough: CGFloat, metal: CGFloat = 0) { Self.pbrS(m, rough: rough, metal: metal) }

    private static func pbrS(_ m: SCNMaterial, rough: CGFloat, metal: CGFloat = 0) {
        m.lightingModel = .physicallyBased
        m.roughness.contents = rough
        m.metalness.contents = metal
    }

    private func buildVenue() {
        let (top, bottom, light) = venue.palette
        // 床
        let floor = SCNNode(geometry: SCNPlane(width: 60, height: 60))
        floor.eulerAngles.x = -.pi / 2
        floor.position = SCNVector3(0, -1.02, -8)
        let fm = SCNMaterial()
        fm.diffuse.contents = UIColor(white: 0.035, alpha: 1)
        pbr(fm, rough: 0.48, metal: 0.04)
        floor.geometry?.materials = [fm]
        scene.rootNode.addChildNode(floor)
        // もや（薄い板を何枚か重ねて空気の厚みを出す）
        let hazeImg = Self.hazeImage()
        for (k, z) in ([-3.5, -6.5, -9.5, -12.5] as [Float]).enumerated() {
            let hz = SCNNode(geometry: SCNPlane(width: 24, height: 7))
            let hm = SCNMaterial()
            hm.lightingModel = .constant
            hm.diffuse.contents = hazeImg
            hm.multiply.contents = UIColor(light)
            hm.blendMode = .add
            hm.writesToDepthBuffer = false
            hm.isDoubleSided = true
            hz.geometry?.materials = [hm]
            hz.position = SCNVector3(Float(k % 2) * 1.5 - 0.75, 2.0, z)
            hz.opacity = 0.16
            scene.rootNode.addChildNode(hz)
            hazes.append(hz)
        }
        // 奥の壁と LED ウォール
        let wall = SCNNode(geometry: SCNPlane(width: 30, height: 12))
        wall.position = SCNVector3(0, 4, -14)
        let wm = SCNMaterial()
        wm.diffuse.contents = UIColor(bottom)
        pbr(wm, rough: 0.9)
        wall.geometry?.materials = [wm]
        scene.rootNode.addChildNode(wall)
        let led = SCNNode(geometry: SCNPlane(width: 12, height: 4.5))
        led.position = SCNVector3(0, 2.4, -13.9)
        led.geometry?.materials = [vjMaterial(aspect: 12 / 4.5, gain: 1.9)]
        scene.rootNode.addChildNode(led)
        ledWall = led
        _ = top
        laptopMat = vjMaterial(aspect: 1.6)
        for sx in [-1, 1] as [Float] {
            let side = SCNNode(geometry: SCNPlane(width: 2.6, height: 4.4))
            side.position = SCNVector3(sx * 6.4, 2.3, -8.5)
            side.eulerAngles.y = -sx * 0.55
            side.geometry?.materials = [vjMaterial(aspect: 2.6 / 4.4, gain: 1.4)]
            scene.rootNode.addChildNode(side)
            // 枠
            let frame = SCNNode(geometry: SCNBox(width: 2.75, height: 4.55, length: 0.08, chamferRadius: 0.02))
            let fm = SCNMaterial(); fm.diffuse.contents = UIColor(white: 0.04, alpha: 1); pbr(fm, rough: 0.6)
            frame.geometry?.materials = [fm]
            frame.position = SCNVector3(0, 0, -0.05)
            side.addChildNode(frame)
        }
        // トラス
        let trussM = SCNMaterial()
        trussM.diffuse.contents = UIColor(white: 0.25, alpha: 1)
        pbr(trussM, rough: 0.35, metal: 1)
        for z in [-3.0, -7.5] as [Float] {
            let bar = SCNNode(geometry: SCNBox(width: 14, height: 0.25, length: 0.25, chamferRadius: 0.02))
            bar.geometry?.materials = [trussM]
            bar.position = SCNVector3(0, 3.4, z)
            scene.rootNode.addChildNode(bar)
        }
        for x in [-6.5, 6.5] as [Float] {
            let leg = SCNNode(geometry: SCNBox(width: 0.25, height: 4.5, length: 0.25, chamferRadius: 0.02))
            leg.geometry?.materials = [trussM]
            leg.position = SCNVector3(x, 1.2, -3)
            scene.rootNode.addChildNode(leg)
        }
        // 両脇のスピーカースタック
        let spkM = SCNMaterial()
        spkM.diffuse.contents = UIColor(white: 0.03, alpha: 1)
        pbr(spkM, rough: 0.8)
        let coneM = SCNMaterial()
        coneM.diffuse.contents = UIColor(white: 0.08, alpha: 1)
        pbr(coneM, rough: 0.6)
        for x in [-4.2, 4.2] as [Float] {
            for k in 0..<3 {
                let b = SCNNode(geometry: SCNBox(width: 1.1, height: 0.9, length: 0.8, chamferRadius: 0.03))
                b.geometry?.materials = [spkM]
                b.position = SCNVector3(x, -0.57 + Float(k) * 0.92, -1.6)
                scene.rootNode.addChildNode(b)
                let cone = SCNNode(geometry: SCNCone(topRadius: 0.10, bottomRadius: 0.28, height: 0.075))
                cone.geometry?.materials = [coneM]
                cone.eulerAngles.x = .pi / 2
                cone.position = SCNVector3(0, 0, 0.41)
                b.addChildNode(cone)
                let capShape = SCNSphere(radius: 0.105)
                capShape.segmentCount = 16
                let cap = SCNNode(geometry: capShape)
                cap.geometry?.materials = [coneM]
                cap.scale = SCNVector3(1, 1, 0.32)
                cap.position = SCNVector3(0, 0, 0.46)
                b.addChildNode(cap)
                let surroundShape = SCNTorus(ringRadius: 0.284, pipeRadius: 0.015)
                surroundShape.ringSegmentCount = 32
                surroundShape.pipeSegmentCount = 8
                let surround = SCNNode(geometry: surroundShape)
                surround.geometry?.materials = [spkM]
                surround.eulerAngles.x = .pi / 2
                surround.position = SCNVector3(0, 0, 0.408)
                b.addChildNode(surround)
            }
        }
    }

    private func buildGear() {
        guard let s = SCNScene(named: "Booth.scnassets/gear.dae") else { return }
        for c in s.rootNode.childNodes { gear.addChildNode(c) }

        // 素材を PBR に
        gear.enumerateHierarchy { node, _ in
            guard let g = node.geometry else { return }
            for m in g.materials {
                let n = (m.name ?? "").lowercased()
                m.emission.contents = UIColor.black
                m.clearCoat.contents = 0
                if n.contains("print") { self.pbr(m, rough: n.contains("booth") ? 0.58 : 0.72) }
                else if n.contains("lamp_bulb") {
                    m.lightingModel = .constant
                    m.emission.contents = UIColor(red: 1, green: 0.9, blue: 0.75, alpha: 1)
                    m.emission.intensity = 1.4
                }
                else if n.contains("cup") { self.pbr(m, rough: 0.25) }
                else if n.contains("drink") { self.pbr(m, rough: 0.05) }
                else if n.contains("cable") || n.contains("hp_pad") { self.pbr(m, rough: 0.6) }
                else if n.contains("gunmetal") { self.pbr(m, rough: 0.38, metal: 0.85) }
                else if n.contains("alu") { self.pbr(m, rough: 0.4, metal: 1) }
                else if n.contains("chrome") { self.pbr(m, rough: 0.22, metal: 1) }
                else if n.contains("rubber") || n.contains("pad") { self.pbr(m, rough: 0.85) }
                else if n.contains("glass") { self.pbr(m, rough: 0.18); m.clearCoat.contents = 0.2 }
                else if n.contains("booth_top") { self.pbr(m, rough: 0.58) }
                else { self.pbr(m, rough: 0.64) }
                if n.contains("gunmetal") || n.contains("alu") {
                    m.normal.contents = Self.metalNormal
                    m.normal.intensity = 0.18
                    m.normal.wrapS = .repeat; m.normal.wrapT = .repeat
                    m.normal.contentsTransform = SCNMatrix4MakeScale(5, 5, 1)
                    if let rough = Self.metalRough {
                        m.roughness.contents = rough
                        m.roughness.wrapS = .repeat; m.roughness.wrapT = .repeat
                        m.roughness.contentsTransform = SCNMatrix4MakeScale(5, 5, 1)
                    }
                }
                Self.gearSurface(m, material: n, node: (node.name ?? "").lowercased())
            }
        }

        func uniq(_ node: SCNNode) -> SCNNode {
            if let g = node.geometry?.copy() as? SCNGeometry {
                g.materials = g.materials.map { ($0.copy() as? SCNMaterial) ?? $0 }
                node.geometry = g
            }
            return node
        }
        func find(_ name: String) -> SCNNode? { gear.childNode(withName: name, recursively: true) }

        for side in ["A", "B"] {
            if let p = find("platter_\(side)") {
                platters.append(uniq(p))
                platterBind.append(p.simdOrientation)
                platterAxis.append(simd_normalize(p.simdWorldOrientation.inverse.act(SIMD3<Float>(0, 1, 0))))
            }
            if let sc = find("screen_\(side)") {
                let m = uniq(sc).geometry?.firstMaterial
                m?.lightingModel = .physicallyBased
                m?.diffuse.contents = UIColor.black
                screens.append(sc)
            }
            if let p = find("play_\(side)") { playLEDs.append(uniq(p)) }
            if let c = find("cue_\(side)") { cueLEDs.append(uniq(c)) }
        }
        for c in 0..<2 {
            for i in 0..<5 { if let k = find("knob_\(c)_\(i)") { knobs[c].append(k) } }
            if let f = find("fader_\(c)") { faders.append(f); faderBase.append(f.simdPosition) }
            for i in 0..<12 { if let m = find("meter_\(c)_\(i)") { meters[c].append(uniq(m)) } }
        }
        if let x = find("xfader") { xfader = x; xBase = x.simdPosition }
        // グースネックのランプで手元を照らす
        if let head = find("lamp_head") {
            let l = SCNNode()
            l.light = SCNLight()
            l.light?.type = .spot
            l.light?.intensity = 35
            l.light?.color = UIColor(red: 1, green: 0.88, blue: 0.7, alpha: 1)
            l.light?.spotInnerAngle = 18
            l.light?.spotOuterAngle = 58
            l.light?.attenuationStartDistance = 0.12
            l.light?.attenuationEndDistance = 0.7
            l.simdPosition = head.simdWorldPosition
            gear.addChildNode(l)
            l.look(at: SCNVector3(0, 0.06, -0.02))
        }
        if let led = find("booth_led") {
            boothLED = uniq(led)
            boothLED?.geometry?.firstMaterial?.emission.contents = UIColor(venue.palette.2)
            boothLED?.geometry?.firstMaterial?.emission.intensity = 1.6
        }
        for i in 0..<platters.count { applyPlatter(i, vinyl(nil)) }
        for i in 0..<screens.count { applyScreen(i, title: nil, mode: "STANDBY", color: .gray) }
    }

    /// 一度読み込んだ人物は使い回す（タイトルとセッションで2回読まない）
    private static var templateCache: [String: SCNNode] = [:]
    private static let cacheLock = NSLock()

    private func loadCharacter(_ name: String, lod: Bool = false) -> SCNNode? { Self.template(name, lod: lod) }

    private static func template(_ name: String, lod: Bool) -> SCNNode? {
        let file = lod ? "\(name)_lod" : name
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = templateCache[file] { return cached }
        guard let s = SCNScene(named: "Crowd.scnassets/\(name)/\(file).dae") else { return nil }
        let n = SCNNode()
        for c in s.rootNode.childNodes { n.addChildNode(c) }
        n.enumerateHierarchy { node, _ in
            guard let g = node.geometry else { return }
            let lname = (node.name ?? "").lowercased()
            let alpha = ["bob", "afro", "ponytail", "long", "short", "braid", "eyebrow", "eyelash", "fedora"].contains { lname.contains($0) }
            let isSkin = lname.contains("generic") || lname.hasSuffix(".body")
            for m in g.materials {
                let mn = (m.name ?? "").lowercased()
                if mn.contains("robo") {
                    robotMaterial(m, mn)
                    continue
                }
                pbrS(m, rough: isSkin ? 0.7 : 0.88)
                // 人は周囲の映り込み（IBL の鏡面）を弱めてテカテカを抑える
                m.ambientOcclusion.contents = UIColor(white: 0.7, alpha: 1)
                if isSkin { skinMaterial(m) }
                else if lname.contains("low-poly") {
                    // The existing eye atlas stays intact; corneal sheen is restrained.
                    pbrS(m, rough: 0.16)
                    m.clearCoat.contents = 0.14
                    m.clearCoatRoughness.contents = 0.20
                } else if ["bob", "afro", "ponytail", "long", "short", "braid"].contains(where: { lname.contains($0) }) {
                    // Preserve the strand alpha and silhouette, vary their highlights.
                    _ = useMap(m.roughness, "hair_detail_rough", tile: 2)
                } else if ["suit", "shirt", "jean", "pants", "skirt", "dress", "jacket", "fedora"].contains(where: { lname.contains($0) }) {
                    _ = useMap(m.normal, "fabric_detail_normal", tile: 32)
                    m.normal.intensity = 0.24
                    _ = useMap(m.roughness, "fabric_detail_rough", tile: 2)
                } else if lname.contains("shoes") {
                    _ = useMap(m.normal, "polymer_detail_normal", tile: 10)
                    m.normal.intensity = 0.15
                    _ = useMap(m.roughness, "polymer_use_rough", tile: 2)
                }
                if alpha {
                    m.transparencyMode = .aOne
                    m.blendMode = .alpha
                    m.isDoubleSided = true
                    m.writesToDepthBuffer = true
                }
            }
        }
        templateCache[file] = n
        return n
    }

    // Shared baked maps: no new mesh, shader, per-frame work or texture per person.
    private static let surfaceImages: [String: UIImage] = {
        let panels = ["deck_a", "deck_b", "mixer", "booth"].flatMap { p in
            ["\(p)_use_rough", "\(p)_use_normal", "\(p)_use_multiply"]
        }
        let names = panels + ["polymer_detail_normal", "polymer_use_rough", "rubber_use_rough",
                              "metal_use_rough", "chrome_use_rough", "fabric_detail_normal", "fabric_detail_rough",
                              "hair_detail_rough", "skin_zone_rough", "skin_zone_multiply"]
        var images: [String: UIImage] = [:]
        for name in names { if let image = UIImage(named: name) { images[name] = image } }
        return images
    }()

    @discardableResult
    private static func useMap(_ property: SCNMaterialProperty, _ name: String, tile: Float = 1) -> Bool {
        guard let image = surfaceImages[name] else { return false }
        property.contents = image
        property.contentsTransform = SCNMatrix4MakeScale(tile, tile, 1)
        property.wrapS = tile > 1 ? .repeat : .clamp
        property.wrapT = tile > 1 ? .repeat : .clamp
        property.minificationFilter = .linear
        property.magnificationFilter = .linear
        property.mipFilter = .linear
        return true
    }

    private static func gearSurface(_ m: SCNMaterial, material: String, node: String) {
        let panel: String?
        switch node {
        case "print_a": panel = "deck_a"
        case "print_b": panel = "deck_b"
        case "print_mixer": panel = "mixer"
        case "booth_top_print": panel = "booth"
        default: panel = nil
        }
        if let panel {
            // Existing print-plane UVs locate wear beside actual PLAY/CUE, jog and faders.
            _ = useMap(m.roughness, "\(panel)_use_rough")
            _ = useMap(m.multiply, "\(panel)_use_multiply")
            _ = useMap(m.normal, "\(panel)_use_normal")
            m.normal.intensity = 0.30
        } else if material.contains("gunmetal") || material.contains("alu") || material.contains("lamp_metal") {
            _ = useMap(m.roughness, "metal_use_rough", tile: 3)
        } else if material.contains("chrome") {
            _ = useMap(m.roughness, "chrome_use_rough", tile: 4)
        } else if material.contains("knob") || material.contains("fader_cap") || material.contains("hp_shell") {
            _ = useMap(m.roughness, "polymer_use_rough", tile: 2)
            _ = useMap(m.normal, "polymer_detail_normal", tile: 3)
            m.normal.intensity = 0.20
        } else if material.contains("rubber") || material.contains("hp_pad") || material.contains("cable") || material.contains("speaker_cab") {
            _ = useMap(m.roughness, "rubber_use_rough", tile: 3)
            _ = useMap(m.normal, "polymer_detail_normal", tile: 5)
            m.normal.intensity = 0.12
        }
    }

    // Pore scale and regional sheen remain distinct from the diffuse complexion.
    private static let metalNormal = UIImage(named: "metal_detail_normal")
    private static let metalRough = UIImage(named: "metal_detail_rough")
    private static let skinNormal = UIImage(named: "skin_detail_normal")
    private static let skinRough = UIImage(named: "skin_detail_rough")

    private static func skinMaterial(_ m: SCNMaterial) {
        let tile = SCNMatrix4MakeScale(22, 22, 1)
        if let n = skinNormal {
            m.normal.contents = n
            m.normal.contentsTransform = tile
            m.normal.wrapS = .repeat; m.normal.wrapT = .repeat
            m.normal.intensity = 0.16
        }
        if !useMap(m.roughness, "skin_zone_rough"), let r = skinRough {
            m.roughness.contents = r
            m.roughness.contentsTransform = tile
            m.roughness.wrapS = .repeat; m.roughness.wrapT = .repeat
        }
        _ = useMap(m.multiply, "skin_zone_multiply")
        m.clearCoat.contents = 0.02
        m.clearCoatRoughness.contents = 0.55
        // Skin responds to the actual club lights; avoid an emissive rim.
        m.shaderModifiers = nil
    }

    private static func robotMaterial(_ m: SCNMaterial, _ n: String) {
        m.lightingModel = .physicallyBased
        if n.contains("chrome") {
            m.metalness.contents = 1.0; m.roughness.contents = 0.24
            _ = useMap(m.roughness, "chrome_use_rough", tile: 4)
        }
        else if n.contains("white") { m.diffuse.contents = UIColor(white: 0.72, alpha: 1); m.metalness.contents = 0.0; m.roughness.contents = 0.44; m.clearCoat.contents = 0.18; m.clearCoatRoughness.contents = 0.35 }
        else if n.contains("orange") { m.metalness.contents = 0.25; m.roughness.contents = 0.38; m.clearCoat.contents = 0.4 }
        else if n.contains("glow") || n.contains("lamp") {
            let c: UIColor = n.contains("cyan") ? UIColor(red: 0.2, green: 0.85, blue: 1, alpha: 1)
                : n.contains("pink") ? UIColor(red: 1, green: 0.25, blue: 0.65, alpha: 1) : UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1)
            m.emission.contents = c
            m.emission.intensity = 2.5
        } else { m.metalness.contents = 0.6; m.roughness.contents = 0.3 }
    }

    /// スキン付きノードを複製し、骨の参照を複製側に付け替える
    private func cloneSkinned(_ template: SCNNode, tint: UIColor? = nil) -> SCNNode {
        let c = template.clone()
        c.enumerateHierarchy { node, _ in
            guard let s = node.skinner else { return }
            let lname = (node.name ?? "").lowercased()
            let recolor = tint != nil && lname.contains("suit")
            if recolor, let g = node.geometry?.copy() as? SCNGeometry {
                g.materials = g.materials.map { m in
                    let n = (m.copy() as? SCNMaterial) ?? m
                    n.multiply.contents = tint
                    return n
                }
                node.geometry = g
            }
            let bones: [SCNNode] = s.bones.compactMap { b in
                guard let nm = b.name else { return nil }
                return c.childNode(withName: nm, recursively: true)
            }
            guard bones.count == s.bones.count, let base = recolor ? node.geometry : (s.baseGeometry ?? node.geometry) else { return }
            let ns = SCNSkinner(baseGeometry: base, bones: bones, boneInverseBindTransforms: s.boneInverseBindTransforms,
                                boneWeights: s.boneWeights, boneIndices: s.boneIndices)
            if let sk = s.skeleton?.name { ns.skeleton = c.childNode(withName: sk, recursively: true) }
            node.skinner = ns
        }
        return c
    }

    private func buildCrowd(into parent: SCNNode) -> [Person] {
        if Self.videoMode { return [] }
        var people: [Person] = []
        let phoneMat = SCNMaterial()
        phoneMat.lightingModel = .constant
        phoneMat.diffuse.contents = UIColor.white
        phoneMat.emission.contents = UIColor(red: 0.9, green: 0.95, blue: 1, alpha: 1)
        phoneMat.emission.intensity = 2.5
        phoneMat.isDoubleSided = true
        let names = (1...18).map { String(format: "c%02d", $0) }
        // 手前の数列だけ精細な版、それ以外は軽い版（読み込みと描画を軽く）
        let near = Self.nearNames.compactMap { loadCharacter($0) }
        let far = names.compactMap { loadCharacter($0, lod: true) }
        guard !near.isEmpty else { return [] }
        let count = min(96, venue.crowdSize * 2 + 20)
        var seed: UInt64 = venue.rawValue.utf8.reduce(0x9E3779B97F4A7C15) { ($0 &* 31) &+ UInt64($1) }
        func rnd() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24)
        }
        // 服の色（元の色に掛け合わせる。白はそのまま）
        let palette: [UIColor] = [.white, .white, .white, UIColor(white: 0.25, alpha: 1), UIColor(white: 0.45, alpha: 1),
                                  UIColor(red: 0.85, green: 0.35, blue: 0.35, alpha: 1), UIColor(red: 0.55, green: 0.6, blue: 0.4, alpha: 1),
                                  UIColor(red: 0.95, green: 0.85, blue: 0.6, alpha: 1), UIColor(red: 0.6, green: 0.45, blue: 0.75, alpha: 1),
                                  UIColor(red: 0.4, green: 0.55, blue: 0.8, alpha: 1), UIColor(red: 0.9, green: 0.6, blue: 0.75, alpha: 1)]
        let boneNames = ["Hips", "Spine", "Spine1", "Spine2", "Neck", "Head", "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand",
                         "RightShoulder", "RightArm", "RightForeArm", "RightHand", "LeftUpLeg", "LeftLeg", "LeftFoot",
                         "RightUpLeg", "RightLeg", "RightFoot"]
        var placed: [SIMD2<Float>] = []
        for i in 0..<count {
            var pos = SIMD2<Float>(0, 0)
            for _ in 0..<40 {
                let depth: Float = 2.2 + powf(rnd(), 0.9) * 10.5
                let half: Float = 1.4 + (depth - 2.2) * 0.5
                pos = SIMD2((rnd() * 2 - 1) * min(half, 6.2), -depth)
                if placed.allSatisfy({ simd_distance($0, pos) > 0.52 }) { break }
            }
            placed.append(pos)
            let useFar = -pos.y > 4.8 && !far.isEmpty
            let pool = useFar ? far : near
            let ti = Int(rnd() * Float(palette.count)) % palette.count
            let node = cloneSkinned(pool[(i * 7 + Int(rnd() * 5)) % pool.count], tint: ti < 3 ? nil : palette[ti])
            node.position = SCNVector3(pos.x, -1.02, pos.y)
            // DJ のほうを向く（少しばらつかせる）
            node.eulerAngles.y = atan2(-pos.x, 1.0 - pos.y) + (rnd() - 0.5) * 0.5
            let sc = 0.92 + rnd() * 0.16
            let width = 0.96 + rnd() * 0.08
            node.scale = SCNVector3(sc * width, sc, sc * width)
            node.enumerateHierarchy { n, _ in n.castsShadow = !useFar }
            parent.addChildNode(node)

            let special: Int = i < 6 ? [1, 2, 3, 4, 5, 0][i] : 0
            let p = Person(root: node, phase: rnd() * 100, speed: 0.92 + rnd() * 0.16, bias: Double(rnd() * 24 - 12),
                           special: special, phoneUser: rnd() < 0.45)
            for b in boneNames {
                let key = "mixamorig:\(b)"
                guard let bn = node.childNode(withName: key, recursively: true)
                        ?? node.childNode(withName: "rig_mixamorig_\(b)", recursively: true) else { continue }
                p.bones.append((bn, key, bn.simdOrientation, CrowdClips.space(for: bn, in: p.root, name: key)))
                if b == "Hips" { p.hips = bn; p.hipsBind = bn.simdPosition }
            }
            if special == 5 { node.isHidden = true }   // 伝説のクラバーは INSANE で現れる
            if p.phoneUser, let hand = node.childNode(withName: "mixamorig:RightHand", recursively: true)
                ?? node.childNode(withName: "rig_mixamorig_RightHand", recursively: true) {
                let screen = SCNNode(geometry: SCNPlane(width: 0.07, height: 0.14))
                screen.geometry?.firstMaterial = phoneMat
                screen.position = SCNVector3(0, 0.1, 0.02)
                screen.isHidden = true
                hand.addChildNode(screen)
                p.phoneLight = screen
            }
            people.append(p)
        }
        return people
    }

    private func buildArms(into parent: SCNNode) -> ([Person], [[ArmRig]]) {
        var people: [Person] = []
        let phoneMat = SCNMaterial()
        phoneMat.lightingModel = .constant
        phoneMat.diffuse.contents = UIColor.white
        phoneMat.emission.contents = UIColor(red: 0.9, green: 0.95, blue: 1, alpha: 1)
        phoneMat.emission.intensity = 2.5
        phoneMat.isDoubleSided = true
        var arms: [[ArmRig]] = []
        // DJ A は左、DJ B は右。観客側（-z）を向いてブースの手前に立つ
        let setups: [(String, Float)] = [(characters[0], -0.42), (characters[1], 0.42)]
        let boneNames = ["Hips", "Spine", "Spine1", "Spine2", "Neck", "Head", "LeftShoulder", "RightShoulder",
                         "LeftUpLeg", "LeftLeg", "LeftFoot", "RightUpLeg", "RightLeg", "RightFoot"]
        for (k, (name, cx)) in setups.enumerated() {
            guard let t = loadCharacter(name) else { arms.append([]); continue }
            let dj = cloneSkinned(t)
            dj.position = SCNVector3(cx, -1.02, 0.5)
            dj.eulerAngles.y = .pi
            parent.addChildNode(dj)
            // 体は観客と同じ仕組みで小さく揺らす（腕は後で IK が上書き）
            let p = Person(root: dj, phase: Float(k) * 0.37, speed: 1, bias: 0, special: 6, phoneUser: false)
            for b in boneNames {
                let key = "mixamorig:\(b)"
                guard let bn = dj.childNode(withName: key, recursively: true)
                        ?? dj.childNode(withName: "rig_mixamorig_\(b)", recursively: true) else { continue }
                p.bones.append((bn, key, bn.simdOrientation, CrowdClips.space(for: bn, in: p.root, name: key)))
                if b == "Hips" { p.hips = bn; p.hipsBind = bn.simdPosition }
            }
            people.append(p)
            // 観客側を向いているので、本人の左手は画面の左
            let left = ArmRig(model: dj, prefix: "Left", side: -1)
            let right = ArmRig(model: dj, prefix: "Right", side: 1)
            // [外側, 内側]
            arms.append(cx < 0 ? [left, right].compactMap { $0 } : [right, left].compactMap { $0 })
        }
        for d in 0..<arms.count {
            for k in 0..<arms[d].count { arms[d][k].tip = restTip(d, outer: k == 0) }
        }
        // VJ：DJ と重ならない人を選び、左の台でノート PC とコントローラーを操作
        let vjName = ["c13", "c16", "c05", "c12"].first { !characters.contains($0) } ?? "c13"
        let desk = vjDesk
        let deskM = SCNMaterial(); deskM.diffuse.contents = UIColor(white: 0.05, alpha: 1); pbr(deskM, rough: 0.55)
        let deskRoot = SCNNode()
        deskRoot.isHidden = Self.videoMode
        let parent = Self.videoMode ? deskRoot : parent
        let riser = SCNNode(geometry: SCNBox(width: 1.6, height: 0.3, length: 1.4, chamferRadius: 0.01))
        riser.geometry?.materials = [deskM]
        riser.simdPosition = SIMD3(desk.x, -0.87, desk.z + 0.35)
        parent.addChildNode(riser)
        let table = SCNNode(geometry: SCNBox(width: 0.9, height: 0.92, length: 0.5, chamferRadius: 0.01))
        table.geometry?.materials = [deskM]
        table.simdPosition = SIMD3(desk.x, desk.y - 0.46, desk.z)
        parent.addChildNode(table)
        let alu = SCNMaterial(); alu.diffuse.contents = UIColor(white: 0.7, alpha: 1); pbr(alu, rough: 0.3, metal: 1)
        let base = SCNNode(geometry: SCNBox(width: 0.34, height: 0.015, length: 0.23, chamferRadius: 0.005))
        base.geometry?.materials = [alu]
        base.simdPosition = SIMD3(desk.x - 0.12, desk.y + 0.008, desk.z + 0.02)
        parent.addChildNode(base)
        let lid = SCNNode(geometry: SCNBox(width: 0.34, height: 0.22, length: 0.01, chamferRadius: 0.005))
        lid.geometry?.materials = [alu]
        lid.simdPosition = SIMD3(desk.x - 0.12, desk.y + 0.115, desk.z - 0.1)
        lid.eulerAngles.x = -0.25
        parent.addChildNode(lid)
        if let lm = laptopMat {
            // 画面は VJ 側（+z）を向く
            let screen = SCNNode(geometry: SCNPlane(width: 0.31, height: 0.19))
            screen.geometry?.materials = [lm]
            screen.position = SCNVector3(0, 0, 0.0055)
            lid.addChildNode(screen)
        }
        let ctrl = SCNNode(geometry: SCNBox(width: 0.2, height: 0.03, length: 0.14, chamferRadius: 0.006))
        ctrl.geometry?.materials = [deskM]
        ctrl.simdPosition = SIMD3(desk.x + 0.2, desk.y + 0.015, desk.z + 0.03)
        parent.addChildNode(ctrl)
        for i in 0..<8 {
            let pad = SCNNode(geometry: SCNBox(width: 0.035, height: 0.008, length: 0.035, chamferRadius: 0.004))
            let pm = SCNMaterial(); pm.lightingModel = .constant
            pm.diffuse.contents = UIColor(hue: CGFloat(i) / 8, saturation: 0.9, brightness: 1, alpha: 1)
            pad.geometry?.materials = [pm]
            pad.simdPosition = SIMD3(Float(i % 4) * 0.045 - 0.0675, 0.018, Float(i / 4) * 0.045 - 0.022)
            ctrl.addChildNode(pad)
        }
        if !Self.videoMode, let t = loadCharacter(vjName) {
            let vj = cloneSkinned(t)
            vj.simdPosition = SIMD3(desk.x - 0.05, -0.72, desk.z + 0.5)
            vj.eulerAngles.y = .pi
            parent.addChildNode(vj)
            let p = Person(root: vj, phase: 3.3, speed: 1, bias: 0, special: 6, phoneUser: false)
            for b in boneNames {
                let key = "mixamorig:\(b)"
                guard let bn = vj.childNode(withName: key, recursively: true)
                        ?? vj.childNode(withName: "rig_mixamorig_\(b)", recursively: true) else { continue }
                p.bones.append((bn, key, bn.simdOrientation, CrowdClips.space(for: bn, in: p.root, name: key)))
                if b == "Hips" { p.hips = bn; p.hipsBind = bn.simdPosition }
            }
            people.append(p)
            // 観客側を向いているので、左手がノート PC（-x）、右手がコントローラー（+x）
            let left = ArmRig(model: vj, prefix: "Left", side: -1)
            let right = ArmRig(model: vj, prefix: "Right", side: 1)
            if let left, let right {
                left.tip = SIMD3(desk.x - 0.15, desk.y + 0.02, desk.z + 0.06)
                right.tip = SIMD3(desk.x + 0.2, desk.y + 0.03, desk.z + 0.05)
                arms.append([left, right])
            }
        }
        return (people, arms)
    }

    private func buildLights() {
        let light = UIColor(venue.palette.2)
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 60
        ambient.light?.color = UIColor(white: 0.8, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        // ブースの手元灯（影あり）
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .spot
        key.light?.intensity = 145
        key.light?.color = UIColor(red: 1, green: 0.92, blue: 0.82, alpha: 1)
        key.light?.spotInnerAngle = 30
        key.light?.spotOuterAngle = 70
        key.light?.castsShadow = true
        key.light?.shadowMode = .deferred
        key.light?.shadowRadius = 4
        key.light?.shadowSampleCount = 8
        key.light?.shadowMapSize = CGSize(width: 1024, height: 1024)
        key.light?.attenuationStartDistance = 0.5
        key.light?.attenuationEndDistance = 3.0
        key.light?.shadowColor = UIColor(white: 0, alpha: 0.7)
        key.position = SCNVector3(0.2, 1.6, -0.2)
        key.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(key)

        // 観客の後ろからの逆光
        let back = SCNNode()
        back.light = SCNLight()
        back.light?.type = .omni
        back.light?.intensity = 420
        back.light?.color = light
        back.light?.attenuationStartDistance = 2
        back.light?.attenuationEndDistance = 16
        back.position = SCNVector3(0, 3, -11)
        scene.rootNode.addChildNode(back)

        // Soft front fill reveals faces without flooding the booth.
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .spot
        fill.light?.color = UIColor(red: 0.68, green: 0.8, blue: 1, alpha: 1)
        fill.light?.intensity = 190
        fill.light?.spotInnerAngle = 50
        fill.light?.spotOuterAngle = 90
        fill.light?.attenuationStartDistance = 1
        fill.light?.attenuationEndDistance = 11
        fill.position = SCNVector3(0, 2.1, -0.8)
        fill.look(at: SCNVector3(0, -0.15, -5.5))
        scene.rootNode.addChildNode(fill)

        // ムービングライト（光の筋つき）
        let beamImg = Self.beamImage()
        for i in 0..<4 {
            let n = SCNNode()
            let color = UIColor(hue: CGFloat(i) / 4 + 0.05, saturation: 0.8, brightness: 1, alpha: 1)
            n.light = SCNLight()
            n.light?.type = .spot
            n.light?.intensity = 0
            n.light?.spotInnerAngle = 6
            n.light?.spotOuterAngle = 22
            n.light?.attenuationStartDistance = 1.5
            n.light?.attenuationEndDistance = 13
            n.light?.color = color
            n.position = SCNVector3(-4.5 + Float(i) * 3, 3.25, i % 2 == 0 ? -3 : -7.5)
            let beam = SCNNode(geometry: SCNCone(topRadius: 0.05, bottomRadius: 1.4, height: 9))
            let bm = SCNMaterial()
            bm.lightingModel = .constant
            bm.diffuse.contents = beamImg
            bm.multiply.contents = color
            bm.blendMode = .add
            bm.writesToDepthBuffer = false
            bm.isDoubleSided = true
            beam.geometry?.materials = [bm]
            beam.position = SCNVector3(0, 0, -4.5)
            beam.eulerAngles.x = .pi / 2
            beam.opacity = 0
            beam.name = "beam"
            n.addChildNode(beam)
            scene.rootNode.addChildNode(n)
            movers.append(n)
        }

        // レーザー
        for i in 0..<10 {
            let n = SCNNode()
            n.position = SCNVector3(i % 2 == 0 ? -6 : 6, 3.2, -12)
            let beam = SCNNode(geometry: SCNCylinder(radius: 0.006, height: 24))
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = UIColor(red: 0.2, green: 1, blue: 0.3, alpha: 1)
            m.emission.contents = UIColor(red: 0.2, green: 1, blue: 0.3, alpha: 1)
            m.emission.intensity = 3
            m.blendMode = .add
            m.writesToDepthBuffer = false
            beam.geometry?.materials = [m]
            beam.position = SCNVector3(0, 12, 0)
            n.addChildNode(beam)
            n.opacity = 0
            scene.rootNode.addChildNode(n)
            lasers.append(n)
        }


        // 反応の演出で一瞬光るライト
        fxLight.light = SCNLight()
        fxLight.light?.type = .omni
        fxLight.light?.intensity = 0
        fxLight.light?.attenuationStartDistance = 1
        fxLight.light?.attenuationEndDistance = 9
        fxLight.position = SCNVector3(0, 1.2, -3.8)
        scene.rootNode.addChildNode(fxLight)

        // 紙吹雪（LEGENDARY のときだけ）
        let ps = SCNParticleSystem()
        ps.birthRate = 0
        ps.particleLifeSpan = 5
        ps.particleSize = 0.035
        ps.particleColor = .systemPink
        ps.particleColorVariation = SCNVector4(1, 0.4, 0.2, 0)
        ps.emitterShape = SCNBox(width: 10, height: 0.1, length: 8, chamferRadius: 0)
        ps.particleVelocity = 0.4
        ps.acceleration = SCNVector3(0, -0.8, 0)
        ps.particleAngularVelocity = 300
        ps.particleAngularVelocityVariation = 200
        ps.isLightingEnabled = false
        ps.blendMode = .alpha
        let cn = SCNNode()
        cn.position = SCNVector3(0, 4, -5)
        cn.addParticleSystem(ps)
        scene.rootNode.addChildNode(cn)
        confetti = ps

        // スモーク（盛り上がると床から流れる）
        let sm = SCNParticleSystem()
        sm.birthRate = 0
        sm.particleLifeSpan = 7
        sm.particleLifeSpanVariation = 2
        sm.particleImage = Self.puffImage()
        sm.particleSize = 1.1
        sm.particleSizeVariation = 0.5
        sm.particleColor = UIColor(white: 0.75, alpha: 0.10)
        sm.emitterShape = SCNBox(width: 12, height: 0.1, length: 1, chamferRadius: 0)
        sm.particleVelocity = 0.25
        sm.particleVelocityVariation = 0.2
        sm.spreadingAngle = 60
        sm.acceleration = SCNVector3(0, 0.02, 0.05)
        sm.blendMode = .alpha
        sm.isLightingEnabled = true
        sm.sortingMode = .distance
        let smn = SCNNode()
        smn.position = SCNVector3(0, -0.85, -6)
        smn.addParticleSystem(sm)
        scene.rootNode.addChildNode(smn)
        smoke = sm
    }

    // MARK: 観客の実写動画

    private func setupCrowdVideo() {
        for i in 0..<2 {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = UIColor.black
            m.readsFromDepthBuffer = false
            m.writesToDepthBuffer = false
            let n = SCNNode(geometry: SCNPlane(width: 1, height: 1))
            n.geometry?.materials = [m]
            n.renderingOrder = -20 + i
            n.position = SCNVector3(0, 0, -videoDistance)
            n.opacity = i == 0 ? 1 : 0
            n.castsShadow = false
            cameraNode.addChildNode(n)
            videoNodes.append(n)
        }
        let first = EnergyTier(72).rawValue
        DispatchQueue.main.async { [self] in showVideo(first, fade: false) }
    }

    /// 描画スレッド：画面の縦横比に合わせて板を覆うように広げ、エネルギーの段階が 1.5 秒続いたら切り替える
    private func updateCrowdVideo(_ renderer: SCNSceneRenderer, time: TimeInterval, energy: Double) {
        let vp = renderer.currentViewport
        if vp.width > 0, vp.height > 0 {
            let aspect = Float(vp.width / vp.height)
            if abs(aspect - videoLayoutAspect) > 0.002 {
                videoLayoutAspect = aspect
                layoutVideo(aspect)
            }
        }
        let tier = EnergyTier(energy).rawValue
        lock.lock()
        if tier != videoWant { videoWant = tier; videoWantSince = time }
        let go = tier != videoTierShown && !videoSwitching && time - videoWantSince > 1.5 && videoTierShown >= 0
        if go { videoSwitching = true }
        lock.unlock()
        if go { DispatchQueue.main.async { [self] in showVideo(tier, fade: true) } }
    }

    private func layoutVideo(_ aspect: Float) {
        let fov = Float(cameraNode.camera?.fieldOfView ?? 60) * .pi / 180
        let H = 2 * videoDistance * tan(fov / 2)
        var w: Float, h: Float, y: Float = 0
        if aspect >= videoAspect {
            // 横に広い画面：幅に合わせて上下を切る。動画の黒い縁（下から約28%）がブースの天板の高さに来るよう上げる
            w = H * aspect
            h = w / videoAspect
            let vis = H / h
            let top = min(max(0.72 - 0.64 * vis, 0), 1 - vis)
            y = (top + vis / 2 - 0.5) * h
        } else {
            h = H
            w = H * videoAspect
        }
        for n in videoNodes {
            (n.geometry as? SCNPlane)?.width = CGFloat(w)
            (n.geometry as? SCNPlane)?.height = CGFloat(h)
            n.position = SCNVector3(0, y, -videoDistance)
        }
    }

    @MainActor
    private func videoPlayer(_ tier: Int) -> AVQueuePlayer? {
        if let p = videoPlayers[tier] { return p.player }
        guard tier < videoURLs.count else { return nil }
        let item = AVPlayerItem(url: videoURLs[tier])
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: item)
        videoPlayers[tier] = (player, looper)
        return player
    }

    @MainActor
    private func showVideo(_ tier: Int, fade: Bool) {
        guard videoNodes.count == 2, let player = videoPlayer(tier) else {
            lock.lock(); videoSwitching = false; lock.unlock()
            return
        }
        let old = videoTierShown
        player.play()
        let back = 1 - videoTop
        let top = videoNodes[videoTop], next = videoNodes[back]
        let mat = next.geometry?.firstMaterial
        videoTop = back
        onRender {
            mat?.diffuse.contents = player
            next.renderingOrder = -19
            top.renderingOrder = -20
            next.removeAllActions()
            if fade {
                next.opacity = 0
                next.runAction(.fadeIn(duration: 1.2))
            } else {
                next.opacity = 1
            }
        }
        lock.lock(); videoTierShown = tier; lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + (fade ? 1.4 : 0.1)) { [self] in
            if old >= 0, old != tier { videoPlayers[old]?.player.pause() }
            let prevMat = top.geometry?.firstMaterial
            onRender { top.opacity = 0; prevMat?.diffuse.contents = UIColor.black }
            lock.lock(); videoSwitching = false; lock.unlock()
        }
    }

    // MARK: 観客の反応 → パーティクル演出

    private static let puffImg = puffImage()
    private static let sparkImg: UIImage = {
        let s: CGFloat = 64
        return UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { ctx in
            let g = CGGradient(colorsSpace: nil, colors: [UIColor.white.cgColor, UIColor(white: 1, alpha: 0.55).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 0.18, 1])!
            ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0, endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s / 2, options: [])
        }
    }()

    @MainActor
    private func fireReaction(_ r: Reaction) {
        func flash(_ c: UIColor, _ amount: Float) {
            let light = fxLight.light
            onRender { light?.color = c }
            lock.lock(); fxFlash = max(fxFlash, amount); lock.unlock()
        }
        switch r {
        case .fire:
            // ステージ前の炎の柱＋火花
            let x = Float.random(in: 1.3...1.9)
            for sx in [-x, x] {
                burst(Self.flameJet(), at: SCNVector3(sx, -1.0, -3.0))
                burst(Self.sparks(UIColor(red: 1, green: 0.7, blue: 0.25, alpha: 1)), at: SCNVector3(sx, -0.6, -3.0))
            }
            flash(UIColor(red: 1, green: 0.5, blue: 0.15, alpha: 1), 1)
        case .heart:
            // フロアの上で弾けるピンクのきらめき
            let p = SCNVector3(Float.random(in: -1.2...1.2), Float.random(in: 1.1...1.8), Float.random(in: -5.5 ... -3.8))
            burst(Self.sparkleBurst(UIColor(red: 1, green: 0.3, blue: 0.6, alpha: 1)), at: p)
            burst(Self.sparkleBurst(UIColor(red: 1, green: 0.75, blue: 0.9, alpha: 1), small: true), at: p)
            flash(UIColor(red: 1, green: 0.3, blue: 0.65, alpha: 1), 0.6)
        case .clap:
            // 左右から紙吹雪の大砲
            for sx: Float in [-2.3, 2.3] {
                burst(Self.confettiCannon(toward: -sx), at: SCNVector3(sx, -0.8, -3.3))
            }
            flash(UIColor(white: 1, alpha: 1), 0.45)
        case .meh:
            burst(Self.dustPuff(UIColor(white: 0.7, alpha: 0.12)), at: SCNVector3(Float.random(in: -1...1), -0.9, -4.2))
        case .boo:
            burst(Self.dustPuff(UIColor(red: 0.35, green: 0.45, blue: 0.8, alpha: 0.16)), at: SCNVector3(Float.random(in: -1...1), -0.9, -4.0))
            flash(UIColor(red: 0.2, green: 0.3, blue: 1, alpha: 1), 0.25)
        }
    }

    @MainActor
    private func burst(_ ps: SCNParticleSystem, at p: SCNVector3) {
        let root = scene.rootNode
        onRender {
            let n = SCNNode()
            n.position = p
            root.addChildNode(n)
            n.addParticleSystem(ps)
            let life = Double(ps.emissionDuration + ps.particleLifeSpan + ps.particleLifeSpanVariation) + 0.3
            n.runAction(.sequence([.wait(duration: life), .removeFromParentNode()]))
        }
    }

    private static func oneShot(_ count: CGFloat, over duration: CGFloat) -> SCNParticleSystem {
        let ps = SCNParticleSystem()
        ps.loops = false
        ps.emissionDuration = duration
        ps.birthRate = count / duration
        ps.isLightingEnabled = false
        ps.blendMode = .additive
        ps.emittingDirection = SCNVector3(0, 1, 0)
        return ps
    }

    private static func fade(_ ps: SCNParticleSystem, _ colors: [UIColor], sizes: [CGFloat]? = nil) {
        let c = CAKeyframeAnimation()
        c.values = colors
        var ctl: [SCNParticleSystem.ParticleProperty: SCNParticlePropertyController] = [.color: SCNParticlePropertyController(animation: c)]
        if let sizes {
            let s = CAKeyframeAnimation()
            s.values = sizes
            ctl[.size] = SCNParticlePropertyController(animation: s)
        }
        ps.propertyControllers = ctl
    }

    private static func flameJet() -> SCNParticleSystem {
        let ps = oneShot(260, over: 0.45)
        ps.particleImage = puffImg
        ps.particleLifeSpan = 0.6
        ps.particleLifeSpanVariation = 0.2
        ps.particleVelocity = 5.2
        ps.particleVelocityVariation = 1.2
        ps.spreadingAngle = 6
        ps.acceleration = SCNVector3(0, 1.5, 0)
        ps.particleSize = 0.2
        ps.emitterShape = SCNSphere(radius: 0.06)
        fade(ps, [UIColor(red: 1, green: 0.95, blue: 0.75, alpha: 1), UIColor(red: 1, green: 0.55, blue: 0.12, alpha: 0.9),
                  UIColor(red: 0.8, green: 0.15, blue: 0.03, alpha: 0.5), UIColor(red: 0.2, green: 0.02, blue: 0, alpha: 0)],
             sizes: [0.12, 0.3, 0.5, 0.7])
        return ps
    }

    private static func sparks(_ color: UIColor) -> SCNParticleSystem {
        let ps = oneShot(160, over: 0.25)
        ps.particleImage = sparkImg
        ps.particleLifeSpan = 1.1
        ps.particleLifeSpanVariation = 0.4
        ps.particleVelocity = 4.5
        ps.particleVelocityVariation = 2
        ps.spreadingAngle = 35
        ps.acceleration = SCNVector3(0, -5, 0)
        ps.particleSize = 0.03
        ps.stretchFactor = 0.05
        fade(ps, [UIColor.white, color, color.withAlphaComponent(0)])
        return ps
    }

    private static func sparkleBurst(_ color: UIColor, small: Bool = false) -> SCNParticleSystem {
        let ps = oneShot(small ? 120 : 260, over: 0.08)
        ps.particleImage = sparkImg
        ps.particleLifeSpan = small ? 1.0 : 1.7
        ps.particleLifeSpanVariation = 0.5
        ps.particleVelocity = small ? 1.0 : 2.2
        ps.particleVelocityVariation = 0.8
        ps.spreadingAngle = 180
        ps.dampingFactor = 1.6
        ps.acceleration = SCNVector3(0, -0.7, 0)
        ps.particleSize = small ? 0.07 : 0.045
        ps.particleSizeVariation = 0.02
        fade(ps, [UIColor.white, color, color, color.withAlphaComponent(0)])
        return ps
    }

    private static func confettiCannon(toward dir: Float) -> SCNParticleSystem {
        let ps = oneShot(170, over: 0.25)
        ps.blendMode = .alpha
        ps.emittingDirection = SCNVector3(dir * 0.16, 1, -0.1)
        ps.spreadingAngle = 16
        ps.particleLifeSpan = 3
        ps.particleLifeSpanVariation = 1
        ps.particleVelocity = 6.5
        ps.particleVelocityVariation = 2
        ps.dampingFactor = 1.4
        ps.acceleration = SCNVector3(0, -2.2, 0)
        ps.particleSize = 0.022
        ps.particleSizeVariation = 0.008
        ps.particleAngularVelocity = 500
        ps.particleAngularVelocityVariation = 400
        ps.particleColor = UIColor(red: 1, green: 0.85, blue: 0.2, alpha: 1)
        ps.particleColorVariation = SCNVector4(1, 0.4, 0.15, 0)
        return ps
    }

    private static func dustPuff(_ color: UIColor) -> SCNParticleSystem {
        let ps = oneShot(18, over: 0.3)
        ps.blendMode = .alpha
        ps.particleImage = puffImg
        ps.particleLifeSpan = 2.2
        ps.particleVelocity = 0.4
        ps.spreadingAngle = 70
        ps.particleSize = 0.5
        ps.particleSizeVariation = 0.2
        fade(ps, [color, color.withAlphaComponent(0)], sizes: [0.4, 1.0])
        return ps
    }

    private static func puffImage() -> UIImage {
        let s: CGFloat = 128
        return UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { ctx in
            let g = CGGradient(colorsSpace: nil, colors: [UIColor(white: 1, alpha: 0.9).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0, endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s / 2, options: [])
        }
    }

    // MARK: 状態（メインスレッドから）

    @MainActor
    func apply(_ s: BoothState) {
        lock.lock(); st = s; let isReady = ready; lock.unlock()
        guard isReady else { lastApplied = s; return }
        let prev = lastApplied
        lastApplied = s

        let poseChanged = prev == nil || prev!.owner != s.owner || prev!.currentID != s.currentID
            || prev!.nextID != s.nextID || prev!.phase != s.phase || prev!.selector != s.selector
            || prev!.nextHidden != s.nextHidden
        if poseChanged {
            updateDecks(s)
            planHands(s)
        }
        if prev?.currentID != s.currentID || prev?.vjMode != s.vjMode { updateVJTrack(s) }
        if prev?.energy != s.energy { updateMeters(s.energy) }
        for r in s.reactions where !seenReactions.contains(r.id) {
            seenReactions.insert(r.id)
            if let kind = Reaction(rawValue: r.text) { fireReaction(kind) }
        }
        if seenReactions.count > 200 { seenReactions = Set(s.reactions.map { $0.id }) }
    }

    private func isLive(_ p: GameEngine.Phase) -> Bool { p == .playing || p == .countdown }

    @MainActor
    private func updateDecks(_ s: BoothState) {
        for d in 0..<min(2, platters.count) {
            let playingHere = s.current != nil && s.owner == d && isLive(s.phase)
            let loadedHere = s.next != nil && s.selector == d
            if s.owner == d, let t = s.current, !loadedHere {
                applyPlatter(d, vinyl(art(for: t)))
                applyScreen(d, title: t.title, mode: playingHere ? "ON AIR" : "LOADED", color: playingHere ? .green : .orange)
            } else if loadedHere, let n = s.next {
                applyPlatter(d, vinyl(s.nextHidden ? nil : art(for: n)))
                applyScreen(d, title: s.nextHidden ? "SECRET TRACK" : n.title, mode: "CUE", color: .orange)
            } else if s.selector == d {
                applyPlatter(d, vinyl(nil))
                applyScreen(d, title: nil, mode: "BROWSING", color: .cyan)
            } else {
                applyPlatter(d, vinyl(nil))
                applyScreen(d, title: nil, mode: "STANDBY", color: .gray)
            }
            if d < playLEDs.count {
                let m = playLEDs[d].geometry?.firstMaterial
                onRender {
                    m?.emission.contents = playingHere ? UIColor.green : UIColor.black
                    m?.emission.intensity = playingHere ? 2 : 0
                }
            }
        }
    }

    @MainActor
    private func updateMeters(_ e: Int) {
        let lit = Int((Double(e) / 100 * 12).rounded())
        let meters = self.meters
        onRender {
        for c in 0..<meters.count {
            for (i, led) in meters[c].enumerated() {
                let color: UIColor = i < 7 ? .green : i < 10 ? .yellow : .red
                let m = led.geometry?.firstMaterial
                m?.emission.contents = i < lit ? color : UIColor.black
                m?.emission.intensity = i < lit ? 2.5 : 0
            }
        }
        }
    }

    // MARK: 手の段取り

    private func worldPos(_ n: SCNNode?, _ off: SIMD3<Float>) -> SIMD3<Float> {
        (n?.simdWorldPosition ?? .zero) + off
    }

    private func restTip(_ d: Int, outer: Bool) -> SIMD3<Float> {
        let cx: Float = d == 0 ? -0.45 : 0.45
        if outer { return SIMD3(cx + (d == 0 ? -0.14 : 0.14), 0.0, 0.3) }
        return SIMD3(cx + (d == 0 ? 0.12 : -0.12), 0.0, 0.3)
    }

    @MainActor
    private func planHands(_ s: BoothState) {
        let live = isLive(s.phase)
        var newTargets = targets
        var newGestures = gestures
        if newTargets.count < 3 { newTargets.append(targets.last ?? []) }
        if newGestures.count < 3 { newGestures.append([.tap(1.2), .twist]) }
        for d in 0..<2 {
            let isOwner = s.owner == d && s.current != nil
            let isSel = s.selector == d
            let side: Float = d == 0 ? -1 : 1
            let jog = worldPos(d < platters.count ? platters[d] : nil, SIMD3(side * 0.06, 0.012, 0.055))
            let screen = worldPos(d < screens.count ? screens[d] : nil, SIMD3(0, 0.015, 0.02))
            let cue = worldPos(d < cueLEDs.count ? cueLEDs[d] : nil, SIMD3(0, 0.012, 0))
            let play = worldPos(d < playLEDs.count ? playLEDs[d] : nil, SIMD3(0, 0.012, 0))
            let knobIdx = s.phase == .countdown ? 4 : abs((s.currentID ?? "").hashValue) % 4
            let knob = worldPos(knobIdx < knobs[d].count ? knobs[d][knobIdx] : nil, SIMD3(0, 0.022, 0.012))
            let fader = worldPos(d < faders.count ? faders[d] : nil, SIMD3(0, 0.016, 0))
            let xf = worldPos(xfader, SIMD3(0, 0.016, 0))
            let rest = [restTip(d, outer: true), restTip(d, outer: false)]

            var g: [Gesture] = [.idle, .idle]
            var t = rest
            switch s.phase {
            case .transition where isSel:
                t = [play, xf]; g = [.tap(1.5), .hold]
            case .transition:
                t = [rest[0], fader]; g = [.idle, .hold]
            case .waitingForNextDJ where isSel:
                t = [screen, cue]; g = [.tap(3), .tap(2)]
            case .searchingTrack where isSel:
                t = [screen, rest[1]]; g = [.tap(1.2), .idle]
            default:
                if live && isOwner {
                    t = [jog, knob]; g = [.jog, .twist]
                } else if live && isSel {
                    t = s.next != nil ? [cue, rest[1]] : [screen, rest[1]]
                    g = s.next != nil ? [.tap(1), .idle] : [.tap(1.3), .idle]
                }
            }
            newTargets[d] = t
            newGestures[d] = g
        }
        // フェーダー：流れている側が上がる。切り替え中は次の人の側へ
        let mixTo = s.phase == .transition ? s.selector : s.owner
        let liveOwner = isLive(s.phase) ? s.owner : -1
        newTargets[2] = targets[2]
        newGestures[2] = gestures[2]
        lock.lock()
        targets = newTargets
        gestures = newGestures
        faderGoal = [(mixTo == 0 || liveOwner == 0) ? 1 : 0, (mixTo == 1 || liveOwner == 1) ? 1 : 0]
        xGoal = mixTo == 0 ? -1 : 1
        lock.unlock()
    }

    // MARK: 毎フレーム（描画スレッド）

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = Float(lastTime == 0 ? 1.0 / 30 : min(0.1, time - lastTime))
        lastTime = time
        lock.lock()
        let s = st
        let tg = targets, gs = gestures, fg = faderGoal, xg = xGoal
        let crowd = people, rigs = arms, isReady = ready
        let jobs = pending
        pending.removeAll()
        lastFrameAt = CACurrentMediaTime()
        lock.unlock()
        for job in jobs { job() }
        if Self.videoMode { updateCrowdVideo(renderer, time: time, energy: Double(s.energy)) }
        guard isReady else { return }
        let t = Float(time.truncatingRemainder(dividingBy: 10000))
        let energy = Double(s.energy)

        updateCrowd(crowd, t: t, dt: dt, energy: energy)
        updateHands(rigs, t: t, dt: dt, targets: tg, gestures: gs)
        updateGear(t: t, dt: dt, s: s, faderGoal: fg, xGoal: xg)
        updateLights(t: t, energy: energy)
        // 人が持っているような、ゆっくりした揺れ
        let sway = simd_quatf(angle: sin(t * 0.37) * 0.006 + sin(t * 1.1) * 0.002, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: sin(t * 0.29 + 1) * 0.008, axis: SIMD3<Float>(0, 1, 0))
        cameraNode.simdOrientation = camBase * sway
        smoke?.birthRate = energy > 70 ? CGFloat((energy - 70) / 30 * 6) : 0
        lock.lock(); fxFlash *= expf(-dt * 4.5); let fl = fxFlash; lock.unlock()
        fxLight.light?.intensity = CGFloat(fl * 1400)
    }

    private func clipFor(_ p: Person, energy: Double) -> String {
        if energy >= 99.5 { return p.special == 6 ? "sway" : (Int(p.phase) % 2 == 0 ? "jump_mc" : "jump") }
        switch p.special {
        case 1: return "crossed"
        case 2: return energy >= 90 ? "clap" : "crossed"
        case 3: return energy >= 60 ? "jump" : "hands_up"
        case 4: return energy >= 40 ? "bounce" : "sway"
        case 6: return "sway"
        default: break
        }
        let e = energy + p.bias
        let pick = Int(p.phase * 7) % 6
        switch e {
        case ..<20.5: return p.phoneUser ? "phone" : (pick < 2 ? "crossed" : "idle")
        case ..<40.5: return ["idle", "sway", "sway", "idle", "dance_a", "sway"][pick]
        case ..<60.5: return ["clap", "sway", "bounce", "dance_a", "dance_twist", "dance_b"][pick]
        case ..<80.5: return ["dance_twist", "dance_a", "dance_b", "mickey", "clap", "hands_up"][pick]
        default: return ["jump_mc", "hands_up", "dance_twist", "mickey", "jump", "macarena"][pick]
        }
    }

    private func updateCrowd(_ people: [Person], t: Float, dt: Float, energy: Double) {
        let clips = CrowdClips.all
        guard !clips.isEmpty else { return }
        for p in people {
            if p.special == 5 { p.root.isHidden = energy < 81 }

            let want = clipFor(p, energy: energy)
            p.phoneLight?.isHidden = !(want == "phone" || energy >= 95)
            if want != p.clip {
                p.prevClip = p.clip
                p.clip = want
                p.blend = 0
            }
            p.blend = min(1, p.blend + dt * 2.5)
            guard let c = clips[p.clip] else { continue }
            p.clock += dt * p.speed
            let ft = p.clock * CrowdClips.fps
            let frame = Int(ft)
            let fraction = ft - Float(frame)
            let f = frame % max(1, c.frames)
            let nf = (f + 1) % max(1, c.frames)
            let prev = p.blend < 1 ? p.prevClip.flatMap { clips[$0] } : nil
            let pf = prev.map { frame % max(1, $0.frames) } ?? 0
            let npf = prev.map { (pf + 1) % max(1, $0.frames) } ?? 0
            let blend = p.blend * p.blend * (3 - 2 * p.blend)
            for b in p.bones {
                guard let qs = c.bones[b.name], f < qs.count else { continue }
                let delta = simd_slerp(qs[f], qs[min(nf, qs.count - 1)], fraction)
                var q = b.bind * b.space * delta * b.space.inverse
                if let pc = prev, let pqs = pc.bones[b.name], pf < pqs.count {
                    let from = simd_slerp(pqs[pf], pqs[min(npf, pqs.count - 1)], fraction)
                    q = simd_slerp(b.bind * b.space * from * b.space.inverse, q, blend)
                }
                b.node.simdOrientation = q
            }
            if Self.debugTilt, let h = p.hips, Int(t * 2) != Int((t - dt) * 2) {
                // 休止姿勢で真上を向く腰ローカルの軸が、今どれだけ傾いたか
                let parentW = h.parent?.simdWorldOrientation ?? simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
                let bindW = parentW * (p.bones.first { $0.name == "mixamorig:Hips" }?.bind ?? h.simdOrientation)
                let upLocal = bindW.inverse.act(SIMD3<Float>(0, 1, 0))
                let up = h.simdWorldOrientation.act(upLocal)
                let tilt = acos(max(-1, min(1, up.y))) * 180 / .pi
                if tilt > 40 {
                    NSLog("TILT %.0f clip=%@ prev=%@ blend=%.2f node=%@ special=%d", tilt, p.clip, p.prevClip ?? "-", p.blend,
                          p.root.childNodes.first?.name ?? "?", p.special)
                }
            }
            if let h = p.hips, f < c.hips.count {
                var off = simd_mix(c.hips[f], c.hips[min(nf, c.hips.count - 1)], SIMD3<Float>(repeating: fraction))
                if let pc = prev, pf < pc.hips.count {
                    let from = simd_mix(pc.hips[pf], pc.hips[min(npf, pc.hips.count - 1)], SIMD3<Float>(repeating: fraction))
                    off = simd_mix(from, off, SIMD3<Float>(repeating: blend))
                }
                h.simdPosition = p.hipsBind + off
            }
        }
    }

    private func updateHands(_ arms: [[ArmRig]], t: Float, dt: Float, targets: [[SIMD3<Float>]], gestures: [[Gesture]]) {
        for d in 0..<arms.count {
            for k in 0..<arms[d].count {
                let rig = arms[d][k]
                guard d < targets.count, d < gestures.count,
                      k < targets[d].count, k < gestures[d].count else { continue }
                let goal = targets[d][k]
                let g = gestures[d][k]
                rig.tip += (goal - rig.tip) * min(1, dt * 5)
                var tip = rig.tip
                // Lift during a reach, then settle the fingertip on the control.
                tip.y += min(0.045, simd_distance(goal, rig.tip) * 0.22)
                // 手の向き：前へ、やや内側・下向き。手のひらは下
                let inward: Float = -rig.side * 0.25
                var hd = simd_normalize(SIMD3<Float>(inward, -0.45, -1))
                var palm = SIMD3<Float>(0, -1, 0.15)
                var curl: [Float] = [0.5, 0.55, 0.6, 0.65, 0.35]
                switch g {
                case .idle:
                    tip.y += sin(t * 1.3 + Float(d * 2 + k)) * 0.004
                case .jog:
                    tip += SIMD3<Float>(sin(t * 2.6) * 0.012, 0, cos(t * 2.6) * 0.008)
                    curl = [0.25, 0.3, 0.35, 0.4, 0.15]
                case .twist:
                    let a = sin(t * 3.2) * 0.35
                    hd = simd_quatf(angle: a, axis: SIMD3<Float>(0, 1, 0)).act(simd_normalize(SIMD3<Float>(inward, -0.8, -0.6)))
                    palm = SIMD3<Float>(0, -0.4, 0.9)
                    curl = [0.9, 1.25, 1.35, 1.4, 0.8]
                case .tap(let speed):
                    tip.y += max(0, sin(t * 5 * speed)) * 0.012
                    hd = simd_normalize(SIMD3<Float>(inward, -0.75, -0.7))
                    curl = [0.08, 1.3, 1.4, 1.45, 0.9]
                case .hold:
                    hd = simd_normalize(SIMD3<Float>(inward, -0.85, -0.5))
                    curl = [0.95, 1.05, 1.2, 1.3, 0.9]
                }
                for i in 0..<5 { rig.curl[i] += (curl[i] - rig.curl[i]) * min(1, dt * 6) }
                rig.solve(tip: tip, handDir: hd, palm: palm)
            }
        }
    }

    private func updateGear(t: Float, dt: Float, s: BoothState, faderGoal: [Float], xGoal: Float) {
        for d in 0..<platters.count {
            let playing = s.current != nil && s.owner == d && isLive(s.phase)
            if playing { platterAngle[d] -= dt * 3.49 }   // 33⅓ 回転
            platters[d].simdOrientation = platterBind[d] * simd_quatf(angle: platterAngle[d], axis: platterAxis[d])
        }
        for c in 0..<faders.count {
            faderPos[c] += (faderGoal[c] - faderPos[c]) * min(1, dt * 2.5)
            faders[c].simdPosition = faderBase[c] + SIMD3<Float>(0, 0, -0.07 * faderPos[c] + 0.035)
        }
        if let x = xfader {
            xPos += (xGoal - xPos) * min(1, dt * 1.8)
            x.simdPosition = xBase + SIMD3<Float>(0.035 + xPos * 0.035, 0, 0)
        }
        // CUE の点滅
        for d in 0..<cueLEDs.count {
            let on = s.next != nil && s.selector == d && sin(t * 8) > 0
            cueLEDs[d].geometry?.firstMaterial?.emission.contents = on ? UIColor.orange : UIColor.black
            cueLEDs[d].geometry?.firstMaterial?.emission.intensity = on ? 2.5 : 0
        }
    }

    private func updateLights(t: Float, energy: Double) {
        let e = Float(energy / 100)
        ambient.light?.intensity = CGFloat(22 + e * 30)
        for (i, m) in movers.enumerated() {
            let active = Float(i) < e * 5
            let target: CGFloat = active ? CGFloat(260 + e * 580) : 0
            let cur = m.light?.intensity ?? 0
            m.light?.intensity = cur + (target - cur) * 0.1
            let pan = sin(t * (0.5 + Float(i) * 0.07) + Float(i)) * 0.6
            let tilt = -0.75 + sin(t * 0.7 + Float(i) * 1.3) * 0.25
            m.simdOrientation = simd_quatf(angle: pan, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: tilt, axis: SIMD3<Float>(1, 0, 0))
            if let beam = m.childNode(withName: "beam", recursively: false) {
                let goal: CGFloat = active ? CGFloat(0.06 + e * 0.10) : 0
                beam.opacity += (goal - beam.opacity) * 0.1
            }
        }
        let nLasers = energy > 80 ? lasers.count : lasers.count / 2
        for (i, l) in lasers.enumerated() {
            let on = energy > 60 && i < nLasers
            l.opacity += ((on ? 0.9 : 0) - l.opacity) * 0.15
            let sweep = sin(t * 1.4 + Float(i) * 0.6) * 0.5
            let base: Float = i % 2 == 0 ? -0.9 : 0.9
            // 奥から観客の上を通ってこちらへ
            l.simdOrientation = simd_quatf(angle: base * 0.5 + sweep, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: 1.62 + sin(t + Float(i)) * 0.05, axis: SIMD3<Float>(1, 0, 0))
            if energy >= 99.5, let m = l.childNodes.first?.geometry?.firstMaterial {
                let c = UIColor(hue: CGFloat((t * 0.2 + Float(i) * 0.1).truncatingRemainder(dividingBy: 1)), saturation: 1, brightness: 1, alpha: 1)
                m.diffuse.contents = c
                m.emission.contents = c
            }
        }
        let legend = energy >= 99.5
        // A gentle light swell keeps detail visible during the finale.
        if legend { ambient.light?.intensity = CGFloat(52 + 12 * (0.5 + 0.5 * sin(t * 2.4))) }
        confetti?.birthRate = legend ? 150 : 0
        for (k, h) in hazes.enumerated() {
            h.opacity = CGFloat(0.035 + e * 0.075 + sin(t * 0.3 + Float(k)) * 0.015)
            h.position.x = sin(t * 0.07 + Float(k) * 2) * 1.2
        }
        updateVJ(t: t, energy: energy, legend: legend)
    }

    // MARK: VJ

    /// GPU で映像を描く素材。種類・速さ・色は uniform で変える
    private func vjMaterial(aspect: Float, gain: Float = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        let fallback = Self.ledWallImage(top: UIColor(venue.palette.0), accent: UIColor(venue.palette.2))
        // A diffuse texture keeps the screen UV mapping active in SceneKit.
        m.diffuse.contents = fallback
        m.shaderModifiers = [.surface: Self.vjShader]
        m.setValue(NSNumber(value: aspect), forKey: "vjAspect")
        m.setValue(NSNumber(value: gain), forKey: "vjGain")
        m.setValue(NSNumber(value: Float(0)), forKey: "vjTime")
        m.setValue(NSNumber(value: Float(0.5)), forKey: "vjEnergy")
        m.setValue(NSNumber(value: Float(0)), forKey: "vjMode")
        m.setValue(NSNumber(value: Float(0)), forKey: "vjCut")
        m.setValue(NSNumber(value: Float(1)), forKey: "vjOn")
        m.setValue(NSValue(scnVector3: SCNVector3(1, 0.2, 0.6)), forKey: "vjColA")
        m.setValue(NSValue(scnVector3: SCNVector3(0.2, 0.6, 1)), forKey: "vjColB")
        m.setValue(SCNMaterialProperty(contents: fallback), forKey: "vjArt")
        m.setValue(SCNMaterialProperty(contents: UIColor.black), forKey: "vjText")
        vjMaterials.append(m)
        return m
    }

    private static let vjShader = """
    #pragma arguments
    float vjAspect;
    float vjGain;
    float vjTime;
    float vjEnergy;
    float vjMode;
    float vjCut;
    float vjOn;
    float3 vjColA;
    float3 vjColB;
    texture2d<float> vjArt;
    texture2d<float> vjText;
    #pragma body
    constexpr sampler smp(filter::linear, address::repeat);
    float2 uv = _surface.diffuseTexcoord;
    float t = vjTime;
    float e = vjEnergy;
    float2 p = uv * 2.0 - 1.0;
    p.x *= vjAspect;
    float3 col = float3(0.0);
    int mode = int(vjMode + 0.5);
    if (mode == 0) {
        float r = length(p);
        float a = atan2(p.y, p.x);
        float rings = sin(9.0 / (r + 0.18) - t * (1.5 + 4.0 * e));
        float spokes = 0.6 + 0.4 * sin(a * 8.0 + t * 0.7);
        col = mix(vjColA, vjColB, 0.5 + 0.5 * sin(r * 5.0 - t)) * smoothstep(0.1, 0.95, rings * 0.5 + 0.5) * spokes;
        col *= smoothstep(0.0, 0.25, r);
    } else if (mode == 1) {
        float r = length(p);
        float a = atan2(p.y, p.x) + t * 0.15;
        float seg = 6.2831853 / 8.0;
        a = fmod(abs(a), seg);
        a = abs(a - seg * 0.5);
        float2 q = float2(cos(a), sin(a)) * r * (0.55 + 0.15 * sin(t * 0.6)) + 0.5;
        col = vjArt.sample(smp, q).rgb * (0.7 + 0.5 * e);
    } else if (mode == 2) {
        float2 q = float2((uv.x - 0.5) * vjAspect * 0.5 + 0.5, uv.y);
        float row = floor(uv.y * 36.0);
        float glitch = step(0.94, fract(sin(row * 12.9898 + floor(t * 6.0)) * 43758.5453));
        q.x += glitch * 0.06 * sin(t * 40.0);
        float sh = 0.004 + 0.02 * e;
        col = float3(vjArt.sample(smp, q + float2(sh, 0.0)).r, vjArt.sample(smp, q).g, vjArt.sample(smp, q - float2(sh, 0.0)).b);
        col *= 0.8 + 0.2 * sin(uv.y * 700.0);
        float inside = step(0.0, q.x) * step(q.x, 1.0);
        col = mix(vjColA * 0.12, col, inside);
    } else if (mode == 3) {
        float v = sin(p.x * 3.0 + t) + sin(p.y * 4.0 - t * 1.3) + sin((p.x + p.y) * 2.5 + t * 0.7) + sin(length(p) * 5.0 - t * 2.0);
        col = mix(vjColA, vjColB, 0.5 + 0.5 * sin(v * 1.8));
        float2 g = abs(fract(p * 3.0 + float2(0.0, t * 0.4)) - 0.5);
        col += smoothstep(0.46, 0.5, max(g.x, g.y)) * 0.5;
    } else {
        float2 q = float2(fract(uv.x * vjAspect / 4.0 + t * 0.06), uv.y);
        float txt = vjText.sample(smp, q).r;
        float bg = 0.12 + 0.08 * sin(uv.x * 30.0 + t * 2.0);
        col = mix(vjColA * bg, mix(float3(1.0), vjColB, 0.3), txt);
    }
    // LED panel cells and restrained highlights, including track changes.
    float2 cell = abs(fract(uv * float2(144.0 * vjAspect, 144.0)) - 0.5);
    float pixels = 1.0 - smoothstep(0.39, 0.5, max(cell.x, cell.y));
    float detail = 1.0 - saturate(length(fwidth(uv)) * 144.0);
    col *= mix(1.0, 0.78 + 0.22 * pixels, detail);
    col += mix(vjColA, vjColB, 0.5) * vjCut * 0.16;
    // 奥は霧で沈むので画面ごとの明るさ（vjGain）で持ち上げる。1 を超えた分は発光にしてブルームに乗せる
    col *= (0.55 + 0.75 * e) * vjGain * vjOn;
    _surface.diffuse = float4(min(col, float3(1.0)), 1.0);
    _surface.emission = float4(max(col - 1.0, float3(0.0)), 1.0);
    """

    /// 曲が変わったら絵・文字・色を入れ替え、AUTO なら映像の種類も切り替える
    @MainActor
    private func updateVJTrack(_ s: BoothState) {
        vjOn = s.vjMode != .off
        if s.vjMode == .auto {
            vjAutoIndex = (vjAutoIndex + 1 + Int.random(in: 0..<3)) % 5
            vjModeNow = Float(vjAutoIndex)
        } else {
            vjModeNow = s.vjMode.index
        }
        vjCutAt = vjTimeNow
        updateVJArtwork(s)
    }

    @MainActor
    private func updateVJArtwork(_ s: BoothState) {
        guard let t = s.current else { return }
        let art = art(for: t) ?? vinyl(nil)
        let (a, b) = Self.palette(art)
        let text = Self.typoImage("\(t.title.uppercased())  —  \(t.artist.uppercased())  ·  ")
        let mats = vjMaterials
        onRender {
            for m in mats {
                m.setValue(SCNMaterialProperty(contents: art), forKey: "vjArt")
                m.setValue(SCNMaterialProperty(contents: text), forKey: "vjText")
                m.setValue(NSValue(scnVector3: a), forKey: "vjColA")
                m.setValue(NSValue(scnVector3: b), forKey: "vjColB")
            }
        }
    }

    private func updateVJ(t: Float, energy: Double, legend: Bool) {
        vjTimeNow = t
        let cut = max(0, 1 - (t - vjCutAt) * 3)
        let flash: Float = legend ? 0.08 * (0.5 + 0.5 * sin(t * 2.4)) : 0
        for m in vjMaterials {
            m.setValue(NSNumber(value: t), forKey: "vjTime")
            m.setValue(NSNumber(value: Float(energy / 100)), forKey: "vjEnergy")
            m.setValue(NSNumber(value: vjModeNow), forKey: "vjMode")
            m.setValue(NSNumber(value: cut + flash), forKey: "vjCut")
            m.setValue(NSNumber(value: Float(vjOn ? 1 : 0)), forKey: "vjOn")
        }
    }

    /// ジャケットから色を2つ（いちばん鮮やかな色と明るい色）
    private static func palette(_ img: UIImage) -> (SCNVector3, SCNVector3) {
        let n = 8
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = img.cgImage else { return (SCNVector3(1, 0.2, 0.6), SCNVector3(0.2, 0.6, 1)) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var best = (sat: -1.0, c: SCNVector3(1, 0.2, 0.6)), bright = (v: -1.0, c: SCNVector3(0.2, 0.6, 1))
        for i in 0..<(n * n) {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx > 0 ? (mx - mn) / mx * mx : 0
            if sat > best.sat { best = (sat, SCNVector3(Float(r / mx), Float(g / mx), Float(b / mx))) }
            if mx > bright.v && (mx - mn) > 0.15 { bright = (mx, SCNVector3(Float(r), Float(g), Float(b))) }
        }
        return (best.c, bright.c)
    }

    private static func typoImage(_ s: String) -> UIImage {
        let w: CGFloat = 1024, h: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: w, height: h))
            let str = NSAttributedString(string: s + s, attributes: [
                .font: UIFont.systemFont(ofSize: 150, weight: .black), .foregroundColor: UIColor.white])
            str.draw(at: CGPoint(x: 0, y: 40))
        }
    }

    // MARK: テクスチャ

    private func applyPlatter(_ d: Int, _ img: UIImage) {
        guard d < platters.count else { return }
        let m = platters[d].geometry?.firstMaterial
        onRender {
            m?.diffuse.contents = img
            m?.lightingModel = .physicallyBased
            m?.roughness.contents = 0.35
        }
    }

    private func applyScreen(_ d: Int, title: String?, mode: String, color: UIColor) {
        guard d < screens.count else { return }
        let w: CGFloat = 400, h: CGFloat = 230
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { _ in
            UIColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: w, height: h))
            NSAttributedString(string: "DECK \(d == 0 ? "A" : "B")  ·  \(mode)", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 28, weight: .heavy), .foregroundColor: color]).draw(at: CGPoint(x: 18, y: 18))
            NSAttributedString(string: title ?? "—", attributes: [
                .font: UIFont.systemFont(ofSize: 42, weight: .bold), .foregroundColor: UIColor.white])
                .draw(with: CGRect(x: 18, y: 76, width: w - 36, height: 130), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
        let m = screens[d].geometry?.firstMaterial
        onRender {
            m?.emission.contents = img
            m?.emission.intensity = 0.8
        }
    }

    @MainActor
    private func art(for t: Track) -> UIImage? {
        if let img = artCache[t.id] { return img }
        if let url = t.artworkURL {
            if !loading.contains(t.id) {
                loading.insert(t.id)
                Task { @MainActor [weak self] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: data), let self else { return }
                    self.artCache[t.id] = img
                    if let s = self.lastApplied { self.updateDecks(s); self.updateVJArtwork(s) }
                }
            }
            return nil
        }
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

    /// 盤の上面。真ん中にジャケット、まわりは溝
    private func vinyl(_ art: UIImage?) -> UIImage {
        let size: CGFloat = 512
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let cg = ctx.cgContext
            UIColor(white: 0.03, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: size, height: size))
            cg.setLineWidth(1.0)
            var rad: CGFloat = 110
            while rad < size / 2 - 4 {
                UIColor(white: 0.09 + (rad.truncatingRemainder(dividingBy: 12) < 6 ? 0.04 : 0), alpha: 1).setStroke()
                cg.strokeEllipse(in: CGRect(x: size / 2 - rad, y: size / 2 - rad, width: rad * 2, height: rad * 2))
                rad += 5
            }
            let label = CGRect(x: size / 2 - 105, y: size / 2 - 105, width: 210, height: 210)
            cg.saveGState()
            cg.addEllipse(in: label)
            cg.clip()
            if let art { art.draw(in: label) } else { UIColor(white: 0.16, alpha: 1).setFill(); cg.fill(label) }
            cg.restoreGState()
            UIColor.white.withAlphaComponent(0.85).setFill()
            cg.fill(CGRect(x: size / 2 - 3, y: 6, width: 6, height: 60))
        }
    }

    private static func environmentImage(_ v: Venue) -> UIImage {
        // 反射用の簡易パノラマ：暗い部屋に色付きの照明がいくつか
        let w: CGFloat = 1024, h: CGFloat = 512
        let light = UIColor(v.palette.2)
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { ctx in
            let cg = ctx.cgContext
            UIColor(white: 0.02, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let spots: [(CGFloat, CGFloat, CGFloat, UIColor)] = [
                (0.25, 0.25, 70, light), (0.5, 0.18, 90, UIColor(white: 1, alpha: 1)), (0.75, 0.3, 60, .cyan),
                (0.1, 0.4, 40, .magenta), (0.9, 0.42, 40, light)]
            for (x, y, r, c) in spots {
                let g = CGGradient(colorsSpace: nil, colors: [c.withAlphaComponent(0.9).cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
                cg.drawRadialGradient(g, startCenter: CGPoint(x: x * w, y: y * h), startRadius: 0, endCenter: CGPoint(x: x * w, y: y * h), endRadius: r, options: [])
            }
        }
    }

    private static func ledWallImage(top: UIColor, accent: UIColor) -> UIImage {
        let w: CGFloat = 512, h: CGFloat = 192
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { ctx in
            let cg = ctx.cgContext
            let g = CGGradient(colorsSpace: nil, colors: [accent.cgColor, top.cgColor, UIColor.black.cgColor] as CFArray, locations: [0, 0.5, 1])!
            cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
            UIColor.black.withAlphaComponent(0.35).setFill()
            var x: CGFloat = 0
            while x < w { cg.fill(CGRect(x: x, y: 0, width: 1, height: h)); x += 4 }
            var y: CGFloat = 0
            while y < h { cg.fill(CGRect(x: 0, y: y, width: w, height: 1)); y += 4 }
        }
    }

    private static func hazeImage() -> UIImage {
        // ふわっとした雲。ぼかした丸を重ねる
        let w: CGFloat = 256, h: CGFloat = 128
        var seed: UInt64 = 42
        func r() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1; return CGFloat(seed >> 40) / CGFloat(1 << 24) }
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { ctx in
            let cg = ctx.cgContext
            let g = CGGradient(colorsSpace: nil, colors: [UIColor(white: 1, alpha: 0.12).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
            for _ in 0..<60 {
                let cx = r() * w, cy = h * (0.3 + r() * 0.5), rad = 20 + r() * 50
                cg.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: rad, options: [])
            }
        }
    }

    private static func beamImage() -> UIImage {
        // 光の筋：根元が明るく、先と縁が消える
        let w: CGFloat = 64, h: CGFloat = 128
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { ctx in
            let cg = ctx.cgContext
            for yy in 0..<Int(h) {
                let v = 1 - CGFloat(yy) / h
                for xx in stride(from: 0, to: Int(w), by: 2) {
                    let u = abs(CGFloat(xx) / w - 0.5) * 2
                    let a = pow(v, 1.6) * (1 - u * u) * 0.6
                    UIColor(white: 1, alpha: a).setFill()
                    cg.fill(CGRect(x: CGFloat(xx), y: CGFloat(yy), width: 2, height: 1))
                }
            }
        }
    }
}
