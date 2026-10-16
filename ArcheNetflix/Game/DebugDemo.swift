#if DEBUG
import Foundation

/// Launch with `-demo` to load a reference architecture (for screenshots and testing only).
extension Design {
    static func demo(failing: Bool) -> Design {
        var d = Design.starter()
        func add(_ k: ServiceKind, _ c: Int, _ x: Double, _ y: Double, tier: Int = 0) -> UUID {
            var n = Node(kind: k, x: x, y: y, count: c, tier: tier)
            n.originShield = k == .cloudFront
            d.nodes.append(n)
            return n.id
        }
        func link(_ a: UUID, _ b: UUID) { d.edges.append(Edge(from: a, to: b)) }
        let v = d.viewers!.id
        let r53 = add(.route53, 1, -50, 0); link(v, r53)
        let waf = add(.waf, 1, 120, 0); link(r53, waf)
        let cf = add(.cloudFront, 11, 290, 0); link(waf, cf)
        let mp = add(.mediaPackage, 2, 460, -150); link(cf, mp)
        let ml = add(.mediaLive, 2, 290, -260); link(ml, mp)
        let lb = add(.alb, 8, 460, 120); link(cf, lb)
        let ec2 = add(.ec2, failing ? 60 : 190, 630, 120, tier: 1); link(lb, ec2)
        let redis = add(.elastiCache, 6, 800, 40); link(ec2, redis)
        let q = add(.sqs, 1, 800, 220); link(ec2, q)
        let ddb = add(.dynamoDB, 3, 970, 120); link(redis, ddb); link(q, ddb)
        d.scheduledScaling = true
        return d
    }
}
#endif
