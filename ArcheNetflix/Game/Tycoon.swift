import Foundation

// MARK: - Choices

enum Business: String, Codable, CaseIterable, Identifiable {
    case store, streaming, social, saas
    var id: String { rawValue }

    var title: String {
        switch self {
        case .store: "Online store"
        case .streaming: "Video streaming"
        case .social: "Social app"
        case .saas: "SaaS for teams"
        }
    }
    var defaultName: String {
        switch self {
        case .store: "ShopHub"
        case .streaming: "StreamBox"
        case .social: "Snapgram"
        case .saas: "TaskFlow"
        }
    }
    var symbol: String {
        switch self {
        case .store: "bag.fill"
        case .streaming: "play.tv.fill"
        case .social: "person.2.wave.2.fill"
        case .saas: "rectangle.3.group.fill"
        }
    }
    var noun: String {
        switch self {
        case .store: "shoppers"
        case .streaming: "subscribers"
        case .social: "users"
        case .saas: "seats"
        }
    }
    var pitch: String {
        switch self {
        case .store: "Sell products online. Lots of cacheable browsing, orders turn into events, every buyer gets an email."
        case .streaming: "Monthly subscriptions for on-demand video. High revenue per user — and a huge CDN bill."
        case .social: "Free photo sharing paid by ads. Explosive growth, uploads, likes and push notifications, tiny revenue per user."
        case .saas: "A productivity tool businesses pay for per seat. Slow growth, great revenue, busy only during work hours."
        }
    }
    var pros: [String] {
        switch self {
        case .store: ["Easy to start: mostly cacheable pages", "Small AWS bill per shopper"]
        case .streaming: ["$9 subscriptions — the most profit per user after SaaS", "Simple, predictable API"]
        case .social: ["Fastest growth (virality)", "Biggest market: 300M users"]
        case .saas: ["Highest revenue per user", "Few users needed to make money"]
        }
    }
    var cons: [String] {
        switch self {
        case .store: ["Scalper bots during drops", "Sales spikes up to 9×"]
        case .streaming: ["Video bandwidth dominates costs", "Slower growth"]
        case .social: ["Revenue per user is pennies", "Upload pipeline and push from day one"]
        case .saas: ["Smallest market (4M seats)", "Slowest growth"]
        }
    }

    var profile: Profile {
        switch self {
        case .store:
            Profile(videoMbps: 0, liveVideo: false, apiPerUser: 0.25, joinCalls: 3, authPerJoin: 0.3, cdnCacheable: 0.45,
                    readsPerAPI: 0.85, writesPerAPI: 0.05, eventsPerAPI: 0.06, writesPerEvent: 2, notificationsPerEvent: 1, surgeBots: 0.3)
        case .streaming:
            Profile(videoMbps: 3, liveVideo: false, apiPerUser: 1.0 / 60, joinCalls: 6, authPerJoin: 0.2, cdnCacheable: 0.2,
                    readsPerAPI: 0.8, writesPerAPI: 0.2, eventsPerAPI: 0, surgeBots: 0.05)
        case .social:
            Profile(videoMbps: 0.3, liveVideo: false, apiPerUser: 0.2, joinCalls: 8, authPerJoin: 0.3, uploadsPerUser: 0.0004, uploadsNeedProcessing: true,
                    cdnCacheable: 0.2, readsPerAPI: 0.9, writesPerAPI: 0.05, eventsPerAPI: 0.15, writesPerEvent: 1, notificationsPerEvent: 1, surgeBots: 0.1)
        case .saas:
            Profile(videoMbps: 0, liveVideo: false, apiPerUser: 0.4, joinCalls: 5, authPerJoin: 0.5, cdnCacheable: 0.1,
                    readsPerAPI: 0.6, writesPerAPI: 0.3, eventsPerAPI: 0.1, writesPerEvent: 1, notificationsPerEvent: 0.5, surgeBots: 0.05)
        }
    }
    /// Share of users online at the daily peak.
    var onlineShare: Double {
        switch self { case .store: 0.03; case .streaming: 0.08; case .social: 0.06; case .saas: 0.25 }
    }
    /// Gross profit per user per day (after product, content or payment costs — before AWS).
    var arpuDay: Double {
        switch self { case .store: 0.012; case .streaming: 0.12; case .social: 0.003; case .saas: 0.35 }
    }
    var marketCap: Double {
        switch self { case .store: 20_000_000; case .streaming: 40_000_000; case .social: 300_000_000; case .saas: 4_000_000 }
    }
    /// Daily growth rate while far from the market cap.
    var growthDay: Double {
        switch self { case .store: 0.04; case .streaming: 0.03; case .social: 0.05; case .saas: 0.025 }
    }
    /// Services the business can't start without.
    var startUnlocks: [ServiceKind] {
        switch self { case .store: [.ses]; case .streaming: []; case .social: [.sns]; case .saas: [.ses, .sqs] }
    }
    var spikes: [SpikeTemplate] {
        switch self {
        case .store: [SpikeTemplate(name: "Flash sale", multiplier: 5, hours: 12), SpikeTemplate(name: "Black Friday", multiplier: 9, hours: 24),
                      SpikeTemplate(name: "Scalper bot wave", multiplier: 1.5, hours: 8, bots: 0.6)]
        case .streaming: [SpikeTemplate(name: "Season finale", multiplier: 4, hours: 6), SpikeTemplate(name: "Blockbuster premiere", multiplier: 6, hours: 8)]
        case .social: [SpikeTemplate(name: "A post goes viral", multiplier: 8, hours: 6), SpikeTemplate(name: "Celebrity joins", multiplier: 5, hours: 12),
                       SpikeTemplate(name: "Spam bot wave", multiplier: 1.5, hours: 8, bots: 0.5)]
        case .saas: [SpikeTemplate(name: "#1 on Product Hunt", multiplier: 6, hours: 12), SpikeTemplate(name: "Enterprise rollout", multiplier: 3, hours: 48)]
        }
    }
}

