import Foundation

struct NodeStat {
    var incoming = Load()
    var capacity = Load()
    var served = Load()
    var unrouted = Load()
    var success = Load.one
    var util = 0.0
    var effectiveCount = 0
    /// Bots stripped by an attached WAF before this service saw them.
    var blocked = 0.0
}

struct Issue: Identifiable {
    enum Severity: Int { case warning, failure }
    var id: String { (node?.uuidString ?? "") + text }
    let severity: Severity
    let node: UUID?
    let text: String
    /// A concrete change that resolves it, so hints can offer "Do it".
    var fix: Fix?
}

struct SimResult {
    var stats: [UUID: NodeStat] = [:]
    /// Edge id → share of the total demand flowing over it (0…1).
    var flow: [UUID: Double] = [:]
    var demand = Demand(viewers: 0, load: Load(), botShare: 0, phase: "")
    /// Share of each user-facing class that is answered end to end.
    var success: [TrafficClass: Double] = [:]
    var issues: [Issue] = []

    var video: Double { success[.video] ?? 1 }
    var api: Double { min(success[.api] ?? 1, success[.auth] ?? 1) }
    var uploads: Double { success[.uploads] ?? 1 }
    var health: Double { success.values.min() ?? 1 }
    var status: Status { Status(health) }
}

enum Status: String {
    case holding = "HOLDING", degraded = "DEGRADED", down = "DOWN"
    init(_ health: Double) { self = health >= 0.995 ? .holding : health >= 0.9 ? .degraded : .down }
}

enum Solver {
    static let cacheHit = 0.9
    static let queueDrain = 0.35
    static let cdnRequestsPerUnit = 2_000_000.0
    /// Each sign-in handled by your own servers costs a profile read plus a session write.
    static let authReads = 1.0, authWrites = 0.1

    static func cdnMiss(_ n: Node) -> Double { n.originShield ? 0.003 : 0.02 }

    /// How many units of a node actually receive API traffic.
    static func effectiveCount(_ n: Node, parents: [Node]) -> Int {
        if n.spec.needsLoadBalancer && !parents.contains(where: { $0.kind.isLoadBalancer }) { return min(n.count, 1) }
        return n.count
    }

    /// Groups of traffic classes that share one capacity pool.
    static func pools(_ n: Node, effective: Int, perf: Double = 1) -> [(classes: [TrafficClass], cap: Double)] {
        // Faster backend languages serve more per server; managed quotas (Step Functions, AppSync) don't change.
        let unit = n.tierSpec.capacity * (n.spec.role == .compute && ![.stepFunctions, .appSync].contains(n.kind) ? perf : 1)
        let c = Double(n.count), e = Double(effective)
        switch n.spec.role {
        case .viewers, .encoder, .firewall: return []
        case .dns: return [([.video, .api, .auth, .uploads], .infinity)]
        case .router: return [([.api, .auth], c * unit)]
        case .cdn: return [([.video], c * unit), ([.api, .auth, .uploads], c * cdnRequestsPerUnit)]
        case .compute:
            // API traffic needs a load balancer to reach every unit; queue workers poll on their own.
            var list: [(classes: [TrafficClass], cap: Double)] = []
            let front = [TrafficClass.api, .auth].filter { n.kind.accepts($0) }
            if !front.isEmpty { list.append((front, e * unit)) }
            if n.kind.accepts(.events) { list.append(([.events], c * unit)) }
            return list
        case .auth: return [([.auth], c * unit)]
        case .cache, .search: return [([.reads], c * unit)]
        case .queue: return [([.writes, .events], c * unit)]
        case .pubsub: return [(n.kind == .sns ? [.events, .notifications] : [.events], c * unit)]
        case .database:
            if n.spec.singleWriter && n.count > 1 { return [([.writes], unit), ([.reads], (c - 1) * unit)] }
            return [([.reads, .writes], c * unit)]
        case .origin: return [([.video], c * unit)]
        case .storage: return [([.video], c * unit), ([.uploads], c * n.spec.uploadCapacity)]
        case .processor: return [([.events], c * unit)]
        case .notifier: return [([.notifications], c * unit)]
        }
    }

