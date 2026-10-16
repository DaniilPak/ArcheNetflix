import SwiftUI

// MARK: - Top HUD

struct HUD: View {
    let store: Store
    var onMissions: () -> Void
    var onCosts: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            header
            StatusCard(store: store)
            if store.selection == nil, let issue = store.forecast.worst.issues.first(where: { $0.severity == .failure }) ?? (store.hasStarted ? nil : store.live.issues.first) {
                Button { store.focus(issue.node) } label: {
                    Banner(text: issue.text, color: Theme.orange, icon: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(issue.id)
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.forecast.worst.issues.first?.id)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "cloud.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.green)
            ViewThatFits {
                Text("archenetflix").font(.system(size: 19, weight: .heavy)).tracking(-0.5).fixedSize()
                Color.clear.frame(width: 0)
            }
            Spacer(minLength: 4)
            Button(action: onMissions) {
                HStack(spacing: 4) {
                    Text(store.mission.title).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .heavy))
                }
            }
            .buttonStyle(SecondaryButtonStyle(height: 36, expand: false))
            Button(action: onCosts) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Fmt.money(store.monthly)).font(.system(size: 15, weight: .heavy).monospacedDigit()).fixedSize()
                    Text("/ month").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
            }
            .buttonStyle(SecondaryButtonStyle(tint: Theme.panel, height: 36, expand: false))
            .accessibilityLabel("Monthly cost \(Fmt.money(store.monthly))")
        }
        .frame(height: 46)
    }
}

struct StatusCard: View {
    let store: Store

    var body: some View {
        let live = store.live
        let status = store.hasStarted ? live.status : .down
        let color = status == .holding ? Theme.green : status == .degraded ? Theme.yellow : Theme.red
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Fmt.viewers(live.demand.viewers)).font(.system(size: 26, weight: .heavy).monospacedDigit())
                            .contentTransition(.numericText())
                        Text("of \(Fmt.viewers(store.mission.peakViewers))").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                    Text("\(live.demand.phase) · \(store.clock)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.soft)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(status.rawValue).font(.system(size: 14, weight: .heavy)).tracking(0.5)
                    }
                    .foregroundStyle(status == .holding ? Color(hex: 0x2b2a27) : .white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(status == .holding ? .white : color.opacity(0.9)))
                    HStack(spacing: 8) {
                        metric("play.rectangle.fill", live.video)
                        metric("bolt.fill", live.api)
                    }
                }
            }
            Sparkline(values: store.history, progress: store.progress)
                .frame(height: 26)
            forecastRow
        }
        .padding(12)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeOut(duration: 0.2), value: status)
    }

    private func metric(_ icon: String, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(Fmt.percent(store.hasStarted ? value : 0)).font(.system(size: 12, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(value >= 0.995 && store.hasStarted ? Theme.greenHi : value >= 0.9 ? Theme.yellow : Theme.red)
    }

    private var forecastRow: some View {
        let f = store.forecast
        let ready = f.minHealth >= 0.995 && store.hasStarted
        return HStack(spacing: 8) {
            Image(systemName: ready ? "checkmark.seal.fill" : "waveform.path.ecg").foregroundStyle(ready ? Theme.greenHi : Theme.orange)
            Text(ready ? "Forecast: survives the whole event" : store.hasStarted ? "Forecast: \(Fmt.percent(f.minHealth)) served at \(f.worstPhase)" : "Forecast: nothing deployed yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ready ? Theme.greenHi : Theme.soft)
            Spacer()
            HStack(spacing: 1) {
                ForEach(0..<3) { i in Image(systemName: i < store.stars && ready ? "star.fill" : "star").font(.system(size: 10, weight: .bold)) }
            }
            .foregroundStyle(ready ? Theme.yellow : Theme.faint)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel2))
    }
}

/// Health over the event so far, with the audience curve behind it.
struct Sparkline: View {
    let values: [Double]
    let progress: Double

    var body: some View {
        Canvas { ctx, size in
            var curve = Path()
            for i in 0...60 {
                let p = Double(i) / 60
                let pt = CGPoint(x: p * size.width, y: size.height * (1 - EventCurve.fraction(p)))
                i == 0 ? curve.move(to: pt) : curve.addLine(to: pt)
            }
            var area = curve
            area.addLine(to: CGPoint(x: size.width, y: size.height)); area.addLine(to: CGPoint(x: 0, y: size.height)); area.closeSubpath()
            ctx.fill(area, with: .color(.white.opacity(0.06)))
            ctx.stroke(curve, with: .color(.white.opacity(0.18)), lineWidth: 1)

            // Health ticks along the elapsed part of the timeline.
            let elapsed = progress * size.width
            if !values.isEmpty {
                let w = max(1, elapsed / CGFloat(values.count))
                for (i, v) in values.enumerated() {
                    let color = v >= 0.995 ? Theme.green : v >= 0.9 ? Theme.yellow : Theme.red
                    ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: size.height - 4, width: w + 0.5, height: 4)), with: .color(color))
                }
            }
            ctx.fill(Path(CGRect(x: elapsed - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
        }
    }
}

struct Banner: View {
    let text: String
    let color: Color
    var icon: String?
    var body: some View {
        HStack(spacing: 10) {
            if let icon { Image(systemName: icon).foregroundStyle(color) }
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.soft).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(HStack(spacing: 0) { color.frame(width: 4); color.opacity(0.15) }.background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 6)))
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    let store: Store
    @Binding var showLog: Bool
    var onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onAdd) { Label("Add service", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle())
            Button { store.playing.toggle() } label: { Image(systemName: store.playing ? "pause.fill" : "play.fill") }
                .buttonStyle(SecondaryButtonStyle(height: 46, expand: false))
                .frame(width: 52)
                .accessibilityLabel(store.playing ? "Pause traffic" : "Play traffic")
            Button { store.speed = store.speed >= 4 ? 1 : store.speed * 2 } label: {
                Text("\(Int(store.speed))×").font(.system(size: 15, weight: .heavy).monospacedDigit())
            }
            .buttonStyle(SecondaryButtonStyle(height: 46, expand: false))
            .frame(width: 52)
            .accessibilityLabel("Speed")
            Button { withAnimation(.easeOut(duration: 0.2)) { showLog.toggle() } } label: { Image(systemName: "terminal.fill") }
                .buttonStyle(SecondaryButtonStyle(tint: showLog ? Theme.greenShadow : Theme.raised, height: 46, expand: false))
                .frame(width: 52)
                .accessibilityLabel("CloudWatch log")
        }
        .labelStyle(.titleAndIcon)
    }
}

