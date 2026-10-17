import SwiftUI

struct ContentView: View {
    @State private var store = Store()
    @State private var showPalette = false
    @State private var showMissions = false
    @State private var showCosts = false
    @State private var showBrief = !UserDefaults.standard.bool(forKey: "briefSeen")
    @State private var showLog = false
    @State private var showSetup = false
    @State private var showShop = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 700
            ZStack {
                BoardView(store: store).ignoresSafeArea()
                VStack(spacing: 8) {
                    Group {
                        if store.mode == .tycoon {
                            TycoonHUD(store: store, onMenu: { showMissions = true }, onCosts: { showCosts = true })
                        } else {
                            HUD(store: store, onMissions: { showMissions = true }, onCosts: { showCosts = true })
                        }
                    }
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
                    if let toast = store.toast {
                        Banner(text: toast, color: Theme.yellow, icon: "info.circle.fill").frame(maxWidth: 520)
                            .transition(.opacity)
                    }
                    Spacer()
                    VStack(spacing: 8) {
                        if showLog { LogPanel(store: store).transition(.move(edge: .bottom).combined(with: .opacity)) }
                        if let hint = store.hint, store.selection == nil, store.selectedEdge == nil {
                            HintCard(store: store, hint: hint).transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if let node = store.selected {
                            Inspector(store: store, node: node)
                                .id(node.id)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if let edge = store.edge {
                            EdgeInspector(store: store, edge: edge, onInsert: { showPalette = true })
                                .id(edge.id)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        BottomBar(store: store, showLog: $showLog, onAdd: { showPalette = true }, onShop: { showShop = true })
                    }
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .animation(.easeOut(duration: 0.2), value: store.selection)
                .animation(.easeOut(duration: 0.2), value: store.selectedEdge)
                .animation(.easeOut(duration: 0.2), value: store.toast)
                .animation(.easeOut(duration: 0.2), value: store.hint?.id)

                if let result = store.ipoResult {
                    Color.black.opacity(0.55).ignoresSafeArea().transition(.opacity)
                    IPOCard(result: result, onNext: { store.ipoResult = nil; showSetup = true })
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else if store.bankrupt && store.mode == .tycoon {
                    Color.black.opacity(0.55).ignoresSafeArea().transition(.opacity)
                    BankruptCard(store: store, onRestart: { showSetup = true })
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                if let victory = store.victory {
                    Color.black.opacity(0.55).ignoresSafeArea().transition(.opacity)
                    VictoryCard(store: store, victory: victory, onNext: { showBrief = true })
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: store.victory?.id)
            .animation(.spring(duration: 0.35), value: store.ipoResult?.id)
            .animation(.spring(duration: 0.35), value: store.bankrupt)
        }
        .foregroundStyle(.white)
        .background(Theme.bg)
        .task { await store.run() }
        .sheet(isPresented: $showPalette) { PaletteSheet(store: store) }
        .sheet(isPresented: $showMissions) {
            MissionsSheet(store: store, onBrief: { showBrief = true }, onNewCompany: { showMissions = false; showSetup = true }, onShop: { showMissions = false; showShop = true })
        }
        .sheet(isPresented: $showSetup) { TycoonSetupSheet(store: store) }
        .sheet(isPresented: $showShop) { ShopSheet(store: store) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { store.save() } }
        .onChange(of: store.offlineReport) { _, report in
            if let report { store.show(report); store.offlineReport = nil }
        }
        .sheet(isPresented: $showCosts) { CostSheet(store: store) }
        .sheet(isPresented: $showBrief, onDismiss: { UserDefaults.standard.set(true, forKey: "briefSeen") }) { BriefSheet(store: store) }
        .sensoryFeedback(.error, trigger: store.live.status == .down && store.hasStarted)
        .sensoryFeedback(.success, trigger: store.victory?.id)
        .sensoryFeedback(.impact(weight: .light), trigger: store.design.edges.count)
    }
}

#Preview { ContentView().preferredColorScheme(.dark) }