enum Frontend: String, Codable, CaseIterable, Identifiable {
    case spa, ssr, templates, mobile
    var id: String { rawValue }

    var title: String {
        switch self {
        case .spa: "React SPA on S3 + CloudFront"
        case .ssr: "Next.js server-side rendering"
        case .templates: "Server-rendered templates"
        case .mobile: "Native iOS + Android apps"
        }
    }
    var symbol: String {
        switch self { case .spa: "atom"; case .ssr: "server.rack"; case .templates: "doc.richtext"; case .mobile: "iphone" }
    }
    var pros: [String] {
        switch self {
        case .spa: ["Pages are static files — CDN serves them for pennies", "Servers only see API calls"]
        case .ssr: ["Great SEO: +20% growth", "Fast first page load"]
        case .templates: ["Simplest to build, one codebase", "Works with any backend"]
        case .mobile: ["+25% revenue per user", "Users stick around: −40% churn", "Push notifications"]
        }
    }
    var cons: [String] {
        switch self {
        case .spa: ["Weaker SEO: −10% growth"]
        case .ssr: ["Every page renders on your servers: +70% load", "$500 to build"]
        case .templates: ["+40% server load", "Feels dated: −5% revenue"]
        case .mobile: ["$1,500 to build both apps", "+25% API calls and more pushes"]
        }
    }
    var buildCost: Double { switch self { case .spa, .templates: 0; case .ssr: 500; case .mobile: 1_500 } }
    var apiMultiplier: Double { switch self { case .spa: 1; case .ssr: 1.7; case .templates: 1.4; case .mobile: 1.25 } }
    var cacheDelta: Double { switch self { case .spa: 0.25; case .ssr: -0.1; case .templates: 0; case .mobile: -0.05 } }
    var growth: Double { switch self { case .spa: 0.9; case .ssr: 1.2; case .templates: 1; case .mobile: 1.05 } }
    var arpu: Double { switch self { case .spa, .ssr: 1; case .templates: 0.95; case .mobile: 1.25 } }
    var churn: Double { self == .mobile ? 0.6 : 1 }
    var extraNotifications: Double { self == .mobile ? 0.5 : 0 }
}

enum Stack: String, Codable, CaseIterable, Identifiable {
    case node, go, python, java, rails, rust
    var id: String { rawValue }

