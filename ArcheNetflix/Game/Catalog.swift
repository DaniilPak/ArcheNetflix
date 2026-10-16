import SwiftUI

/// The four kinds of traffic that flow through an architecture.
enum TrafficClass: Int, CaseIterable {
    case video, api, reads, writes

    var title: String {
        switch self {
        case .video: "Video"
        case .api: "API"
        case .reads: "DB reads"
        case .writes: "DB writes"
        }
    }

    var noun: String {
        switch self {
        case .video: "video segments"
        case .api: "API requests"
        case .reads: "database reads"
        case .writes: "database writes"
        }
    }
}

/// A value per traffic class (load, capacity or success ratio).
struct Load {
    var values: [Double] = [0, 0, 0, 0]
    subscript(c: TrafficClass) -> Double {
        get { values[c.rawValue] }
        set { values[c.rawValue] = newValue }
    }
    static let infinite = Load(values: Array(repeating: .infinity, count: 4))
    static let one = Load(values: [1, 1, 1, 1])
}

enum Category: String, CaseIterable {
    case networking = "Networking & CDN"
    case security = "Security"
    case compute = "Compute"
    case database = "Database & Cache"
    case integration = "App Integration"
    case storage = "Storage"
    case media = "Media Services"

    /// AWS Architecture Icon category colours.
    var color: Color {
        switch self {
        case .networking: Color(hex: 0x8c4fff)
        case .security: Color(hex: 0xdd344c)
        case .compute: Color(hex: 0xed7100)
        case .database: Color(hex: 0xc925d1)
        case .integration: Color(hex: 0xe7157b)
        case .storage: Color(hex: 0x7aa116)
        case .media: Color(hex: 0x01a88d)
        }
    }
}

enum Role { case viewers, router, firewall, cdn, compute, cache, queue, database, origin, encoder }

struct Tier: Hashable {
    let name: String
    /// Capacity of one unit in the role's main traffic class (Gbps for video, req/s or ops/s otherwise).
    let capacity: Double
    /// On-demand price of one unit for a full month (730 h).
    let monthly: Double
}

enum ServiceKind: String, Codable, CaseIterable, Identifiable {
    case viewers, route53, cloudFront, globalAccelerator, alb, nlb, waf, apiGateway
    case ec2, ecs, fargate, eks, lambda, appRunner
    case elastiCache, dax, dynamoDB, aurora, auroraDSQL, rds, memoryDB
    case sqs, kinesis, s3, mediaLive, mediaPackage, ivs
    var id: String { rawValue }
    var spec: ServiceSpec { ServiceSpec.all[self]! }
    static var buildable: [ServiceKind] { allCases.filter { $0 != .viewers } }
}

struct ServiceSpec {
    let name: String
    let category: Category
    let symbol: String
    let role: Role
    let unit: String
    let blurb: String
    let tiers: [Tier]
    let maxCount: Int
    let defaultCount: Int
    /// Instance-hours that can be cut with scheduled scaling around the event.
    var schedulable = false
    /// Compute that only spreads traffic over its units when a load balancer sits in front.
    var needsLoadBalancer = false
    /// Relational engines where extra instances are read replicas and only one instance writes.
    var singleWriter = false
    /// Serves video with its own built-in live encoder (no MediaLive needed).
    var builtInLive = false
    /// Flat monthly charge on top of the per-unit price (e.g. the EKS control plane).
    var baseMonthly = 0.0

    var color: Color { category.color }

