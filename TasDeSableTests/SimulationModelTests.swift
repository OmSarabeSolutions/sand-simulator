import AppKit
import SwiftUI
import Testing
@testable import TasDeSable

/// Réglages isolés des préférences de l'application hôte.
@MainActor
func makeSettings(side: Int = 32, pour: Int = 2_000, threshold: Int = 4,
                  language: AppLanguage = .fr) -> AppSettings {
    let settings = AppSettings(defaults: MemorySettingsStore())
    settings.gridWidth = side
    settings.gridHeight = side
    settings.pourAmount = pour
    settings.threshold = threshold
    settings.language = language
    settings.save()
    return settings
}

/// Attend que le modèle ait fini son opération et son calcul d'arrière-plan (10 s au plus).
@MainActor
func waitUntilIdle(_ model: SimulationModel) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while (model.state.isBusy || model.isComputingPourStats) && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("Modèle de simulation")
@MainActor
struct SimulationModelTests {
    @Test("Ajout aléatoire : statistiques, conservation, remise à zéro")
    func randomDrops() async {
        let model = SimulationModel(settings: makeSettings())
        let version = model.snapshot.version
        model.drop(3_000)
        #expect(model.state == .dropping)
        model.drop(10)                                   // ignoré : une opération est en cours
        await waitUntilIdle(model)
        #expect(model.stats.drops == 3_000)
        #expect(model.randomGrid.totalGrains + UInt64(model.stats.lostGrains) == 3_000)
        #expect(model.randomGrid.isStable(threshold: 4))
        #expect(model.lastAvalanche != nil)
        #expect(model.snapshot.version > version)
        #expect(model.snapshot.kind == .grains)
        #expect(model.hasContent)

        model.resetRandom()
        #expect(model.stats.drops == 0)
        #expect(model.randomGrid.isEmpty)
        #expect(model.lastAvalanche == nil)
    }

    @Test("Ajout continu : démarre, ajoute des grains, s'arrête")
    func continuousDrops() async throws {
        let model = SimulationModel(settings: makeSettings())
        model.dropsPerTick = 100
        model.startContinuousDrop()
        #expect(model.isDroppingContinuously)
        try await Task.sleep(for: .milliseconds(200))
        model.stopContinuousDrop()
        #expect(!model.isDroppingContinuously)
        #expect(model.state == .idle)
        #expect(model.stats.drops > 0)
    }

    @Test("Versement central : GPU, puis avalanches grain par grain identiques au GPU")
    func centralPour() async {
        let model = SimulationModel(settings: makeSettings(side: 32, pour: 2_000))
        model.mode = .centralPour
        model.pourCenter()
        await waitUntilIdle(model)
        #expect(model.pouredGrains == 2_000)
        #expect(model.pourGrid.isStable(threshold: 4))
        #expect(model.lastPourSeconds != nil)
        #expect(model.pourStats.drops == 2_000)
        #expect(model.pourStatsDone == model.pourStatsTotal)
        #expect(model.pourStatsMatchGPU == true)

        model.pourCenter()                               // la série continue sur la grille déjà versée
        await waitUntilIdle(model)
        #expect(model.pouredGrains == 4_000)
        #expect(model.pourStats.drops == 4_000)
        #expect(model.pourStatsMatchGPU == true)
        #expect(UInt64(model.pouredGrains) >= model.pourGrid.totalGrains)

        model.resetPour()
        #expect(model.pouredGrains == 0)
        #expect(model.pourGrid.isEmpty)
        #expect(model.pourStatsTotal == 0)
    }

