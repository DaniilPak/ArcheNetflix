import Foundation

/// A change the game can make to a design on the player's behalf.
enum Action {
    /// Add a service. `from` sends traffic into it, it sends to `to`; `replacing` is an edge it splits.
    case add(ServiceKind, from: UUID? = nil, to: UUID? = nil, replacing: UUID? = nil)
    case connect(UUID, UUID)
    case setCount(UUID, Int)
    case setTier(UUID, tier: Int, count: Int)
    case originShield(UUID)
    case scheduledScaling
    /// Another copy of a maxed-out service, wired the same way.
    case duplicate(UUID)
}

/// A concrete next step: what to do, in plain words, and the action that does it.
struct Fix {
    let title: String
    let action: Action
}

/// Builds fixes that are valid for a given design (only real AWS connections, within quotas).
struct Fixer {
    let design: Design
    let mission: Mission

    /// True when traffic can already flow from `a` to `b`.
    private func reaches(_ a: UUID, _ b: UUID) -> Bool {
        var seen = Set<UUID>(), stack = [a]
        while let id = stack.popLast() {
            if id == b { return true }
            guard seen.insert(id).inserted else { continue }
            stack += design.edges.filter { $0.from == id }.map(\.to)
        }
        return false
    }

    /// An existing service worth connecting to: right kind, valid link, no loop, passes `keep`.
    private func existing(_ kinds: [ServiceKind], from n: Node, keep: (Node) -> Bool = { _ in true }) -> Node? {
        for k in kinds where n.kind.linkProblem(to: k) == nil {
            if let t = design.nodes.first(where: { c in
                c.kind == k && c.id != n.id && keep(c) && !reaches(c.id, n.id)
                    && !design.edges.contains { $0.from == n.id && $0.to == c.id }
            }) { return t }
        }
        return nil
    }

    func connectOrAdd(_ n: Node, prefer kinds: [ServiceKind], add: ServiceKind, keep: (Node) -> Bool = { _ in true }) -> Fix {
        if let t = existing(kinds, from: n, keep: keep) { return Fix(title: "Connect \(n.title) → \(t.title)", action: .connect(n.id, t.id)) }
        // In tycoon mode, fall back to something already unlocked.
        let kind = mission.allows(add) ? add : (kinds.first { mission.allows($0) && n.kind.linkProblem(to: $0) == nil } ?? add)
        return Fix(title: "Add \(kind.spec.name) after \(n.title)", action: .add(kind, from: n.id))
    }

    /// Services that already take user API traffic shouldn't double as background workers.
    private func servesUsers(_ c: Node) -> Bool {
        design.edges.contains { e in e.to == c.id && (design.node(e.from).map { [.router, .cdn, .dns, .viewers].contains($0.spec.role) } ?? false) }
    }

    private func fedByStorage(_ c: Node) -> Bool {
        design.edges.contains { e in e.to == c.id && design.node(e.from)?.kind == .s3 }
    }

