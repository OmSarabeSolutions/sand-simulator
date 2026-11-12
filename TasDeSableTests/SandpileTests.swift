import Foundation
import Testing
@testable import TasDeSable

@Suite("Tas abélien sur le CPU")
struct CPUSandpileTests {
    @Test("Une case à 4 grains donne un grain à chacune de ses voisines")
    func singleTopple() {
        var grid = Grid(width: 5, height: 5)
        grid[2, 2] = 4
        var scratch = ToppleScratch(count: grid.count)
        let avalanche = CPUSandpile.relax(&grid, threshold: 4, scratch: &scratch)
        #expect(grid[2, 2] == 0)
        #expect(grid[1, 2] == 1 && grid[3, 2] == 1 && grid[2, 1] == 1 && grid[2, 3] == 1)
        #expect(grid.totalGrains == 4)
        #expect(avalanche == Avalanche(topples: 1, area: 1, lost: 0))
    }

    @Test("Un coin bascule et perd deux grains par le bord")
    func cornerLosesGrains() {
        var grid = Grid(width: 3, height: 3)
        grid[0, 0] = 4
        var scratch = ToppleScratch(count: grid.count)
        let avalanche = CPUSandpile.relax(&grid, threshold: 4, scratch: &scratch)
        #expect(avalanche.lost == 2)
        #expect(grid.totalGrains == 2)
    }

    @Test("Grains ajoutés = grains restants + grains perdus, et la grille reste stable")
    func conservationAndStability() {
        var dropper = RandomDropper(grid: Grid(width: 16, height: 16), threshold: 4)
        let avalanches = dropper.drop(20_000)
        let lost = avalanches.reduce(0) { $0 + $1.lost }
        #expect(dropper.grid.totalGrains + UInt64(lost) == 20_000)
        #expect(dropper.grid.isStable(threshold: 4))
    }

    @Test("Plus d'un ajout sur deux ne fait rien à l'état critique")
    func mostDropsAreQuiet() {
        var dropper = RandomDropper(grid: Grid(width: 64, height: 64), threshold: 4)
        _ = dropper.drop(30_000)                     // on atteint l'état critique
        var stats = AvalancheStats()
        stats.record(dropper.drop(20_000))
        #expect(stats.quietFraction > 0.5)
        #expect(stats.largestArea > 1_000)
        #expect(!stats.histogram.isEmpty)
    }

    @Test("Versement grain par grain au centre = relaxation d'un bloc, et statistiques par lots = un seul lot")
    func centerDropper() async throws {
        var initial = Grid(width: 48, height: 48)
        initial.cells[initial.centerIndex] = 20_000
        let direct = try await CPUSandpile().relax(initial, threshold: 4)

        var oneByOne = CenterDropper(grid: Grid(width: 48, height: 48), threshold: 4)
        var whole = AvalancheStats()
        oneByOne.drop(20_000, into: &whole)
        #expect(oneByOne.grid == direct)
        #expect(whole.drops == 20_000)
        #expect(whole.quietFraction > 0 && whole.quietFraction < 1)

        var batched = CenterDropper(grid: Grid(width: 48, height: 48), threshold: 4)
        var merged = AvalancheStats()
        for _ in 0..<4 {
            var part = AvalancheStats()
            batched.drop(5_000, into: &part)
            merged.merge(part)
        }
        #expect(batched.grid == direct)
        #expect(merged.drops == whole.drops && merged.quietDrops == whole.quietDrops)
        #expect(merged.totalTopples == whole.totalTopples && merged.bins == whole.bins)
        #expect(merged.largestArea == whole.largestArea)
    }

    @Test("Graduations en puissances de 10")
    func powersOfTen() {
        #expect(AvalancheHistogram.powerOfTen(0) == "10⁰")
        #expect(AvalancheHistogram.powerOfTen(3) == "10³")
        #expect(AvalancheHistogram.powerOfTen(12) == "10¹²")
        #expect(AvalancheHistogram.powerOfTen(-2) == "10⁻²")
        #expect(AvalancheHistogram.decades(from: 2e-7, to: 0.3) == Array(-7...0))
        #expect(AvalancheHistogram.decades(from: 1e-3, to: 1e-2) == [-3, -2])
    }

    @Test("L'ordre des bascules ne change pas le résultat", arguments: [4, 7])
    func randomOrderMatchesStack(threshold: Int) async throws {
        var initial = Grid(width: 48, height: 48)
        initial.cells[initial.centerIndex] = 50_000
        initial[3, 40] = 900
        let queue = try await CPUSandpile(order: .queue).relax(initial, threshold: threshold)
        let stack = try await CPUSandpile(order: .stack).relax(initial, threshold: threshold)
        let random = try await CPUSandpile(order: .random).relax(initial, threshold: threshold)
        #expect(queue == stack)
        #expect(queue == random)
        #expect(queue.isStable(threshold: threshold))
    }
}

@Suite("Palette")
struct PaletteTests {
    @Test("Les 4 niveaux d'un seuil 4 prennent exactement les 4 couleurs")
    func fourLevels() {
        let colors: [UInt32] = [0x2B2722, 0x634731, 0x644835, 0xD1B58C]
        let palette = Palette(colors.map { SIMD3<Float>(hex: $0) })
        #expect((0..<4).map { palette.grains($0, threshold: 4).hex } == colors)
        #expect(palette.mass(1).hex == 0xD1B58C)
        #expect(palette.mass(0).hex == 0x2B2722)
    }