    static func run(_ design: Design, _ mission: Mission, _ demand: Demand) -> SimResult {
        var result = SimResult(demand: demand)
        guard let viewers = design.viewers else { return result }
        let f = mission.profile
        let nodes = Dictionary(uniqueKeysWithValues: design.nodes.map { ($0.id, $0) })
        var kids: [UUID: [Edge]] = [:]
        var parents: [UUID: [Node]] = [:]
        var guardedBy: [UUID: UUID] = [:]
        for e in design.edges where e.from != e.to {
            guard let from = nodes[e.from], nodes[e.to] != nil else { continue }
            // WAF isn't a hop: its edges mark what it protects.
            if from.kind == .waf { guardedBy[e.to] = from.id; continue }
            kids[e.from, default: []].append(e)
            parents[e.to, default: []].append(from)
        }

        // Topological order from Users, ignoring edges that close a loop.
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
        var pool: [UUID: [(classes: [TrafficClass], cap: Double)]] = [:]
        for n in design.nodes {
            var s = NodeStat()
            s.effectiveCount = effectiveCount(n, parents: parents[n.id] ?? [])
            pool[n.id] = pools(n, effective: s.effectiveCount, perf: mission.computeMultiplier)
            for p in pool[n.id]! { for c in p.classes { s.capacity[c] = p.cap } }
            stats[n.id] = s
        }
        stats[viewers.id]!.incoming = demand.load

        let userTotal = max(demand.load[.api] + demand.load[.auth] + demand.load[.uploads], 1e-9)
        func norm(_ c: TrafficClass) -> Double {
            TrafficClass.userFacing.contains(c) ? max(demand.load[c], 1e-9) : userTotal
        }

        // Forward pass: push load through the graph.
        var shares: [UUID: [(to: UUID, cls: TrafficClass, frac: Double)]] = [:]
        for id in order {
            let n = nodes[id]!
            var s = stats[id]!
            if let waf = guardedBy[id] {
                let bots = (s.incoming[.api] + s.incoming[.auth]) * demand.botShare
                stats[waf]!.incoming[.api] += s.incoming[.api] + s.incoming[.auth]
                s.blocked = bots
                s.incoming[.api] *= 1 - demand.botShare
                s.incoming[.auth] *= 1 - demand.botShare
            }
            let inL = s.incoming
            var served = Load()
            var util = 0.0
            if n.kind == .viewers {
                served = inL
            } else {
                for p in pool[id]! {
                    let total = p.classes.reduce(0) { $0 + inL[$1] }
                    guard total > 0 else { continue }
                    let u = p.cap > 0 ? total / p.cap : .infinity
                    util = max(util, u)
                    let ratio = u > 1 ? 1 / u : 1
                    for c in p.classes { served[c] = inL[c] * ratio }
                }
            }
            s.served = served
            s.util = util

            var out = Load()
            switch n.spec.role {
            case .viewers, .dns, .router: out = served
            case .cdn:
                out = served
                out[.video] = served[.video] * cdnMiss(n)
                out[.api] = served[.api] * (1 - f.cdnCacheable)
            case .compute:
                out[.reads] = served[.api] * f.readsPerAPI + served[.auth] * authReads
                out[.writes] = served[.api] * f.writesPerAPI + served[.auth] * authWrites + served[.events] * f.writesPerEvent
                out[.events] = served[.api] * f.eventsPerAPI
                out[.notifications] = served[.events] * f.notificationsPerEvent
            case .cache: out[.reads] = served[.reads] * (1 - cacheHit)
            case .queue:
                out[.writes] = served[.writes] * queueDrain
                out[.events] = served[.events] * queueDrain
            case .pubsub: out[.events] = served[.events]
            case .storage: if f.uploadsNeedProcessing { out[.events] = served[.uploads] }
            case .auth, .search, .database, .origin, .encoder, .processor, .notifier, .firewall: break
            }

            for c in TrafficClass.allCases where out[c] > 1e-9 {
                let candidates = (kids[id] ?? []).filter { nodes[$0.to]!.kind.accepts(c) }
                if n.spec.role == .pubsub && c == .events {
                    // Fan-out: every subscriber gets its own copy.
                    guard !candidates.isEmpty else { s.unrouted[c] = out[c]; continue }
                    for e in candidates {
                        stats[e.to]!.incoming[c] += out[c]
                        result.flow[e.id, default: 0] = max(result.flow[e.id, default: 0], out[c] / norm(c))
                        shares[id, default: []].append((e.to, c, 1 / Double(candidates.count)))
                    }
                    continue
                }
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
                for (e, w) in zip(chosen, weights) {
                    let frac = sum > 0 ? w / sum : 1 / Double(chosen.count)
                    stats[e.to]!.incoming[c] += out[c] * frac
                    result.flow[e.id, default: 0] = max(result.flow[e.id, default: 0], out[c] * frac / norm(c))
                    shares[id, default: []].append((e.to, c, frac))
                }
            }
            stats[id] = s
        }

        // WAF load: everything it inspects on the services it protects.
        for n in design.nodes where n.kind == .waf {
            var s = stats[n.id]!
            let cap = n.tierSpec.capacity
            s.capacity[.api] = cap
            s.served[.api] = min(s.incoming[.api], cap)
            s.util = s.incoming[.api] / cap
            stats[n.id] = s
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
            /// Weighted success of the outputs a unit of input turns into.
            func mix(_ parts: [(Double, TrafficClass)]) -> Double {
                let total = parts.reduce(0) { $0 + $1.0 }
                return total > 0 ? parts.reduce(0) { $0 + $1.0 * down($1.1) } / total : 1
            }
            let hasLive = n.spec.builtInLive || (parents[id] ?? []).contains { $0.kind == .mediaLive }
            var succ = Load.one
            switch n.spec.role {
            case .viewers:
                for c in TrafficClass.userFacing { succ[c] = down(c) }
            case .dns, .router:
                for c in TrafficClass.userFacing { succ[c] = ratio(c) * down(c) }
            case .cdn:
                // Live segments expire every few seconds, so the edge is only as healthy as its origin.
                succ[.video] = ratio(.video) * down(.video)
                succ[.api] = ratio(.api) * (f.cdnCacheable + (1 - f.cdnCacheable) * down(.api))
                succ[.auth] = ratio(.auth) * down(.auth)
                succ[.uploads] = ratio(.uploads) * down(.uploads)
            case .compute:
                succ[.api] = ratio(.api) * mix([(f.readsPerAPI, .reads), (f.writesPerAPI, .writes), (f.eventsPerAPI, .events)])
                succ[.auth] = ratio(.auth) * mix([(authReads, .reads), (authWrites, .writes)])
                succ[.events] = ratio(.events) * mix([(f.writesPerEvent, .writes), (f.notificationsPerEvent, .notifications)])
            case .cache: succ[.reads] = ratio(.reads) * (cacheHit + (1 - cacheHit) * down(.reads))
            case .queue:
                succ[.writes] = ratio(.writes) * down(.writes)
                succ[.events] = ratio(.events) * down(.events)
            case .pubsub:
                succ[.events] = ratio(.events) * down(.events)
                succ[.notifications] = ratio(.notifications)
            case .origin:
                succ[.video] = (f.liveVideo && !hasLive) ? 0 : ratio(.video)
            case .storage:
                succ[.video] = (f.liveVideo && !hasLive) ? 0 : ratio(.video)
                succ[.uploads] = ratio(.uploads) * (f.uploadsNeedProcessing ? down(.events) : 1)
            case .auth, .search, .database, .processor, .notifier:
                for c in TrafficClass.allCases { succ[c] = ratio(c) }
            case .encoder, .firewall: break
            }
            s.success = succ
            stats[id] = s
        }

        result.stats = stats
        for c in TrafficClass.userFacing where demand.load[c] > 0 { result.success[c] = stats[viewers.id]!.success[c] }
        result.issues = issues(design, mission, nodes: nodes, kids: kids, parents: parents, guarded: Set(guardedBy.keys), stats: stats, demand: demand)
        return result
    }

