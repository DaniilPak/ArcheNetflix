import SwiftUI

struct PaletteSheet: View {
    let store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let anchor = store.selected, anchor.spec.role != .database, anchor.spec.role != .origin {
                        Banner(text: "Adds after \(anchor.title) and connects it automatically.", color: Theme.green, icon: "link")
                    }
                    ForEach(Category.allCases, id: \.self) { cat in
                        let kinds = ServiceKind.buildable.filter { $0.spec.category == cat }
                        if !kinds.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(cat.rawValue.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Theme.muted)
                                ForEach(kinds) { kind in cell(kind) }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Add AWS service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
    }

    private func cell(_ kind: ServiceKind) -> some View {
        let spec = kind.spec
        let tier = spec.tiers[kind == .ec2 ? 1 : 0]
        return Button {
            store.add(kind)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ServiceIcon(kind: kind, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(spec.name).font(.system(size: 15, weight: .heavy))
                        Spacer()
                        Text(tier.monthly > 0 ? "\(Fmt.money(tier.monthly))/mo" : "pay per use").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.greenHi)
                    }
                    Text(spec.blurb).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        }
        .buttonStyle(.plain)
    }
}

struct MissionsSheet: View {
    let store: Store
    var onBrief: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Mission.all) { m in
                        let current = m.id == store.mission.id
                        Button {
                            if !current { store.choose(m) }
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(m.title).font(.system(size: 18, weight: .heavy))
                                    Spacer()
                                    if current {
                                        Text("PLAYING").font(.system(size: 10, weight: .heavy)).tracking(0.6).foregroundStyle(Color(hex: 0x2b2a27))
                                            .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Theme.greenHi))
                                    }
                                }
                                Text(m.tagline).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.greenHi)
                                Text(m.brief).font(.system(size: 13)).foregroundStyle(Theme.soft).multilineTextAlignment(.leading)
                                Text("★★★ budget \(Fmt.money(m.budget))/mo · \(Int(m.bitrateMbps)) Mbps · \(Int(m.eventHours)) h event")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                            }
                            .foregroundStyle(.white)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel).strokeBorder(current ? Theme.green : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 8) {
                        Button { dismiss(); onBrief() } label: { Label("Mission brief", systemImage: "doc.text") }
                            .buttonStyle(SecondaryButtonStyle())
                        Button { confirmReset = true } label: { Label("Clear board", systemImage: "trash") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.top, 6)
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Events")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove every service from \(store.mission.title)?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Clear board", role: .destructive) { store.resetDesign(); dismiss() }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationBackground(Theme.bg)
    }
}

