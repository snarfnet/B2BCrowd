import SwiftUI

// 観客。ENERGY に応じてルールで動く（生成 AI は使わない）。
struct Clubber {
    enum Kind: Int, CaseIterable { case clubber, student, office, dancer, cyber, techno, rock, tourist, oldMan, critic }
    enum Special { case none, legend, neverDancer, hype, harshCritic, danceKing }

    var x: CGFloat
    var row: Int
    var kind: Kind
    var special: Special = .none
    var hue: Double
    var bias: Double
    var phase: Double
    var sits: Bool
    var phone: Bool

    static func crowd(for venue: Venue) -> [Clubber] {
        var seed = UInt64(abs(venue.rawValue.hashValue) % 100_000) + 7
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(UInt64(1) << 31)
        }
        var out: [Clubber] = []
        let n = venue.crowdSize
        for i in 0..<n {
            let row = i % 4
            let kind = Kind(rawValue: Int(rnd() * Double(Kind.allCases.count))) ?? .clubber
            out.append(Clubber(
                x: CGFloat(0.04 + rnd() * 0.92), row: row, kind: kind,
                hue: rnd(), bias: rnd() * 24 - 12, phase: rnd() * 6.28,
                sits: rnd() < 0.25, phone: rnd() < 0.45))
        }
        // 特殊観客
        let specials: [Special] = [.legend, .neverDancer, .hype, .harshCritic, .danceKing]
        for (k, s) in specials.enumerated() where k < out.count {
            let idx = (k * 7 + 3) % out.count
            out[idx].special = s
            if s == .harshCritic { out[idx].kind = .critic }
            if s == .neverDancer { out[idx].kind = .office }
            if s == .legend { out[idx].row = 0 }
            if s == .danceKing || s == .hype { out[idx].row = 3 }
        }
        return out.sorted { $0.row < $1.row }
    }
}

struct CrowdView: View {
    let energy: Double
    let venue: Venue
    let reactions: [FloatEvent]
    let active: Bool

