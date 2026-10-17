import SwiftUI

/// Figma-style infinite canvas: drag empty space to pan, pinch to zoom, drag services to move them,
/// drag a service's ⊕ handle onto another service to connect them. Tap a connection to select it;
/// drag its end dots to rewire it. A selected service shows × bubbles on its connections.
struct BoardView: View {
    let store: Store
    @State private var mode: DragMode?
    @State private var zoomStart: (scale: CGFloat, offset: CGSize)?

    private enum DragMode {
        case pan(CGSize), move(UUID, CGPoint, started: Bool), link(UUID), rewire(UUID, Store.EdgeEnd), bubble(UUID), edge(UUID, CGSize), ignore
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                GridLayer(scale: store.scale, offset: store.offset)
                EdgesLayer(store: store)
                ForEach(store.design.nodes) { node in
                    NodeView(store: store, node: node)
                        .scaleEffect(store.scale)
                        .position(store.screenPoint(node.position))
                }
                pendingLink
                rewirePreview
            }
            .allowsHitTesting(false)
            .contentShape(Rectangle())
            .coordinateSpace(name: "board")
            .gesture(pointer)
            .simultaneousGesture(zoom)
            .clipped()
            .onAppear {
                store.boardSize = geo.size
                store.recenter()
            }
            .onChange(of: geo.size) { _, size in store.boardSize = size }
        }
    }

    /// One-finger gesture for the whole board. Hit-testing is done here against node and edge
    /// geometry, so taps and drags work at any zoom level.
    private var pointer: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if zoomStart != nil { mode = .ignore }
                if mode == nil {
                    store.stopCamera()
                    let p = v.startLocation
                    if let e = store.deleteBubble(atScreen: p) { mode = .bubble(e.id) }
                    else if let end = store.edgeHandle(atScreen: p), let e = store.selectedEdge { mode = .rewire(e, end) }
                    else if let n = store.port(atScreen: p) { mode = .link(n.id) }
                    else if let n = store.node(atScreen: p) { mode = .move(n.id, n.position, started: false) }
                    else if let e = store.edge(atScreen: p) { mode = .edge(e.id, store.offset) }
                    else { mode = .pan(store.offset) }
                }
                let moved = hypot(v.translation.width, v.translation.height) > 5
                switch mode {
                case .link(let id): store.pendingLink = (id, v.location)
                case .rewire(let id, let end): store.rewiring = (id, end, v.location)
                case .move(let id, let start, let started) where moved:
                    if !started { store.beginMove(); mode = .move(id, start, started: true) }
                    store.move(id, to: CGPoint(x: start.x + v.translation.width / store.scale, y: start.y + v.translation.height / store.scale))
                case .pan(let start) where moved, .edge(_, let start) where moved:
                    store.offset = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
                default: break
                }
            }
            .onEnded { v in
                let moved = hypot(v.translation.width, v.translation.height) > 5
                switch mode {
                case .link(let id):
                    if let target = store.node(atScreen: v.location), target.id != id { store.link(id, target.id) }
                    else if !moved { store.select(id) }
                    store.pendingLink = nil
                case .rewire(let id, let end):
                    if let target = store.node(atScreen: v.location) { store.rewire(id, end: end, to: target.id) }
                    store.rewiring = nil
                case .bubble(let id):
                    if !moved { store.unlink(id) }
                case .move(let id, _, _):
                    if moved { store.save() } else { store.select(id) }
                case .edge(let id, _):
                    if !moved { withAnimation(.easeOut(duration: 0.15)) { store.selectedEdge = id } }
                case .pan:
                    if !moved {
                        withAnimation(.easeOut(duration: 0.15)) {
                            store.selection = nil
                            store.selectedEdge = nil
                        }
                    }
                default: break
                }
                mode = nil
            }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if zoomStart == nil { store.stopCamera(); zoomStart = (store.scale, store.offset) }
                guard let start = zoomStart else { return }
                let s = min(2.5, max(0.12, start.scale * v.magnification))
                let anchor = v.startLocation
                let world = CGPoint(x: (anchor.x - start.offset.width) / start.scale, y: (anchor.y - start.offset.height) / start.scale)
                store.scale = s
                store.offset = CGSize(width: anchor.x - world.x * s, height: anchor.y - world.y * s)
            }
            .onEnded { _ in zoomStart = nil }
    }

    @ViewBuilder private var pendingLink: some View {
        if let link = store.pendingLink, let from = store.design.node(link.from) {
            let a = store.screenPoint(CGPoint(x: from.x + 41, y: from.y))
            let target = store.node(atScreen: link.point).flatMap { $0.id == from.id ? nil : $0 }
            preview(from: a, to: target.map { store.screenPoint($0.position) } ?? link.point,
                    valid: target.map { store.canLink(from.id, $0.id) == nil },
                    reason: target.flatMap { store.canLink(from.id, $0.id) })
        }
    }

    @ViewBuilder private var rewirePreview: some View {
        if let r = store.rewiring, let e = store.design.edges.first(where: { $0.id == r.edge }), let c = store.curve(e) {
            let fixed = r.end == .to ? c.start : c.end
            let target = store.node(atScreen: r.point)
            let check = target.flatMap { t in store.canLink(r.end == .from ? t.id : e.from, r.end == .to ? t.id : e.to, ignoring: e.id) }
            preview(from: fixed, to: target.map { store.screenPoint($0.position) } ?? r.point,
                    valid: target.map { _ in check == nil }, reason: check)
        }
    }

    /// Dashed line while connecting: green when the drop is valid, red with the reason when it isn't.
    private func preview(from a: CGPoint, to b: CGPoint, valid: Bool?, reason: String?) -> some View {
        let color = valid == true ? Theme.greenHi : valid == false ? Theme.red : Color.white.opacity(0.7)
        return ZStack(alignment: .topLeading) {
            Path { p in p.move(to: a); p.addLine(to: b) }
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6]))
            Circle().fill(color).frame(width: 12, height: 12).position(b)
            if valid == false, let reason, !reason.isEmpty {
                Text(reason).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.red.opacity(0.9)))
                    .frame(maxWidth: 240)
                    .fixedSize(horizontal: false, vertical: true)
                    .position(x: b.x, y: b.y - 44)
            }
        }
    }
}

