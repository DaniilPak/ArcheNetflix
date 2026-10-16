import Foundation

struct NodeStat {
    var incoming = Load()
    var capacity = Load()
    var served = Load()
    var unrouted = Load()
    var success = Load.one
    var util = 0.0
    var effectiveCount = 0
}

struct Issue: Identifiable, Hashable {
    enum Severity: Int { case warning, failure }
    var id: String { (node?.uuidString ?? "") + text }
    let severity: Severity
    let node: UUID?
    let text: String
}

struct SimResult {
    var stats: [UUID: NodeStat] = [:]
    /// Edge id → share of the total demand flowing over it (0…1).
    var flow: [UUID: Double] = [:]
    var demand = Demand(viewers: 0, load: Load(), botShare: 0, phase: "")
    var video = 1.0
    var api = 1.0
    var issues: [Issue] = []

    var health: Double { min(video, api) }
    var status: Status { Status(health) }
}

enum Status: String {
    case holding = "HOLDING", degraded = "DEGRADED", down = "DOWN"
    init(_ health: Double) { self = health >= 0.995 ? .holding : health >= 0.9 ? .degraded : .down }
}

enum Solver {
    static let readShare = 0.8
    static let cacheHit = 0.9
    static let queueDrain = 0.35
    static let cdnAPICache = 0.15
    static let cdnAPIPerUnit = 2_000_000.0

    static func cdnMiss(_ n: Node) -> Double { n.originShield ? 0.003 : 0.02 }

    /// How many units of a node actually receive traffic.
    static func effectiveCount(_ n: Node, parents: [Node]) -> Int {
        if n.spec.needsLoadBalancer && !parents.contains(where: { $0.kind.isLoadBalancer }) { return min(n.count, 1) }
        return n.count
    }

    static func capacity(_ n: Node, count: Int) -> Load {
        let unit = n.tierSpec.capacity
        let c = Double(count)
        var cap = Load()
        switch n.spec.role {
        case .viewers, .encoder: return Load()
        case .router where n.kind == .route53: return .infinite
        case .router, .compute: cap[.api] = c * unit
        case .firewall: cap[.api] = unit; cap[.video] = .infinity
        case .cdn: cap[.video] = c * unit; cap[.api] = c * cdnAPIPerUnit
        case .cache: cap[.reads] = c * unit
        case .queue: cap[.writes] = c * unit
        case .origin: cap[.video] = c * unit
        case .database:
            if n.spec.singleWriter && count > 1 {
                cap[.writes] = unit
                cap[.reads] = Double(count - 1) * unit
            } else {
                // Shared capacity: reads + writes compete for the same units.
                cap[.reads] = c * unit; cap[.writes] = c * unit
            }
        }
        return cap
    }

    static func shared(_ n: Node, count: Int) -> Bool { n.spec.role == .database && !(n.spec.singleWriter && count > 1) }

