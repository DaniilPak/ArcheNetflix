import SwiftUI

/// Kinds of traffic that flow through an architecture. The first four come from users;
/// the rest are generated inside the system.
enum TrafficClass: Int, CaseIterable {
    case video, api, auth, uploads, reads, writes, events, notifications

    var title: String {
        switch self {
        case .video: "Video"
        case .api: "API"
        case .auth: "Logins"
        case .uploads: "Uploads"
        case .reads: "DB reads"
        case .writes: "DB writes"
        case .events: "Events"
        case .notifications: "Notifications"
        }
    }

    var noun: String {
        switch self {
        case .video: "video"
        case .api: "API requests"
        case .auth: "sign-ins"
        case .uploads: "uploads"
        case .reads: "database reads"
        case .writes: "database writes"
        case .events: "events"
        case .notifications: "notifications"
        }
    }

    /// Classes users send directly; the ones the HUD reports on.
    static let userFacing: [TrafficClass] = [.video, .api, .auth, .uploads]
}

/// A value per traffic class (load, capacity or success ratio).
struct Load {
    var values = [Double](repeating: 0, count: TrafficClass.allCases.count)
    subscript(c: TrafficClass) -> Double {
        get { values[c.rawValue] }
        set { values[c.rawValue] = newValue }
    }
    static let infinite = Load(values: .init(repeating: .infinity, count: TrafficClass.allCases.count))
    static let one = Load(values: .init(repeating: 1, count: TrafficClass.allCases.count))
}

enum Category: String, CaseIterable {
    case networking = "Networking & CDN"
    case security = "Security & Identity"
    case compute = "Compute"
    case database = "Databases & Caches"
    case integration = "Messaging & Events"
    case messaging = "Customer Messaging"
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
        case .messaging: Color(hex: 0x2e73b8)
        case .storage: Color(hex: 0x7aa116)
        case .media: Color(hex: 0x01a88d)
        }
    }
}

enum Role {
    case viewers, dns, router, firewall, cdn, compute, auth, cache, queue, pubsub, database, search, origin, storage, encoder, processor, notifier
}

struct Tier: Hashable {
    let name: String
    /// Capacity of one unit in the role's main traffic class (Gbps for video, per second otherwise).
    let capacity: Double
    /// On-demand price of one unit for a full month (730 h).
    let monthly: Double
}

enum ServiceKind: String, Codable, CaseIterable, Identifiable {
    case viewers, route53, cloudFront, globalAccelerator, alb, nlb, apiGateway, appSync
    case waf, cognito
    case ec2, ecs, fargate, eks, lambda, appRunner, stepFunctions
    case elastiCache, dax, dynamoDB, aurora, auroraDSQL, rds, memoryDB, neptune, openSearch
    case sqs, sns, eventBridge, kinesis, msk, firehose
    case ses, endUserMessaging
    case s3, mediaLive, mediaPackage, ivs, mediaConvert
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
    /// S3 only: uploads (PUTs) per second per unit, alongside its video capacity.
    var uploadCapacity = 0.0

    var color: Color { category.color }

