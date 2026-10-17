import SwiftUI

struct LogLine: Identifiable {
    enum Level: String { case info = "INFO", ok = "OK", alarm = "ALARM" }
    let id = UUID()
    let time: String
    let level: Level
    let text: String
}

struct Victory: Identifiable {
    let id = UUID()
    let cost: Double
    let stars: Int
}

@MainActor @Observable
final class Store {
    private(set) var mission: Mission
    private(set) var design: Design
    /// Selected service. Mutually exclusive with `selectedEdge`.
    var selection: UUID? { didSet { if selection != nil { selectedEdge = nil } } }
    /// Selected connection.
    var selectedEdge: UUID? { didSet { if selectedEdge != nil { selection = nil } } }

    // Camera: screen = world * scale + offset.
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    var boardSize: CGSize = .zero

    // Simulation
    var playing = true
    var speed = 1.0
    private(set) var progress = 0.0
    private(set) var live = SimResult()
    private(set) var forecast = Forecast()
    private(set) var costs: [CostLine] = []
    private(set) var logs: [LogLine] = []
    private(set) var history: [Double] = []
    private var runMin = 1.0
    private var lastPhase = ""
    private var lastStatus: Status?
    private var hot = Set<UUID>()
    private var jitter = 1.0
    var victory: Victory?
    var toast: String?
    /// A connection being drawn: from a ⊕ handle, or the end of an existing edge being rewired.
    var pendingLink: (from: UUID, point: CGPoint)?
    var rewiring: (edge: UUID, end: EdgeEnd, point: CGPoint)?
    var hint: Hint?
    private(set) var hintLoading = false
    private var undoStack: [Design] = []

    enum EdgeEnd { case from, to }

    /// Best stars earned per mission id.
    private(set) var best: [String: Int] = UserDefaults.standard.dictionary(forKey: "bestStars") as? [String: Int] ?? [:]

    init() {
        let id = UserDefaults.standard.string(forKey: "mission") ?? Mission.all[0].id
        let m = Mission.all.first { $0.id == id } ?? Mission.all[0]
        mission = m
        design = Store.load(m)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-unlockAll") { for m in Mission.all { best[m.id] = max(best[m.id] ?? 0, 1) } }
        if args.contains("-demo") || args.contains("-demoFail") { design = .demo(failing: args.contains("-demoFail")) }
        #endif
        log(.info, "“\(m.title)” loaded · peak \(Fmt.viewers(m.peakUsers)) \(m.audience)")
        recompute()
        restartEvent()
    }

    var monthly: Double { costs.reduce(0) { $0 + $1.total } }
    var stars: Int { monthly <= mission.budget ? 3 : monthly <= mission.budget * 1.5 ? 2 : 1 }
    var selected: Node? { design.node(selection) }
    var edge: Edge? { design.edges.first { $0.id == selectedEdge } }
    var hasStarted: Bool { design.nodes.count > 1 }
    var canUndo: Bool { !undoStack.isEmpty }

    /// The tutorial opens both tracks; inside a track, clear one event to open the next.
    func isUnlocked(_ m: Mission) -> Bool {
        if m.track == .basics { return true }
        let tutorialDone = Mission.all.filter { $0.track == .basics }.allSatisfy { (best[$0.id] ?? 0) > 0 }
        let track = Mission.all.filter { $0.track == m.track }
        guard let i = track.firstIndex(where: { $0.id == m.id }) else { return false }
        return i == 0 ? tutorialDone : (best[track[i - 1].id] ?? 0) > 0
    }

    var nextMission: Mission? {
        let track = Mission.all.filter { $0.track == mission.track }
        if mission.track == .basics { return Mission.all.first { $0.track == .streaming } }
        guard let i = track.firstIndex(where: { $0.id == mission.id }), i + 1 < track.count else { return nil }
        return track[i + 1]
    }

    /// Index of the first tutorial step not yet done (steps.count once the build steps are all done).
    var tutorialStep: Int {
        let steps = mission.steps
        return steps.firstIndex { !$0.done(design) } ?? steps.count
    }