    /// Where a class of traffic should go next from `n`.
    func route(_ c: TrafficClass, from n: Node) -> Fix {
        let databases: [ServiceKind] = [.dynamoDB, .auroraDSQL, .aurora, .rds, .memoryDB, .neptune]
        let workers: [ServiceKind] = [.lambda, .ecs, .eks, .ec2, .fargate, .firehose]
        switch c {
        case .video:
            if n.spec.role == .cdn {
                return connectOrAdd(n, prefer: mission.profile.liveVideo ? [.mediaPackage, .s3] : [.s3], add: mission.profile.liveVideo ? .mediaPackage : .s3)
            }
            return connectOrAdd(n, prefer: [.cloudFront], add: .cloudFront)
        case .api:
            if n.kind.isLoadBalancer { return connectOrAdd(n, prefer: [.ec2, .ecs, .eks, .fargate, .lambda], add: .ec2) }
            if n.kind == .globalAccelerator { return connectOrAdd(n, prefer: [.alb, .nlb], add: .alb) }
            // From the outside world, go through the CDN first; behind it, a load balancer.
            if n.spec.role == .viewers || n.spec.role == .dns { return connectOrAdd(n, prefer: [.cloudFront, .alb, .apiGateway, .appSync], add: .cloudFront) }
            return connectOrAdd(n, prefer: [.alb, .apiGateway, .appSync], add: .alb)
        case .auth:
            guard let users = design.viewers else { return route(.api, from: n) }
            if let cognito = design.nodes.first(where: { $0.kind == .cognito }) {
                return Fix(title: "Connect Users → Cognito for sign-ins", action: .connect(users.id, cognito.id))
            }
            return Fix(title: "Add Cognito so users sign in without touching your servers", action: .add(.cognito, from: users.id))
        case .uploads:
            return connectOrAdd(n, prefer: [.s3], add: .s3)
        case .reads, .writes:
            return connectOrAdd(n, prefer: databases, add: .dynamoDB)
        case .events:
            switch n.spec.role {
            case .storage: return connectOrAdd(n, prefer: [.sqs, .eventBridge, .sns, .lambda], add: .sqs, keep: { !servesUsers($0) })
            case .queue: return connectOrAdd(n, prefer: workers, add: .lambda, keep: { !servesUsers($0) })
            case .pubsub:
                return n.kind == .sns ? connectOrAdd(n, prefer: [.sqs, .lambda], add: .sqs, keep: { !servesUsers($0) })
                    : connectOrAdd(n, prefer: [.lambda, .sqs, .stepFunctions], add: .lambda, keep: { !servesUsers($0) })
            default:
                // Keep app events apart from upload notifications.
                return connectOrAdd(n, prefer: [.eventBridge, .sns, .kinesis, .msk, .sqs], add: .sqs, keep: { !fedByStorage($0) })
            }
        case .notifications:
            let preferred: ServiceKind = mission.audience == "shoppers" ? .ses : .sns
            return connectOrAdd(n, prefer: [preferred, .sns, .endUserMessaging, .ses], add: preferred)
        }
    }

    /// Scale an overloaded service: more units, then a bigger tier, then max it out.
    func scale(_ n: Node, util: Double, units: Int) -> Fix? {
        guard n.spec.maxCount > 1 else { return nil }
        let need = Int((Double(max(units, 1)) * util * 1.1).rounded(.up))
        if need <= n.spec.maxCount {
            return Fix(title: "Scale \(n.title) to \(need) \(n.spec.unit)", action: .setCount(n.id, need))
        }
        if n.tier + 1 < n.spec.tiers.count {
            let next = n.spec.tiers[n.tier + 1]
            let needed = Int((Double(units) * util * n.tierSpec.capacity / next.capacity * 1.1).rounded(.up))
            if needed <= n.spec.maxCount {
                return Fix(title: "Upgrade \(n.title) to \(needed) × \(next.name)", action: .setTier(n.id, tier: n.tier + 1, count: needed))
            }
        }
        if n.count < n.spec.maxCount {
            return Fix(title: "Max \(n.title) out at \(n.spec.maxCount) \(n.spec.unit)", action: .setCount(n.id, n.spec.maxCount))
        }
        return Fix(title: "Add a second \(n.spec.name) next to \(n.title) (it's maxed at \(n.spec.maxCount))", action: .duplicate(n.id))
    }

    /// A single-writer database that can't keep up with writes.
    func writer(_ n: Node, parents: [Node]) -> Fix? {
        if n.tier + 1 < n.spec.tiers.count {
            return Fix(title: "Upgrade \(n.title) to \(n.spec.tiers[n.tier + 1].name) for a bigger writer", action: .setTier(n.id, tier: n.tier + 1, count: n.count))
        }
        if let p = parents.first(where: { $0.spec.role == .compute }), let e = design.edges.first(where: { $0.from == p.id && $0.to == n.id }) {
            return Fix(title: "Buffer writes through SQS between \(p.title) and \(n.title)", action: .add(.sqs, from: p.id, to: n.id, replacing: e.id))
        }
        return nil
    }

    func loadBalancer(for n: Node, parents: [Node]) -> Fix? {
        guard let p = parents.first(where: { !$0.kind.isLoadBalancer && $0.kind.linkProblem(to: .alb) == nil }),
              let e = design.edges.first(where: { $0.from == p.id && $0.to == n.id }) else { return nil }
        return Fix(title: "Put an Application LB between \(p.title) and \(n.title)", action: .add(.alb, from: p.id, to: n.id, replacing: e.id))
    }
}

/// A ranked next step: the fix plus the problem it solves.
struct Suggestion {
    let fix: Fix
    let why: String
}

