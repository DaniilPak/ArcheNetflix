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
    /// Save format. 2 added starter-size tiers in front of EC2, RDS and ElastiCache.
    var version: Int? = 2

    static func starter() -> Design {
        Design(nodes: [Node(kind: .viewers, x: -220, y: 0, count: 1, tier: 0)])
    }

    /// Brings boards saved by older versions up to date.
    mutating func upgrade() {
        if (version ?? 1) < 2 {
            for i in nodes.indices where [.ec2, .rds, .elastiCache].contains(nodes[i].kind) { nodes[i].tier += 1 }
            version = 2
        }
    }

    var viewers: Node? { nodes.first { $0.kind == .viewers } }
    func node(_ id: UUID?) -> Node? { nodes.first { $0.id == id } }
}

/// The audience curve of one event: a slow build, a sharp surge, a plateau and a tail-off.
enum EventCurve {
    static let phaseEnds = [0.15, 0.55, 0.62, 0.85, 1.0]
    /// A day (tycoon mode): quiet nights, a lunchtime bump, an evening peak.
    static let dayEnds = [0.25, 0.5, 0.75, 0.92, 1.0]

    static func phase(_ p: Double, _ m: Mission) -> String {
        m.phases[(m.daily ? dayEnds : phaseEnds).firstIndex { p < $0 } ?? 4]
    }

    /// Share of the day's peak online at time of day p (0 = midnight); peaks at 20:00.
    static func daily(_ p: Double) -> Double {
        0.3 + 0.7 * (0.5 + 0.5 * cos(2 * .pi * (p - 20.0 / 24)))
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
        func curve(_ x: Double) -> Double { m.daily ? EventCurve.daily(x) : EventCurve.fraction(x) }
        let v = m.peakUsers * curve(p) * jitter
        let span = m.daily ? 24 * 3600.0 : m.eventHours * 3600
        let joinsPerSecond = max(0, (curve(p + 0.002) - curve(p - 0.002)) / 0.004) * m.peakUsers / span
        let surge = m.daily ? m.surging : p >= 0.5 && p < 0.85
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