    static func run(_ design: Design, _ demand: Demand) -> SimResult {
        var result = SimResult(demand: demand)
        guard let viewers = design.viewers else { return result }
        let nodes = Dictionary(uniqueKeysWithValues: design.nodes.map { ($0.id, $0) })
        var kids: [UUID: [Edge]] = [:]
        var parents: [UUID: [Node]] = [:]
        for e in design.edges where e.from != e.to {
            guard let from = nodes[e.from], nodes[e.to] != nil else { continue }
            kids[e.from, default: []].append(e)
            parents[e.to, default: []].append(from)
        }

        // Topological order from Viewers, ignoring edges that close a loop.
        var order: [UUID] = []
        var state: [UUID: Int] = [:]
        var loopEdges = Set<UUID>()
        func visit(_ id: UUID) {
            state[id] = 1
            for e in kids[id] ?? [] {
                if state[e.to] == 1 { loopEdges.insert(e.id); continue }
                if state[e.to] == nil { visit(e.to) }
            }
            state[id] = 2
            order.append(id)
        }
        visit(viewers.id)
        for n in design.nodes where state[n.id] == nil { visit(n.id) }
        order.reverse()
        for (id, list) in kids { kids[id] = list.filter { !loopEdges.contains($0.id) } }

        var stats: [UUID: NodeStat] = [:]
        for n in design.nodes {
            var s = NodeStat()
            s.effectiveCount = effectiveCount(n, parents: parents[n.id] ?? [])
            s.capacity = capacity(n, count: s.effectiveCount)
            stats[n.id] = s
        }
        stats[viewers.id]!.incoming = demand.load

        // Forward pass: push load through the graph.
        var shares: [UUID: [(to: UUID, cls: TrafficClass, frac: Double)]] = [:]
        for id in order {
            let n = nodes[id]!
            var s = stats[id]!
            let inL = s.incoming
            var served = inL
            var util = 0.0
            if n.kind != .viewers {
                if shared(n, count: s.effectiveCount) {
                    let total = inL[.reads] + inL[.writes]
                    let cap = s.capacity[.reads]
                    util = total > 0 ? (cap > 0 ? total / cap : .infinity) : 0
                    let ratio = util > 1 ? 1 / util : 1
                    served[.reads] *= ratio; served[.writes] *= ratio
                } else {
                    for c in TrafficClass.allCases where n.kind.accepts(c) && inL[c] > 0 {
                        let cap = s.capacity[c]
                        let u = cap > 0 ? inL[c] / cap : .infinity
                        util = max(util, u)
                        served[c] = min(inL[c], cap)
                    }
                }
                for c in TrafficClass.allCases where !n.kind.accepts(c) { served[c] = 0 }
            }
            s.served = served
            s.util = util

            var out = Load()
            switch n.spec.role {
            case .viewers, .router: out = served
            case .firewall: out = served; out[.api] = served[.api] * (1 - demand.botShare)
            case .cdn: out[.video] = served[.video] * cdnMiss(n); out[.api] = served[.api] * (1 - cdnAPICache)
            case .compute: out[.reads] = served[.api] * readShare; out[.writes] = served[.api] * (1 - readShare)
            case .cache: out[.reads] = served[.reads] * (1 - cacheHit)
            case .queue: out[.writes] = served[.writes] * queueDrain
            case .database, .origin, .encoder: break
            }

            for c in TrafficClass.allCases where out[c] > 1e-9 {
                let candidates = (kids[id] ?? []).filter { nodes[$0.to]!.kind.accepts(c) }
                guard let top = candidates.map({ nodes[$0.to]!.kind.priority(c) }).max() else {
                    s.unrouted[c] = out[c]
                    continue
                }
                let chosen = candidates.filter { nodes[$0.to]!.kind.priority(c) == top }
                let weights = chosen.map { e -> Double in
                    let cap = stats[e.to]!.capacity[c]
                    return cap.isFinite ? cap : 1e12
                }
                let sum = weights.reduce(0, +)
                let norm = c == .video ? max(demand.load[.video], 1e-9) : max(demand.load[.api], 1e-9)
                for (e, w) in zip(chosen, weights) {
                    let frac = sum > 0 ? w / sum : 1 / Double(chosen.count)
                    stats[e.to]!.incoming[c] += out[c] * frac
                    result.flow[e.id, default: 0] = max(result.flow[e.id, default: 0], out[c] * frac / norm)
                    shares[id, default: []].append((e.to, c, frac))
                }
            }
            stats[id] = s
        }

        // Backward pass: what share of each node's traffic is eventually answered.
        for id in order.reversed() {
            let n = nodes[id]!
            var s = stats[id]!
            func down(_ c: TrafficClass) -> Double {
                let list = (shares[id] ?? []).filter { $0.cls == c }
                if list.isEmpty { return 0 }
                return list.reduce(0) { $0 + $1.frac * stats[$1.to]!.success[c] }
            }
            func ratio(_ c: TrafficClass) -> Double { s.incoming[c] > 1e-9 ? s.served[c] / s.incoming[c] : 1 }
            var succ = Load.one
            switch n.spec.role {
            case .viewers: succ[.video] = down(.video); succ[.api] = down(.api)
            case .router: succ[.video] = ratio(.video) * down(.video); succ[.api] = ratio(.api) * down(.api)
            case .firewall:
                succ[.video] = ratio(.video) * down(.video)
                // Blocked bots don't count; what matters is how many real viewers get through.
                succ[.api] = ratio(.api) * down(.api)
            case .cdn:
                // Live segments expire every few seconds, so the edge is only as healthy as its origin.
                succ[.video] = ratio(.video) * down(.video)
                succ[.api] = ratio(.api) * (cdnAPICache + (1 - cdnAPICache) * down(.api))
            case .compute: succ[.api] = ratio(.api) * (readShare * down(.reads) + (1 - readShare) * down(.writes))
            case .cache: succ[.reads] = ratio(.reads) * (cacheHit + (1 - cacheHit) * down(.reads))
            case .queue: succ[.writes] = ratio(.writes) * down(.writes)
            case .database: succ[.reads] = ratio(.reads); succ[.writes] = ratio(.writes)
            case .origin:
                let live = n.spec.builtInLive || (parents[id] ?? []).contains { $0.kind == .mediaLive }
                succ[.video] = live ? ratio(.video) : 0
            case .encoder: break
            }
            s.success = succ
            stats[id] = s
        }

        result.stats = stats
        result.video = demand.load[.video] > 0 ? stats[viewers.id]!.success[.video] : 1
        result.api = demand.load[.api] > 0 ? stats[viewers.id]!.success[.api] : 1
        result.issues = issues(design, nodes: nodes, kids: kids, parents: parents, stats: stats)
        return result
    }

