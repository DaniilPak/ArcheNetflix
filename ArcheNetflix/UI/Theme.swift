import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: opacity)
    }
}

/// Same palette as ChessBoi / Knightly.
enum Theme {
    static let bg = Color(hex: 0x312e2b)
    static let panel = Color(hex: 0x262421)
    static let panel2 = Color(hex: 0x21201d)
    static let raised = Color(hex: 0x3c3a37)
    static let soft = Color.white.opacity(0.8)
    static let muted = Color(hex: 0x989795)
    static let faint = Color(hex: 0x77756f)
    static let green = Color(hex: 0x81b64c)
    static let greenHi = Color(hex: 0xa3d160)
    static let greenShadow = Color(hex: 0x45753c)
    static let light = Color(hex: 0xebecd0)
    static let orange = Color(hex: 0xffaa00)
    static let yellow = Color(hex: 0xf7c631)
    static let red = Color(hex: 0xfa412d)
    static let terminal = Color(hex: 0x161513)

    static func load(_ util: Double) -> Color {
        util > 1.0001 ? red : util > 0.8 ? orange : green
    }
}

/// Chunky green button with a darker bottom edge that presses down.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: compact ? 15 : 17, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 8 : 12)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(RoundedRectangle(cornerRadius: 7).fill(pressed ? Theme.greenHi : Theme.green))
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.greenShadow).offset(y: pressed ? 1 : 4))
            .offset(y: pressed ? 3 : 0)
            .padding(.bottom, 4)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.raised
    var height: CGFloat = 46
    var expand = true
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Theme.soft)
            .padding(.horizontal, expand ? 0 : 12)
            .frame(maxWidth: expand ? .infinity : nil, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 7).fill(pressed ? tint.mix(with: .white, by: 0.06) : tint))
            .background(RoundedRectangle(cornerRadius: 7).fill(tint.mix(with: .black, by: 0.45)).offset(y: pressed ? 1 : 3))
            .offset(y: pressed ? 2 : 0)
            .padding(.bottom, 3)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

struct GreenIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.icon.foregroundStyle(Theme.green); configuration.title }
    }
}

enum Fmt {
    static func viewers(_ v: Double) -> String {
        v >= 1e6 ? String(format: v >= 1e7 ? "%.1fM" : "%.2fM", v / 1e6) : v >= 1e3 ? String(format: "%.0fk", v / 1e3) : String(format: "%.0f", v)
    }
    static func money(_ v: Double) -> String {
        v >= 1e6 ? String(format: "$%.2fM", v / 1e6) : v >= 1e4 ? String(format: "$%.0fk", v / 1e3) : v >= 1e3 ? String(format: "$%.1fk", v / 1e3) : String(format: "$%.0f", v)
    }
    static func rate(_ v: Double, _ c: TrafficClass) -> String {
        if !v.isFinite { return "∞" }
        switch c {
        case .video: return v >= 1000 ? String(format: "%.1f Tbps", v / 1000) : v >= 10 ? String(format: "%.0f Gbps", v) : String(format: "%.1f Gbps", v)
        default:
            let unit: String
            switch c {
            case .api: unit = " req/s"
            case .auth: unit = " sign-ins/s"
            case .uploads: unit = " uploads/s"
            case .events: unit = " events/s"
            case .notifications: unit = " msgs/s"
            default: unit = " ops/s"
            }
            return (v >= 1e6 ? String(format: "%.2fM", v / 1e6) : v >= 1e3 ? String(format: "%.0fk", v / 1e3) : String(format: "%.0f", v)) + unit
        }
    }
    static func percent(_ v: Double) -> String {
        v >= 0.9995 && v < 1 ? "99.9%" : v < 0.1 ? String(format: "%.1f%%", v * 100) : String(format: "%.0f%%", v * 100)
    }
}
