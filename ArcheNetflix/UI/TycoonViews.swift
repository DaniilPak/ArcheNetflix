import SwiftUI

// MARK: - HUD

struct TycoonHUD: View {
    let store: Store
    var onMenu: () -> Void
    var onCosts: () -> Void

    var body: some View {
        if let s = store.tycoon {
            let busy = store.selection != nil || store.selectedEdge != nil
            VStack(spacing: 8) {
                header(s)
                card(s, compact: busy)
                if !busy, let spike = s.spike { spikeBanner(s, spike) }
                else if !busy, store.hint == nil, let issue = store.forecast.worst.issues.first(where: { $0.severity == .failure }) {
                    Button { store.focus(issue.node) } label: { Banner(text: issue.text, color: Theme.orange, icon: "exclamationmark.triangle.fill") }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func header(_ s: TycoonState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "cloud.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.green)
            Button(action: onMenu) {
                HStack(spacing: 6) {
                    Image(systemName: s.business.symbol).foregroundStyle(Theme.greenHi)
                    Text(s.company).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .heavy))
                }
            }
            .buttonStyle(SecondaryButtonStyle(height: 36, expand: false))
            Spacer(minLength: 4)
            Button(action: onCosts) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("−\(Fmt.money(store.costPerHour * 24))").font(.system(size: 14, weight: .heavy).monospacedDigit()).fixedSize()
                    Text("AWS / day").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 10).frame(height: 36)
            }
            .buttonStyle(SecondaryButtonStyle(tint: Theme.panel, height: 36, expand: false))
        }
        .frame(height: 46)
    }

    private func card(_ s: TycoonState, compact: Bool) -> some View {
        let net = store.revenuePerHour - store.costPerHour
        let status = store.hasStarted ? store.live.status : .down
        let color = status == .holding ? Theme.green : status == .degraded ? Theme.yellow : Theme.red
        return VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.money(s.cash)).font(.system(size: 28, weight: .heavy).monospacedDigit())
                        .foregroundStyle(s.cash < 0 ? Theme.red : .white)
                        .contentTransition(.numericText())
                    Text("\(net >= 0 ? "+" : "−")\(Fmt.money(abs(net) * 24)) / day")
                        .font(.system(size: 13, weight: .heavy).monospacedDigit())
                        .foregroundStyle(net >= 0 ? Theme.greenHi : Theme.red)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(status.rawValue).font(.system(size: 13, weight: .heavy)).tracking(0.5)
                    }
                    .foregroundStyle(status == .holding ? Color(hex: 0x2b2a27) : .white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(status == .holding ? .white : color.opacity(0.9)))
                    Text("\(Fmt.viewers(s.users)) \(s.business.noun)").font(.system(size: 13, weight: .bold).monospacedDigit())
                    Text("\(Fmt.viewers(store.live.demand.viewers)) online").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.muted)
                }
            }
            if !compact {
                HStack {
                    Text("\(store.clock) · \(store.live.demand.phase)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.soft)
                    Spacer()
                    Text("Valued at \(Fmt.money(store.valuation))").font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(Theme.muted)
                }
                milestone(s)
            }
        }
        .padding(12)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func milestone(_ s: TycoonState) -> some View {
        if let next = Tycoon.nextMilestone(s) {
            let progress = log10(max(s.users, 1)) / log10(next.users)
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { g in
                    Capsule().fill(Theme.raised)
                        .overlay(alignment: .leading) { Capsule().fill(Theme.green).frame(width: g.size.width * min(max(progress, 0), 1)) }
                }
                .frame(height: 6)
                Text("\(Fmt.viewers(next.users)) \(s.business.noun) unlocks \(next.kinds.prefix(4).map(\.spec.name).joined(separator: ", "))\(next.kinds.count > 4 ? "…" : "")")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        } else if store.valuation >= Tycoon.ipoValuation {
            Button { store.goPublic() } label: { Label("Ring the bell — go public", systemImage: "building.columns.fill") }
                .buttonStyle(PrimaryButtonStyle(compact: true))
        } else {
            Text("Every AWS service unlocked · IPO at \(Fmt.money(Tycoon.ipoValuation)) valuation").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    private func spikeBanner(_ s: TycoonState, _ spike: Spike) -> some View {
        let live = s.hour >= spike.start
        let text: String
        if live {
            text = "\(spike.name) is live · \(Int(spike.end - s.hour)) h left · worst so far \(Fmt.percent(spike.minHealth)) served. Hold ≥ 98% to win 10% more \(s.business.noun)."
        } else {
            let ready = store.spikeForecast.map { $0.minHealth >= 0.98 } ?? false
            let served = store.spikeForecast.map { Fmt.percent($0.minHealth) } ?? "?"
            text = "\(spike.name) in \(Int(spike.start - s.hour)) h: \(Int(spike.multiplier))× traffic for \(Int(spike.end - spike.start)) h. At that load you'd serve \(served)\(ready ? " — ready." : ". Scale up first!")"
        }
        return Banner(text: text, color: live ? Theme.red : Theme.yellow, icon: "bolt.fill")
    }
}

// MARK: - Setup

struct TycoonSetupSheet: View {
    let store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var business: Business = .store
    @State private var frontend: Frontend = .spa
    @State private var stack: Stack = .node
    @State private var name = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(["1 · CHOOSE YOUR BUSINESS", "2 · CHOOSE A FRONTEND", "3 · CHOOSE A BACKEND STACK"][step])
                        .font(.system(size: 11, weight: .heavy)).tracking(0.6).foregroundStyle(Theme.greenHi)
                    switch step {
                    case 0:
                        ForEach(Business.allCases) { b in
                            choice(b.title, b.symbol, b.pitch, b.pros, b.cons, selected: business == b,
                                   stats: String(format: "$%.2f profit/user/month · market ", b.arpuDay * 30) + Fmt.viewers(b.marketCap)) { business = b }
                        }
                    case 1:
                        ForEach(Frontend.allCases) { f in
                            choice(f.title, f.symbol, nil, f.pros, f.cons, selected: frontend == f,
                                   stats: f.buildCost > 0 ? "Costs \(Fmt.money(f.buildCost)) of your \(Fmt.money(Tycoon.startingCash))" : "Free to build") { frontend = f }
                        }
                    default:
                        ForEach(Stack.allCases) { k in
                            choice(k.title, k.symbol, nil, k.pros, k.cons, selected: stack == k,
                                   stats: String(format: "%.1f× throughput · %.2f× shipping speed", k.perf, k.devSpeed)) { stack = k }
                        }
                        TextField(business.defaultName, text: $name)
                            .textInputAutocapitalization(.words)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                        if let points = store.tycoon?.founderPoints, points > 0 {
                            Text(String(format: "Founder bonus from past IPOs: +%.0f%% growth and revenue", points * 10))
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.yellow)
                        }
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    if step > 0 { Button("Back") { step -= 1 }.buttonStyle(SecondaryButtonStyle()) }
                    Button(step < 2 ? "Next" : "Found \(name.isEmpty ? business.defaultName : name)") {
                        if step < 2 { step += 1 } else {
                            store.startTycoon(business, frontend: frontend, stack: stack, name: name)
                            dismiss()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(16)
                .background(Theme.bg)
            }
            .background(Theme.bg)
            .navigationTitle("New company")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationBackground(Theme.bg)
    }

    private func choice(_ title: String, _ symbol: String, _ pitch: String?, _ pros: [String], _ cons: [String], selected: Bool,
                        stats: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.green : Theme.raised))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 16, weight: .heavy))
                        Text(stats).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 20)).foregroundStyle(selected ? Theme.greenHi : Theme.faint)
                }
                if let pitch { Text(pitch).font(.system(size: 13)).foregroundStyle(Theme.soft) }
                ForEach(pros, id: \.self) { p in Label(p, systemImage: "plus.circle.fill").foregroundStyle(Theme.greenHi) }
                ForEach(cons, id: \.self) { c in Label(c, systemImage: "minus.circle.fill").foregroundStyle(Theme.orange) }
            }
            .font(.system(size: 12, weight: .semibold))
            .multilineTextAlignment(.leading)
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel).strokeBorder(selected ? Theme.green : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shop

struct ShopSheet: View {
    let store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let s = store.tycoon {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(Fmt.money(s.cash)).font(.system(size: 26, weight: .heavy).monospacedDigit())
                            Spacer()
                            Text("\(Fmt.viewers(s.users)) \(s.business.noun) · \(Int(s.equity * 100))% yours").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                        }
                        section("GROWTH", [.marketing, .features, .international], s)
                        section("AUTOMATION", [.autoCompute, .autoData, .autoQuotas], s)
                        section("SAVINGS", [.reserved, .cdnDeal], s)
                        Text("FUNDING").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Theme.muted)
                        ForEach(Funding.allCases) { f in funding(f, s) }
                        Text("IPO").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Theme.muted)
                        ipo(s)
                    }
                    .padding(16)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Upgrades")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
    }

    private func section(_ title: String, _ items: [Upgrade], _ s: TycoonState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Theme.muted)
            ForEach(items) { u in row(u, s) }
        }
    }

    private func row(_ u: Upgrade, _ s: TycoonState) -> some View {
        let level = s.level(u)
        let maxed = level >= u.maxLevel
        let locked = s.users < u.unlockUsers
        return HStack(spacing: 12) {
            Image(systemName: u.symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(width: 38, height: 38).background(RoundedRectangle(cornerRadius: 8).fill(locked ? Theme.raised : Theme.greenShadow))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(u.title).font(.system(size: 14, weight: .heavy))
                    if u.maxLevel > 1 { Text("Lv \(level)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted) }
                }
                Text(locked ? "Unlocks at \(Fmt.viewers(u.unlockUsers)) \(s.business.noun)" : u.detail)
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if maxed {
                Text(u.maxLevel > 1 ? "MAX" : "OWNED").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.greenHi)
            } else {
                Button(Fmt.money(u.cost(level: level))) { store.buy(u) }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .disabled(!store.canBuy(u))
                    .opacity(store.canBuy(u) ? 1 : 0.45)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
    }

    private func funding(_ f: Funding, _ s: TycoonState) -> some View {
        let taken = s.funding.contains(f.rawValue)
        let ready = s.users >= f.minUsers
        return HStack(spacing: 12) {
            Image(systemName: "dollarsign.circle.fill").font(.system(size: 20)).foregroundStyle(taken ? Theme.faint : Theme.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(f.title): \(Fmt.money(f.cash))").font(.system(size: 14, weight: .heavy))
                Text(ready ? "Investors take \(Int(f.dilution * 100))% — lowers your IPO payout" : "Investors want \(Fmt.viewers(f.minUsers)) \(s.business.noun) first")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if taken {
                Text("RAISED").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.muted)
            } else {
                Button("Raise") { store.raise(f) }.buttonStyle(PrimaryButtonStyle(compact: true)).disabled(!ready).opacity(ready ? 1 : 0.45)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
    }

    private func ipo(_ s: TycoonState) -> some View {
        let ready = store.valuation >= Tycoon.ipoValuation
        return VStack(alignment: .leading, spacing: 8) {
            Text("Valuation \(Fmt.money(store.valuation)) of \(Fmt.money(Tycoon.ipoValuation))").font(.system(size: 14, weight: .heavy))
            Text("Valuation = 8× yearly revenue. Going public ends this company and turns your share into founder points: +10% growth and revenue each, forever.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            Button { store.goPublic(); dismiss() } label: { Label("Go public", systemImage: "building.columns.fill") }
                .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(!ready).opacity(ready ? 1 : 0.45)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
    }
}

// MARK: - End states

struct IPOCard: View {
    let result: IPOResult
    var onNext: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "building.columns.fill").font(.system(size: 26, weight: .heavy))
                .frame(width: 60, height: 60).background(Circle().fill(Theme.green))
            Text("\(result.company) is public!").font(.system(size: 24, weight: .heavy)).multilineTextAlignment(.center)
            Text("Day \(result.days) · valued at \(Fmt.money(result.valuation)) · you kept \(Int(result.equity * 100))%")
                .font(.system(size: 14)).foregroundStyle(Theme.soft).multilineTextAlignment(.center)
            Text(String(format: "+%.1f founder points → +%.0f%% growth and revenue in your next company", result.points, result.points * 10))
                .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.yellow).multilineTextAlignment(.center)
            Button("Found your next company", action: onNext).buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel).strokeBorder(Theme.green.opacity(0.5)))
        .padding(24)
        .frame(maxWidth: 460)
    }
}

struct BankruptCard: View {
    let store: Store
    var onRestart: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "xmark").font(.system(size: 24, weight: .heavy))
                .frame(width: 56, height: 56).background(Circle().fill(Theme.red))
            Text("Out of runway").font(.system(size: 24, weight: .heavy))
            Text("\(store.tycoon?.company ?? "Your company") spent more on AWS than it earned. Keep infrastructure small until revenue catches up — Lambda and DynamoDB cost nothing when idle.")
                .font(.system(size: 14)).foregroundStyle(Theme.soft).multilineTextAlignment(.center)
            Button("Start a new company", action: onRestart).buttonStyle(PrimaryButtonStyle())
            Button("Back to missions") { store.leaveTycoon() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel).strokeBorder(Theme.red.opacity(0.5)))
        .padding(24)
        .frame(maxWidth: 460)
    }
}
