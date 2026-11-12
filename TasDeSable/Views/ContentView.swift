import SwiftUI

/// Fenêtre principale : liste des expériences à gauche, vue 3D et panneau de commandes à droite.
struct ContentView: View {
    @Environment(SimulationModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(SimulationMode.allCases, selection: $model.mode) { mode in
                Label(mode.title, systemImage: mode.symbol).tag(mode)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            detail
                .navigationTitle(model.mode.title)
                .navigationSubtitle("\(model.gridWidth) × \(model.gridHeight) · seuil \(model.threshold) · \(model.state.label)")
                .toolbar {
                    ToolbarItem {
                        SettingsLink {
                            Label("Réglages", systemImage: "gearshape")
                        }
                    }
                }
        }
        .task { model.runDemoIfRequested() }
        .alert("Erreur", isPresented: Binding(get: { model.errorMessage != nil },
                                              set: { if !$0 { model.dismissError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.mode == .comparison {
            ComparisonView()
        } else {
            HStack(spacing: 0) {
                SimulationCanvas()
                Divider()
                ScrollView {
                    panel
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 320)
            }
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch model.mode {
        case .randomDrop: RandomDropPanel()
        case .centralPour: CentralPourPanel()
        case .divisible: DivisiblePanel()
        case .comparison: EmptyView()
        }
    }
}

/// Vue 3D de la grille courante et légende des couleurs.
///
/// Vue distincte pour que SwiftUI suive `model.snapshot` dans son propre `body` et
/// transmette chaque nouvelle grille au rendu.
struct SimulationCanvas: View {
    @Environment(SimulationModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MetalView(snapshot: model.snapshot, displayMode: settings.displayMode)
            if model.mode != .divisible {
                PaletteLegend(threshold: model.threshold)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
            }
        }
    }
}

/// Ligne « libellé : valeur » des panneaux.
struct StatRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent(title) {
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}