    // Approximate us-east-1 on-demand list prices.
    static let all: [ServiceKind: ServiceSpec] = [
        .viewers: ServiceSpec(name: "Users", category: .networking, symbol: "person.3.fill", role: .viewers, unit: "",
                              blurb: "Everyone using your product at once. What they send — video, API calls, sign-ins, uploads — depends on the event.",
                              tiers: [Tier(name: "Internet", capacity: .infinity, monthly: 0)], maxCount: 1, defaultCount: 1),
        .route53: ServiceSpec(name: "Route 53", category: .networking, symbol: "globe", role: .dns, unit: "hosted zone",
                              blurb: "DNS. Resolves your domain to CloudFront, a load balancer or Global Accelerator. Scales without limits.",
                              tiers: [Tier(name: "Hosted zone + health checks", capacity: .infinity, monthly: 25)], maxCount: 1, defaultCount: 1),
        .cloudFront: ServiceSpec(name: "CloudFront", category: .networking, symbol: "bolt.horizontal.fill", role: .cdn, unit: "× 10 Tbps quota",
                                 blurb: "CDN with 600+ edge locations. Caches ~98% of video and the cacheable share of API calls (product pages, feeds). Forwards uploads to S3. Default quota is tiny for big events — request more bandwidth. Origin Shield collapses misses to 0.3%.",
                                 tiers: [Tier(name: "10 Tbps bandwidth quota", capacity: 10_000, monthly: 0)], maxCount: 60, defaultCount: 1),
        .waf: ServiceSpec(name: "WAF + Shield", category: .security, symbol: "shield.lefthalf.filled", role: .firewall, unit: "web ACL",
                          blurb: "Attach it to CloudFront, a load balancer, API Gateway or AppSync (drag its ⊕ onto them). Blocks bots, scalpers, credential stuffing and DDoS before they reach your servers.",
                          tiers: [Tier(name: "Web ACL + Shield Advanced", capacity: 5_000_000, monthly: 3_020)], maxCount: 1, defaultCount: 1),
        .alb: ServiceSpec(name: "Application LB", category: .networking, symbol: "arrow.triangle.branch", role: .router, unit: "pre-warmed ALB",
                          blurb: "Application Load Balancer. Spreads API and sign-in traffic across EC2, ECS, EKS or Lambda targets behind it. Each pre-warmed ALB handles ~100k req/s.",
                          tiers: [Tier(name: "ALB · 100k req/s pre-warmed", capacity: 100_000, monthly: 22)], maxCount: 50, defaultCount: 1),
        .apiGateway: ServiceSpec(name: "API Gateway", category: .integration, symbol: "point.3.connected.trianglepath.dotted", role: .router, unit: "× 10k req/s quota",
                                 blurb: "Managed HTTP API front door. Pay per request. Account throttle defaults to 10k req/s — raise the quota for big events.",
                                 tiers: [Tier(name: "10k req/s throttle quota", capacity: 10_000, monthly: 0)], maxCount: 200, defaultCount: 1),
        .ec2: ServiceSpec(name: "EC2 · Node.js", category: .compute, symbol: "server.rack", role: .compute, unit: "instances",
                          blurb: "Node.js servers on Graviton. Serve the API, or poll a queue as workers. Behind a load balancer every instance takes API traffic; without one only one does.",
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
                             blurb: "Functions that scale per request: behind API Gateway or an ALB, or triggered by SQS, SNS, EventBridge, Kinesis or S3. 1,000 concurrency ≈ 20k req/s at 50 ms.",
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
                          blurb: "Message queue. Absorbs bursts of events or writes; consumers (Lambda, ECS, EC2 workers) drain it at a steady ~35% of the peak rate. Nearly unlimited throughput.",
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
                              blurb: "On-demand data stream for clicks, views and analytics events. Consumers like Lambda or Firehose read it in order; ~200k records/s per stream.",
                              tiers: [Tier(name: "On-demand stream", capacity: 200_000, monthly: 29)], maxCount: 50, defaultCount: 1),

        // Front doors & identity
        .appSync: ServiceSpec(name: "AppSync", category: .networking, symbol: "arrow.triangle.2.circlepath", role: .compute, unit: "× 10k req/s quota",
                              blurb: "Managed GraphQL and real-time API. Resolvers talk straight to DynamoDB, Lambda or Aurora — no servers or load balancer. Pay per request.",
                              tiers: [Tier(name: "10k req/s quota", capacity: 10_000, monthly: 0)], maxCount: 100, defaultCount: 1),
        .cognito: ServiceSpec(name: "Cognito", category: .security, symbol: "person.badge.key.fill", role: .auth, unit: "× 1k sign-ins/s quota",
                              blurb: "User sign-up and sign-in. Apps call it directly, so logins never touch your servers. Sign-in rate is a quota — raise it before a launch. Priced per monthly active user.",
                              tiers: [Tier(name: "1k sign-ins/s quota", capacity: 1_000, monthly: 0)], maxCount: 100, defaultCount: 1),

        // Workflows
        .stepFunctions: ServiceSpec(name: "Step Functions", category: .integration, symbol: "flowchart.fill", role: .compute, unit: "× 6k starts/s quota",
                                    blurb: "Express workflows that orchestrate an order or upload end to end: call services, retry, then write results and send notifications. Triggered by EventBridge or API Gateway.",
                                    tiers: [Tier(name: "Express · 6k starts/s quota", capacity: 6_000, monthly: 0)], maxCount: 50, defaultCount: 1),

        // Data
        .neptune: ServiceSpec(name: "Neptune", category: .database, symbol: "circle.hexagongrid.fill", role: .database, unit: "instances",
                              blurb: "Graph database for follows, friends and recommendations. Extra instances are read replicas — one writer.",
                              tiers: [Tier(name: "db.r6g.large", capacity: 8_000, monthly: 254),
                                      Tier(name: "db.r6g.2xlarge", capacity: 32_000, monthly: 1_016)],
                              maxCount: 16, defaultCount: 2, singleWriter: true),
        .openSearch: ServiceSpec(name: "OpenSearch", category: .database, symbol: "magnifyingglass", role: .search, unit: "data nodes",
                                 blurb: "Search and browse: product search, hashtags, feeds. Handles reads only — writes must still land in a database.",
                                 tiers: [Tier(name: "r7g.large.search", capacity: 3_000, monthly: 122),
                                         Tier(name: "r7g.2xlarge.search", capacity: 12_000, monthly: 488)],
                                 maxCount: 200, defaultCount: 3, schedulable: true),

        // Messaging & events
        .sns: ServiceSpec(name: "SNS", category: .integration, symbol: "megaphone.fill", role: .pubsub, unit: "× 30k msgs/s quota",
                          blurb: "Pub/sub. Every subscriber (SQS queues, Lambda, Firehose) gets its own copy of each event — classic fan-out. Also delivers mobile push, SMS and email.",
                          tiers: [Tier(name: "Standard topic · 30k/s quota", capacity: 30_000, monthly: 0)], maxCount: 50, defaultCount: 1),
        .eventBridge: ServiceSpec(name: "EventBridge", category: .integration, symbol: "antenna.radiowaves.left.and.right", role: .pubsub, unit: "× 10k events/s quota",
                                  blurb: "Event bus. Rules route each event to every matching target: Lambda, SQS, SNS, Step Functions, Firehose. PutEvents quota is 10k/s by default.",
                                  tiers: [Tier(name: "Event bus · 10k/s quota", capacity: 10_000, monthly: 0)], maxCount: 50, defaultCount: 1),
        .msk: ServiceSpec(name: "MSK (Kafka)", category: .integration, symbol: "rectangle.3.group.fill", role: .queue, unit: "Express brokers",
                          blurb: "Managed Apache Kafka. Durable, replayable event log for very high throughput. Consumers: Lambda, ECS/EKS workers, Firehose.",
                          tiers: [Tier(name: "express.m7g.large", capacity: 30_000, monthly: 298),
                                  Tier(name: "express.m7g.xlarge", capacity: 60_000, monthly: 596)],
                          maxCount: 30, defaultCount: 3),
        .firehose: ServiceSpec(name: "Data Firehose", category: .integration, symbol: "flame.fill", role: .processor, unit: "streams",
                               blurb: "Loads event streams into S3, Redshift or OpenSearch for analytics. A sink: views, clicks and likes end here.",
                               tiers: [Tier(name: "Delivery stream · 500k records/s", capacity: 500_000, monthly: 0)], maxCount: 20, defaultCount: 1),

        // Customer messaging
        .ses: ServiceSpec(name: "SES", category: .messaging, symbol: "envelope.fill", role: .notifier, unit: "× 1k emails/s quota",
                          blurb: "Simple Email Service: order confirmations, receipts, password resets. Sending rate is a quota you raise before big sales.",
                          tiers: [Tier(name: "1k emails/s quota", capacity: 1_000, monthly: 0)], maxCount: 100, defaultCount: 1),
        .endUserMessaging: ServiceSpec(name: "End User Messaging", category: .messaging, symbol: "bell.badge.fill", role: .notifier, unit: "× 25k msgs/s quota",
                                       blurb: "AWS End User Messaging (Pinpoint's successor for push and SMS): mobile push and SMS at high rates.",
                                       tiers: [Tier(name: "Push/SMS · 25k/s quota", capacity: 25_000, monthly: 0)], maxCount: 100, defaultCount: 1),

        // Media
        .mediaConvert: ServiceSpec(name: "MediaConvert", category: .media, symbol: "wand.and.stars", role: .processor, unit: "reserved slots",
                                   blurb: "Transcodes uploaded videos into streaming formats. Each reserved slot finishes ~20 short clips per second. Triggered by Lambda, Step Functions or EventBridge.",
                                   tiers: [Tier(name: "Reserved transcode slot", capacity: 20, monthly: 400)], maxCount: 500, defaultCount: 5),
        .ivs: ServiceSpec(name: "IVS", category: .media, symbol: "play.tv.fill", role: .origin, unit: "× 100k viewers quota",
                          blurb: "Amazon Interactive Video Service: ingest, encoding and global delivery in one. Point viewers straight at it — no MediaLive or CloudFront needed. Priced per viewer-hour.",
                          tiers: [Tier(name: "Standard channel · ~400 Gbps quota", capacity: 400, monthly: 0)], maxCount: 50, defaultCount: 1, builtInLive: true),
        .s3: ServiceSpec(name: "S3", category: .storage, symbol: "archivebox.fill", role: .storage, unit: "buckets",
                         blurb: "Object storage. Origin for on-demand video and images behind CloudFront, and the landing spot for user uploads. Sends an event per upload to SQS, SNS, EventBridge or Lambda.",
                         tiers: [Tier(name: "Bucket · 100 Gbps · 35k PUT/s", capacity: 100, monthly: 25)], maxCount: 50, defaultCount: 1, uploadCapacity: 35_000),
        .mediaLive: ServiceSpec(name: "MediaLive", category: .media, symbol: "video.fill", role: .encoder, unit: "channels",
                                blurb: "Live encoder. Takes the camera feed from the arena and encodes the adaptive-bitrate stream. Connect it to an origin.",
                                tiers: [Tier(name: "HD channel · 2 pipelines", capacity: 1, monthly: 3_100)], maxCount: 4, defaultCount: 1),
        .mediaPackage: ServiceSpec(name: "MediaPackage", category: .media, symbol: "film.stack.fill", role: .origin, unit: "endpoints",
                                   blurb: "Live video origin. Packages the MediaLive feed into HLS/DASH for CloudFront. ~400 Gbps per endpoint.",
                                   tiers: [Tier(name: "Live origin endpoint", capacity: 400, monthly: 300)], maxCount: 50, defaultCount: 1),
    ]
}