struct CostSheet: View {
    let store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Fmt.money(store.monthly)).font(.system(size: 32, weight: .heavy).monospacedDigit())
                            Text("/ month").foregroundStyle(Theme.muted)
                        }
                        Text("\(Fmt.money(store.monthly * 12)) / year").font(.system(size: 17, weight: .bold).monospacedDigit()).foregroundStyle(Theme.soft)
                        HStack(spacing: 4) {
                            ForEach(0..<3) { i in Image(systemName: i < store.stars ? "star.fill" : "star") }
                            Text("★★★ under \(Fmt.money(store.mission.budget))/mo").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.leading, 4)
                        }
                        .foregroundStyle(Theme.yellow)
                    }
                    .listRowBackground(Theme.panel)
                    Toggle(isOn: Binding(get: { store.design.scheduledScaling }, set: { store.setScheduled($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scheduled scaling").font(.system(size: 15, weight: .bold))
                            Text("Run EC2, Fargate and ElastiCache only around the event (+\(Int(Pricing.scheduledHoursPerEvent)) h warm-up) instead of 24/7.")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                    .tint(Theme.green)
                    .listRowBackground(Theme.panel)
                }
                Section("Breakdown") {
                    if store.costs.isEmpty { Text("Nothing deployed yet.").foregroundStyle(Theme.muted) }
                    ForEach(store.costs) { line in
                        HStack(spacing: 10) {
                            ServiceIcon(kind: line.node.kind, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.node.title).font(.system(size: 14, weight: .bold))
                                Text(detail(line)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Text(Fmt.money(line.total)).font(.system(size: 14, weight: .heavy).monospacedDigit())
                        }
                        .listRowBackground(Theme.panel)
                    }
                }
                Section {
                    Text("Approximate us-east-1 list prices. Assumes one \(Int(store.mission.eventHours)) h event per month at \(Int(store.mission.bitrateMbps)) Mbps. CloudFront data transfer at the 5 PB+ tier ($0.02/GB) — at this scale it dominates the bill, which is why streamers negotiate private CDN pricing.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Cost estimate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
    }

    private func detail(_ line: CostLine) -> String {
        let n = line.node
        var parts: [String] = []
        if n.spec.maxCount > 1 { parts.append("\(n.count) × \(n.tierSpec.name)") } else { parts.append(n.tierSpec.name) }
        if line.fixed > 0 { parts.append("\(Fmt.money(line.fixed)) fixed") }
        if line.usage > 0.5 { parts.append("\(Fmt.money(line.usage)) usage") }
        return parts.joined(separator: " · ")
    }
}

struct BriefSheet: View {
    let store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let m = store.mission
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 22, weight: .bold))
                .frame(width: 46, height: 46).background(RoundedRectangle(cornerRadius: 8).fill(Theme.green))
            Text(m.tagline.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Theme.greenHi)
            Text(m.title).font(.system(size: 28, weight: .heavy))
            Text(m.brief).font(.system(size: 15)).foregroundStyle(Theme.soft).lineSpacing(3)
            VStack(alignment: .leading, spacing: 8) {
                step("01", "Tap Add service to place AWS services on the board.")
                step("02", "Drag a service's green ⊕ handle onto another to connect them.")
                step("03", "Traffic runs live. Red means dropping requests — scale it up.")
                step("04", "Survive a full event at 99.5%+ under \(Fmt.money(m.budget))/mo for ★★★.")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            Text("Pinch to zoom · drag empty space to pan").font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Button("Start building") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
        .foregroundStyle(.white)
        .presentationDetents([.large])
        .presentationBackground(Theme.bg)
        .preferredColorScheme(.dark)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(n).font(.system(size: 12, weight: .heavy)).frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 4).fill(Theme.raised))
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.soft)
        }
    }
}

struct VictoryCard: View {
    let store: Store
    let victory: Victory
    var onNext: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark").font(.system(size: 26, weight: .heavy))
                .frame(width: 60, height: 60).background(Circle().fill(Theme.green))
            Text("The stream held!").font(.system(size: 24, weight: .heavy))
            Text("Every viewer got \(store.mission.mainEvent) without buffering.").font(.system(size: 14)).foregroundStyle(Theme.soft).multilineTextAlignment(.center)
            HStack(spacing: 6) {
                ForEach(0..<3) { i in Image(systemName: i < victory.stars ? "star.fill" : "star").font(.system(size: 28, weight: .bold)) }
            }
            .foregroundStyle(Theme.yellow)
            HStack {
                stat("Per month", Fmt.money(victory.cost))
                stat("Per year", Fmt.money(victory.cost * 12))
                stat("★★★ budget", Fmt.money(store.mission.budget))
            }
            if victory.stars < 3 {
                Text("Trim idle capacity or try scheduled scaling to earn more stars.").font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                Button("Keep tuning") { store.victory = nil }.buttonStyle(SecondaryButtonStyle())
                if let next = nextMission {
                    Button("Next event") { store.victory = nil; store.choose(next); onNext() }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel).strokeBorder(Theme.green.opacity(0.5)))
        .padding(24)
        .frame(maxWidth: 460)
    }

    private var nextMission: Mission? {
        guard let i = Mission.all.firstIndex(where: { $0.id == store.mission.id }), i + 1 < Mission.all.count else { return nil }
        return Mission.all[i + 1]
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .heavy).monospacedDigit())
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel2))
    }
}
