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
    case viewers, route53, cloudFront, waf, alb, apiGateway, ec2, fargate, lambda, elastiCache, dynamoDB, aurora, sqs, s3, mediaLive, mediaPackage
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
        .alb: ServiceSpec(name: "Load Balancer", category: .networking, symbol: "arrow.triangle.branch", role: .router, unit: "pre-warmed ALB",
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
                          maxCount: 5_000, defaultCount: 2, schedulable: true),
        .fargate: ServiceSpec(name: "ECS Fargate", category: .compute, symbol: "shippingbox.fill", role: .compute, unit: "tasks",
                              blurb: "Serverless containers running the same Node.js API. No servers to patch. Needs a load balancer to spread traffic.",
                              tiers: [Tier(name: "0.5 vCPU · 1 GB", capacity: 1_000, monthly: 14.4),
                                      Tier(name: "1 vCPU · 2 GB", capacity: 2_000, monthly: 28.8),
                                      Tier(name: "2 vCPU · 4 GB", capacity: 4_000, monthly: 57.7)],
                              maxCount: 5_000, defaultCount: 4, schedulable: true),
        .lambda: ServiceSpec(name: "Lambda", category: .compute, symbol: "function", role: .compute, unit: "× 1k concurrency",
                             blurb: "Functions that scale per request. 1,000 concurrent executions ≈ 20k req/s at 50 ms. Pay per invocation.",
                             tiers: [Tier(name: "1,000 concurrency quota", capacity: 20_000, monthly: 0)], maxCount: 100, defaultCount: 1),
        .elastiCache: ServiceSpec(name: "ElastiCache Redis", category: .database, symbol: "memorychip.fill", role: .cache, unit: "shards",
                                  blurb: "In-memory cache. Serves 90% of reads (sessions, entitlements, profiles) before they reach the database.",
                                  tiers: [Tier(name: "cache.r7g.large", capacity: 100_000, monthly: 160),
                                          Tier(name: "cache.r7g.xlarge", capacity: 200_000, monthly: 320),
                                          Tier(name: "cache.r7g.2xlarge", capacity: 400_000, monthly: 640)],
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
                             maxCount: 16, defaultCount: 1),
        .sqs: ServiceSpec(name: "SQS", category: .integration, symbol: "tray.full.fill", role: .queue, unit: "queue",
                          blurb: "Queue that absorbs write bursts (watch progress, analytics). The database drains it at a steady ~35% of the peak rate.",
                          tiers: [Tier(name: "Standard queue", capacity: .infinity, monthly: 0)], maxCount: 1, defaultCount: 1),
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
        case .firewall: 3
        case .cdn: 2
        case .cache, .queue: 2
        default: 1
        }
    }

    var isLoadBalancer: Bool { self == .alb || self == .apiGateway }
}

struct Mission: Identifiable {
    let id: String
    let title: String
    let tagline: String
    let brief: String
    let mainEvent: String
    let peakViewers: Double
    let bitrateMbps: Double
    let eventHours: Double
    /// Monthly budget for three stars.
    let budget: Double

    static let all: [Mission] = [
        Mission(id: "premiere", title: "Indie Premiere", tagline: "Warm-up · 50k viewers",
                brief: "A documentary premieres live tonight and 50,000 fans will tune in at once. Build a stream that never buffers and keep the bill small.",
                mainEvent: "Premiere", peakViewers: 50_000, bitrateMbps: 4, eventHours: 2, budget: 9_000),
        Mission(id: "paul-tyson", title: "Paul vs Tyson", tagline: "Main event · 20M viewers",
                brief: "Jake Paul vs Mike Tyson streams live worldwide. 20 million people hit play at the walkout — and they all log in at once. Last time, the stream buckled. Design an AWS architecture that survives the spike.",
                mainEvent: "Paul vs Tyson", peakViewers: 20_000_000, bitrateMbps: 5, eventHours: 3, budget: 1_850_000),
        Mission(id: "final", title: "World Cup Final", tagline: "Endgame · 40M viewers",
                brief: "40 million fans, higher bitrate, two halves and a penalty shoot-out surge. Everything you learned, at twice the scale.",
                mainEvent: "World Cup Final", peakViewers: 40_000_000, bitrateMbps: 6, eventHours: 3, budget: 4_400_000),
    ]
}