    var title: String {
        switch self {
        case .node: "Node.js (TypeScript)"
        case .go: "Go"
        case .python: "Python (Django / FastAPI)"
        case .java: "Java / Kotlin (Spring)"
        case .rails: "Ruby on Rails"
        case .rust: "Rust"
        }
    }
    var symbol: String {
        switch self {
        case .node: "curlybraces"; case .go: "hare.fill"; case .python: "chevron.left.forwardslash.chevron.right"
        case .java: "cup.and.saucer.fill"; case .rails: "tram.fill"; case .rust: "gearshape.2.fill"
        }
    }
    /// Requests each server handles, relative to Node.js.
    var perf: Double { switch self { case .node: 1; case .go: 2.2; case .python: 0.6; case .java: 1.7; case .rails: 0.5; case .rust: 3 } }
    /// How fast the team ships features (feeds growth).
    var devSpeed: Double { switch self { case .node: 1.05; case .go: 0.95; case .python: 1.15; case .java: 0.9; case .rails: 1.2; case .rust: 0.85 } }
    var pros: [String] {
        switch self {
        case .node: ["Same language as the frontend", "Huge hiring pool"]
        case .go: ["2.2× requests per server", "Tiny memory footprint"]
        case .python: ["Ship features fast: +15% growth", "Great for ML later"]
        case .java: ["1.7× requests per server", "Battle-tested at scale"]
        case .rails: ["Fastest to build: +20% growth", "Batteries included"]
        case .rust: ["3× requests per server", "Lowest compute bill"]
        }
    }
    var cons: [String] {
        switch self {
        case .node: ["Single-threaded: average throughput"]
        case .go: ["More code per feature: −5% growth"]
        case .python: ["0.6× requests per server"]
        case .java: ["Slower to ship: −10% growth"]
        case .rails: ["0.5× requests per server"]
        case .rust: ["Slowest to ship: −15% growth"]
        }
    }
}

struct SpikeTemplate {
    let name: String
    let multiplier: Double
    let hours: Double
    var bots = 0.0
}

struct Spike: Codable {
    let name: String
    let multiplier: Double
    let start: Double
    let end: Double
    var bots: Double
    var minHealth = 1.0
}

enum Upgrade: String, Codable, CaseIterable, Identifiable {
    case marketing, features, international, reserved, cdnDeal, autoCompute, autoData, autoQuotas
    var id: String { rawValue }

    var title: String {
        switch self {
        case .marketing: "Marketing campaign"
        case .features: "Ship new features"
        case .international: "Expand internationally"
        case .reserved: "Savings Plans"
        case .cdnDeal: "CloudFront private pricing"
        case .autoCompute: "Auto Scaling for compute"
        case .autoData: "Auto scaling for data"
        case .autoQuotas: "Quota automation"
        }
    }
    var symbol: String {
        switch self {
        case .marketing: "megaphone.fill"; case .features: "sparkles"; case .international: "globe.europe.africa.fill"
        case .reserved: "percent"; case .cdnDeal: "bolt.horizontal.fill"
        case .autoCompute: "server.rack"; case .autoData: "cylinder.split.1x2.fill"; case .autoQuotas: "gauge.with.needle.fill"
        }
    }
    var detail: String {
        switch self {
        case .marketing: "+12% growth per level"
        case .features: "+10% revenue per user per level"
        case .international: "Market ×2.5 per level"
        case .reserved: "−30% on servers, databases and caches"
        case .cdnDeal: "−40% on CloudFront data transfer"
        case .autoCompute: "Keeps EC2/ECS/EKS/Lambda/Fargate counts at ~65% load"
        case .autoData: "Keeps databases, caches, search and queues at ~65% load"
        case .autoQuotas: "Raises CloudFront, API Gateway, SNS, SES… quotas ahead of demand"
        }
    }
    var maxLevel: Int {
        switch self { case .marketing: 12; case .features: 10; case .international: 3; default: 1 }
    }
    var unlockUsers: Double {
        switch self {
        case .marketing, .features: 0
        case .reserved, .autoCompute: 1_000
        case .international, .autoData, .autoQuotas: 10_000
        case .cdnDeal: 1_000_000
        }
    }
    func cost(level: Int) -> Double {
        switch self {
        case .marketing: 400 * pow(2.6, Double(level))
        case .features: 600 * pow(2.8, Double(level))
        case .international: 25_000 * pow(6, Double(level))
        case .reserved: 5_000
        case .cdnDeal: 200_000
        case .autoCompute: 2_000
        case .autoData: 5_000
        case .autoQuotas: 10_000
        }
    }
}