    // MARK: Issues and their fixes

    private static func issues(_ design: Design, _ mission: Mission, nodes: [UUID: Node], kids: [UUID: [Edge]], parents: [UUID: [Node]],
                               guarded: Set<UUID>, stats: [UUID: NodeStat], demand: Demand) -> [Issue] {
        var list: [Issue] = []
        guard let viewers = design.viewers else { return list }
        let f = mission.profile
        let fixer = Fixer(design: design, mission: mission)

        if (kids[viewers.id] ?? []).isEmpty {
            list.append(Issue(severity: .failure, node: viewers.id,
                              text: "Users aren't connected to anything. Start with an entry point like CloudFront.",
                              fix: Fix(title: "Add CloudFront in front of Users", action: .add(.cloudFront, from: viewers.id))))
        }
        for n in design.nodes {
            guard let s = stats[n.id] else { continue }
            let frontTraffic = s.incoming[.api] + s.incoming[.auth]
            for c in TrafficClass.allCases where s.unrouted[c] > 0 {
                let fix = fixer.route(c, from: n)
                list.append(Issue(severity: .failure, node: n.id, text: "\(n.title) has nowhere to send \(c.noun). \(fix.title).", fix: fix))
            }
            if s.util > 1.0001 && n.kind != .waf {
                if n.spec.singleWriter && n.count > 1 && s.incoming[.writes] > s.capacity[.writes] {
                    list.append(Issue(severity: .failure, node: n.id,
                                      text: "\(n.title)'s single writer is at \(Fmt.percent(s.incoming[.writes] / s.capacity[.writes])) — replicas can't take writes.",
                                      fix: fixer.writer(n, parents: parents[n.id] ?? [])))
                } else if !(s.effectiveCount < n.count && frontTraffic > 0) {
                    // Queue workers poll on their own, so every unit counts even without a load balancer.
                    let fix = fixer.scale(n, util: s.util, units: frontTraffic > 0 ? s.effectiveCount : n.count)
                    list.append(Issue(severity: .failure, node: n.id, text: "\(n.title) is at \(Fmt.percent(s.util)) of capacity.", fix: fix))
                }
            }
            if s.effectiveCount < n.count && frontTraffic > 0 {
                list.append(Issue(severity: .failure, node: n.id,
                                  text: "Only 1 of \(n.count) \(n.title) \(n.spec.unit) gets API traffic — there's no load balancer in front.",
                                  fix: fixer.loadBalancer(for: n, parents: parents[n.id] ?? [])))
            }
            if f.liveVideo && (n.spec.role == .origin || n.spec.role == .storage) && !n.spec.builtInLive && s.incoming[.video] > 0
                && !(parents[n.id] ?? []).contains(where: { $0.kind == .mediaLive }) {
                list.append(Issue(severity: .failure, node: n.id, text: "\(n.title) has no live feed to serve.",
                                  fix: Fix(title: "Add MediaLive feeding \(n.title)", action: .add(.mediaLive, to: n.id))))
            }
            if n.kind == .waf && (design.edges.allSatisfy { $0.from != n.id }) {
                let target = design.nodes.first { [.cloudFront, .alb, .apiGateway, .appSync].contains($0.kind) }
                list.append(Issue(severity: .warning, node: n.id, text: "WAF isn't protecting anything yet.",
                                  fix: target.map { Fix(title: "Attach WAF to \($0.title)", action: .connect(n.id, $0.id)) }))
            }
            if n.kind == .mediaLive && n.count == 1 && !(kids[n.id] ?? []).isEmpty {
                list.append(Issue(severity: .warning, node: n.id, text: "A single MediaLive channel is a single point of failure.",
                                  fix: Fix(title: "Run 2 MediaLive channels", action: .setCount(n.id, 2))))
            }
            if (0.8...1.0001).contains(s.util) && n.kind != .waf {
                let target = Int((Double(n.count) * s.util / 0.7).rounded(.up))
                list.append(Issue(severity: .warning, node: n.id, text: "\(n.title) runs hot at \(Fmt.percent(s.util)) — no headroom for surprises.",
                                  fix: target <= n.spec.maxCount && target > n.count ? Fix(title: "Scale \(n.title) to \(target) \(n.spec.unit)", action: .setCount(n.id, target)) : nil))
            }
        }
        // Bots: suggest a WAF on the busiest unprotected front door.
        if demand.botShare >= 0.08, !design.nodes.contains(where: { $0.kind == .waf }),
           let front = design.nodes.filter({ [.cloudFront, .alb, .apiGateway, .appSync].contains($0.kind) && !guarded.contains($0.id) })
            .max(by: { (stats[$0.id]?.incoming[.api] ?? 0) < (stats[$1.id]?.incoming[.api] ?? 0) }),
           (stats[front.id]?.incoming[.api] ?? 0) > 0 {
            list.append(Issue(severity: .warning, node: front.id,
                              text: "Bots are \(Fmt.percent(demand.botShare)) of API traffic right now and nothing filters them.",
                              fix: Fix(title: "Attach WAF to \(front.title)", action: .add(.waf, to: front.id))))
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

    /// Live traffic wobbles by up to ±3%; the forecast assumes the worst so a pass is a real pass.
    static let jitter = 1.03

    static func run(_ design: Design, _ m: Mission) -> Forecast {
        var f = Forecast()
        var peakDemand = -1.0, peakP = 0.0
        for i in 0...160 {
            let p = Double(i) / 160
            let r = Solver.run(design, m, EventCurve.demand(m, p, jitter: jitter))
            for (id, s) in r.stats { f.peakUtil[id] = max(f.peakUtil[id] ?? 0, s.util) }
            if i == 0 || r.health < f.minHealth { f.minHealth = r.health; f.worstPhase = r.demand.phase; f.worst = r }
            let total = r.demand.load[.video] + (r.demand.load[.api] + r.demand.load[.auth] + r.demand.load[.uploads]) / 1000
            if total > peakDemand { peakDemand = total; peakP = p }
        }
        f.peak = Solver.run(design, m, EventCurve.demand(m, peakP))
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
            let front = s.served[.api] + s.served[.auth]
            var usage = 0.0
            switch n.kind {
            case .cloudFront:
                let gb = s.served[.video] * seconds / 8
                let segmentRequests = s.served[.video] * 1e9 / 8 / 2.5e6
                usage = gb * 0.02 + (segmentRequests + front + s.served[.uploads]) * million * 1.0
                if n.originShield { fixed += 500 }
            case .waf: usage = s.served[.api] * million * 0.60
            case .alb: usage = front / 1000 * 0.008 * seconds / 3600
            case .nlb: usage = front / 1000 * 0.006 * seconds / 3600
            case .apiGateway: usage = front * million * 1.00
            case .appSync: usage = front * million * 4.00
            case .globalAccelerator: usage = front * 4e-6 * seconds * 0.015
            case .lambda: usage = (front + s.served[.events]) * million * 0.29
            case .stepFunctions: usage = (s.served[.api] + s.served[.events]) * million * 2.0
            case .cognito: usage = front > 0 || s.served[.auth] > 0 ? m.peakUsers * 0.0055 : 0
            case .dynamoDB: usage = (s.served[.reads] * 0.125 + s.served[.writes] * 0.625) * million
            case .auroraDSQL: usage = (s.served[.reads] * 0.40 + s.served[.writes] * 1.60) * million
            case .sqs: usage = (s.served[.writes] + s.served[.events]) * million * 0.80
            case .sns: usage = (s.served[.events] + s.served[.notifications]) * million * 0.50
            case .eventBridge: usage = s.served[.events] * million * 1.00
            case .kinesis: usage = (s.served[.writes] + s.served[.events]) * million * 0.16
            case .firehose: usage = s.served[.events] * million * 0.03
            case .ses: usage = s.served[.notifications] * million * 100
            case .endUserMessaging: usage = s.served[.notifications] * million * 1.0
            case .mediaConvert: usage = s.served[.events] * seconds * 0.0075
            case .mediaPackage: usage = s.served[.video] * seconds / 8 * 0.03
            case .ivs:
                // Viewer-hours at ~1080p plus the channel's input hours.
                let viewers = s.served[.video] * 1000 / max(m.profile.videoMbps, 0.1)
                usage = viewers * seconds / 3600 * 0.0375 + m.eventHours * 2
            case .s3: usage = (s.served[.video] * 1e9 / 8 / 2.5e6 * 0.4 + s.served[.uploads] * 5) * million
            default: break
            }
            return CostLine(node: n, fixed: fixed, usage: usage)
        }
        .sorted { $0.total > $1.total }
    }
}