struct GridLayer: View {
    let scale: CGFloat
    let offset: CGSize

    var body: some View {
        Canvas { ctx, size in
            var step = 40 * scale
            while step < 18 { step *= 2 }
            let dot = max(1.2, min(2.2, 2 * scale))
            let startX = offset.width.truncatingRemainder(dividingBy: step) - step
            let startY = offset.height.truncatingRemainder(dividingBy: step) - step
            var path = Path()
            var x = startX
            while x < size.width + step {
                var y = startY
                while y < size.height + step {
                    path.addEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                    y += step
                }
                x += step
            }
            ctx.fill(path, with: .color(.white.opacity(0.09)))
        }
        .background(Theme.bg)
    }
}

/// Connections with animated traffic: thickness = share of traffic, colour = health of the receiving service.
struct EdgesLayer: View {
    let store: Store

    var body: some View {
        let nodes = Dictionary(uniqueKeysWithValues: store.design.nodes.map { ($0.id, $0) })
        let edges = store.design.edges
        let live = store.live
        let scale = store.scale
        let offset = store.offset
        let selection = store.selection
        let selectedEdge = store.selectedEdge
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !store.playing)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, _ in
                func screen(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * scale + offset.width, y: y * scale + offset.height) }
                for e in edges {
                    guard let a = nodes[e.from], let b = nodes[e.to] else { continue }
                    let p0 = screen(a.x + 40, a.y), p3 = screen(b.x - 44, b.y)
                    let bend = max(40 * scale, abs(p3.x - p0.x) / 2)
                    var path = Path()
                    path.move(to: p0)
                    path.addCurve(to: p3, control1: CGPoint(x: p0.x + bend, y: p0.y), control2: CGPoint(x: p3.x - bend, y: p3.y))

                    let ingest = a.kind == .mediaLive
                    let shield = a.kind == .waf
                    let flow = live.flow[e.id] ?? 0
                    let util = live.stats[b.id]?.util ?? 0
                    let active = (flow > 1e-6 || ingest) && !shield
                    let color = shield ? Category.security.color : ingest ? Category.media.color : active ? Theme.load(util) : Color.white.opacity(0.25)
                    let highlight = selection == a.id || selection == b.id
                    let chosen = selectedEdge == e.id
                    let width = (active ? 2 + 7 * sqrt(min(flow, 1)) : 2) * max(scale, 0.4) * (highlight || chosen ? 1.3 : 1)

                    if chosen {
                        ctx.stroke(path, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: width + 6, lineCap: .round))
                    }
                    if shield {
                        // WAF protects rather than carries traffic: a dashed security line.
                        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5 * max(scale, 0.5), lineCap: .round, dash: [3 * scale, 6 * scale]))
                        continue
                    }

                    ctx.stroke(path, with: .color(color.opacity(active ? 0.35 : 0.5)), style: StrokeStyle(lineWidth: width, lineCap: .round))
                    if active {
                        let speed = ingest ? 30.0 : 40 + 80 * min(flow, 1)
                        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(1.5, width * 0.45), lineCap: .round,
                                                                                  dash: [6 * scale, 14 * scale], dashPhase: -t * speed * scale))
                    }
                    // Arrowhead pointing into the receiver.
                    let tip = CGPoint(x: p3.x + 6 * scale, y: p3.y)
                    var head = Path()
                    head.move(to: tip)
                    head.addLine(to: CGPoint(x: tip.x - 11 * scale, y: tip.y - 7 * scale))
                    head.addLine(to: CGPoint(x: tip.x - 11 * scale, y: tip.y + 7 * scale))
                    head.closeSubpath()
                    ctx.fill(head, with: .color(active ? color : .white.opacity(0.4)))
                }
                // Controls: × bubbles on the selected service's connections, end handles on the selected connection.
                func mid(_ a: Node, _ b: Node) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
                    let p0 = screen(a.x + 40, a.y), p3 = screen(b.x - 44, b.y)
                    let bend = max(40 * scale, abs(p3.x - p0.x) / 2)
                    return (p0, CGPoint(x: p0.x + bend, y: p0.y), CGPoint(x: p3.x - bend, y: p3.y), p3)
                }
                for e in edges {
                    guard let a = nodes[e.from], let b = nodes[e.to] else { continue }
                    let c = mid(a, b)
                    if let s = selection, s == a.id || s == b.id {
                        let m = Store.point(on: (c.0, c.1, c.2, c.3), 0.5)
                        ctx.fill(Path(ellipseIn: CGRect(x: m.x - 12, y: m.y - 12, width: 24, height: 24)), with: .color(Theme.bg))
                        ctx.fill(Path(ellipseIn: CGRect(x: m.x - 10, y: m.y - 10, width: 20, height: 20)), with: .color(Theme.red))
                        var x = Path()
                        x.move(to: CGPoint(x: m.x - 4, y: m.y - 4)); x.addLine(to: CGPoint(x: m.x + 4, y: m.y + 4))
                        x.move(to: CGPoint(x: m.x + 4, y: m.y - 4)); x.addLine(to: CGPoint(x: m.x - 4, y: m.y + 4))
                        ctx.stroke(x, with: .color(.white), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    }
                    if selectedEdge == e.id {
                        for p in [c.0, c.3] {
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)), with: .color(Theme.bg))
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(.white))
                        }
                    }
                }
            }
        }
    }
}