extension ServiceKind {
    /// Traffic a service takes in.
    func accepts(_ c: TrafficClass) -> Bool {
        switch spec.role {
        case .viewers, .encoder, .firewall: false
        case .dns, .cdn: [.video, .api, .auth, .uploads].contains(c)
        case .router: c == .api || c == .auth
        case .compute:
            switch self {
            case .appSync, .appRunner: c == .api || c == .auth
            case .stepFunctions: c == .api || c == .events
            default: c == .api || c == .auth || c == .events
            }
        case .auth: c == .auth
        case .cache, .search: c == .reads
        case .queue: c == .writes || c == .events
        case .pubsub: self == .sns ? (c == .events || c == .notifications) : c == .events
        case .database: c == .reads || c == .writes
        case .origin: c == .video
        case .storage: c == .video || c == .uploads
        case .processor: c == .events
        case .notifier: c == .notifications
        }
    }

    /// Traffic a service can send on (used to decide which connections make sense).
    var emits: Set<TrafficClass> {
        switch spec.role {
        case .viewers: [.video, .api, .auth, .uploads]
        case .dns, .cdn: [.video, .api, .auth, .uploads]
        case .router: [.api, .auth]
        case .compute: [.reads, .writes, .events, .notifications]
        case .cache: [.reads]
        case .queue: [.writes, .events]
        case .pubsub: [.events]
        case .storage: [.events]
        case .encoder: [.video]
        case .auth, .database, .search, .origin, .processor, .notifier, .firewall: []
        }
    }

