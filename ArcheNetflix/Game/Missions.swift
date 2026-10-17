import SwiftUI

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

enum Track: String, CaseIterable {
    case basics = "Start here"
    case streaming = "Live streaming"
    case eventDriven = "Event-driven apps"
}

/// What each active user does, per second. Drives every traffic class in the simulation.
struct Profile {
    /// Video bitrate each user pulls (0 = no video).
    var videoMbps = 0.0
    /// Whether the video is live (needs MediaLive/IVS) or on-demand from S3.
    var liveVideo = true
    /// Steady API calls per user per second (heartbeats, feed refreshes, page views).
    var apiPerUser = 1.0 / 30
    /// Extra API calls each arriving user makes (entitlements, cart, manifest…).
    var joinCalls = 20.0
    /// Sign-ins each arriving user makes.
    var authPerJoin = 0.0
    /// Uploads per user per second (photos, clips).
    var uploadsPerUser = 0.0
    /// Uploads must be processed (resized/transcoded) via an S3 event to count as done.
    var uploadsNeedProcessing = false
    /// Share of API responses CloudFront can cache (product pages, public feeds).
    var cdnCacheable = 0.15
    /// What one API call does inside your system.
    var readsPerAPI = 0.8
    var writesPerAPI = 0.2
    var eventsPerAPI = 0.0
    /// What one event does when a worker processes it.
    var writesPerEvent = 1.0
    var notificationsPerEvent = 0.0
    /// Bots as a share of real API/sign-in traffic during the surge (a fifth of it otherwise).
    var surgeBots = 0.25
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
    let track: Track
    let difficulty: Difficulty
    let title: String
    let tagline: String
    let brief: String
    /// Names of the five phases of the event curve.
    let phases: [String]
    /// What to call the people using it ("viewers", "shoppers", "users").
    let audience: String
    let peakUsers: Double
    let eventHours: Double
    /// Monthly budget for three stars.
    let budget: Double
    let profile: Profile
    /// Real seconds one event takes at 1×.
    var realSeconds = 75.0
    var steps: [TutorialStep] = []

    var isTutorial: Bool { !steps.isEmpty }
    var mainEvent: String { phases[3] }
    var hasAPI: Bool { profile.apiPerUser > 0 || profile.joinCalls > 0 }

    static let streamingPhases = ["Doors open", "Undercard", "Walkout surge"]