    @State private var crowd: [Clubber] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                drawBackground(&g, size, t)
                drawLights(&g, size, t)
                for c in crowd { drawClubber(&g, size, c, t) }
                drawEffects(&g, size, t)
                drawReactions(&g, size, ctx.date)
                drawBooth(&g, size, t)
            }
        }
        .onAppear { crowd = Clubber.crowd(for: venue) }
        .onChange(of: venue) { _, v in crowd = Clubber.crowd(for: v) }
    }

    private var tier: EnergyTier { EnergyTier(energy) }

    // MARK: 背景

    private func drawBackground(_ g: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        let (top, bottom, light) = venue.palette
        let rect = CGRect(origin: .zero, size: s)
        g.fill(Path(rect), with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: .zero, endPoint: CGPoint(x: 0, y: s.height)))

        switch venue {
        case .spaceClub, .rooftop, .beach:
            for i in 0..<40 {
                let x = CGFloat((i * 73) % 100) / 100 * s.width
                let y = CGFloat((i * 37) % 45) / 100 * s.height
                let tw = 0.4 + 0.6 * abs(sin(t * 1.3 + Double(i)))
                g.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.white.opacity(tw * 0.8)))
            }
        default: break
        }
        if venue == .tokyoNight || venue == .rooftop {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: s.height * 0.42))
            var x: CGFloat = 0
            var i = 0
            while x < s.width {
                let w = CGFloat(18 + (i * 13) % 30)
                let h = CGFloat(20 + (i * 29) % 60)
                p.addLine(to: CGPoint(x: x, y: s.height * 0.42 - h))
                p.addLine(to: CGPoint(x: x + w, y: s.height * 0.42 - h))
                x += w
                i += 1
            }
            p.addLine(to: CGPoint(x: s.width, y: s.height * 0.42))
            p.closeSubpath()
            g.fill(p, with: .color(.black.opacity(0.7)))
            for k in 0..<30 {
                let wx = CGFloat((k * 53) % 100) / 100 * s.width
                let wy = s.height * (0.30 + CGFloat((k * 17) % 10) / 100)
                g.fill(Path(CGRect(x: wx, y: wy, width: 2, height: 3)), with: .color(light.opacity(0.5)))
            }
        }
        if venue == .beach {
            g.fill(Path(ellipseIn: CGRect(x: s.width * 0.62, y: s.height * 0.12, width: s.width * 0.22, height: s.width * 0.22)),
                   with: .color(.orange.opacity(0.55)))
        }
        if venue == .megaFestival {
            var truss = Path()
            truss.addRect(CGRect(x: s.width * 0.05, y: s.height * 0.08, width: s.width * 0.9, height: 4))
            truss.addRect(CGRect(x: s.width * 0.05, y: s.height * 0.08, width: 4, height: s.height * 0.4))
            truss.addRect(CGRect(x: s.width * 0.95 - 4, y: s.height * 0.08, width: 4, height: s.height * 0.4))
            g.fill(truss, with: .color(.gray.opacity(0.5)))
        }
        // 床
        g.fill(Path(CGRect(x: 0, y: s.height * 0.42, width: s.width, height: s.height * 0.58)),
               with: .linearGradient(Gradient(colors: [light.opacity(0.08 + energy / 900), .black.opacity(0.6)]),
                                     startPoint: CGPoint(x: 0, y: s.height * 0.42), endPoint: CGPoint(x: 0, y: s.height)))
    }

    // MARK: 照明・レーザー（装飾。音の解析結果ではない）

    private func drawLights(_ g: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        let light = venue.palette.2
        if energy > 40 {
            let cones = energy > 60 ? 4 : 2
            for i in 0..<cones {
                let ox = s.width * (CGFloat(i) + 0.5) / CGFloat(cones)
                let swing = sin(t * (0.6 + Double(i) * 0.15) + Double(i)) * 0.35
                let tx = ox + CGFloat(swing) * s.width
                var p = Path()
                p.move(to: CGPoint(x: ox, y: 0))
                p.addLine(to: CGPoint(x: tx - s.width * 0.12, y: s.height * 0.95))
                p.addLine(to: CGPoint(x: tx + s.width * 0.12, y: s.height * 0.95))
                p.closeSubpath()
                let hue = Color(hue: (Double(i) * 0.23 + t * 0.03).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 1)
                g.fill(p, with: .linearGradient(Gradient(colors: [(i % 2 == 0 ? light : hue).opacity(0.28), .clear]),
                                                startPoint: CGPoint(x: ox, y: 0), endPoint: CGPoint(x: tx, y: s.height)))
            }
        }
        if energy > 60 {
            let n = energy > 80 ? 12 : 6
            let origin = CGPoint(x: s.width * 0.5, y: s.height * 0.05)
            for i in 0..<n {
                let a = Double.pi * (0.15 + 0.7 * Double(i) / Double(n - 1)) + sin(t * 1.7 + Double(i) * 0.4) * 0.12
                let end = CGPoint(x: origin.x + CGFloat(cos(a)) * s.width * 1.2, y: origin.y + CGFloat(sin(a)) * s.height * 1.2)
                var p = Path()
                p.move(to: origin)
                p.addLine(to: end)
                let c: Color = energy >= 99.5 ? Color(hue: Double(i) / Double(n), saturation: 1, brightness: 1) : .green
                g.stroke(p, with: .color(c.opacity(0.18)), lineWidth: 6)
                g.stroke(p, with: .color(c.opacity(0.85)), lineWidth: 1.2)
            }
        }
    }

    // MARK: 観客

    private func personalTier(_ c: Clubber) -> Int {
        let base = EnergyTier(min(99, energy + c.bias)).rawValue
        let legend = energy >= 99.5
        switch c.special {
        case .neverDancer: return legend ? 5 : 0
        case .harshCritic: return legend ? 5 : (energy >= 90 ? 2 : 0)
        case .hype: return legend ? 5 : max(3, base)
        case .danceKing: return legend ? 5 : max(2, base)
        case .legend: return legend ? 5 : 4
        case .none: return legend ? 5 : base
        }
    }

    private func drawClubber(_ g: inout GraphicsContext, _ s: CGSize, _ c: Clubber, _ t: Double) {
        if c.special == .legend, energy < 81 { return }   // 伝説のクラバーは INSANE から現れる

        let rows: [CGFloat] = [0.52, 0.64, 0.77, 0.92]
        let scales: [CGFloat] = [0.55, 0.68, 0.83, 1.0]
        let sc = scales[c.row] * min(1.4, s.height / 260)
        let tierN = personalTier(c)

        var jump: CGFloat = 0
        var sway: CGFloat = 0
        var armL = 0.25, armR = 0.25
        var crossed = false
        var sitting = false
        var phoneGlow = false
        var phoneUp = false
        var clap = false

        switch tierN {
        case 0, 1:
            if tierN == 0 || c.special == .neverDancer || c.special == .harshCritic {
                crossed = c.kind == .critic || c.special != .none || !c.phone
                sitting = c.sits && c.special == .none
                phoneGlow = c.phone && !crossed
                if phoneGlow { armR = 2.2 }
            }
            if tierN == 1 {
                sway = CGFloat(sin(t * 2 + c.phase)) * 3 * sc
                crossed = false
                sitting = false
                phoneGlow = false
                armL = 0.35; armR = 0.35
            }
        case 2:
            jump = CGFloat(abs(sin(t * 4.2 + c.phase))) * 4 * sc
            sway = CGFloat(sin(t * 2.1 + c.phase)) * 4 * sc
            if c.kind.rawValue % 2 == 0 {
                clap = sin(t * 8.4 + c.phase) > 0
                armL = clap ? 1.3 : 0.9; armR = armL
            } else {
                armL = 1.2 + sin(t * 4.2 + c.phase) * 0.6
                armR = 1.2 - sin(t * 4.2 + c.phase) * 0.6
            }
        case 3, 4:
            jump = CGFloat(abs(sin(t * 5 + c.phase))) * (tierN == 4 ? 12 : 8) * sc
            armL = 2.6 + sin(t * 5 + c.phase) * 0.2
            armR = 2.6 - sin(t * 5 + c.phase) * 0.2
        default:
            jump = CGFloat(abs(sin(t * 5.2))) * 15 * sc       // 全員そろってジャンプ
            armL = 2.75; armR = 2.75
            phoneUp = c.phone
        }
        if c.special == .danceKing, tierN >= 2 {
            sway = CGFloat(sin(t * 3 + c.phase)) * 10 * sc
            armL = 1.6 + sin(t * 6) * 1.2
            armR = 1.6 - sin(t * 6) * 1.2
        }

        let cx = c.x * s.width + sway
        let base = rows[c.row] * s.height - jump
        let lit = 0.18 + 0.12 * Double(c.row) + energy / 400
        var body = Color(hue: c.hue, saturation: 0.55, brightness: lit)
        var head = Color(hue: 0.07, saturation: 0.35, brightness: lit + 0.08)
        switch c.kind {
        case .office: body = Color(white: lit * 0.6)
        case .techno: body = Color(white: 0.08)
        case .cyber: body = Color(hue: 0.52, saturation: 0.8, brightness: lit)
        case .oldMan: head = Color(white: lit + 0.25)
        default: break
        }

        let hip = CGPoint(x: cx, y: base - (sitting ? 10 : 18) * sc)
        let shoulderY = hip.y - 21 * sc
        let headC = CGPoint(x: cx, y: shoulderY - 8 * sc)

        // 足
        var legs = Path()
        if sitting {
            legs.move(to: hip); legs.addLine(to: CGPoint(x: cx - 9 * sc, y: hip.y + 2 * sc)); legs.addLine(to: CGPoint(x: cx - 9 * sc, y: base))
            legs.move(to: hip); legs.addLine(to: CGPoint(x: cx + 9 * sc, y: hip.y + 2 * sc)); legs.addLine(to: CGPoint(x: cx + 9 * sc, y: base))
        } else {
            legs.move(to: hip); legs.addLine(to: CGPoint(x: cx - 5 * sc, y: base))
            legs.move(to: hip); legs.addLine(to: CGPoint(x: cx + 5 * sc, y: base))
        }
        g.stroke(legs, with: .color(body.opacity(0.9)), style: StrokeStyle(lineWidth: 4 * sc, lineCap: .round))

        // 胴
        let torso = Path(roundedRect: CGRect(x: cx - 7 * sc, y: shoulderY, width: 14 * sc, height: hip.y - shoulderY + 2 * sc), cornerRadius: 5 * sc)
        g.fill(torso, with: .color(body))
        if c.kind == .office {
            var tie = Path(); tie.move(to: CGPoint(x: cx, y: shoulderY + 1 * sc)); tie.addLine(to: CGPoint(x: cx, y: shoulderY + 10 * sc))
            g.stroke(tie, with: .color(.red.opacity(0.8)), lineWidth: 2 * sc)
        }

        // 腕（角度は真下=0、真上=π）
        let armLen = 15 * sc
        func arm(_ dir: CGFloat, _ a: Double) -> (Path, CGPoint) {
            let sh = CGPoint(x: cx + dir * 6 * sc, y: shoulderY + 2 * sc)
            let end = CGPoint(x: sh.x + dir * CGFloat(sin(a)) * armLen, y: sh.y + CGFloat(cos(a)) * armLen)
            var p = Path(); p.move(to: sh); p.addLine(to: end)
            return (p, end)
        }
        if crossed {
            var p = Path()
            p.move(to: CGPoint(x: cx - 8 * sc, y: shoulderY + 7 * sc))
            p.addLine(to: CGPoint(x: cx + 8 * sc, y: shoulderY + 7 * sc))
            g.stroke(p, with: .color(body.opacity(0.8)), style: StrokeStyle(lineWidth: 4 * sc, lineCap: .round))
        } else {
            let left = arm(-1, clap ? 1.3 : armL)
            let right = arm(1, clap ? 1.3 : armR)
            var both = left.0; both.addPath(right.0)
            g.stroke(both, with: .color(body.opacity(0.9)), style: StrokeStyle(lineWidth: 3.5 * sc, lineCap: .round))
            if phoneUp {
                for e in [left.1, right.1].prefix(c.kind.rawValue % 2 == 0 ? 1 : 2) {
                    g.fill(Path(ellipseIn: CGRect(x: e.x - 3 * sc, y: e.y - 3 * sc, width: 6 * sc, height: 6 * sc)), with: .color(.white))
                    g.fill(Path(ellipseIn: CGRect(x: e.x - 9 * sc, y: e.y - 9 * sc, width: 18 * sc, height: 18 * sc)), with: .color(.white.opacity(0.18)))
                }
            }
        }

        // 頭
        g.fill(Path(ellipseIn: CGRect(x: headC.x - 7 * sc, y: headC.y - 7 * sc, width: 14 * sc, height: 14 * sc)), with: .color(head))
        if phoneGlow {
            g.fill(Path(CGRect(x: cx + 3 * sc, y: headC.y + 2 * sc, width: 5 * sc, height: 7 * sc)), with: .color(.cyan.opacity(0.8)))
            g.fill(Path(ellipseIn: CGRect(x: headC.x - 9 * sc, y: headC.y - 6 * sc, width: 18 * sc, height: 18 * sc)), with: .color(.cyan.opacity(0.12)))
        }
        accessory(&g, c, headC, sc, t)

        if c.special == .legend {
            g.stroke(Path(ellipseIn: CGRect(x: headC.x - 10 * sc, y: headC.y - 10 * sc, width: 20 * sc, height: 20 * sc)),
                     with: .color(.yellow.opacity(0.6 + 0.4 * sin(t * 4))), lineWidth: 2)
        }
    }

    private func accessory(_ g: inout GraphicsContext, _ c: Clubber, _ h: CGPoint, _ sc: CGFloat, _ t: Double) {
        switch c.kind {
        case .cyber:
            g.fill(Path(CGRect(x: h.x - 7 * sc, y: h.y - 2 * sc, width: 14 * sc, height: 3 * sc)),
                   with: .color(.cyan.opacity(0.7 + 0.3 * sin(t * 6 + c.phase))))
        case .rock:
            var p = Path()
            for k in 0..<3 {
                let x = h.x - 3 * sc + CGFloat(k) * 3 * sc
                p.move(to: CGPoint(x: x - 1.5 * sc, y: h.y - 6 * sc)); p.addLine(to: CGPoint(x: x, y: h.y - 12 * sc)); p.addLine(to: CGPoint(x: x + 1.5 * sc, y: h.y - 6 * sc))
            }
            g.fill(p, with: .color(.pink))
        case .tourist:
            g.fill(Path(CGRect(x: h.x - 10 * sc, y: h.y - 6 * sc, width: 20 * sc, height: 2 * sc)), with: .color(.yellow.opacity(0.8)))
            g.fill(Path(CGRect(x: h.x - 5 * sc, y: h.y - 10 * sc, width: 10 * sc, height: 4 * sc)), with: .color(.yellow.opacity(0.8)))
        case .student:
            g.fill(Path(CGRect(x: h.x - 7 * sc, y: h.y - 8 * sc, width: 14 * sc, height: 4 * sc)), with: .color(.blue.opacity(0.8)))
        case .techno:
            g.fill(Path(CGRect(x: h.x - 8 * sc, y: h.y - 7 * sc, width: 16 * sc, height: 4 * sc)), with: .color(Color(white: 0.15)))
        case .critic:
            g.stroke(Path(CGRect(x: h.x - 6 * sc, y: h.y - 1 * sc, width: 12 * sc, height: 3 * sc)), with: .color(.white.opacity(0.8)), lineWidth: 1)
            g.fill(Path(ellipseIn: CGRect(x: h.x - 7 * sc, y: h.y - 10 * sc, width: 12 * sc, height: 5 * sc)), with: .color(.red.opacity(0.7)))
        case .oldMan:
            g.fill(Path(ellipseIn: CGRect(x: h.x - 4 * sc, y: h.y + 3 * sc, width: 8 * sc, height: 6 * sc)), with: .color(.white.opacity(0.8)))
        case .dancer:
            g.fill(Path(ellipseIn: CGRect(x: h.x - 8 * sc, y: h.y - 9 * sc, width: 16 * sc, height: 8 * sc)), with: .color(Color(hue: c.hue, saturation: 1, brightness: 1)))
        default: break
        }
    }

    // MARK: 紙吹雪・ストロボ

    private func drawEffects(_ g: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        guard energy >= 99.5 else { return }
        if sin(t * 22) > 0.85 {
            g.fill(Path(CGRect(origin: .zero, size: s)), with: .color(.white.opacity(0.18)))
        }
        for i in 0..<70 {
            let speed = 0.25 + Double(i % 7) * 0.05
            let y = CGFloat((t * speed + Double(i) * 0.137).truncatingRemainder(dividingBy: 1)) * s.height
            let x = CGFloat((Double(i) * 0.6180339).truncatingRemainder(dividingBy: 1)) * s.width + CGFloat(sin(t * 2 + Double(i))) * 12
            let rect = CGRect(x: x, y: y, width: 5, height: 3)
            var gg = g
            gg.translateBy(x: rect.midX, y: rect.midY)
            gg.rotate(by: .radians(t * 4 + Double(i)))
            gg.fill(Path(CGRect(x: -2.5, y: -1.5, width: 5, height: 3)), with: .color(Color(hue: Double(i % 10) / 10, saturation: 0.9, brightness: 1)))
        }
    }

    private func drawReactions(_ g: inout GraphicsContext, _ s: CGSize, _ now: Date) {
        for r in reactions {
            let age = now.timeIntervalSince(r.born)
            guard age < 2.5 else { continue }
            let seed = abs(r.id.hashValue % 1000)
            let x = CGFloat(seed) / 1000 * s.width * 0.8 + s.width * 0.1
            let y = s.height * 0.75 - CGFloat(age) * s.height * 0.28
            var gg = g
            gg.opacity = max(0, 1 - age / 2.5)
            gg.draw(Text(r.text).font(.system(size: 26)), at: CGPoint(x: x, y: y))
        }
    }

    private func drawBooth(_ g: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        let h: CGFloat = 16
        let rect = CGRect(x: 0, y: s.height - h, width: s.width, height: h)
        g.fill(Path(rect), with: .color(Color(white: 0.05)))
        g.fill(Path(CGRect(x: 0, y: s.height - h, width: s.width, height: 1.5)), with: .color(venue.palette.2.opacity(0.7)))
        let n = 24
        for i in 0..<n {
            let on = Double(i) / Double(n) < energy / 100
            let x = s.width * (CGFloat(i) + 0.5) / CGFloat(n)
            g.fill(Path(ellipseIn: CGRect(x: x - 2, y: s.height - h / 2 - 2, width: 4, height: 4)),
                   with: .color(on ? EnergyTier(energy).color : .white.opacity(0.08)))
        }
    }
}