    /// When a service sends traffic to several children, the highest priority ones get it.
    func priority(_ c: TrafficClass) -> Int {
        switch spec.role {
        case .auth: 5
        case .dns: 4
        // An accelerator is added specifically to carry API traffic, so it wins over the CDN.
        case .router where self == .globalAccelerator: 3
        case .cdn: 2
        case .cache, .search: 2
        case .queue, .pubsub: 2
        default: 1
        }
    }

    var isLoadBalancer: Bool { self == .alb || self == .nlb || self == .apiGateway }

    /// Why a connection from `self` to `target` isn't possible in AWS, or nil when it is.
    func linkProblem(to target: ServiceKind) -> String? {
        let a = spec, b = target.spec
        if target == .viewers { return "Users only send traffic." }
        if self == .waf {
            return [.cloudFront, .alb, .apiGateway, .appSync].contains(target) ? nil
                : "WAF attaches to CloudFront, an Application LB, API Gateway or AppSync."
        }
        if target == .waf { return "WAF isn't a hop — drag from WAF's ⊕ onto what it should protect." }
        if self == .mediaLive {
            return target == .mediaPackage || target == .s3 ? nil : "MediaLive pushes its encoded stream to MediaPackage or S3."
        }
        if target == .mediaLive { return "MediaLive takes the camera feed, not traffic from \(a.name)." }
        if target == .cognito && self != .viewers { return "Apps sign in with Cognito directly — connect Users → Cognito." }
        if self == .s3 && ![.sqs, .sns, .eventBridge, .lambda].contains(target) {
            return "S3 event notifications go to SQS, SNS, EventBridge or Lambda."
        }
        if (self == .sqs || self == .kinesis || self == .msk) && [.appRunner, .appSync, .stepFunctions, .sns, .eventBridge, .sqs].contains(target) {
            return "\(b.name) can't consume from \(a.name). Use Lambda, EC2, ECS, EKS or Firehose."
        }
        if self == .sns && ![.sqs, .lambda, .firehose, .ec2, .ecs, .fargate, .eks].contains(target) {
            return "SNS delivers to SQS, Lambda, Firehose or HTTPS endpoints (EC2/ECS/EKS)."
        }
        if target == .mediaConvert && ![.lambda, .stepFunctions, .eventBridge].contains(self) {
            return "MediaConvert jobs are started by Lambda, Step Functions or EventBridge."
        }
        if target == .ivs && self != .viewers && a.role != .dns { return "Viewers play IVS streams directly." }
        if emits.isDisjoint(with: TrafficClass.allCases.filter { target.accepts($0) }) {
            let sends = emits.map(\.noun).sorted().joined(separator: ", ")
            let takes = TrafficClass.allCases.filter { target.accepts($0) }.map(\.noun).joined(separator: ", ")
            if sends.isEmpty { return "\(a.name) is a final stop — it doesn't send traffic on." }
            return "\(a.name) sends \(sends); \(b.name) takes \(takes.isEmpty ? "nothing" : takes)."
        }
        return nil
    }
}