    @Test("Versement central : le calcul grain par grain peut être arrêté")
    func cancelPourStats() async throws {
        let model = SimulationModel(settings: makeSettings(side: 256, pour: 200_000))
        model.pourCenter()
        while model.state.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.isComputingPourStats)
        model.cancelPourStats()
        #expect(!model.isComputingPourStats)
        #expect(model.pourStatsMatchGPU == nil)
        #expect(model.pourStatsDone < model.pourStatsTotal)
    }

    @Test("Vérification abélienne : trois ordres, une seule grille")
    func abelianCheck() async {
        let model = SimulationModel(settings: makeSettings(side: 40, pour: 5_000))
        model.verifyAbelian()
        #expect(model.state == .verifying)
        await waitUntilIdle(model)
        let report = try? #require(model.abelianReport)
        #expect(report?.isAbelian == true)
        #expect(report?.differingCells == 0)
        #expect(report?.grains == 5_000)
    }

    @Test("Tas divisible : rapport et image envoyée au rendu")
    func divisible() async {
        let model = SimulationModel(settings: makeSettings(side: 64, pour: 1_000))
        model.mode = .divisible
        model.runDivisible()
        await waitUntilIdle(model)
        let report = try? #require(model.divisibleReport)
        #expect((900...1_000).contains(report?.fullCells ?? 0))
        #expect(abs((report?.remainingMass ?? 0) - 1_000) < 1)
        #expect(model.snapshot.kind == .mass)
        #expect(abs((report?.fullRadius ?? 0) - (report?.discRadius ?? 0)) < 1)
    }

    @Test("Quatre tas : N à 1 000 N grains, aucun grain perdu")
    func comparison() async {
        let model = SimulationModel(settings: makeSettings(pour: 100))
        model.mode = .comparison
        model.runComparison()
        await waitUntilIdle(model)
        #expect(model.comparison.map(\.grains) == [100, 1_000, 10_000, 100_000])
        for pile in model.comparison {
            #expect(pile.grid.totalGrains == UInt64(pile.grains))
        }
    }

    @Test("Appliquer les réglages recrée les grilles et efface les résultats")
    func applySettings() async {
        let settings = makeSettings()
        let model = SimulationModel(settings: settings)
        model.drop(500)
        await waitUntilIdle(model)
        settings.gridWidth = 20
        settings.gridHeight = 10
        settings.threshold = 6
        model.applyGridSettings()
        #expect(model.gridWidth == 20 && model.gridHeight == 10)
        #expect(model.threshold == 6)
        #expect(!model.hasContent)
        #expect(model.snapshot.threshold == 6)
    }

    @Test("Lancement avec -demo <mode>")
    func demoArgument() async {
        let model = SimulationModel(settings: makeSettings(pour: 1_000))
        model.runDemoIfRequested(arguments: ["app", "-demo", "divisible"])
        #expect(model.mode == .divisible)
        await waitUntilIdle(model)
        #expect(model.divisibleReport != nil)
        model.runDemoIfRequested(arguments: ["app", "-demo", "inconnu"])
        #expect(model.mode == .divisible)
    }

    @Test("Titres et états traduits dans les deux langues")
    func labels() {
        for mode in SimulationMode.allCases {
            #expect(AppLanguage.en.localized(mode.titleResource) != AppLanguage.fr.localized(mode.titleResource))
            #expect(!mode.symbol.isEmpty)
        }
        let states: [SimulationState] = [.idle, .dropping, .pouring, .verifying, .relaxing, .comparing]
        for state in states {
            #expect(!AppLanguage.en.localized(state.labelResource).isEmpty)
        }
        #expect(GPUSandpileError.noDevice.errorDescription?.isEmpty == false)
        #expect(AppLanguage.en.localized(GPUSandpileError.missingFunction("topple").message).contains("topple"))
    }
}

/// Construit chaque vue dans une fenêtre hors écran, dans les deux langues, pour vérifier que
/// leurs corps s'évaluent sans erreur (y compris les branches qui affichent des résultats).
@Suite("Vues")
@MainActor
struct ViewTests {
    private func render(_ view: some View, settings: AppSettings, model: SimulationModel,
                        size: CGSize = CGSize(width: 1_100, height: 800)) {
        let host = NSHostingView(rootView: view
            .environment(settings)
            .environment(model)
            .environment(\.locale, settings.language.locale))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }

    @Test("Toutes les vues, vides puis avec résultats", arguments: AppLanguage.allCases)
    func allViews(language: AppLanguage) async {
        let settings = makeSettings(side: 32, pour: 1_000, language: language)
        let model = SimulationModel(settings: settings)
        for mode in SimulationMode.allCases {
            model.mode = mode
            render(ContentView(), settings: settings, model: model)
        }
        render(SettingsView(), settings: settings, model: model, size: CGSize(width: 560, height: 1_000))

        // Avec des résultats dans chaque panneau
        model.drop(2_000)
        await waitUntilIdle(model)
        model.pourCenter()
        await waitUntilIdle(model)
        model.verifyAbelian()
        await waitUntilIdle(model)
        model.runDivisible()
        await waitUntilIdle(model)
        model.runComparison()
        await waitUntilIdle(model)
        render(RandomDropPanel(), settings: settings, model: model)
        render(CentralPourPanel(), settings: settings, model: model)
        render(DivisiblePanel(), settings: settings, model: model)
        render(ComparisonView(), settings: settings, model: model)

        // Palette personnalisée et couleur seule
        settings.palette = .custom
        settings.displayMode = .colorOnly
        render(SettingsView(), settings: settings, model: model, size: CGSize(width: 560, height: 1_200))
        render(PaletteSwatch(colors: settings.paletteColors), settings: settings, model: model)
        render(AvalancheHistogram(stats: model.pourStats), settings: settings, model: model)
    }
}