    static let all: [Mission] = [
        Mission(id: "tutorial", track: .basics, difficulty: .tutorial, title: "First Stream", tagline: "Tutorial · 1k viewers",
                brief: "A local boxing gym streams its sparring night to 1,000 fans. Video only — no logins, no databases. Learn the three services every live stream on AWS needs.",
                phases: streamingPhases + ["Sparring night", "Post-event"], audience: "viewers", peakUsers: 1_000, eventHours: 1, budget: 4_000,
                profile: Profile(videoMbps: 3, apiPerUser: 0, joinCalls: 0, surgeBots: 0), realSeconds: 40, steps: tutorialSteps),

        // Live streaming
        Mission(id: "premiere", track: .streaming, difficulty: .easy, title: "Indie Premiere", tagline: "Easy · 50k viewers",
                brief: "A documentary premieres live and 50,000 fans tune in. Viewers also log in and send heartbeats, so you'll need servers and a database behind the video. No bots, gentle arrivals.",
                phases: streamingPhases + ["Premiere", "Post-event"], audience: "viewers", peakUsers: 50_000, eventHours: 2, budget: 9_000,
                profile: Profile(videoMbps: 4, joinCalls: 5, surgeBots: 0), realSeconds: 60),
        Mission(id: "esports", track: .streaming, difficulty: .medium, title: "Esports Final", tagline: "Medium · 2M viewers",
                brief: "Two million fans pile in for the grand final. CloudFront's quota, a single Aurora writer and a burst of logins at the opening ceremony will all bite. Some bots show up too.",
                phases: streamingPhases + ["Grand final", "Post-event"], audience: "viewers", peakUsers: 2_000_000, eventHours: 3, budget: 200_000,
                profile: Profile(videoMbps: 5, joinCalls: 12, surgeBots: 0.1)),
        Mission(id: "paul-tyson", track: .streaming, difficulty: .hard, title: "Paul vs Tyson", tagline: "Hard · 60M viewers",
                brief: "Jake Paul vs Mike Tyson streams live worldwide — the real fight peaked at about 60 million concurrent streams. They all hit play at the walkout, all log in at once, with a wave of bots behind them. Design an AWS architecture that survives the spike.",
                phases: streamingPhases + ["Paul vs Tyson", "Post-event"], audience: "viewers", peakUsers: 60_000_000, eventHours: 3, budget: 5_500_000,
                profile: Profile(videoMbps: 5)),

        // Event-driven apps
        Mission(id: "sneaker-drop", track: .eventDriven, difficulty: .easy, title: "Sneaker Drop", tagline: "Easy · 200k shoppers",
                brief: "A limited sneaker release goes live at noon. 200,000 shoppers sign in, hammer product pages and check out at once — and scalper bots join them. Every order must be saved, and every buyer gets a confirmation email. Decouple checkout with a queue so the database isn't flattened.",
                phases: ["Store opens", "Browsing", "Drop goes live", "Checkout rush", "Sold out"], audience: "shoppers", peakUsers: 200_000, eventHours: 2, budget: 4_500,
                profile: Profile(videoMbps: 0, liveVideo: false, apiPerUser: 0.3, joinCalls: 4, authPerJoin: 1, cdnCacheable: 0.4,
                                 readsPerAPI: 0.85, writesPerAPI: 0.05, eventsPerAPI: 0.1, writesPerEvent: 2, notificationsPerEvent: 1, surgeBots: 0.4),
                realSeconds: 60),
        Mission(id: "social-launch", track: .eventDriven, difficulty: .medium, title: "Social App Launch", tagline: "Medium · 3M users",
                brief: "Your photo-sharing app hits #1 on the App Store. Three million people sign up, scroll feeds, post photos and like each other's posts. Uploads must be resized by an S3-triggered worker, and every like sends a push notification. Fan events out with SNS or EventBridge.",
                phases: ["Launch", "Early adopters", "Goes viral", "#1 on the App Store", "Settling"], audience: "users", peakUsers: 3_000_000, eventHours: 3, budget: 55_000,
                profile: Profile(videoMbps: 0.3, liveVideo: false, apiPerUser: 0.2, joinCalls: 8, authPerJoin: 1, uploadsPerUser: 0.0005, uploadsNeedProcessing: true,
                                 cdnCacheable: 0.2, readsPerAPI: 0.9, writesPerAPI: 0.05, eventsPerAPI: 0.15, writesPerEvent: 1, notificationsPerEvent: 1, surgeBots: 0.1)),
        Mission(id: "tiktok-trend", track: .eventDriven, difficulty: .hard, title: "TikTok Trend", tagline: "Hard · 30M users",
                brief: "A dance trend explodes. Thirty million people watch short videos, upload their own takes and like everything in sight. Every upload must be processed after it lands in S3, every view and like streams through your event pipeline, and creators get push notifications. Keep the For You feed fast — and the bill sane.",
                phases: ["Morning scroll", "Trend starts", "Trend explodes", "Peak trend", "Winding down"], audience: "users", peakUsers: 30_000_000, eventHours: 3, budget: 1_200_000,
                profile: Profile(videoMbps: 1.5, liveVideo: false, apiPerUser: 0.15, joinCalls: 10, authPerJoin: 1, uploadsPerUser: 0.0002, uploadsNeedProcessing: true,
                                 cdnCacheable: 0.2, readsPerAPI: 0.6, writesPerAPI: 0.05, eventsPerAPI: 0.35, writesPerEvent: 0.3, notificationsPerEvent: 0.2, surgeBots: 0.2)),
    ]

    private static func has(_ d: Design, _ from: ServiceKind, _ to: ServiceKind) -> Bool {
        d.edges.contains { e in d.node(e.from)?.kind == from && d.node(e.to)?.kind == to }
    }

    static let tutorialSteps: [TutorialStep] = [
        TutorialStep(title: "Add CloudFront",
                     hint: "Tap Add → CloudFront. It's a CDN: it keeps copies of the video close to every viewer.",
                     suggested: .cloudFront,
                     done: { d in d.nodes.contains { $0.kind == .cloudFront } }),
        TutorialStep(title: "Connect Users → CloudFront",
                     hint: "Drag the green ⊕ on Users and drop it on CloudFront. Arrows show which way traffic flows.",
                     done: { d in has(d, .viewers, .cloudFront) }),
        TutorialStep(title: "Give CloudFront an origin",
                     hint: "Select CloudFront, then Add → MediaPackage. CloudFront fetches new video segments from it.",
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