    // Approximate us-east-1 on-demand list prices.
    static let all: [ServiceKind: ServiceSpec] = [
        .viewers: ServiceSpec(name: "Viewers", category: .networking, symbol: "person.3.fill", role: .viewers, unit: "",
                              blurb: "Everyone tuning in. Every viewer pulls a live video stream and sends a heartbeat API call every 30 s; joining costs ~20 API calls.",
                              tiers: [Tier(name: "Internet", capacity: .infinity, monthly: 0)], maxCount: 1, defaultCount: 1),
        .route53: ServiceSpec(name: "Route 53", category: .networking, symbol: "globe", role: .router, unit: "hosted zone",
                              blurb: "DNS. Points viewers at your CloudFront distribution. Scales without limits.",
                              tiers: [Tier(name: "Hosted zone + health checks", capacity: .infinity, monthly: 25)], maxCount: 1, defaultCount: 1),
        .cloudFront: ServiceSpec(name: "CloudFront", category: .networking, symbol: "bolt.horizontal.fill", role: .cdn, unit: "× 10 Tbps quota",
                                 blurb: "CDN with 600+ edge locations. Caches ~98% of live video segments and 15% of API calls. Default quota is tiny for an event this size — request more bandwidth. Origin Shield collapses misses to 0.3%.",
                                 tiers: [Tier(name: "10 Tbps bandwidth quota", capacity: 10_000, monthly: 0)], maxCount: 30, defaultCount: 1),
        .waf: ServiceSpec(name: "WAF + Shield", category: .security, symbol: "shield.lefthalf.filled", role: .firewall, unit: "web ACL",
                          blurb: "Blocks bots, credential stuffing and DDoS. Big events attract up to 25% junk API traffic that otherwise hits your servers.",
                          tiers: [Tier(name: "Web ACL + Shield Advanced", capacity: 5_000_000, monthly: 3_020)], maxCount: 1, defaultCount: 1),
        .alb: ServiceSpec(name: "Application LB", category: .networking, symbol: "arrow.triangle.branch", role: .router, unit: "pre-warmed ALB",
                          blurb: "Application Load Balancer. Spreads API traffic across every instance behind it. Each pre-warmed ALB handles ~100k req/s.",
                          tiers: [Tier(name: "ALB · 100k req/s pre-warmed", capacity: 100_000, monthly: 22)], maxCount: 50, defaultCount: 1),
        .apiGateway: ServiceSpec(name: "API Gateway", category: .integration, symbol: "point.3.connected.trianglepath.dotted", role: .router, unit: "× 10k req/s quota",
                                 blurb: "Managed HTTP API front door. Pay per request. Account throttle defaults to 10k req/s — raise the quota for big events.",
                                 tiers: [Tier(name: "10k req/s throttle quota", capacity: 10_000, monthly: 0)], maxCount: 200, defaultCount: 1),
        .ec2: ServiceSpec(name: "EC2 · Node.js", category: .compute, symbol: "server.rack", role: .compute, unit: "instances",
                          blurb: "Node.js API servers on Graviton. Handles auth, entitlements, playback sessions and heartbeats. Needs a load balancer to use more than one instance.",
                          tiers: [Tier(name: "c7g.large · 2 vCPU", capacity: 2_000, monthly: 52.9),
                                  Tier(name: "c7g.xlarge · 4 vCPU", capacity: 4_000, monthly: 105.9),
                                  Tier(name: "c7g.2xlarge · 8 vCPU", capacity: 8_000, monthly: 211.7),
                                  Tier(name: "c7g.4xlarge · 16 vCPU", capacity: 16_000, monthly: 423.4)],
                          maxCount: 5_000, defaultCount: 2, schedulable: true, needsLoadBalancer: true),
        .fargate: ServiceSpec(name: "ECS Fargate", category: .compute, symbol: "shippingbox.fill", role: .compute, unit: "tasks",
                              blurb: "Serverless containers running the same Node.js API. No servers to patch. Needs a load balancer to spread traffic.",
                              tiers: [Tier(name: "0.5 vCPU · 1 GB", capacity: 1_000, monthly: 14.4),
                                      Tier(name: "1 vCPU · 2 GB", capacity: 2_000, monthly: 28.8),
                                      Tier(name: "2 vCPU · 4 GB", capacity: 4_000, monthly: 57.7)],
                              maxCount: 5_000, defaultCount: 4, schedulable: true, needsLoadBalancer: true),
        .lambda: ServiceSpec(name: "Lambda", category: .compute, symbol: "function", role: .compute, unit: "× 1k concurrency",
                             blurb: "Functions that scale per request. 1,000 concurrent executions ≈ 20k req/s at 50 ms. Pay per invocation.",
                             tiers: [Tier(name: "1,000 concurrency quota", capacity: 20_000, monthly: 0)], maxCount: 100, defaultCount: 1),
        .elastiCache: ServiceSpec(name: "ElastiCache Valkey", category: .database, symbol: "memorychip.fill", role: .cache, unit: "shards",
                                  blurb: "In-memory cache (Valkey, the open-source Redis successor). Serves 90% of reads — sessions, entitlements, profiles — before they reach the database.",
                                  tiers: [Tier(name: "cache.r7g.large", capacity: 100_000, monthly: 128),
                                          Tier(name: "cache.r7g.xlarge", capacity: 200_000, monthly: 256),
                                          Tier(name: "cache.r7g.2xlarge", capacity: 400_000, monthly: 512)],
                                  maxCount: 500, defaultCount: 1, schedulable: true),
        .dynamoDB: ServiceSpec(name: "DynamoDB", category: .database, symbol: "tablecells.fill", role: .database, unit: "× 40k ops/s quota",
                               blurb: "Serverless key-value database. On-demand, pay per request. Table quota is 40k ops/s — raise it for spikes.",
                               tiers: [Tier(name: "On-demand · 40k ops/s quota", capacity: 40_000, monthly: 0)], maxCount: 100, defaultCount: 1),
        .aurora: ServiceSpec(name: "Aurora Postgres", category: .database, symbol: "cylinder.split.1x2.fill", role: .database, unit: "instances",
                             blurb: "Relational database. Extra instances become read replicas, but only the single writer takes writes.",
                             tiers: [Tier(name: "db.r7g.large", capacity: 5_000, monthly: 190),
                                     Tier(name: "db.r7g.xlarge", capacity: 10_000, monthly: 380),
                                     Tier(name: "db.r7g.2xlarge", capacity: 20_000, monthly: 760),
                                     Tier(name: "db.r7g.4xlarge", capacity: 40_000, monthly: 1_520)],
                             maxCount: 16, defaultCount: 1, singleWriter: true),
        .sqs: ServiceSpec(name: "SQS", category: .integration, symbol: "tray.full.fill", role: .queue, unit: "queue",
                          blurb: "Queue that absorbs write bursts (watch progress, analytics). The database drains it at a steady ~35% of the peak rate.",
                          tiers: [Tier(name: "Standard queue", capacity: .infinity, monthly: 0)], maxCount: 1, defaultCount: 1),

        // Networking
        .globalAccelerator: ServiceSpec(name: "Global Accelerator", category: .networking, symbol: "globe.americas.fill", role: .router, unit: "accelerator",
                                        blurb: "Two static anycast IPs that carry API traffic over the AWS backbone to your load balancers. Faster logins worldwide; no caching.",
                                        tiers: [Tier(name: "Standard accelerator", capacity: .infinity, monthly: 18)], maxCount: 1, defaultCount: 1),
        .nlb: ServiceSpec(name: "Network LB", category: .networking, symbol: "arrow.left.arrow.right", role: .router, unit: "NLBs",
                          blurb: "Layer-4 load balancer. Millions of requests per second with ultra-low latency, but no path-based routing. ~500k req/s each.",
                          tiers: [Tier(name: "NLB · 500k req/s", capacity: 500_000, monthly: 16)], maxCount: 20, defaultCount: 1),

        // Compute
        .ecs: ServiceSpec(name: "ECS on EC2", category: .compute, symbol: "square.grid.3x3.fill", role: .compute, unit: "tasks",
                          blurb: "Containers scheduled by ECS onto your own Graviton instances. Cheaper than Fargate per vCPU, but you manage the capacity. Needs a load balancer.",
                          tiers: [Tier(name: "1 vCPU task on c7g", capacity: 2_000, monthly: 26.5),
                                  Tier(name: "2 vCPU task on c7g", capacity: 4_000, monthly: 53)],
                          maxCount: 5_000, defaultCount: 4, schedulable: true, needsLoadBalancer: true),
        .eks: ServiceSpec(name: "EKS", category: .compute, symbol: "steeringwheel", role: .compute, unit: "pods",
                          blurb: "Managed Kubernetes. Run the API as pods on managed node groups, scaled by Karpenter. $73/mo control plane. Exposed through an ALB or NLB.",
                          tiers: [Tier(name: "1 vCPU pod on m7g", capacity: 2_000, monthly: 30),
                                  Tier(name: "2 vCPU pod on m7g", capacity: 4_000, monthly: 60),
                                  Tier(name: "4 vCPU pod on m7g", capacity: 8_000, monthly: 120)],
                          maxCount: 5_000, defaultCount: 6, schedulable: true, needsLoadBalancer: true, baseMonthly: 73),
        .appRunner: ServiceSpec(name: "App Runner", category: .compute, symbol: "figure.run", role: .compute, unit: "instances",
                                blurb: "Push a container, get an HTTPS service with its own load balancer and autoscaling. Simple, but capped at 25 instances per service.",
                                tiers: [Tier(name: "1 vCPU · 2 GB", capacity: 1_500, monthly: 57),
                                        Tier(name: "2 vCPU · 4 GB", capacity: 3_000, monthly: 114)],
                                maxCount: 25, defaultCount: 2, schedulable: true),

        // Databases & caches
        .dax: ServiceSpec(name: "DynamoDB DAX", category: .database, symbol: "hare.fill", role: .cache, unit: "nodes",
                          blurb: "In-memory accelerator in front of DynamoDB. Microsecond reads, 90% hit rate. Writes go straight to DynamoDB.",
                          tiers: [Tier(name: "dax.r5.large", capacity: 100_000, monthly: 196),
                                  Tier(name: "dax.r5.xlarge", capacity: 200_000, monthly: 393)],
                          maxCount: 11, defaultCount: 3, schedulable: true),
        .auroraDSQL: ServiceSpec(name: "Aurora DSQL", category: .database, symbol: "point.3.filled.connected.trianglepath.dotted", role: .database, unit: "× 25k ops/s quota",
                                 blurb: "Serverless, distributed PostgreSQL-compatible database. Reads and writes scale out — no single writer. Pay per request.",
                                 tiers: [Tier(name: "Serverless · 25k ops/s quota", capacity: 25_000, monthly: 0)], maxCount: 100, defaultCount: 1),
        .rds: ServiceSpec(name: "RDS Postgres", category: .database, symbol: "externaldrive.fill", role: .database, unit: "instances",
                          blurb: "Classic managed PostgreSQL. Cheaper than Aurora, but extra instances are read replicas — one writer takes every write.",
                          tiers: [Tier(name: "db.m7g.large", capacity: 4_000, monthly: 120),
                                  Tier(name: "db.m7g.xlarge", capacity: 8_000, monthly: 240),
                                  Tier(name: "db.m7g.2xlarge", capacity: 16_000, monthly: 480),
                                  Tier(name: "db.m7g.4xlarge", capacity: 32_000, monthly: 960)],
                          maxCount: 16, defaultCount: 1, singleWriter: true),
        .memoryDB: ServiceSpec(name: "MemoryDB", category: .database, symbol: "cpu.fill", role: .database, unit: "shards",
                               blurb: "Durable in-memory database (Valkey API). Primary store for sessions and watch state with cache-like speed. Reads and writes share each shard.",
                               tiers: [Tier(name: "db.r7g.large", capacity: 100_000, monthly: 225),
                                       Tier(name: "db.r7g.xlarge", capacity: 200_000, monthly: 450)],
                               maxCount: 500, defaultCount: 2),

        // Streaming
        .kinesis: ServiceSpec(name: "Kinesis Streams", category: .integration, symbol: "water.waves", role: .queue, unit: "streams",
                              blurb: "On-demand data stream for heartbeats and analytics events. Absorbs write bursts like SQS; ~200k records/s per stream.",
                              tiers: [Tier(name: "On-demand stream", capacity: 200_000, monthly: 29)], maxCount: 50, defaultCount: 1),

        // Media
        .ivs: ServiceSpec(name: "IVS", category: .media, symbol: "play.tv.fill", role: .origin, unit: "× 100k viewers quota",
                          blurb: "Amazon Interactive Video Service: ingest, encoding and global delivery in one. Point viewers straight at it — no MediaLive or CloudFront needed. Priced per viewer-hour.",
                          tiers: [Tier(name: "Standard channel · ~400 Gbps quota", capacity: 400, monthly: 0)], maxCount: 50, defaultCount: 1, builtInLive: true),
        .s3: ServiceSpec(name: "S3", category: .storage, symbol: "archivebox.fill", role: .origin, unit: "buckets",
                         blurb: "Object storage. Can act as a video origin if MediaLive writes HLS segments into it. ~100 Gbps per bucket.",
                         tiers: [Tier(name: "Bucket", capacity: 100, monthly: 25)], maxCount: 50, defaultCount: 1),
        .mediaLive: ServiceSpec(name: "MediaLive", category: .media, symbol: "video.fill", role: .encoder, unit: "channels",
                                blurb: "Live encoder. Takes the camera feed from the arena and encodes the adaptive-bitrate stream. Connect it to an origin.",
                                tiers: [Tier(name: "HD channel · 2 pipelines", capacity: 1, monthly: 3_100)], maxCount: 4, defaultCount: 1),
        .mediaPackage: ServiceSpec(name: "MediaPackage", category: .media, symbol: "film.stack.fill", role: .origin, unit: "endpoints",
                                   blurb: "Live video origin. Packages the MediaLive feed into HLS/DASH for CloudFront. ~400 Gbps per endpoint.",
                                   tiers: [Tier(name: "Live origin endpoint", capacity: 400, monthly: 300)], maxCount: 50, defaultCount: 1),
    ]
}

