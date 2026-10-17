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

/// The audience curve of one event: a slow build, a sharp surge, a plateau and a tail-off.
enum EventCurve {
    static let phaseEnds = [0.15, 0.55, 0.62, 0.85, 1.0]

    static func phase(_ p: Double, _ m: Mission) -> String {
        m.phases[phaseEnds.firstIndex { p < $0 } ?? 4]
    }

    private static func smooth(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }

    /// Share of peak users active at progress p (0…1).
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
        let f = m.profile
        let v = m.peakUsers * fraction(p) * jitter
        let joinsPerSecond = max(0, (fraction(p + 0.002) - fraction(p - 0.002)) / 0.004) * m.peakUsers / (m.eventHours * 3600)
        let surge = p >= 0.5 && p < 0.85
        let bots = surge ? f.surgeBots : f.surgeBots / 5
        var load = Load()
        load[.video] = v * f.videoMbps / 1000
        load[.api] = (v * f.apiPerUser + joinsPerSecond * f.joinCalls) * (1 + bots)
        load[.auth] = joinsPerSecond * f.authPerJoin * (1 + bots)
        load[.uploads] = v * f.uploadsPerUser
        return Demand(viewers: v, load: load, botShare: bots / (1 + bots), phase: phase(p, m))
    }
}

struct Demand {
    var viewers: Double
    var load: Load
    /// Fraction of incoming API and sign-in traffic that is bots.
    var botShare: Double
    var phase: String
}