struct ServiceIcon: View {
    let kind: ServiceKind
    var size: CGFloat = 56

    var body: some View {
        let spec = kind.spec
        let viewers = kind == .viewers
        let radius = size * 0.24
        Image(systemName: spec.symbol)
            .font(.system(size: size * (viewers ? 0.4 : 0.44), weight: .bold))
            .foregroundStyle(viewers ? Color(hex: 0x2b2a27) : .white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: radius).fill(viewers ? AnyShapeStyle(Theme.light) : AnyShapeStyle(LinearGradient(colors: [spec.color.mix(with: .white, by: 0.18), spec.color], startPoint: .top, endPoint: .bottom))))
            .background(RoundedRectangle(cornerRadius: radius).fill(.black.opacity(0.4)).offset(y: size * 0.06))
            .accessibilityLabel(spec.name)
    }
}

struct NodeView: View {
    let store: Store
    let node: Node

    var body: some View {
        let stat = store.live.stats[node.id]
        let util = stat?.util ?? 0
        let over = util > 1.0001
        let selected = store.selection == node.id
        ServiceIcon(kind: node.kind, size: 64)
            .overlay {
                RoundedRectangle(cornerRadius: 19)
                    .strokeBorder(selected ? .white : over ? Theme.red : .clear, lineWidth: 3)
                    .padding(-6)
                    .shadow(color: over ? Theme.red.opacity(0.8) : .clear, radius: 8)
            }
            .overlay(alignment: .topTrailing) { badge.offset(x: 12, y: -10) }
            .overlay(alignment: .bottom) { label(util: util, stat: stat).fixedSize().offset(y: 50) }
            .overlay(alignment: .trailing) { if !node.kind.emits.isEmpty || node.kind == .waf { port.offset(x: 26) } }
            .frame(width: 64, height: 64)
    }

    @ViewBuilder private var badge: some View {
        if node.kind != .viewers && node.spec.maxCount > 1 {
            Text("×\(node.count)")
                .font(.system(size: 12, weight: .heavy).monospacedDigit())
                .foregroundStyle(Color(hex: 0x2b2a27))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.white))
        }
    }

    private func label(util: Double, stat: NodeStat?) -> some View {
        VStack(spacing: 3) {
            Text(node.title).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            if node.kind == .viewers {
                Text("\(Fmt.viewers(store.live.demand.viewers)) \(store.mission.audience)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.greenHi)
            } else if node.kind == .mediaLive {
                Text(node.tierSpec.name).font(.system(size: 10)).foregroundStyle(Theme.muted)
            } else {
                HStack(spacing: 5) {
                    Capsule().fill(Theme.panel2).frame(width: 44, height: 5)
                        .overlay(alignment: .leading) { Capsule().fill(Theme.load(util)).frame(width: 44 * min(util, 1), height: 5) }
                    Text(Fmt.percent(util)).font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(util > 1.0001 ? Theme.red : Theme.muted)
                }
            }
        }
    }

    private var port: some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(Color(hex: 0x2b2a27))
            .frame(width: 20, height: 20)
            .background(Circle().fill(Theme.greenHi))
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
            .frame(width: 34, height: 34)
            .accessibilityLabel("Connect \(node.title)")
    }

}