enum Funding: String, Codable, CaseIterable, Identifiable {
    case seed, seriesA, seriesB
    var id: String { rawValue }
    var title: String { switch self { case .seed: "Seed round"; case .seriesA: "Series A"; case .seriesB: "Series B" } }
    var minUsers: Double { switch self { case .seed: 1_000; case .seriesA: 50_000; case .seriesB: 1_000_000 } }
    var cash: Double { switch self { case .seed: 25_000; case .seriesA: 1_000_000; case .seriesB: 20_000_000 } }
    var dilution: Double { switch self { case .seed: 0.15; case .seriesA: 0.2; case .seriesB: 0.2 } }
}

// MARK: - State

struct TycoonState: Codable {
    var business: Business
    var frontend: Frontend
    var stack: Stack
    var company: String
    var cash: Double
    var users: Double
    /// Game hours since founding (1 real second = 1 game hour at 1×).
    var hour: Double
    var design: Design
    var upgrades: [String: Int] = [:]
    var funding: [String] = []
    /// Founder's share of the company.
    var equity = 1.0
    var spike: Spike?
    var nextSpike: Double
    var totalRevenue = 0.0
    /// Last known rates, for offline progress.
    var netPerHour = 0.0
    var growthPerHour = 0.0
    var lastSaved = Date()
    /// Carried across companies: each point is +10% growth and revenue.
    var founderPoints = 0.0
    var ipos = 0

    func level(_ u: Upgrade) -> Int { upgrades[u.rawValue] ?? 0 }
    var day: Int { Int(hour / 24) + 1 }
    var timeOfDay: Double { hour.truncatingRemainder(dividingBy: 24) / 24 }
}

// MARK: - Rules

enum Tycoon {
    static let startingCash = 3_000.0
    static let startingUsers = 200.0
    static let ipoValuation = 1_000_000_000.0
    /// Spike warning time, game hours.
    static let warning = 24.0

    static let unlocks: [(users: Double, kinds: [ServiceKind])] = [
        (0, [.route53, .cloudFront, .s3, .ec2, .lambda, .apiGateway, .dynamoDB, .rds, .alb]),
        (1_000, [.elastiCache, .sqs, .sns, .ses, .cognito, .fargate]),
        (10_000, [.ecs, .appRunner, .aurora, .eventBridge, .waf, .kinesis, .firehose, .endUserMessaging, .appSync, .stepFunctions]),
        (100_000, [.eks, .nlb, .dax, .openSearch, .neptune, .memoryDB, .mediaConvert, .globalAccelerator]),
        (1_000_000, [.auroraDSQL, .msk, .mediaLive, .mediaPackage, .ivs]),
    ]

    static func available(_ s: TycoonState) -> Set<ServiceKind> {
        var set = Set(unlocks.filter { s.users >= $0.users }.flatMap(\.kinds))
        set.formUnion(s.business.startUnlocks)
        return set
    }

    static func unlockThreshold(_ kind: ServiceKind) -> Double? {
        unlocks.first { $0.kinds.contains(kind) }?.users
    }

    static func nextMilestone(_ s: TycoonState) -> (users: Double, kinds: [ServiceKind])? {
        unlocks.first { $0.users > s.users }
    }

    static func founderBonus(_ s: TycoonState) -> Double { 1 + 0.1 * s.founderPoints }

    static func marketCap(_ s: TycoonState) -> Double { s.business.marketCap * pow(2.5, Double(s.level(.international))) }

    static func profile(_ s: TycoonState) -> Profile {
        var p = s.business.profile
        p.apiPerUser *= s.frontend.apiMultiplier
        p.cdnCacheable = min(0.8, max(0, p.cdnCacheable + s.frontend.cacheDelta))
        if p.eventsPerAPI > 0 { p.notificationsPerEvent += s.frontend.extraNotifications }
        if let spike = s.spike, spike.start <= s.hour { p.surgeBots = max(p.surgeBots, spike.bots) }
        return p
    }

