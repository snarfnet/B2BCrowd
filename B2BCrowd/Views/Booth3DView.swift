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

    static func == (l: BoothState, r: BoothState) -> Bool {
        l.owner == r.owner && l.currentID == r.currentID && l.nextID == r.nextID && l.nextHidden == r.nextHidden
            && l.phase == r.phase && l.selector == r.selector && l.energy == r.energy && l.venue == r.venue
    }
}

struct Booth3DView: UIViewRepresentable {
    let state: BoothState

    func makeCoordinator() -> ClubScene { ClubScene(venue: state.venue) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        let club = context.coordinator
        v.scene = club.scene
        v.pointOfView = club.cameraNode
        v.delegate = club
        v.backgroundColor = .black
        v.antialiasingMode = .multisampling4X
        v.rendersContinuously = true
        v.isPlaying = true
        v.isUserInteractionEnabled = false
        v.preferredFramesPerSecond = 30
        club.apply(state)
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        context.coordinator.apply(state)
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
    static let all: [String: CrowdClip] = {
        guard let url = Bundle.main.url(forResource: "crowd_clips", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clips = root["clips"] as? [String: [String: Any]] else { return [:] }
        var out: [String: CrowdClip] = [:]
        for (name, c) in clips {
            let frames = c["frames"] as? Int ?? 1
            var bones: [String: [simd_quatf]] = [:]
            for (b, arr) in (c["bones"] as? [String: [Double]]) ?? [:] {
                var qs: [simd_quatf] = []
                qs.reserveCapacity(frames)
                var i = 0
                while i + 3 < arr.count {
                    qs.append(simd_quatf(ix: Float(arr[i]), iy: Float(arr[i + 1]), iz: Float(arr[i + 2]), r: Float(arr[i + 3])))
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
    var bones: [(node: SCNNode, name: String, bind: simd_quatf)] = []
    var hips: SCNNode?
    var hipsBind = SIMD3<Float>(repeating: 0)
    var clip = "idle"
    var prevClip: String?
    var blend: Float = 1
    var phase: Float
    var speed: Float
    let bias: Double
    var phoneLight: SCNNode?
    let special: Int          // 0 普通 / 1 絶対踊らない / 2 辛口評論家 / 3 何でも盛り上がる / 4 ダンスキング / 5 伝説
    let phoneUser: Bool

    init(root: SCNNode, phase: Float, speed: Float, bias: Double, special: Int, phoneUser: Bool) {
        self.root = root
        self.phase = phase
        self.speed = speed
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
    var fingers: [(node: SCNNode, bind: simd_quatf, axis: SIMD3<Float>, sign: Float, finger: Int)] = []
    var tip = SIMD3<Float>(0, 0, 0)
    var curl: [Float] = [0.5, 0.5, 0.5, 0.5, 0.3]   // 人差し指・中指・薬指・小指・親指
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
                fingers.append((node, node.simdOrientation, axisLocal, sign, fi))
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
        let wrist = tip - hd * 0.15 - pn * 0.02
        let shoulder = arm.simdWorldPosition

        // 2本の骨の IK（肘は外側やや下・後ろへ）
        var d = wrist - shoulder
        var dist = max(0.05, simd_length(d))
        let maxReach = l1 + l2 - 0.002
        if dist > maxReach { d = d / dist * maxReach; dist = maxReach }
        let dir = d / dist
        let a = (l1 * l1 - l2 * l2 + dist * dist) / (2 * dist)
        let h = sqrt(max(0, l1 * l1 - a * a))
        var pole = SIMD3<Float>(side * 0.7, -0.6, 0.4)
        pole = simd_normalize(pole - dir * simd_dot(pole, dir))
        let elbow = shoulder + dir * a + pole * h
        let w = shoulder + d

        // 3本の骨を「骨の向き＋手のひらの向き」でそろえる
        func frame(_ y: SIMD3<Float>, _ ref: SIMD3<Float>) -> simd_float3x3 {
            var r = ref - y * simd_dot(ref, y)
            if simd_length(r) < 1e-4 { r = simd_cross(y, SIMD3<Float>(1, 0, 0)) }
            r = simd_normalize(r)
            return simd_float3x3(columns: (y, r, simd_normalize(simd_cross(y, r))))
        }
        func aim(_ q0: simd_quatf, _ y0: SIMD3<Float>, _ y1: SIMD3<Float>) -> simd_quatf {
            simd_quatf(frame(y1, pn) * frame(y0, palm0).transpose) * q0
        }
        orient(arm, aim(qArm0, armDir0, simd_normalize(elbow - shoulder)))
        orient(fore, aim(qFore0, foreDir0, simd_normalize(w - elbow)))
        orient(hand, aim(qHand0, handDir0, hd))

        for f in fingers {
            let c = curl[f.finger] * (f.finger == 4 ? 0.9 : 1.15)
            f.node.simdOrientation = f.bind * simd_quatf(angle: c * f.sign, axis: f.axis)
        }
    }
}

// MARK: - シーン

final class ClubScene: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    enum Gesture: Equatable { case idle, jog, twist, tap(Float), hold }

    let scene = SCNScene()
    let cameraNode = SCNNode()

    private let lock = NSLock()
    private var st = BoothState(owner: 0, currentID: nil, nextID: nil, nextHidden: false, phase: .searchingTrack,
                                selector: 0, energy: 50, venue: .smallClub, current: nil, next: nil)
    private let venue: Venue

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
    private var gestures: [[Gesture]] = [[.idle, .idle], [.idle, .idle]]
    private var targets: [[SIMD3<Float>]] = [[SIMD3(-0.59, 0, 0.3), SIMD3(-0.33, 0, 0.3)], [SIMD3(0.59, 0, 0.3), SIMD3(0.33, 0, 0.3)]]
    private var faderGoal: [Float] = [1, 0]
    private var xGoal: Float = -1

    private var movers: [SCNNode] = []
    private var lasers: [SCNNode] = []
    private let ambient = SCNNode()
    private let strobe = SCNNode()
    private var confetti: SCNParticleSystem?
    private var ledWall: SCNNode?
    private var hazes: [SCNNode] = []

    private var lastTime: TimeInterval = 0
    private var ready = false   // 機材と人物の読み込みが終わったら true
    private var camBase = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var smoke: SCNParticleSystem?
    private var artCache: [String: UIImage] = [:]
    private var loading: Set<String> = []
    private var lastApplied: BoothState?

    init(venue: Venue) {
        self.venue = venue
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
        cam.bloomIntensity = 0.8
        cam.bloomThreshold = 0.92
        cam.bloomBlurRadius = 10
        cam.vignettingIntensity = 0.5
        cam.vignettingPower = 1.2
        cam.screenSpaceAmbientOcclusionIntensity = 0.7
        cam.exposureOffset = -0.1
        cam.saturation = 1.08
        cam.wantsDepthOfField = true
        cam.focusDistance = 2.6
        cam.fStop = 4.5
        cam.apertureBladeCount = 6
        cam.motionBlurIntensity = 0.25
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, 1.3, 1.45)
        cameraNode.look(at: SCNVector3(0, -0.3, -1.9))
        camBase = cameraNode.simdOrientation
        if ProcessInfo.processInfo.arguments.contains("-boothcam") {   // 手元の確認用
            cameraNode.position = SCNVector3(0.1, 0.95, 1.1)
            cameraNode.look(at: SCNVector3(0, 0, -0.1))
        }
        camBase = cameraNode.simdOrientation
        scene.rootNode.addChildNode(cameraNode)

        scene.lightingEnvironment.contents = Self.environmentImage(venue)
        scene.lightingEnvironment.intensity = 0.9
        scene.background.contents = UIColor.black
        scene.fogColor = UIColor(venue.palette.1)
        scene.fogStartDistance = 5
        scene.fogEndDistance = 22
        scene.fogDensityExponent = 1.4

        buildVenue()
        buildLights()
        // 機材と人物は重いので裏で読み込み、できたらまとめて足す（画面が固まらないように）
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            buildGear()
            let root = SCNNode()
            let crowd = buildCrowd(into: root)
            let (djs, rigs) = buildArms(into: root)
            DispatchQueue.main.async { [self] in
                scene.rootNode.addChildNode(gear)
                scene.rootNode.addChildNode(root)
                lock.lock()
                people = crowd + djs
                arms = rigs
                ready = true
                lock.unlock()
                if let s = lastApplied {
                    lastApplied = nil
                    apply(s)
                }
            }
        }
    }

    static let nearNames = ["c01", "c02", "c03", "c05", "c06", "c09", "c12", "c16"]

    /// アプリ起動時に人物を先に読んでおく（起動の邪魔をしないよう少し待ってから）
    static func preload() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            for n in nearNames { _ = template(n, lod: false) }
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
        pbr(fm, rough: 0.32, metal: 0.1)
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
        let lm = SCNMaterial()
        lm.lightingModel = .constant
        lm.diffuse.contents = Self.ledWallImage(top: UIColor(top), accent: UIColor(light))
        lm.diffuse.intensity = 0.6
        led.geometry?.materials = [lm]
        scene.rootNode.addChildNode(led)
        ledWall = led
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
                let cone = SCNNode(geometry: SCNCylinder(radius: 0.3, height: 0.02))
                cone.geometry?.materials = [coneM]
                cone.eulerAngles.x = .pi / 2
                cone.position = SCNVector3(0, 0, 0.41)
                b.addChildNode(cone)
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
                if n.contains("print") { self.pbr(m, rough: n.contains("booth") ? 0.35 : 0.6, metal: 0.15) }
                else if n.contains("lamp_bulb") {
                    m.lightingModel = .constant
                    m.emission.contents = UIColor(red: 1, green: 0.9, blue: 0.75, alpha: 1)
                    m.emission.intensity = 3
                }
                else if n.contains("cup") { self.pbr(m, rough: 0.25) }
                else if n.contains("drink") { self.pbr(m, rough: 0.05) }
                else if n.contains("cable") || n.contains("hp_pad") { self.pbr(m, rough: 0.6) }
                else if n.contains("gunmetal") { self.pbr(m, rough: 0.38, metal: 0.85) }
                else if n.contains("alu") { self.pbr(m, rough: 0.25, metal: 1) }
                else if n.contains("chrome") { self.pbr(m, rough: 0.1, metal: 1) }
                else if n.contains("rubber") || n.contains("pad") { self.pbr(m, rough: 0.85) }
                else if n.contains("glass") { self.pbr(m, rough: 0.05) }
                else if n.contains("booth_top") { self.pbr(m, rough: 0.3, metal: 0.05) }
                else { self.pbr(m, rough: 0.5, metal: 0.1) }
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
            l.light?.intensity = 260
            l.light?.color = UIColor(red: 1, green: 0.88, blue: 0.7, alpha: 1)
            l.light?.spotInnerAngle = 25
            l.light?.spotOuterAngle = 75
            l.light?.attenuationEndDistance = 1.2
            l.simdPosition = head.simdWorldPosition
            gear.addChildNode(l)
            l.look(at: SCNVector3(0, 0.06, -0.02))
        }
        if let led = find("booth_led") {
            boothLED = uniq(led)
            boothLED?.geometry?.firstMaterial?.emission.contents = UIColor(venue.palette.2)
            boothLED?.geometry?.firstMaterial?.emission.intensity = 4
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
            for m in g.materials {
                pbrS(m, rough: lname.contains("generic") ? 0.55 : 0.75)
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
        var seed: UInt64 = 0x9E3779B97F4A7C15 &+ UInt64(abs(venue.rawValue.hashValue) % 1000)
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
            let sc = 0.95 + rnd() * 0.1
            node.scale = SCNVector3(sc, sc, sc)
            parent.addChildNode(node)

            let special: Int = i < 6 ? [1, 2, 3, 4, 5, 0][i] : 0
            let p = Person(root: node, phase: rnd() * 100, speed: 0.92 + rnd() * 0.16, bias: Double(rnd() * 24 - 12),
                           special: special, phoneUser: rnd() < 0.45)
            for b in boneNames {
                let key = "mixamorig:\(b)"
                guard let bn = node.childNode(withName: key, recursively: true)
                        ?? node.childNode(withName: "rig_mixamorig_\(b)", recursively: true) else { continue }
                p.bones.append((bn, key, bn.simdOrientation))
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
        let setups: [(String, Float)] = [("c09", -0.42), ("c02", 0.42)]
        let boneNames = ["Hips", "Spine", "Spine1", "Spine2", "Neck", "Head", "LeftShoulder", "RightShoulder",
                         "LeftUpLeg", "LeftLeg", "LeftFoot", "RightUpLeg", "RightLeg", "RightFoot"]
        for (k, (name, cx)) in setups.enumerated() {
            guard let t = loadCharacter(name) else { arms.append([]); continue }
            let dj = cloneSkinned(t, tint: k == 0 ? UIColor(white: 0.18, alpha: 1) : UIColor(red: 0.2, green: 0.22, blue: 0.3, alpha: 1))
            dj.position = SCNVector3(cx, -1.02, 0.5)
            dj.eulerAngles.y = .pi
            parent.addChildNode(dj)
            // 体は観客と同じ仕組みで小さく揺らす（腕は後で IK が上書き）
            let p = Person(root: dj, phase: Float(k) * 0.37, speed: 1, bias: 0, special: 6, phoneUser: false)
            for b in boneNames {
                let key = "mixamorig:\(b)"
                guard let bn = dj.childNode(withName: key, recursively: true)
                        ?? dj.childNode(withName: "rig_mixamorig_\(b)", recursively: true) else { continue }
                p.bones.append((bn, key, bn.simdOrientation))
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
        key.light?.intensity = 300
        key.light?.color = UIColor(red: 1, green: 0.92, blue: 0.82, alpha: 1)
        key.light?.spotInnerAngle = 30
        key.light?.spotOuterAngle = 70
        key.light?.castsShadow = true
        key.light?.shadowMode = .deferred
        key.light?.shadowRadius = 4
        key.light?.shadowSampleCount = 8
        key.light?.shadowColor = UIColor(white: 0, alpha: 0.7)
        key.position = SCNVector3(0.2, 1.6, -0.2)
        key.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(key)

        // 観客の後ろからの逆光
        let back = SCNNode()
        back.light = SCNLight()
        back.light?.type = .omni
        back.light?.intensity = 900
        back.light?.color = light
        back.light?.attenuationStartDistance = 2
        back.light?.attenuationEndDistance = 16
        back.position = SCNVector3(0, 3, -11)
        scene.rootNode.addChildNode(back)

        // ムービングライト（光の筋つき）
        let beamImg = Self.beamImage()
        for i in 0..<6 {
            let n = SCNNode()
            let color = UIColor(hue: CGFloat(i) / 6, saturation: 0.8, brightness: 1, alpha: 1)
            n.light = SCNLight()
            n.light?.type = .spot
            n.light?.intensity = 0
            n.light?.spotInnerAngle = 6
            n.light?.spotOuterAngle = 22
            n.light?.attenuationEndDistance = 14
            n.light?.color = color
            n.position = SCNVector3(-5 + Float(i) * 2, 3.25, i % 2 == 0 ? -3 : -7.5)
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

        strobe.light = SCNLight()
        strobe.light?.type = .omni
        strobe.light?.intensity = 0
        strobe.light?.color = UIColor.white
        strobe.position = SCNVector3(0, 3, -4)
        scene.rootNode.addChildNode(strobe)

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
        if prev?.energy != s.energy { updateMeters(s.energy) }
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
                playLEDs[d].geometry?.firstMaterial?.emission.contents = playingHere ? UIColor.green : UIColor.black
                playLEDs[d].geometry?.firstMaterial?.emission.intensity = playingHere ? 2 : 0
            }
        }
    }

    @MainActor
    private func updateMeters(_ e: Int) {
        let lit = Int((Double(e) / 100 * 12).rounded())
        for c in 0..<meters.count {
            for (i, led) in meters[c].enumerated() {
                let color: UIColor = i < 7 ? .green : i < 10 ? .yellow : .red
                let m = led.geometry?.firstMaterial
                m?.emission.contents = i < lit ? color : UIColor.black
                m?.emission.intensity = i < lit ? 2.5 : 0
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
        lock.unlock()
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
        let legend = energy >= 99.5
        for p in people {
            if p.special == 5 { p.root.isHidden = energy < 81 }
            p.phoneLight?.isHidden = energy < 95
            let want = clipFor(p, energy: energy)
            if want != p.clip {
                p.prevClip = p.clip
                p.clip = want
                p.blend = 0
            }
            p.blend = min(1, p.blend + dt * 2.5)
            guard let c = clips[p.clip] else { continue }
            let ft = (t * (legend ? 1 : p.speed) + (legend ? 0 : p.phase)) * CrowdClips.fps
            let f = Int(ft) % max(1, c.frames)
            let prev = p.blend < 1 ? p.prevClip.flatMap { clips[$0] } : nil
            let pf = prev.map { Int(ft) % max(1, $0.frames) } ?? 0
            for b in p.bones {
                guard let qs = c.bones[b.name], f < qs.count else { continue }
                var q = b.bind * qs[f]
                if let pc = prev, let pqs = pc.bones[b.name], pf < pqs.count {
                    q = simd_slerp(b.bind * pqs[pf], q, p.blend)
                }
                b.node.simdOrientation = q
            }
            if let h = p.hips, f < c.hips.count {
                var off = c.hips[f]
                if let pc = prev, pf < pc.hips.count { off = simd_mix(pc.hips[pf], off, SIMD3<Float>(repeating: p.blend)) }
                h.simdPosition = p.hipsBind + off
            }
        }
    }

    private func updateHands(_ arms: [[ArmRig]], t: Float, dt: Float, targets: [[SIMD3<Float>]], gestures: [[Gesture]]) {
        for d in 0..<arms.count {
            for k in 0..<arms[d].count {
                let rig = arms[d][k]
                let goal = targets[d][k]
                let g = gestures[d][k]
                rig.tip += (goal - rig.tip) * min(1, dt * 5)
                var tip = rig.tip
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
                    tip.y += max(0, sin(t * 7 * speed)) * 0.022
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
        ambient.light?.intensity = CGFloat(40 + e * 90)
        for (i, m) in movers.enumerated() {
            let active = Float(i) < e * 7
            let target: CGFloat = active ? CGFloat(1500 + e * 2500) : 0
            let cur = m.light?.intensity ?? 0
            m.light?.intensity = cur + (target - cur) * 0.1
            let pan = sin(t * (0.5 + Float(i) * 0.07) + Float(i)) * 0.6
            let tilt = -0.75 + sin(t * 0.7 + Float(i) * 1.3) * 0.25
            m.simdOrientation = simd_quatf(angle: pan, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: tilt, axis: SIMD3<Float>(1, 0, 0))
            if let beam = m.childNode(withName: "beam", recursively: false) {
                let goal: CGFloat = active ? CGFloat(0.22 + e * 0.25) : 0
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
        strobe.light?.intensity = legend && sin(t * 24) > 0.85 ? 4000 : 0
        confetti?.birthRate = legend ? 220 : 0
        for (k, h) in hazes.enumerated() {
            h.opacity = CGFloat(0.08 + e * 0.18 + sin(t * 0.3 + Float(k)) * 0.03)
            h.position.x = sin(t * 0.07 + Float(k) * 2) * 1.2
        }
        ledWall?.geometry?.firstMaterial?.diffuse.intensity = CGFloat(0.35 + e * 0.9 + (legend ? sin(t * 10) * 0.3 : 0))
    }

    // MARK: テクスチャ

    private func applyPlatter(_ d: Int, _ img: UIImage) {
        guard d < platters.count else { return }
        let m = platters[d].geometry?.firstMaterial
        m?.diffuse.contents = img
        m?.lightingModel = .physicallyBased
        m?.roughness.contents = 0.35
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
        m?.emission.contents = img
        m?.emission.intensity = 1.2
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
                    if let s = self.lastApplied { self.updateDecks(s) }
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
