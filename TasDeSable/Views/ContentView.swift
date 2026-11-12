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
                // La barre de titre ne suit pas \.locale : les textes sont résolus dans la langue choisie.
                .navigationTitle(settings.language.localized(model.mode.titleResource))
                .navigationSubtitle(settings.language.localized(
                    "\(model.gridWidth) × \(model.gridHeight) · seuil \(model.threshold)")
                    + " · " + settings.language.localized(model.state.labelResource))
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
            Text(verbatim: model.errorMessage ?? "")
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
            MetalView(snapshot: model.snapshot, displayMode: settings.displayMode,
                      palette: settings.paletteColors)
            if model.mode != .divisible {
                PaletteLegend(threshold: model.threshold, palette: Palette(settings.paletteColors))
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
            }
        }
    }
}

/// Ligne « libellé : valeur » des panneaux. La valeur est un `Text`, pour que les nombres
/// soient formatés selon la langue de l'interface (`Text(n, format: .number)`).
struct StatRow: View {
    let title: LocalizedStringKey
    let value: Text

    init(_ title: LocalizedStringKey, _ value: Text) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent {
            value.monospacedDigit()
        } label: {
            Text(title)
        }
        .font(.callout)
    }
}

/// « n case » ou « n cases » selon n.
func cellsText(_ n: Int) -> Text {
    n == 1 ? Text("\(n, format: .number) case") : Text("\(n, format: .number) cases")
}

/// « n bascule » ou « n bascules » selon n.
func topplesText(_ n: Int) -> Text {
    n == 1 ? Text("\(n, format: .number) bascule") : Text("\(n, format: .number) bascules")
}

/// Durée en secondes, formatée selon la langue.
func secondsText(_ seconds: Double, digits: Int = 3) -> Text {
    Text("\(seconds, format: .number.precision(.fractionLength(digits))) s")
}