    static func spikeMultiplier(_ s: TycoonState) -> Double {
        guard let spike = s.spike, spike.start <= s.hour, s.hour < spike.end else { return 1 }
        return spike.multiplier
    }

    /// Users online at today's evening peak.
    static func peakOnline(_ s: TycoonState, multiplier: Double? = nil) -> Double {
        s.users * s.business.onlineShare * (multiplier ?? spikeMultiplier(s))
    }

    /// The simulator's view of the company: a day-long "event" at the current size.
    static func mission(_ s: TycoonState, multiplier: Double? = nil, monthlyRevenue: Double = 0) -> Mission {
        var m = Mission(id: "tycoon", track: .basics, difficulty: .easy, title: s.company, tagline: s.business.title,
                        brief: s.business.pitch, phases: ["Night", "Morning", "Afternoon", "Evening peak", "Late night"],
                        audience: s.business.noun, peakUsers: max(peakOnline(s, multiplier: multiplier), 1), eventHours: 720,
                        budget: max(monthlyRevenue, 1), profile: profile(s), realSeconds: 24)
        m.daily = true
        m.surging = (multiplier ?? spikeMultiplier(s)) > 1
        m.computeMultiplier = s.stack.perf
        m.available = available(s)
        return m
    }

    static func revenuePerHour(_ s: TycoonState, health: Double) -> Double {
        s.users * s.business.arpuDay / 24 * s.frontend.arpu * pow(1.1, Double(s.level(.features))) * founderBonus(s) * health
    }

    /// Net change in users per hour: logistic growth when the service holds, churn when it doesn't.
    static func growthPerHour(_ s: TycoonState, health: Double) -> Double {
        let g = s.business.growthDay * s.frontend.growth * s.stack.devSpeed * (1 + 0.12 * Double(s.level(.marketing))) * founderBonus(s) / 24
        let room = max(0, 1 - s.users / marketCap(s))
        // Launch buzz: early adopters spread the word fast, fading out by ~10k users.
        let buzz = 1 + 2 * max(0, 1 - log10(max(s.users, 1)) / 4)
        let growth = s.users * g * buzz * room * (health >= 0.99 ? 1 : health * health)
        let churn = health < 0.99 ? s.users * 0.15 / 24 * (1 - health) * s.frontend.churn : 0
        return growth - churn
    }

    /// Monthly AWS bill after Savings Plans / private pricing.
    static func monthlyCost(_ lines: [CostLine], _ s: TycoonState) -> Double {
        lines.reduce(0) { sum, l in
            var fixed = l.fixed, usage = l.usage
            if s.level(.reserved) > 0, [.compute, .database, .cache, .search].contains(l.node.spec.role) { fixed *= 0.7 }
            if s.level(.cdnDeal) > 0, l.node.kind == .cloudFront { usage *= 0.6 }
            return sum + fixed + usage
        }
    }

    static func valuation(revenuePerDay: Double) -> Double { revenuePerDay * 365 * 8 }

    static func randomSpike(_ s: TycoonState) -> Spike {
        let t = s.business.spikes.randomElement()!
        let start = s.nextSpike
        return Spike(name: t.name, multiplier: t.multiplier, start: start, end: start + t.hours, bots: t.bots)
    }

    /// Roles each automation upgrade manages.
    static func managed(_ u: Upgrade) -> (Node) -> Bool {
        switch u {
        case .autoCompute: { $0.spec.role == .compute && ![.stepFunctions, .appSync].contains($0.kind) }
        case .autoData: { [.database, .cache, .search].contains($0.spec.role) || $0.kind == .msk }
        case .autoQuotas: { n in
            [.cloudFront, .apiGateway, .appSync, .stepFunctions, .sns, .eventBridge, .ses, .endUserMessaging, .cognito,
             .kinesis, .firehose, .s3, .mediaPackage, .ivs, .alb, .nlb].contains(n.kind) }
        default: { _ in false }
        }
    }
}
