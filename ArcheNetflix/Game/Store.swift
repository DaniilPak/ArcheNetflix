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
    var selection: UUID?

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
    private var runClean = false
    private var runMin = 1.0
    private var lastPhase = ""
    private var lastStatus: Status?
    private var hot = Set<UUID>()
    private var jitter = 1.0
    var victory: Victory?
    var toast: String?
    var pendingLink: (from: UUID, point: CGPoint)?

    /// Seconds of real time one event takes at 1×.
    static let eventDuration = 75.0

    init() {
        let id = UserDefaults.standard.string(forKey: "mission") ?? Mission.all[1].id
        let m = Mission.all.first { $0.id == id } ?? Mission.all[1]
        mission = m
        design = Store.load(m)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demo") || args.contains("-demoFail") { design = .demo(failing: args.contains("-demoFail")) }
        #endif
        log(.info, "Event “\(m.title)” loaded · peak \(Fmt.viewers(m.peakViewers)) viewers")
        recompute()
        restartEvent()
    }

    var monthly: Double { costs.reduce(0) { $0 + $1.total } }
    var stars: Int { monthly <= mission.budget ? 3 : monthly <= mission.budget * 1.5 ? 2 : 1 }
    var selected: Node? { design.node(selection) }
    var hasStarted: Bool { design.nodes.count > 1 }

    // MARK: Missions & persistence

    func choose(_ m: Mission) {
        save()
        mission = m
        UserDefaults.standard.set(m.id, forKey: "mission")
        design = Store.load(m)
        selection = nil
        logs = []
        log(.info, "Event “\(m.title)” loaded · peak \(Fmt.viewers(m.peakViewers)) viewers")
        restartEvent()
        recenter()
    }

    private static func load(_ m: Mission) -> Design {
        guard let data = UserDefaults.standard.data(forKey: "design.\(m.id)"),
              let d = try? JSONDecoder().decode(Design.self, from: data), d.viewers != nil else { return .starter() }
        return d
    }

    func save() {
        if let data = try? JSONEncoder().encode(design) { UserDefaults.standard.set(data, forKey: "design.\(mission.id)") }
    }

    func resetDesign() {
        design = .starter()
        selection = nil
        changed()
        recenter()
    }

    // MARK: Editing

    private func changed() {
        recompute()
        runClean = false
        save()
    }

    private func recompute() {
        forecast = Forecast.run(design, mission)
        costs = Pricing.lines(design, mission, peak: forecast.peak)
        tickSolve()
    }

    func add(_ kind: ServiceKind) {
        let spec = kind.spec
        let index = (design.nodes.filter { $0.kind == kind }.map(\.index).max() ?? 0) + 1
        var position = worldPoint(CGPoint(x: boardSize.width / 2, y: boardSize.height * 0.5))
        // Connect from the selection; the very first service hangs off Viewers.
        let viewersFree = design.viewers.map { v in !design.edges.contains { $0.from == v.id } } ?? false
        let anchor = selected.flatMap { canLinkFrom($0) ? $0 : nil } ?? (viewersFree ? design.viewers : nil)
        if let a = anchor {
            let siblings = design.edges.filter { $0.from == a.id }.count
            position = CGPoint(x: a.x + 170, y: a.y + Double(siblings) * 130)
        }
        while design.nodes.contains(where: { abs($0.x - position.x) < 120 && abs($0.y - position.y) < 120 }) { position.y += 130 }
        let node = Node(kind: kind, x: position.x, y: position.y, count: spec.defaultCount, tier: kind == .ec2 ? 1 : 0, index: index)
        design.nodes.append(node)
        if let a = anchor, canLink(a.id, node.id) == nil { design.edges.append(Edge(from: a.id, to: node.id)) }
        selection = node.id
        changed()
        reveal(node.id)
    }

    private func canLinkFrom(_ n: Node) -> Bool { n.spec.role != .database && n.spec.role != .origin }

    /// Pans just enough to bring a node into the open part of the board.
    func reveal(_ id: UUID) {
        guard let n = design.node(id), boardSize.width > 0 else { return }
        let p = screenPoint(n.position)
        // With the inspector open only a strip between the HUD and the panel is visible.
        let visible = selection == nil
            ? CGRect(x: 90, y: boardSize.height * 0.42, width: boardSize.width - 180, height: boardSize.height * 0.16)
            : CGRect(x: 90, y: boardSize.height * 0.31, width: boardSize.width - 180, height: boardSize.height * 0.11)
        guard !visible.contains(p) else { return }
        let dx = p.x < visible.minX ? visible.minX - p.x : p.x > visible.maxX ? visible.maxX - p.x : 0
        let dy = p.y < visible.minY ? visible.minY - p.y : p.y > visible.maxY ? visible.maxY - p.y : 0
        withAnimation(.spring(duration: 0.4)) { offset = CGSize(width: offset.width + dx, height: offset.height + dy) }
    }

    func remove(_ id: UUID) {
        guard design.node(id)?.kind != .viewers else { return }
        design.nodes.removeAll { $0.id == id }
        design.edges.removeAll { $0.from == id || $0.to == id }
        if selection == id { selection = nil }
        changed()
    }

    func duplicate(_ id: UUID) {
        guard let n = design.node(id), n.kind != .viewers else { return }
        var copy = n
        copy.id = UUID()
        copy.y += 100
        copy.index = (design.nodes.filter { $0.kind == n.kind }.map(\.index).max() ?? 0) + 1
        design.nodes.append(copy)
        for e in design.edges where e.to == id { design.edges.append(Edge(from: e.from, to: copy.id)) }
        for e in design.edges where e.from == id { design.edges.append(Edge(from: copy.id, to: e.to)) }
        selection = copy.id
        changed()
    }

    func update(_ id: UUID, _ change: (inout Node) -> Void) {
        guard let i = design.nodes.firstIndex(where: { $0.id == id }) else { return }
        change(&design.nodes[i])
        design.nodes[i].count = min(max(design.nodes[i].count, 1), design.nodes[i].spec.maxCount)
        changed()
    }

    func move(_ id: UUID, to p: CGPoint) {
        guard let i = design.nodes.firstIndex(where: { $0.id == id }) else { return }
        design.nodes[i].x = p.x
        design.nodes[i].y = p.y
    }

    func setScheduled(_ on: Bool) {
        design.scheduledScaling = on
        changed()
    }

    /// Why a link can't be made, or nil if it can.
    func canLink(_ from: UUID, _ to: UUID) -> String? {
        guard let a = design.node(from), let b = design.node(to), from != to else { return "" }
        if b.kind == .viewers { return "Viewers only send traffic." }
        if design.edges.contains(where: { $0.from == from && $0.to == to }) { return "Already connected." }
        if a.kind == .mediaLive && b.spec.role != .origin { return "MediaLive pushes its stream to MediaPackage or S3." }
        if b.kind == .mediaLive { return "MediaLive takes the arena camera feed, not traffic." }
        if a.spec.role == .database || a.spec.role == .origin { return "\(a.spec.name) is a final stop — it doesn't forward traffic." }
        return nil
    }

    func link(_ from: UUID, _ to: UUID) {
        if let reason = canLink(from, to) {
            if !reason.isEmpty { show(reason) }
            return
        }
        design.edges.append(Edge(from: from, to: to))
        changed()
    }

    func unlink(_ edge: UUID) {
        design.edges.removeAll { $0.id == edge }
        changed()
    }

    func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if toast == message { toast = nil }
        }
    }

    // MARK: Camera

    func screenPoint(_ world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * scale + offset.width, y: world.y * scale + offset.height)
    }

    func worldPoint(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - offset.width) / scale, y: (screen.y - offset.height) / scale)
    }

    /// The service under a screen point (generous target so small zoom levels stay tappable).
    func node(atScreen p: CGPoint) -> Node? {
        let radius = max(40 * scale, 24)
        return design.nodes
            .map { ($0, hypot(screenPoint($0.position).x - p.x, screenPoint($0.position).y - p.y)) }
            .filter { $0.1 < radius }
            .min { $0.1 < $1.1 }?.0
    }

    /// The service whose ⊕ connect handle is under a screen point.
    func port(atScreen p: CGPoint) -> Node? {
        let radius = max(18 * scale, 14)
        return design.nodes
            .filter { $0.spec.role != .database && $0.spec.role != .origin }
            .map { ($0, hypot(screenPoint(CGPoint(x: $0.x + 41, y: $0.y)).x - p.x, screenPoint(CGPoint(x: $0.x + 41, y: $0.y)).y - p.y)) }
            .filter { $0.1 < radius }
            .min { $0.1 < $1.1 }?.0
    }

    func recenter() {
        guard boardSize.width > 0 else { return }
        let xs = design.nodes.map(\.x), ys = design.nodes.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
        let w = maxX - minX + 200, h = maxY - minY + 220
        let usable = CGSize(width: boardSize.width, height: boardSize.height * 0.55)
        withAnimation(.spring(duration: 0.4)) {
            scale = min(1.2, max(0.25, min(usable.width / w, usable.height / h)))
            offset = CGSize(width: boardSize.width / 2 - (minX + maxX) / 2 * scale,
                            height: boardSize.height * 0.45 - (minY + maxY) / 2 * scale)
        }
    }

    func focus(_ id: UUID?) {
        guard let n = design.node(id) else { return }
        withAnimation(.easeOut(duration: 0.15)) { selection = n.id }
        withAnimation(.spring(duration: 0.4)) {
            offset = CGSize(width: boardSize.width / 2 - n.x * scale, height: boardSize.height * 0.36 - n.y * scale)
        }
    }

    func select(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.15)) { selection = id }
        reveal(id)
    }

    // MARK: Simulation clock

    func restartEvent() {
        progress = 0
        history = []
        runMin = 1
        runClean = true
        hot = []
        tickSolve()
    }

    func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            guard playing, victory == nil else { continue }
            progress += 0.1 / Store.eventDuration * speed
            jitter = min(1.03, max(0.97, jitter + Double.random(in: -0.006...0.006)))
            if progress >= 1 { finishEvent() } else { tickSolve() }
        }
    }

    private func finishEvent() {
        let survived = runClean && runMin >= 0.995 && hasStarted
        if survived {
            log(.ok, "Event complete. Every viewer got the fight. Bill: \(Fmt.money(monthly))/mo")
            victory = Victory(cost: monthly, stars: stars)
        } else {
            log(.info, runClean ? "Event ended · worst health \(Fmt.percent(runMin)). Replaying…" : "Event ended · design changed mid-event. Replaying to certify…")
        }
        restartEvent()
    }

    private func tickSolve() {
        let demand = EventCurve.demand(mission, progress, jitter: jitter)
        live = Solver.run(design, demand)
        let health = hasStarted ? live.health : 0
        runMin = min(runMin, health)
        if history.count > 240 { history.removeFirst() }
        history.append(health)

        let stamp = clock
        if demand.phase != lastPhase {
            lastPhase = demand.phase
            log(.info, "\(demand.phase) · \(Fmt.viewers(demand.viewers)) viewers", time: stamp)
        }
        let status = live.status
        if status != lastStatus, hasStarted {
            if lastStatus != nil { log(status == .holding ? .ok : .alarm, "Stream \(status.rawValue.lowercased()) · \(Fmt.percent(health)) of viewers served", time: stamp) }
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
