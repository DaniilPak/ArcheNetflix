import Foundation

struct Node: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: ServiceKind
    var x: Double
    var y: Double
    var count: Int
    var tier: Int
    var index = 1
    var originShield = false

    var spec: ServiceSpec { kind.spec }
    var tierSpec: Tier { spec.tiers[min(max(tier, 0), spec.tiers.count - 1)] }
    var title: String { index > 1 ? "\(spec.name) \(index)" : spec.name }
    var position: CGPoint { CGPoint(x: x, y: y) }
}

struct Edge: Identifiable, Codable, Hashable {
    var id = UUID()
    var from: UUID
    var to: UUID
}

struct Design: Codable {
    var nodes: [Node]
    var edges: [Edge] = []
    var scheduledScaling = false

    static func starter() -> Design {
        Design(nodes: [Node(kind: .viewers, x: -220, y: 0, count: 1, tier: 0)])
    }

    var viewers: Node? { nodes.first { $0.kind == .viewers } }
    func node(_ id: UUID?) -> Node? { nodes.first { $0.id == id } }
}

/// The audience curve of one event, from doors open to post-fight.
enum EventCurve {
    static let phases: [(end: Double, name: String)] = [(0.15, "Doors open"), (0.55, "Undercard"), (0.62, "Walkout surge"), (0.85, "Main event"), (1.0, "Post-event")]

    static func phase(_ p: Double, _ m: Mission) -> String {
        let name = phases.first { p < $0.end }?.name ?? "Post-event"
        return name == "Main event" ? m.mainEvent : name
    }

    private static func smooth(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }

    /// Share of peak viewers watching at progress p (0…1).
    static func fraction(_ p: Double) -> Double {
        switch p {
        case ..<0.15: 0.05 + 0.30 * smooth(p / 0.15)
        case ..<0.55: 0.35 + 0.25 * smooth((p - 0.15) / 0.40)
        case ..<0.62: 0.60 + 0.40 * smooth((p - 0.55) / 0.07)
        case ..<0.85: 1.0
        default: 1.0 - 0.7 * smooth((p - 0.85) / 0.15)
        }
    }

    static func demand(_ m: Mission, _ p: Double, jitter: Double = 1) -> Demand {
        let v = m.peakViewers * fraction(p) * jitter
        let eventSeconds = m.eventHours * 3600
        let joinsPerSecond = max(0, (fraction(p + 0.002) - fraction(p - 0.002)) / 0.004) * m.peakViewers / eventSeconds
        let surge = p >= 0.5 && p < 0.85
        let bots = surge ? m.surgeBots : m.surgeBots / 5
        let legitAPI = m.hasAPI ? v / 30 + joinsPerSecond * m.joinCalls : 0
        var load = Load()
        load[.video] = v * m.bitrateMbps / 1000
        load[.api] = legitAPI * (1 + bots)
        return Demand(viewers: v, load: load, botShare: bots / (1 + bots), phase: phase(p, m))
    }
}

struct Demand {
    var viewers: Double
    var load: Load
    /// Fraction of incoming API traffic that is bots.
    var botShare: Double
    var phase: String
}