extension ServiceKind {
    func accepts(_ c: TrafficClass) -> Bool {
        switch spec.role {
        case .viewers, .encoder: false
        case .router: self == .route53 ? (c == .video || c == .api) : c == .api
        case .firewall, .cdn: c == .video || c == .api
        case .compute: c == .api
        case .cache: c == .reads
        case .queue: c == .writes
        case .database: c == .reads || c == .writes
        case .origin: c == .video
        }
    }

    /// When a service sends traffic to several children, the highest priority ones get it.
    func priority(_ c: TrafficClass) -> Int {
        switch spec.role {
        case .router where self == .route53: 4
        // An accelerator is added specifically to carry API traffic, so it wins over the CDN.
        case .firewall, .router where self == .globalAccelerator: 3
        case .cdn: 2
        case .cache, .queue: 2
        default: 1
        }
    }

    var isLoadBalancer: Bool { self == .alb || self == .nlb || self == .apiGateway }
}

enum Difficulty: String {
    case tutorial = "Tutorial", easy = "Easy", medium = "Medium", hard = "Hard"

    var color: Color {
        switch self {
        case .tutorial: Color(hex: 0x6cb6ff)
        case .easy: Theme.greenHi
        case .medium: Theme.yellow
        case .hard: Theme.red
        }
    }
}

