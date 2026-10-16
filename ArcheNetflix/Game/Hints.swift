import Foundation

struct Hint: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// Service the hint is about, so tapping it can focus the board there.
    let node: UUID?
    let fromAI: Bool
}

/// "What should I do next?" — asks OpenAI with a summary of the board, and falls back to the
/// simulator's own diagnosis when there's no key or no network.
enum Hints {
    static func next(design: Design, mission: Mission, forecast: Forecast, costs: [CostLine], tutorialStep: Int) async -> Hint {
        let offline = offlineHint(design: design, mission: mission, forecast: forecast, costs: costs, tutorialStep: tutorialStep)
        guard !Secrets.openAIKey.isEmpty,
              let text = try? await ask(context(design: design, mission: mission, forecast: forecast, costs: costs, tutorialStep: tutorialStep)) else {
            return offline
        }
        // Point at the service the AI talks about, if it names one on the board.
        let named = design.nodes.filter { $0.kind != .viewers }.sorted { $0.title.count > $1.title.count }.first { text.localizedCaseInsensitiveContains($0.title) }
        return Hint(text: text, node: named?.id ?? offline.node, fromAI: true)
    }

    // MARK: Offline

    static func offlineHint(design: Design, mission: Mission, forecast: Forecast, costs: [CostLine], tutorialStep: Int) -> Hint {
        if mission.steps.indices.contains(tutorialStep) {
            let step = mission.steps[tutorialStep]
            return Hint(text: step.hint, node: nil, fromAI: false)
        }
        if design.nodes.count == 1 {
            return Hint(text: "Start with the video path: add CloudFront, then MediaPackage behind it, and feed MediaPackage from MediaLive.", node: nil, fromAI: false)
        }
        if let issue = forecast.worst.issues.first(where: { $0.severity == .failure }) {
            return Hint(text: issue.text, node: issue.node, fromAI: false)
        }
        let monthly = costs.reduce(0) { $0 + $1.total }
        if monthly > mission.budget {
            // Biggest fixed spend that barely gets used is the easiest saving.
            if let idle = costs.filter({ $0.fixed > 0 && (forecast.peakUtil[$0.id] ?? 0) < 0.5 && $0.node.count > 1 }).max(by: { $0.fixed < $1.fixed }) {
                let util = forecast.peakUtil[idle.id] ?? 0
                return Hint(text: "\(idle.node.title) peaks at only \(Fmt.percent(util)). Trim it to save money, or turn on scheduled scaling in the cost sheet.", node: idle.id, fromAI: false)
            }
            return Hint(text: "You survive but cost \(Fmt.money(monthly))/mo against a \(Fmt.money(mission.budget)) budget. Try scheduled scaling, Origin Shield, or cheaper compute like ECS on EC2.", node: nil, fromAI: false)
        }
        if let warning = forecast.worst.issues.first {
            return Hint(text: warning.text, node: warning.node, fromAI: false)
        }
        return Hint(text: "This design survives the whole event within budget. Let it run to the end to lock in your stars.", node: nil, fromAI: false)
    }

    // MARK: OpenAI

    private static let instructions = """
    You are a friendly AWS solutions architect coaching a player in a game about designing live-streaming architectures.
    The player must serve every viewer through the whole event (99.5%+) within a monthly budget.
    Read the JSON state and give the single most useful NEXT action. Rules:
    - At most 2 short sentences, plain text, no markdown or lists.
    - Name the exact service as it appears in the game and, when scaling, the target count or tier.
    - Only suggest services from `availableServices`. Connections go from `from` to `to`.
    - Fix failures first (the forecast issues), then budget, then resilience.
    - In the tutorial, guide the current tutorial step only.
    """

    private struct Response: Decodable {
        struct Item: Decodable { let type: String; let content: [Content]? }
        struct Content: Decodable { let type: String; let text: String? }
        let output: [Item]
    }

    private static func ask(_ input: [String: Any]) async throws -> String {
        struct Unavailable: Error {}
        let body: [String: Any] = ["model": Secrets.openAIModel, "max_output_tokens": 160, "instructions": instructions,
                                   "input": String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(Secrets.openAIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Unavailable() }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }.compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Unavailable() }
        return text
    }

    private static func context(design: Design, mission: Mission, forecast: Forecast, costs: [CostLine], tutorialStep: Int) -> [String: Any] {
        let names = Dictionary(uniqueKeysWithValues: design.nodes.map { ($0.id, $0.title) })
        let peak = forecast.peak.demand
        var state: [String: Any] = [
            "mission": ["title": mission.title, "difficulty": mission.difficulty.rawValue, "brief": mission.brief,
                        "peakViewers": mission.peakViewers, "bitrateMbps": mission.bitrateMbps, "monthlyBudget": mission.budget,
                        "viewersAlsoUseAPI": mission.hasAPI],
            "peakDemand": ["videoGbps": peak.load[.video].rounded(), "apiRequestsPerSecond": peak.load[.api].rounded(), "botShare": peak.botShare],
            "services": design.nodes.map { n -> [String: Any] in
                ["name": n.title, "count": n.count, "unit": n.spec.unit, "tier": n.tierSpec.name,
                 "capacityPerUnit": n.tierSpec.capacity.isFinite ? n.tierSpec.capacity : "unlimited",
                 "peakUtilization": ((forecast.peakUtil[n.id] ?? 0) * 100).rounded() / 100,
                 "originShield": n.originShield]
            },
            "connections": design.edges.compactMap { e -> [String: String]? in
                guard let a = names[e.from], let b = names[e.to] else { return nil }
                return ["from": a, "to": b]
            },
            "forecast": ["worstServedShare": (forecast.minHealth * 1000).rounded() / 1000, "worstPhase": forecast.worstPhase,
                         "issues": forecast.worst.issues.prefix(6).map(\.text)],
            "monthlyCost": costs.reduce(0) { $0 + $1.total }.rounded(),
            "scheduledScaling": design.scheduledScaling,
            "availableServices": ServiceKind.buildable.map { "\($0.spec.name): \($0.spec.blurb)" },
        ]
        if mission.steps.indices.contains(tutorialStep) {
            state["tutorialStep"] = ["title": mission.steps[tutorialStep].title, "hint": mission.steps[tutorialStep].hint]
        }
        return state
    }
}