    @Test("Conversion hexadécimale aller-retour")
    func hexRoundTrip() {
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0x1A8C99, 0xD94033] {
            #expect(SIMD3<Float>(hex: hex).hex == hex)
        }
    }
}

@Suite("Tas sur le GPU")
struct GPUSandpileTests {
    @Test("Versement central : CPU séquentiel = GPU parallèle", arguments: [10_000, 1_000_000])
    func abelianCentralPour(grains: Int) async throws {
        let gpu = try GPUSandpile()
        var initial = Grid(width: 64, height: 64)
        initial.cells[initial.centerIndex] = UInt32(grains)
        let cpu = try await CPUSandpile().relax(initial, threshold: 4)
        let parallel = try await gpu.pourCenter(count: grains, width: 64, height: 64, threshold: 4)
        #expect(cpu == parallel)
        #expect(parallel.isStable(threshold: 4))
    }

    @Test("Relaxation directe sur GPU = CPU")
    func directRelax() async throws {
        let gpu = try GPUSandpile()
        var initial = Grid(width: 40, height: 30)
        for i in initial.cells.indices { initial.cells[i] = UInt32((i * 7919) % 13) }
        let cpu = try await CPUSandpile().relax(initial, threshold: 4)
        let parallel = try await gpu.relax(initial, threshold: 4)
        #expect(cpu == parallel)
    }

    @Test("Seuil 7 : toutes les cases < 7 et CPU = GPU")
    func threshold7() async throws {
        let gpu = try GPUSandpile()
        var initial = Grid(width: 64, height: 64)
        initial.cells[initial.centerIndex] = 50_000
        let cpu = try await CPUSandpile().relax(initial, threshold: 7)
        let parallel = try await gpu.pourCenter(count: 50_000, width: 64, height: 64, threshold: 7)
        #expect(cpu == parallel)
        #expect(parallel.isStable(threshold: 7))
        #expect(parallel.cells.contains { $0 >= 4 })
    }

    @Test("Tas divisible : masse conservée et cases pleines ≈ disque d'aire N")
    func divisibleDisc() async throws {
        let gpu = try GPUSandpile()
        let masses = try await gpu.divisibleCenter(mass: 1_000, width: 64, height: 64)
        let total = masses.reduce(0.0) { $0 + Double($1) }
        #expect(abs(total - 1_000) < 1)
        #expect(masses.allSatisfy { $0 <= 1.001 })
        let full = masses.filter { $0 >= 0.999 }.count
        #expect(full > 900 && full <= 1_000)
    }

    @Test("Comparaison : un tas central de 100 000 grains ne touche pas le bord")
    func comparisonSideFits() async throws {
        let gpu = try GPUSandpile()
        let side = SimulationModel.comparisonSide(for: 100_000, threshold: 4)
        let grid = try await gpu.pourCenter(count: 100_000, width: side, height: side, threshold: 4)
        #expect(grid.totalGrains == 100_000)
    }
}

@Suite("Réglages")
@MainActor
struct AppSettingsTests {
    /// Un stockage vide, sans repli sur les préférences de l'application hôte.
    private func freshDefaults() -> MemorySettingsStore {
        MemorySettingsStore()
    }

    @Test("Valeurs par défaut")
    func defaults() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.gridWidth == AppSettings.defaultSide)
        #expect(settings.gridHeight == AppSettings.defaultSide)
        #expect(settings.threshold == AppSettings.defaultThreshold)
        #expect(settings.displayMode == AppSettings.defaultDisplayMode)
        #expect(settings.pourAmount == AppSettings.defaultPourAmount)
        #expect(settings.palette == AppSettings.defaultPalette)
    }

    @Test("Les valeurs sont bornées et relues")
    func clampingAndPersistence() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.gridWidth = 5_000
        settings.gridHeight = 2
        settings.threshold = 2
        settings.pourAmount = 0
        settings.displayMode = .colorOnly
        settings.save()
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.gridWidth == 1024)
        #expect(reloaded.gridHeight == 8)
        #expect(reloaded.threshold == 4)
        #expect(reloaded.pourAmount == 1)
        #expect(reloaded.displayMode == .colorOnly)
    }

    @Test("Langue et palette : valeurs par défaut et persistance")
    func languageAndPalette() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.palette = .sand
        #expect(settings.paletteColors.map(\.hex) == CellPalette.sandColors)
        settings.language = .en
        settings.palette = .custom
        settings.customColors = [0x000000, 0x112233, 0x445566, 0xFFFFFF]
        settings.save()
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.language == .en)
        #expect(reloaded.palette == .custom)
        #expect(reloaded.paletteColors.map(\.hex) == [0x000000, 0x112233, 0x445566, 0xFFFFFF])
        reloaded.palette = .classic
        #expect(reloaded.paletteColors.map(\.hex) == CellPalette.classicColors)
    }

    @Test("Textes traduits dans la langue choisie")
    func localization() {
        #expect(AppLanguage.en.localized("Tas divisible") == "Divisible sandpile")
        #expect(AppLanguage.fr.localized("Tas divisible") == "Tas divisible")
        #expect(AppLanguage.en.localized(SimulationMode.comparison.titleResource) == "Four piles")
        #expect(AppLanguage.en.localized("\(64) × \(32) · seuil \(4)") == "64 × 32 · threshold 4")
    }

    @Test("Quantités des quatre tas")
    func comparisonAmounts() {
        #expect(SimulationModel.comparisonAmounts(for: 1_000) == [1_000, 10_000, 100_000, 1_000_000])
        #expect(SimulationModel.comparisonAmounts(for: 10_000_000) == [2_000, 20_000, 200_000, 2_000_000])
    }
}