/// A guided tutorial step, checked off automatically when the design satisfies it.
struct TutorialStep {
    let title: String
    let hint: String
    /// Service to feature at the top of the Add service list during this step.
    var suggested: ServiceKind?
    let done: (Design) -> Bool
}

struct Mission: Identifiable {
    let id: String
    let difficulty: Difficulty
    let title: String
    let tagline: String
    let brief: String
    let mainEvent: String
    let peakViewers: Double
    let bitrateMbps: Double
    let eventHours: Double
    /// Monthly budget for three stars.
    let budget: Double
    /// Whether viewers also hit your API (logins, heartbeats). The tutorial is video only.
    var hasAPI = true
    /// API calls each new viewer makes when joining (login, entitlements, manifest…).
    var joinCalls = 20.0
    /// Share of extra bot traffic during the main-event surge.
    var surgeBots = 0.25
    /// Real seconds one event takes at 1×.
    var realSeconds = 75.0
    var steps: [TutorialStep] = []

    var isTutorial: Bool { !steps.isEmpty }

    static let all: [Mission] = [
        Mission(id: "tutorial", difficulty: .tutorial, title: "First Stream", tagline: "Tutorial · 1k viewers",
                brief: "A local boxing gym streams its sparring night to 1,000 fans. Video only — no logins, no databases. Learn the three services every live stream on AWS needs.",
                mainEvent: "Sparring night", peakViewers: 1_000, bitrateMbps: 3, eventHours: 1, budget: 4_000,
                hasAPI: false, joinCalls: 0, surgeBots: 0, realSeconds: 40, steps: tutorialSteps),
        Mission(id: "premiere", difficulty: .easy, title: "Indie Premiere", tagline: "Easy · 50k viewers",
                brief: "A documentary premieres live and 50,000 fans tune in. Now viewers log in and send heartbeats too, so you'll need servers and a database behind the video. No bots, gentle arrivals.",
                mainEvent: "Premiere", peakViewers: 50_000, bitrateMbps: 4, eventHours: 2, budget: 9_000,
                joinCalls: 5, surgeBots: 0, realSeconds: 60),
        Mission(id: "esports", difficulty: .medium, title: "Esports Final", tagline: "Medium · 2M viewers",
                brief: "Two million fans pile in for the grand final. CloudFront's quota, a single Aurora writer and a burst of logins at the opening ceremony will all bite. Some bots show up too.",
                mainEvent: "Grand final", peakViewers: 2_000_000, bitrateMbps: 5, eventHours: 3, budget: 200_000,
                joinCalls: 12, surgeBots: 0.1),
        Mission(id: "paul-tyson", difficulty: .hard, title: "Paul vs Tyson", tagline: "Hard · 20M viewers",
                brief: "Jake Paul vs Mike Tyson streams live worldwide. 20 million people hit play at the walkout — and they all log in at once, with a wave of bots behind them. Last time, the stream buckled. Design an AWS architecture that survives the spike.",
                mainEvent: "Paul vs Tyson", peakViewers: 20_000_000, bitrateMbps: 5, eventHours: 3, budget: 1_850_000),
    ]