extension Action {
    /// The service the action is mainly about, for "Show me".
    var focus: UUID? {
        switch self {
        case .add(_, let from, let to, _): from ?? to
        case .connect(let a, _): a
        case .setCount(let id, _), .setTier(let id, _, _), .originShield(let id), .duplicate(let id): id
        case .scheduledScaling: nil
        }
    }
}

/// Ranks every useful next step for the current board, most important first.
enum Advisor {
    static func suggestions(design: Design, mission: Mission, forecast: Forecast, costs: [CostLine], tutorialStep: Int) -> [Suggestion] {
        var list: [Suggestion] = []
        if mission.isTutorial, mission.steps.indices.contains(tutorialStep), let fix = tutorialFix(design: design, step: tutorialStep) {
            list.append(Suggestion(fix: fix, why: mission.steps[tutorialStep].hint))
        }
        if design.nodes.count == 1, let users = design.viewers {
            list.append(Suggestion(fix: Fix(title: "Add CloudFront in front of Users", action: .add(.cloudFront, from: users.id)),
                                   why: "Every design starts at the front door. CloudFront serves users from the edge and forwards the rest."))
        }
        for issue in forecast.worst.issues where issue.severity == .failure {
            if let fix = issue.fix { list.append(Suggestion(fix: fix, why: "At \(forecast.worstPhase): \(issue.text)")) }
        }
        for issue in forecast.worst.issues where issue.severity == .warning {
            if let fix = issue.fix { list.append(Suggestion(fix: fix, why: issue.text)) }
        }

        let monthly = costs.reduce(0) { $0 + $1.total }
        if monthly > mission.budget {
            let over = "You're at \(Fmt.money(monthly))/mo against a \(Fmt.money(mission.budget)) budget."
            if !design.scheduledScaling && design.nodes.contains(where: { $0.spec.schedulable }) {
                list.append(Suggestion(fix: Fix(title: "Turn on scheduled scaling — run servers only around the event", action: .scheduledScaling),
                                       why: "\(over) Servers billed 24/7 for a few hours of traffic are the easiest saving."))
            }
            for n in design.nodes where n.kind == .cloudFront && !n.originShield && mission.profile.videoMbps > 0 {
                list.append(Suggestion(fix: Fix(title: "Turn on Origin Shield for \(n.title)", action: .originShield(n.id)),
                                       why: "\(over) Origin Shield cuts origin traffic about 7×, so you need far fewer origin endpoints."))
            }
            for line in costs where line.fixed > 0 && line.node.count > 1 {
                let util = forecast.peakUtil[line.id] ?? 0
                let target = max(1, Int((Double(line.node.count) * util / 0.75).rounded(.up)))
                if util < 0.5 && target < line.node.count {
                    list.append(Suggestion(fix: Fix(title: "Trim \(line.node.title) to \(target) \(line.node.spec.unit)", action: .setCount(line.id, target)),
                                           why: "\(over) \(line.node.title) never goes above \(Fmt.percent(util)) of its capacity."))
                }
            }
        }
        // Drop duplicates, keep order.
        var seen = Set<String>()
        return list.filter { s in
            if case let .add(kind, _, _, _) = s.fix.action, !mission.allows(kind) { return false }
            return seen.insert(s.fix.title).inserted
        }
    }

    private static func tutorialFix(design: Design, step: Int) -> Fix? {
        guard let users = design.viewers else { return nil }
        let cdn = design.nodes.first { $0.kind == .cloudFront }
        let origin = design.nodes.first { $0.kind == .mediaPackage }
        switch step {
        case 0: return Fix(title: "Add CloudFront in front of Users", action: .add(.cloudFront, from: users.id))
        case 1: return cdn.map { Fix(title: "Connect Users → CloudFront", action: .connect(users.id, $0.id)) }
        case 2: return cdn.map { Fix(title: "Add MediaPackage behind CloudFront", action: .add(.mediaPackage, from: $0.id)) }
        case 3:
            guard let origin else { return nil }
            if let live = design.nodes.first(where: { $0.kind == .mediaLive }) {
                return Fix(title: "Connect MediaLive → MediaPackage", action: .connect(live.id, origin.id))
            }
            return Fix(title: "Add MediaLive feeding MediaPackage", action: .add(.mediaLive, to: origin.id))
        default: return nil
        }
    }
}