    // MARK: Missions & persistence

    func choose(_ m: Mission) {
        save()
        mission = m
        UserDefaults.standard.set(m.id, forKey: "mission")
        design = Store.load(m)
        selection = nil
        selectedEdge = nil
        hint = nil
        undoStack = []
        logs = []
        log(.info, "“\(m.title)” loaded · peak \(Fmt.viewers(m.peakUsers)) \(m.audience)")
        recompute()
        restartEvent()
        recenter()
    }

    private static func load(_ m: Mission) -> Design {
        guard let data = UserDefaults.standard.data(forKey: "design.\(m.id)"),
              var d = try? JSONDecoder().decode(Design.self, from: data), d.viewers != nil else { return .starter() }
        migrate(&d)
        return d
    }

    /// Older boards ran traffic *through* WAF (A → WAF → B). WAF now attaches to B, so link A → B directly.
    private static func migrate(_ d: inout Design) {
        for waf in d.nodes where waf.kind == .waf {
            let into = d.edges.filter { $0.to == waf.id }
            let out = d.edges.filter { $0.from == waf.id }
            for a in into { for b in out where !d.edges.contains(where: { $0.from == a.from && $0.to == b.to }) {
                d.edges.append(Edge(from: a.from, to: b.to))
            } }
            d.edges.removeAll { $0.to == waf.id }
        }
        // Drop any connection the current rules no longer allow.
        let nodes = d.nodes
        d.edges.removeAll { e in
            guard let a = nodes.first(where: { $0.id == e.from }), let b = nodes.first(where: { $0.id == e.to }) else { return true }
            return a.kind.linkProblem(to: b.kind) != nil
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(design) { UserDefaults.standard.set(data, forKey: "design.\(mission.id)") }
    }

    func resetDesign() {
        checkpoint()
        design = .starter()
        selection = nil
        changed()
        recenter()
    }

    // MARK: Undo

    /// Call before any change the player might want to take back.
    func checkpoint() {
        undoStack.append(design)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        design = previous
        if design.node(selection) == nil { selection = nil }
        if edge == nil { selectedEdge = nil }
        hint = nil
        changed()
        show("Undone")
    }

    // MARK: Editing

    private func changed() {
        recompute()
        // Edits restart the live check; the forecast already covers the whole event curve.
        runMin = hasStarted ? live.health : 0
        save()
    }

    private func recompute() {
        forecast = Forecast.run(design, mission)
        costs = Pricing.lines(design, mission, peak: forecast.peak)
        tickSolve()
    }

    /// Adds a service from the palette: after the selected service, into the selected connection,
    /// or (for the very first one) after Users.
    func add(_ kind: ServiceKind) {
        if let e = edge, let a = design.node(e.from), let b = design.node(e.to),
           a.kind.linkProblem(to: kind) == nil, kind.linkProblem(to: b.kind) == nil {
            insert(kind, from: a.id, to: b.id, replacing: e.id)
            return
        }
        let usersFree = design.viewers.map { v in !design.edges.contains { $0.from == v.id } } ?? false
        let anchor = selected.flatMap { $0.kind.linkProblem(to: kind) == nil ? $0 : nil }
            ?? (usersFree && design.viewers?.kind.linkProblem(to: kind) == nil ? design.viewers : nil)
        // An encoder or firewall has no traffic parent; drop it beside what it serves.
        var target: UUID?
        if anchor == nil, kind == .mediaLive { target = design.nodes.first { $0.kind == .mediaPackage || $0.kind == .s3 }?.id }
        if anchor == nil, kind == .waf { target = design.nodes.first { [.cloudFront, .alb, .apiGateway, .appSync].contains($0.kind) }?.id }
        insert(kind, from: anchor?.id, to: target, replacing: nil)
    }

    /// Creates a service wired between `from` and `to` (either may be nil).
    @discardableResult
    func insert(_ kind: ServiceKind, from: UUID?, to: UUID?, replacing: UUID?) -> UUID {
        checkpoint()
        let a = design.node(from), b = design.node(to)
        var position: CGPoint
        switch (a, b) {
        case let (a?, b?): position = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        case let (a?, nil):
            let siblings = design.edges.filter { $0.from == a.id }.count
            position = CGPoint(x: a.x + 170, y: a.y + Double(siblings) * 130)
        case let (nil, b?): position = CGPoint(x: b.x - 170, y: b.y - 130)
        case (nil, nil): position = worldPoint(CGPoint(x: boardSize.width / 2, y: boardSize.height * 0.55))
        }
        if let a, let b, abs(a.x - b.x) < 300 {
            // Make room: slide everything downstream of the insertion point to the right.
            shiftDownstream(from: b.id, by: 170)
            position = CGPoint(x: a.x + 170, y: a.y + (b.y - a.y) / 2)
        }
        while design.nodes.contains(where: { abs($0.x - position.x) < 110 && abs($0.y - position.y) < 110 }) { position.y += 130 }
        let index = (design.nodes.filter { $0.kind == kind }.map(\.index).max() ?? 0) + 1
        let node = Node(kind: kind, x: position.x, y: position.y, count: kind.spec.defaultCount, tier: kind == .ec2 ? 1 : 0, index: index)
        design.nodes.append(node)
        if let replacing { design.edges.removeAll { $0.id == replacing } }
        if let a, a.kind.linkProblem(to: kind) == nil { design.edges.append(Edge(from: a.id, to: node.id)) }
        if let b, kind.linkProblem(to: b.kind) == nil { design.edges.append(Edge(from: node.id, to: b.id)) }
        selection = node.id
        changed()
        reveal(node.id)
        return node.id
    }

    private func shiftDownstream(from start: UUID, by dx: Double) {
        var seen = Set<UUID>(), queue = [start]
        while let id = queue.popLast() {
            guard seen.insert(id).inserted, let i = design.nodes.firstIndex(where: { $0.id == id }), design.nodes[i].kind != .viewers else { continue }
            design.nodes[i].x += dx
            queue += design.edges.filter { $0.from == id }.map(\.to)
        }
    }

    func remove(_ id: UUID) {
        guard design.node(id)?.kind != .viewers else { return }
        checkpoint()
        design.nodes.removeAll { $0.id == id }
        design.edges.removeAll { $0.from == id || $0.to == id }
        if selection == id { selection = nil }
        changed()
    }

    func duplicate(_ id: UUID) {
        guard let n = design.node(id), n.kind != .viewers else { return }
        checkpoint()
        var copy = n
        copy.id = UUID()
        copy.y += 130
        copy.index = (design.nodes.filter { $0.kind == n.kind }.map(\.index).max() ?? 0) + 1
        design.nodes.append(copy)
        for e in design.edges where e.to == id { design.edges.append(Edge(from: e.from, to: copy.id)) }
        for e in design.edges where e.from == id { design.edges.append(Edge(from: copy.id, to: e.to)) }
        selection = copy.id
        changed()
    }

    func update(_ id: UUID, _ change: (inout Node) -> Void) {
        guard let i = design.nodes.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        change(&design.nodes[i])
        design.nodes[i].count = min(max(design.nodes[i].count, 1), design.nodes[i].spec.maxCount)
        design.nodes[i].tier = min(max(design.nodes[i].tier, 0), design.nodes[i].spec.tiers.count - 1)
        changed()
    }

    func beginMove() { checkpoint() }

    func move(_ id: UUID, to p: CGPoint) {
        guard let i = design.nodes.firstIndex(where: { $0.id == id }) else { return }
        design.nodes[i].x = p.x
        design.nodes[i].y = p.y
    }

    func setScheduled(_ on: Bool) {
        checkpoint()
        design.scheduledScaling = on
        changed()
    }

    // MARK: Connections

    /// Why a link can't be made, or nil if it can.
    func canLink(_ from: UUID, _ to: UUID, ignoring: UUID? = nil) -> String? {
        guard let a = design.node(from), let b = design.node(to), from != to else { return "" }
        let others = design.edges.filter { $0.id != ignoring }
        if others.contains(where: { $0.from == from && $0.to == to }) { return "Already connected." }
        if others.contains(where: { $0.from == to && $0.to == from }) { return "\(b.title) already sends to \(a.title). Tap that connection to reverse it." }
        return a.kind.linkProblem(to: b.kind)
    }

    func link(_ from: UUID, _ to: UUID) {
        if let reason = canLink(from, to) {
            if !reason.isEmpty { show(reason) }
            return
        }
        checkpoint()
        design.edges.append(Edge(from: from, to: to))
        changed()
    }

    func unlink(_ edge: UUID) {
        checkpoint()
        design.edges.removeAll { $0.id == edge }
        if selectedEdge == edge { selectedEdge = nil }
        changed()
    }

    func reverse(_ id: UUID) {
        guard let e = design.edges.first(where: { $0.id == id }) else { return }
        if let reason = canLink(e.to, e.from, ignoring: id) { show(reason.isEmpty ? "Can't reverse that." : reason); return }
        checkpoint()
        if let i = design.edges.firstIndex(where: { $0.id == id }) { design.edges[i] = Edge(id: id, from: e.to, to: e.from) }
        changed()
    }

    /// Moves one end of a connection onto another service.
    func rewire(_ id: UUID, end: EdgeEnd, to node: UUID) {
        guard let e = design.edges.first(where: { $0.id == id }) else { return }
        let from = end == .from ? node : e.from, to = end == .to ? node : e.to
        if from == e.from && to == e.to { return }
        if let reason = canLink(from, to, ignoring: id) { show(reason.isEmpty ? "Can't connect those." : reason); return }
        checkpoint()
        if let i = design.edges.firstIndex(where: { $0.id == id }) { design.edges[i] = Edge(id: id, from: from, to: to) }
        changed()
    }

    // MARK: Hints

    func requestHint(index: Int = 0) {
        guard !hintLoading else { return }
        hintLoading = true
        if index == 0 { hint = nil }
        let suggestions = Advisor.suggestions(design: design, mission: mission, forecast: forecast, costs: costs, tutorialStep: tutorialStep)
        let context = Hints.context(design: design, mission: mission, forecast: forecast, costs: costs)
        Task {
            let result = await Hints.next(suggestions, index: index, context: context, useAI: true)
            withAnimation(.easeOut(duration: 0.2)) {
                hint = result
                hintLoading = false
            }
        }
    }

    /// "Do it": applies the hinted step, then shows what's next.
    func applyHint() {
        guard let fix = hint?.fix else { return }
        apply(fix.action)
        log(.ok, "Applied: \(fix.title)")
        show("Done: \(fix.title)")
        hint = nil
    }

    func apply(_ action: Action) {
        switch action {
        case let .add(kind, from, to, replacing):
            insert(kind, from: from, to: to, replacing: replacing)
        case let .connect(a, b):
            link(a, b)
        case let .setCount(id, count):
            update(id) { $0.count = count }
            select(id)
        case let .setTier(id, tier, count):
            update(id) { $0.tier = tier; $0.count = count }
            select(id)
        case let .originShield(id):
            update(id) { $0.originShield = true }
        case .scheduledScaling:
            setScheduled(true)
        case let .duplicate(id):
            duplicate(id)
        }
    }

    func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if toast == message { toast = nil }
        }
    }

    // MARK: Camera & hit testing

    func screenPoint(_ world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * scale + offset.width, y: world.y * scale + offset.height)
    }

    func worldPoint(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - offset.width) / scale, y: (screen.y - offset.height) / scale)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// The service under a screen point (generous target so small zoom levels stay tappable).
    func node(atScreen p: CGPoint) -> Node? {
        let radius = max(40 * scale, 24)
        return design.nodes.map { ($0, distance(screenPoint($0.position), p)) }.filter { $0.1 < radius }.min { $0.1 < $1.1 }?.0
    }

    /// The service whose ⊕ connect handle is under a screen point.
    func port(atScreen p: CGPoint) -> Node? {
        let radius = max(18 * scale, 14)
        return design.nodes
            .filter { !$0.kind.emits.isEmpty || $0.kind == .waf }
            .map { ($0, distance(screenPoint(CGPoint(x: $0.x + 41, y: $0.y)), p)) }
            .filter { $0.1 < radius }.min { $0.1 < $1.1 }?.0
    }

    /// Screen geometry of a connection (also used for drawing).
    func curve(_ e: Edge) -> (start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint)? {
        guard let a = design.node(e.from), let b = design.node(e.to) else { return nil }
        let p0 = screenPoint(CGPoint(x: a.x + 40, y: a.y)), p3 = screenPoint(CGPoint(x: b.x - 44, y: b.y))
        let bend = max(40 * scale, abs(p3.x - p0.x) / 2)
        return (p0, CGPoint(x: p0.x + bend, y: p0.y), CGPoint(x: p3.x - bend, y: p3.y), p3)
    }

    static func point(on c: (start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint), _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = u * u * u * c.start.x + 3 * u * u * t * c.c1.x + 3 * u * t * t * c.c2.x + t * t * t * c.end.x
        let y = u * u * u * c.start.y + 3 * u * u * t * c.c1.y + 3 * u * t * t * c.c2.y + t * t * t * c.end.y
        return CGPoint(x: x, y: y)
    }

    /// The connection under a screen point.
    func edge(atScreen p: CGPoint) -> Edge? {
        var best: (Edge, CGFloat)?
        for e in design.edges {
            guard let c = curve(e) else { continue }
            for i in 1..<24 {
                let d = distance(Store.point(on: c, CGFloat(i) / 24), p)
                if d < 16, d < (best?.1 ?? .infinity) { best = (e, d) }
            }
        }
        return best?.0
    }

    /// Delete bubble shown at the middle of each connection of the selected service.
    func deleteBubble(atScreen p: CGPoint) -> Edge? {
        guard let id = selection else { return nil }
        return design.edges.filter { $0.from == id || $0.to == id }.first { e in
            curve(e).map { distance(Store.point(on: $0, 0.5), p) < 18 } ?? false
        }
    }

    /// The draggable end handle of the selected connection.
    func edgeHandle(atScreen p: CGPoint) -> EdgeEnd? {
        guard let e = edge, let c = curve(e) else { return nil }
        if distance(c.end, p) < 22 { return .to }
        if distance(c.start, p) < 22 { return .from }
        return nil
    }

    private var cameraTask: Task<Void, Never>?

    func stopCamera() { cameraTask?.cancel() }

    /// Eases the camera frame by frame, so services and the connections drawn between them move together.
    func moveCamera(offset target: CGSize, scale targetScale: CGFloat? = nil) {
        cameraTask?.cancel()
        let startOffset = offset, startScale = scale, endScale = targetScale ?? scale
        cameraTask = Task {
            let frames = 18
            for i in 1...frames {
                if Task.isCancelled { return }
                let t = CGFloat(i) / CGFloat(frames)
                let e = 1 - pow(1 - t, 3)
                offset = CGSize(width: startOffset.width + (target.width - startOffset.width) * e,
                                height: startOffset.height + (target.height - startOffset.height) * e)
                scale = startScale + (endScale - startScale) * e
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func recenter() {
        guard boardSize.width > 0 else { return }
        let xs = design.nodes.map(\.x), ys = design.nodes.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
        let w = maxX - minX + 200, h = maxY - minY + 220
        let usable = CGSize(width: boardSize.width, height: boardSize.height * 0.4)
        let s = min(1.2, max(0.2, min(usable.width / w, usable.height / h)))
        moveCamera(offset: CGSize(width: boardSize.width / 2 - (minX + maxX) / 2 * s,
                                  height: boardSize.height * 0.62 - (minY + maxY) / 2 * s), scale: s)
    }

    func focus(_ id: UUID?) {
        guard let n = design.node(id) else { return }
        withAnimation(.easeOut(duration: 0.15)) { selection = n.id }
        moveCamera(offset: CGSize(width: boardSize.width / 2 - n.x * scale, height: boardSize.height * 0.36 - n.y * scale))
    }

    func select(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.15)) { selection = id }
        reveal(id)
    }

    /// Pans just enough to bring a node into the open part of the board.
    func reveal(_ id: UUID) {
        guard let n = design.node(id), boardSize.width > 0 else { return }
        let p = screenPoint(n.position)
        // With the inspector open only a strip between the HUD and the panel is visible.
        let visible = selection == nil
            ? CGRect(x: 90, y: boardSize.height * 0.5, width: boardSize.width - 180, height: boardSize.height * 0.2)
            : CGRect(x: 90, y: boardSize.height * (mission.isTutorial ? 0.36 : 0.3), width: boardSize.width - 180, height: boardSize.height * 0.08)
        guard !visible.contains(p) else { return }
        let dx = p.x < visible.minX ? visible.minX - p.x : p.x > visible.maxX ? visible.maxX - p.x : 0
        let dy = p.y < visible.minY ? visible.minY - p.y : p.y > visible.maxY ? visible.maxY - p.y : 0
        moveCamera(offset: CGSize(width: offset.width + dx, height: offset.height + dy))
    }

    // MARK: Simulation clock

    func restartEvent() {
        progress = 0
        history = []
        runMin = 1
        hot = []
        tickSolve()
    }

    func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            guard playing, victory == nil else { continue }
            progress += 0.1 / mission.realSeconds * speed
            jitter = min(Forecast.jitter, max(2 - Forecast.jitter, jitter + Double.random(in: -0.006...0.006)))
            if progress >= 1 { finishEvent() } else { tickSolve() }
        }
    }

    private func finishEvent() {
        let survived = hasStarted && runMin >= 0.995 && forecast.minHealth >= 0.995
        if survived {
            log(.ok, "Event complete. Every one of your \(mission.audience) was served. Bill: \(Fmt.money(monthly))/mo")
            victory = Victory(cost: monthly, stars: stars)
            best[mission.id] = max(best[mission.id] ?? 0, stars)
            UserDefaults.standard.set(best, forKey: "bestStars")
        } else {
            log(.info, "Event ended · worst moment \(Fmt.percent(min(runMin, forecast.minHealth))) served. Replaying…")
        }
        restartEvent()
    }

    private func tickSolve() {
        let demand = EventCurve.demand(mission, progress, jitter: jitter)
        live = Solver.run(design, mission, demand)
        let health = hasStarted ? live.health : 0
        runMin = min(runMin, health)
        if history.count > 240 { history.removeFirst() }
        history.append(health)

        let stamp = clock
        if demand.phase != lastPhase {
            lastPhase = demand.phase
            log(.info, "\(demand.phase) · \(Fmt.viewers(demand.viewers)) \(mission.audience)", time: stamp)
        }
        let status = live.status
        if status != lastStatus, hasStarted {
            if lastStatus != nil { log(status == .holding ? .ok : .alarm, "Service \(status.rawValue.lowercased()) · \(Fmt.percent(health)) of requests served", time: stamp) }
            lastStatus = status
        }
        for n in design.nodes {
            let util = live.stats[n.id]?.util ?? 0
            if util > 1.0001, !hot.contains(n.id) {
                hot.insert(n.id)
                log(.alarm, "\(n.title) · Utilization \(Fmt.percent(util)) · requests dropping", time: stamp)
            } else if util < 0.95, hot.contains(n.id) {
                hot.remove(n.id)
                log(.ok, "\(n.title) · back under capacity (\(Fmt.percent(util)))", time: stamp)
            }
        }
    }

    var clock: String {
        let t = Int(progress * mission.eventHours * 3600)
        return String(format: "T+%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    private func log(_ level: LogLine.Level, _ text: String, time: String? = nil) {
        logs.append(LogLine(time: time ?? clock, level: level, text: text))
        if logs.count > 80 { logs.removeFirst(logs.count - 80) }
    }
}
