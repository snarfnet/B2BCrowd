import SwiftUI

// 大型 LED 画面風の文字
struct LEDText: View {
    let text: String
    var size: CGFloat = 18
    var color: Color = .cyan

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .heavy, design: .monospaced))
            .foregroundStyle(color)
            .shadow(color: color.opacity(0.9), radius: 6)
            .shadow(color: color.opacity(0.5), radius: 14)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

struct NeonButtonStyle: ButtonStyle {
    var color: Color = .pink
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .heavy, design: .rounded))
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(filled ? color.opacity(configuration.isPressed ? 0.6 : 0.85) : Color.white.opacity(0.06))
            )
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(color, lineWidth: filled ? 0 : 1.5))
            .foregroundStyle(filled ? Color.black : color)
            .shadow(color: color.opacity(0.6), radius: configuration.isPressed ? 2 : 10)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

// ジャケット。デモ曲は色のグラデーションで代用。
struct ArtworkView: View {
    let track: Track?
    var hidden = false

    var body: some View {
        ZStack {
            if hidden {
                LinearGradient(colors: [.purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text("?").font(.system(size: 60, weight: .black)).foregroundStyle(.white.opacity(0.8))
            } else if let t = track, let url = t.artworkURL {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.3)
                }
            } else if let t = track {
                LinearGradient(colors: [Color(hue: t.demoHue, saturation: 0.8, brightness: 0.9),
                                        Color(hue: (t.demoHue + 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.9, brightness: 0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(String(t.title.prefix(1)))
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Color.white.opacity(0.06)
                Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.white.opacity(0.3))
            }
        }
        .clipped()
    }
}

// 回転するレコード。中央ラベルにジャケット。
struct RecordView: View {
    let track: Track?
    let spinning: Bool
    var hidden = false

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { ctx in
            let angle = ctx.date.timeIntervalSinceReferenceDate * 200   // 33⅓回転ぶん
            ZStack {
                ZStack {
                    Circle().fill(Color(white: 0.06))
                    ForEach(0..<7) { i in
                        Circle().stroke(Color.white.opacity(0.05), lineWidth: 1)
                            .padding(CGFloat(6 + i * 6))
                    }
                    ArtworkView(track: track, hidden: hidden)
                        .clipShape(Circle())
                        .padding(28)
                    Circle().fill(Color.black).frame(width: 6, height: 6)
                }
                .rotationEffect(.degrees(spinning ? angle.truncatingRemainder(dividingBy: 360) : 0))
                // 光の反射は回さない
                Circle()
                    .trim(from: 0.05, to: 0.15)
                    .stroke(Color.white.opacity(0.18), lineWidth: 10)
                    .padding(10)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// CROWD ENERGY メーター。ゲーム内の数値を表示するもので、音の実測ではない。
struct EnergyMeter: View {
    let energy: Double

    var body: some View {
        let tier = EnergyTier(energy)
        VStack(spacing: 4) {
            HStack {
                Text("CROWD ENERGY")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                LEDText(text: tier.label, size: 13, color: tier.color)
                LEDText(text: String(format: "%3d", Int(energy.rounded())), size: 20, color: tier.color)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(0..<25) { i in
                        let lit = Double(i) < energy / 4
                        RoundedRectangle(cornerRadius: 2)
                            .fill(lit ? segmentColor(i) : Color.white.opacity(0.07))
                            .shadow(color: lit ? segmentColor(i).opacity(0.8) : .clear, radius: 4)
                    }
                }
                .frame(width: geo.size.width)
            }
            .frame(height: 14)
        }
    }

    private func segmentColor(_ i: Int) -> Color {
        if energy >= 99.5 {
            return Color(hue: Double(i) / 25, saturation: 0.9, brightness: 1)
        }
        switch i {
        case ..<5: return .cyan
        case ..<10: return .green
        case ..<15: return .yellow
        case ..<20: return .orange
        default: return .red
        }
    }
}

func formatTime(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.down)))
    return String(format: "%d:%02d", s / 60, s % 60)
}
