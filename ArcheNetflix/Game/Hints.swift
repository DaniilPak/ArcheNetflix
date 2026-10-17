import Foundation

struct Hint: Identifiable {
    let id = UUID()
    /// The step to take; nil when there's nothing left to fix.
    let fix: Fix?
    let explanation: String
    let fromAI: Bool
    /// Position in the ranked suggestions, for "Next idea".
    let index: Int
    let total: Int

    var node: UUID? { fix?.action.focus }
}

/// "What should I do next?" The advisor lists only valid, executable steps; the AI picks the most
/// useful one and explains it. Without a key or network, the top step and its reason are used.
enum Hints {
    static func next(_ suggestions: [Suggestion], index: Int = 0, context: [String: Any], useAI: Bool) async -> Hint {
        guard !suggestions.isEmpty else {
            return Hint(fix: nil, explanation: "This design survives the whole event within budget. Let it run to the end to lock in your stars.",
                        fromAI: false, index: 0, total: 0)
        }
        let start = min(index, suggestions.count - 1)
        let offline = Hint(fix: suggestions[start].fix, explanation: suggestions[start].why, fromAI: false, index: start, total: suggestions.count)
        // "Next idea" just walks the ranked list; only the first hint asks the AI to choose.
        guard useAI, start == 0, !Secrets.openAIKey.isEmpty else { return offline }
        let options = Array(suggestions.prefix(6))
        guard let pick = try? await ask(options: options, context: context), options.indices.contains(pick.choice) else { return offline }
        // Keep it short even when the model rambles: at most two sentences.
        // A sentence ends at . ! or ? followed by a space or the end (so "Node.js" and "2.5×" stay whole).
        let sentences = pick.explanation.matches(of: /.+?[.!?](?=\s|$)|.+$/).map { String($0.output) }
        let text = sentences.prefix(2).joined().trimmingCharacters(in: .whitespaces)
        return Hint(fix: options[pick.choice].fix, explanation: text, fromAI: true, index: pick.choice, total: suggestions.count)
    }

    private static let instructions = """
    You coach a player in a game about designing AWS architectures for traffic spikes.
    You get the board state and `options`: valid next steps, already ranked by the simulator (index 0 = most urgent), each with a `reason`.
    Choose index 0 unless a later option clearly fixes a bigger failure first.
    Then explain the chosen step in plain words, max 2 sentences and 35 words: what goes wrong now and how this step fixes it.
    Use the numbers in the reason when helpful. Never mention option numbers, never invent services or steps, no markdown.
    """

    private struct Pick: Decodable { let choice: Int; let explanation: String }
    private struct Response: Decodable {
        struct Item: Decodable { let type: String; let content: [Content]? }
        struct Content: Decodable { let type: String; let text: String? }
        let output: [Item]
    }

    private static func ask(options: [Suggestion], context: [String: Any]) async throws -> Pick {
        struct Unavailable: Error {}
        var input = context
        input["options"] = options.enumerated().map { ["index": $0.offset, "step": $0.element.fix.title, "reason": $0.element.why] }
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["choice": ["type": "integer"], "explanation": ["type": "string"]],
            "required": ["choice", "explanation"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": Secrets.openAIModel, "max_output_tokens": 200, "instructions": instructions,
            "input": String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self),
            "text": ["format": ["type": "json_schema", "name": "hint", "schema": schema, "strict": true]],
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(Secrets.openAIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Unavailable() }
        let text = try JSONDecoder().decode(Response.self, from: data).output
            .filter { $0.type == "message" }.flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }.compactMap(\.text).joined()
        return try JSONDecoder().decode(Pick.self, from: Data(text.utf8))
    }

    /// A compact summary of the board for the AI.
    static func context(design: Design, mission: Mission, forecast: Forecast, costs: [CostLine]) -> [String: Any] {
        let names = Dictionary(uniqueKeysWithValues: design.nodes.map { ($0.id, $0.title) })
        return [
            "mission": ["title": mission.title, "brief": mission.brief, "peakUsers": mission.peakUsers, "monthlyBudget": mission.budget],
            "services": design.nodes.map { n -> [String: Any] in
                ["name": n.title, "count": n.count, "tier": n.tierSpec.name, "peakUtilization": ((forecast.peakUtil[n.id] ?? 0) * 100).rounded() / 100]
            },
            "connections": design.edges.compactMap { e -> String? in
                guard let a = names[e.from], let b = names[e.to] else { return nil }
                return "\(a) → \(b)"
            },
            "forecast": ["worstServedShare": (forecast.minHealth * 1000).rounded() / 1000, "worstPhase": forecast.worstPhase],
            "monthlyCost": costs.reduce(0) { $0 + $1.total }.rounded(),
        ]
    }
}