    private static func issues(_ design: Design, nodes: [UUID: Node], kids: [UUID: [Edge]], parents: [UUID: [Node]], stats: [UUID: NodeStat]) -> [Issue] {
        var list: [Issue] = []
        guard let viewers = design.viewers else { return list }
        if (kids[viewers.id] ?? []).isEmpty {
            list.append(Issue(severity: .failure, node: viewers.id, text: "Viewers aren't connected. Drag from their ⊕ handle to your entry point (Route 53 or CloudFront)."))
        }
        let hints: [TrafficClass: String] = [
            .video: "connect it to a video origin (MediaPackage or S3), ideally through CloudFront",
            .api: "connect it to a load balancer, API Gateway or compute",
            .reads: "connect it to ElastiCache, DynamoDB or Aurora",
            .writes: "connect it to DynamoDB, Aurora or an SQS queue",
        ]
        for n in design.nodes {
            guard let s = stats[n.id], s.incoming.values.contains(where: { $0 > 0 }) || n.kind == .viewers || n.kind == .mediaLive else { continue }
            for c in TrafficClass.allCases where s.unrouted[c] > 0 {
                list.append(Issue(severity: .failure, node: n.id, text: "\(n.title) has nowhere to send \(c.noun) — \(hints[c]!)."))
            }
            if s.util > 1.0001 {
                let need = Int((Double(s.effectiveCount) * s.util * 1.05).rounded(.up))
                if n.spec.singleWriter && n.count > 1 && s.incoming[.writes] > s.capacity[.writes] {
                    list.append(Issue(severity: .failure, node: n.id, text: "\(n.title)'s single writer is at \(Fmt.percent(s.incoming[.writes] / s.capacity[.writes])). Replicas can't take writes — upgrade the tier, add SQS, or use DynamoDB."))
                } else if n.kind == .waf {
                    list.append(Issue(severity: .failure, node: n.id, text: "\(n.title) is at \(Fmt.percent(s.util))."))
                } else {
                    let room = need > n.spec.maxCount ? " Max is \(n.spec.maxCount) — upgrade the tier or add another \(n.spec.name)." : ""
                    list.append(Issue(severity: .failure, node: n.id, text: "\(n.title) is at \(Fmt.percent(s.util)) — needs about \(need) \(n.spec.unit).\(room)"))
                }
            }
            if s.effectiveCount < n.count && s.incoming[.api] > 0 {
                list.append(Issue(severity: .failure, node: n.id, text: "Only 1 of \(n.count) \(n.title) \(n.spec.unit) gets traffic. Put a Load Balancer in front."))
            }
            if n.spec.role == .origin && !n.spec.builtInLive && s.incoming[.video] > 0 && !(parents[n.id] ?? []).contains(where: { $0.kind == .mediaLive }) {
                list.append(Issue(severity: .failure, node: n.id, text: "\(n.title) has no live feed. Add MediaLive and connect it → \(n.title)."))
            }
            if n.kind == .mediaLive && (kids[n.id] ?? []).isEmpty {
                list.append(Issue(severity: .warning, node: n.id, text: "\(n.title) isn't sending its stream anywhere. Connect it to MediaPackage."))
            }
            if n.kind == .mediaLive && n.count == 1 {
                list.append(Issue(severity: .warning, node: n.id, text: "Single MediaLive channel: one encoder failure ends the stream for everyone. Consider 2."))
            }
            if (0.8...1.0001).contains(s.util) {
                list.append(Issue(severity: .warning, node: n.id, text: "\(n.title) is running hot at \(Fmt.percent(s.util)). Leave headroom for surprises."))
            }
        }
        return list.sorted { $0.severity.rawValue > $1.severity.rawValue }
    }
}