struct LogPanel: View {
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("~ aws logs tail /event/\(store.mission.id) --follow").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.muted)
                Spacer()
                Button { store.restartEvent() } label: { Label("Replay", systemImage: "arrow.counterclockwise").font(.system(size: 11, weight: .bold)) }
                    .foregroundStyle(Theme.greenHi)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.panel2)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(store.logs) { line in
                            let level = Text(line.level.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0))
                                .foregroundStyle(line.level == .alarm ? Theme.red : line.level == .ok ? Theme.greenHi : Color(hex: 0x6cb6ff))
                            Text("\(Text(line.time).foregroundStyle(Theme.faint)) \(level)\(Text(line.text).foregroundStyle(Theme.soft))")
                                .font(.system(size: 11, design: .monospaced))
                                .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: store.logs.last?.id) { _, id in withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                .onAppear { proxy.scrollTo(store.logs.last?.id, anchor: .bottom) }
            }
        }
        .frame(height: 170)
        .background(Theme.terminal)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.06)))
    }
}

// MARK: - Inspector

struct Inspector: View {
    let store: Store
    let node: Node

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(12).background(Theme.panel2)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if node.kind == .viewers { viewers } else { controls }
                    connections
                    Text(node.spec.blurb).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ServiceIcon(kind: node.kind, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title).font(.system(size: 17, weight: .heavy))
                Text(node.spec.category.rawValue.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(node.spec.color.mix(with: .white, by: 0.35))
            }
            Spacer()
            if node.kind != .viewers {
                Menu {
                    Button { store.duplicate(node.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { store.remove(node.id) } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.muted).frame(width: 36, height: 36)
                }
            }
            Button { withAnimation(.easeOut(duration: 0.15)) { store.selection = nil } } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(Theme.muted).frame(width: 36, height: 36)
            }
            .accessibilityLabel("Close")
        }
    }

    private var viewers: some View {
        let d = store.live.demand
        return VStack(alignment: .leading, spacing: 8) {
            row("Watching now", Fmt.viewers(d.viewers))
            row("Video demand", Fmt.rate(d.load[.video], .video))
            row("API demand", Fmt.rate(d.load[.api], .api))
            row("Bot traffic", Fmt.percent(d.botShare))
            row("Bitrate", "\(Int(store.mission.bitrateMbps)) Mbps · 1080p")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.soft)
            Spacer()
            Text(value).font(.system(size: 14, weight: .bold).monospacedDigit())
        }
    }

    private var primary: [TrafficClass] {
        switch node.spec.role {
        case .cdn: [.video, .api]
        case .origin: [.video]
        case .cache: [.reads]
        case .queue: [.writes]
        case .database: [.reads, .writes]
        case .encoder: []
        default: [.api]
        }
    }

    @ViewBuilder private var controls: some View {
        let stat = store.live.stats[node.id] ?? NodeStat()
        let peak = store.forecast.peakUtil[node.id] ?? 0
        let cost = store.costs.first { $0.id == node.id }

        if node.spec.tiers.count > 1 {
            Menu {
                ForEach(Array(node.spec.tiers.enumerated()), id: \.offset) { i, t in
                    Button("\(t.name) · \(Fmt.money(t.monthly))/mo") { store.update(node.id) { $0.tier = i } }
                }
            } label: {
                HStack {
                    Text(node.tierSpec.name).font(.system(size: 14, weight: .bold))
                    Spacer()
                    Text("\(Fmt.rate(node.tierSpec.capacity, primary.first ?? .api)) each").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
            }
        }

        if node.spec.maxCount > 1 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(node.count)").font(.system(size: 26, weight: .heavy).monospacedDigit()).contentTransition(.numericText())
                    Text(node.spec.unit).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    Spacer()
                    if stat.effectiveCount < node.count {
                        Text("\(stat.effectiveCount) in use").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.orange)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(steps, id: \.self) { step in
                        Button(step > 0 ? "+\(step)" : "\(step)") {
                            withAnimation(.snappy) { store.update(node.id) { $0.count += step } }
                        }
                        .buttonStyle(SecondaryButtonStyle(tint: step > 0 ? Theme.raised : Theme.panel2, height: 36))
                        .disabled(step > 0 ? node.count >= node.spec.maxCount : node.count <= 1)
                    }
                }
                .font(.system(size: 14, weight: .heavy).monospacedDigit())
            }
        }

        if node.kind == .cloudFront {
            Toggle(isOn: Binding(get: { node.originShield }, set: { on in store.update(node.id) { $0.originShield = on } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Origin Shield").font(.system(size: 14, weight: .bold))
                    Text("Extra caching layer · misses 2% → 0.3% · +$500/mo").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            .tint(Theme.green)
        }

        if node.kind != .mediaLive {
            VStack(spacing: 8) {
                utilBar("Now", stat.util)
                utilBar("Event peak", peak)
                ForEach(primary, id: \.self) { c in
                    HStack {
                        Text(c.title).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("\(Fmt.rate(stat.incoming[c], c)) / \(Fmt.rate(stat.capacity[c], c))").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.soft)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel2))
        }

        if let cost {
            HStack {
                Text("Cost").font(.system(size: 13)).foregroundStyle(Theme.soft)
                Spacer()
                Text("\(Fmt.money(cost.total))/mo").font(.system(size: 15, weight: .heavy).monospacedDigit())
                Text("· \(Fmt.money(cost.total * 12))/yr").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }

    private var steps: [Int] {
        node.spec.maxCount >= 500 ? [-10, -1, 1, 10, 100] : node.spec.maxCount >= 30 ? [-5, -1, 1, 5] : [-1, 1]
    }

    private func utilBar(_ title: String, _ util: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.soft).frame(width: 72, alignment: .leading)
            GeometryReader { g in
                Capsule().fill(Theme.raised)
                    .overlay(alignment: .leading) { Capsule().fill(Theme.load(util)).frame(width: g.size.width * min(util, 1)) }
            }
            .frame(height: 8)
            Text(Fmt.percent(util)).font(.system(size: 12, weight: .heavy).monospacedDigit()).foregroundStyle(util > 1.0001 ? Theme.red : .white)
                .frame(width: 52, alignment: .trailing)
        }
    }

    @ViewBuilder private var connections: some View {
        let outgoing = store.design.edges.filter { $0.from == node.id }
        let incoming = store.design.edges.filter { $0.to == node.id }
        if !outgoing.isEmpty || !incoming.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !incoming.isEmpty { chips("FROM", incoming, other: \.from) }
                if !outgoing.isEmpty { chips("SENDS TO", outgoing, other: \.to) }
            }
        } else if node.spec.role != .database && node.spec.role != .origin {
            Text("Drag the green ⊕ handle onto another service to connect it.").font(.system(size: 12)).foregroundStyle(Theme.greenHi)
        }
    }

    private func chips(_ title: String, _ edges: [Edge], other: KeyPath<Edge, UUID>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(Theme.muted)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(edges) { e in
                        if let n = store.design.node(e[keyPath: other]) {
                            HStack(spacing: 6) {
                                ServiceIcon(kind: n.kind, size: 18)
                                Text(n.title).font(.system(size: 12, weight: .bold))
                                Button { store.unlink(e.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)) }
                                    .foregroundStyle(Theme.muted)
                                    .accessibilityLabel("Disconnect \(n.title)")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Capsule().fill(Theme.raised))
                            .onTapGesture { store.focus(n.id) }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}