    private static func has(_ d: Design, _ from: ServiceKind, _ to: ServiceKind) -> Bool {
        d.edges.contains { e in d.node(e.from)?.kind == from && d.node(e.to)?.kind == to }
    }

    static let tutorialSteps: [TutorialStep] = [
        TutorialStep(title: "Add CloudFront",
                     hint: "Tap Add service → CloudFront. It's a CDN: it keeps copies of the video close to every viewer.",
                     suggested: .cloudFront,
                     done: { d in d.nodes.contains { $0.kind == .cloudFront } }),
        TutorialStep(title: "Connect Viewers → CloudFront",
                     hint: "Drag the green ⊕ on Viewers and drop it on CloudFront. Arrows show which way traffic flows.",
                     done: { d in has(d, .viewers, .cloudFront) }),
        TutorialStep(title: "Give CloudFront an origin",
                     hint: "Select CloudFront, then Add service → MediaPackage. CloudFront fetches new video segments from it.",
                     suggested: .mediaPackage,
                     done: { d in has(d, .cloudFront, .mediaPackage) }),
        TutorialStep(title: "Feed the origin with MediaLive",
                     hint: "Add MediaLive, then drag its ⊕ onto MediaPackage. MediaLive encodes the camera feed from the gym.",
                     suggested: .mediaLive,
                     done: { d in has(d, .mediaLive, .mediaPackage) }),
        TutorialStep(title: "Survive the stream",
                     hint: "Everything is green. Let the event run to the end — try 4× speed.",
                     done: { _ in false }),
    ]
}