/// Runs the whole event curve to predict whether the design survives.
struct Forecast {
    var minHealth = 1.0
    var worstPhase = ""
    var worst = SimResult()
    /// Highest utilisation each node reaches during the event.
    var peakUtil: [UUID: Double] = [:]
    /// Stats at the moment of highest total demand (used for usage pricing).
    var peak = SimResult()

    static func run(_ design: Design, _ m: Mission) -> Forecast {
        var f = Forecast()
        var peakDemand = -1.0
        for i in 0...160 {
            let p = Double(i) / 160
            let r = Solver.run(design, EventCurve.demand(m, p))
            for (id, s) in r.stats { f.peakUtil[id] = max(f.peakUtil[id] ?? 0, s.util) }
            if i == 0 || r.health < f.minHealth { f.minHealth = r.health; f.worstPhase = r.demand.phase; f.worst = r }
            let total = r.demand.load[.video] + r.demand.load[.api] / 1000
            if total > peakDemand { peakDemand = total; f.peak = r }
        }
        return f
    }
}

struct CostLine: Identifiable {
    var id: UUID { node.id }
    let node: Node
    let fixed: Double
    let usage: Double
    var total: Double { fixed + usage }
}

enum Pricing {
    /// Hours of compute per event when scaling is scheduled (warm-up, event, cool-down).
    static let scheduledHoursPerEvent = 8.0

    static func lines(_ design: Design, _ m: Mission, peak: SimResult) -> [CostLine] {
        // Peak-equivalent seconds of traffic in one event (the curve averages ~65% of peak).
        let seconds = m.eventHours * 3600 * 0.65
        let hoursFactor = design.scheduledScaling ? min(1, (m.eventHours + scheduledHoursPerEvent) / 730) : 1
        return design.nodes.filter { $0.kind != .viewers }.map { n in
            let s = peak.stats[n.id] ?? NodeStat()
            var fixed = Double(n.count) * n.tierSpec.monthly * (n.spec.schedulable ? hoursFactor : 1) + n.spec.baseMonthly
            let million = seconds / 1e6
            var usage = 0.0
            switch n.kind {
            case .cloudFront:
                let gb = s.served[.video] * seconds / 8
                let segmentRequests = s.served[.video] * 1e9 / 8 / 2.5e6
                usage = gb * 0.02 + (segmentRequests + s.served[.api]) * million * 1.0
                if n.originShield { fixed += 500 }
            case .waf: usage = s.served[.api] * million * 0.60
            case .alb: usage = s.served[.api] / 1000 * 0.008 * seconds / 3600
            case .apiGateway: usage = s.served[.api] * million * 1.00
            case .lambda: usage = s.served[.api] * million * 0.29
            case .dynamoDB: usage = (s.served[.reads] * 0.125 + s.served[.writes] * 0.625) * million
            case .sqs: usage = s.served[.writes] * million * 0.80
            case .mediaPackage: usage = s.served[.video] * seconds / 8 * 0.03
            case .nlb: usage = s.served[.api] / 1000 * 0.006 * seconds / 3600
            case .globalAccelerator: usage = s.served[.api] * 4e-6 * seconds * 0.015
            case .auroraDSQL: usage = (s.served[.reads] * 0.40 + s.served[.writes] * 1.60) * million
            case .kinesis: usage = s.served[.writes] * million * 0.16
            case .ivs:
                // Viewer-hours at ~1080p plus the channel's input hours.
                let viewers = s.served[.video] * 1000 / m.bitrateMbps
                usage = viewers * seconds / 3600 * 0.0375 + m.eventHours * 2
            case .s3: usage = s.served[.video] * 1e9 / 8 / 2.5e6 * million * 0.4
            default: break
            }
            return CostLine(node: n, fixed: fixed, usage: usage)
        }
        .sorted { $0.total > $1.total }
    }
}
