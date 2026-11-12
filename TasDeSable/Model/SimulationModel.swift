import Foundation
import Observation
import SwiftUI

/// Les quatre expériences proposées par l'application.
enum SimulationMode: String, CaseIterable, Identifiable, Sendable {
    case randomDrop
    case centralPour
    case divisible
    case comparison

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .randomDrop: "Ajout aléatoire"
        case .centralPour: "Versement central"
        case .divisible: "Tas divisible"
        case .comparison: "Quatre tas"
        }
    }

    /// Le titre, pour un texte résolu hors des vues (titre de fenêtre).
    var titleResource: LocalizedStringResource {
        switch self {
        case .randomDrop: "Ajout aléatoire"
        case .centralPour: "Versement central"
        case .divisible: "Tas divisible"
        case .comparison: "Quatre tas"
        }
    }

    var symbol: String {
        switch self {
        case .randomDrop: "sparkles"
        case .centralPour: "drop.triangle"
        case .divisible: "circle.dotted"
        case .comparison: "square.grid.2x2"
        }
    }
}

/// Ce que fait la simulation en ce moment.
enum SimulationState: Equatable, Sendable {
    case idle
    case dropping
    case pouring
    case verifying
    case relaxing
    case comparing

    var isBusy: Bool { self != .idle }

    /// L'étiquette, pour un texte résolu hors des vues (sous-titre de fenêtre).
    var labelResource: LocalizedStringResource {
        switch self {
        case .idle: "Stable"
        case .dropping: "Ajout de grains…"
        case .pouring: "Versement au centre…"
        case .verifying: "Vérification abélienne…"
        case .relaxing: "Partage de la masse…"
        case .comparing: "Calcul des quatre tas…"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .idle: "Stable"
        case .dropping: "Ajout de grains…"
        case .pouring: "Versement au centre…"
        case .verifying: "Vérification abélienne…"
        case .relaxing: "Partage de la masse…"
        case .comparing: "Calcul des quatre tas…"
        }
    }
}

/// Nature des valeurs envoyées au rendu.
enum ValueKind: UInt32, Sendable {
    /// Nombre entier de grains, de 0 à T − 1.
    case grains = 0
    /// Masse réelle du tas divisible, pleine à 1.
    case mass = 1
}

/// Image figée d'une grille, prête à être copiée dans un tampon GPU.
struct RenderSnapshot: Sendable {
    var width: Int
    var height: Int
    var values: [Float]
    var kind: ValueKind
    var threshold: Int
    /// Augmente à chaque changement : le rendu ne recopie les valeurs que si elle change.
    var version: Int

    init(grid: Grid, threshold: Int, version: Int) {
        width = grid.width
        height = grid.height
        values = grid.cells.map { Float($0) }
        kind = .grains
        self.threshold = threshold
        self.version = version
    }

    init(masses: [Float], width: Int, height: Int, threshold: Int, version: Int) {
        self.width = width
        self.height = height
        values = masses
        kind = .mass
        self.threshold = threshold
        self.version = version
    }
}

/// Résultat de la vérification abélienne : mêmes grains, trois ordres de bascule.
struct AbelianReport: Sendable {
    let grains: Int
    let queueEqualsRandom: Bool
    let queueEqualsGPU: Bool
    let differingCells: Int
    let remaining: UInt64
    let cpuSeconds: Double
    let gpuSeconds: Double
    let gpuRounds: Int

    var isAbelian: Bool { queueEqualsRandom && queueEqualsGPU }
}

/// Résultat du tas divisible.
struct DivisibleReport: Sendable {
    let mass: Int
    let fullCells: Int
    let remainingMass: Double
    let seconds: Double

    /// Rayon du disque d'aire `mass`, en cases.
    var discRadius: Double { (Double(mass) / .pi).squareRoot() }
    /// Rayon du disque de même aire que l'ensemble des cases pleines.
    var fullRadius: Double { (Double(fullCells) / .pi).squareRoot() }
}

/// Un des quatre tas de la comparaison.
struct ComparisonPile: Identifiable, Sendable {
    var id: Int { grains }
    let grains: Int
    let grid: Grid
    let seconds: Double
}

/// État de la simulation et commandes de l'interface.
@MainActor
@Observable
final class SimulationModel {
    let settings: AppSettings

    var mode: SimulationMode = .randomDrop {
        didSet { publish() }
    }
    private(set) var state: SimulationState = .idle
    private(set) var errorMessage: String?

    /// Seuil de bascule en vigueur (celui des réglages au dernier « Appliquer »).
    private(set) var threshold: Int

    // Ajout aléatoire
    private(set) var randomGrid: Grid
    private(set) var stats = AvalancheStats()
    private(set) var lastAvalanche: Avalanche?
    /// Grains ajoutés à chaque pas du mode continu.
    var dropsPerTick = 10

    // Versement central
    private(set) var pourGrid: Grid
    private(set) var pouredGrains = 0
    private(set) var lastPourSeconds: Double?
    private(set) var abelianReport: AbelianReport?
    /// Avalanches des grains versés un par un au centre (calcul CPU en arrière-plan).
    private(set) var pourStats = AvalancheStats()
    /// Grains déjà versés un par un, sur `pourStatsTotal`.
    private(set) var pourStatsDone = 0
    private(set) var pourStatsTotal = 0
    private(set) var isComputingPourStats = false
    /// Vrai si la grille obtenue grain par grain est identique à celle du GPU (propriété abélienne).
    private(set) var pourStatsMatchGPU: Bool?

    // Tas divisible
    private(set) var masses: [Float]
    private(set) var divisibleReport: DivisibleReport?

    // Comparaison
    private(set) var comparison: [ComparisonPile] = []

    private(set) var snapshot: RenderSnapshot

    @ObservationIgnored private var version = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var gpuEngine: GPUSandpile?
    @ObservationIgnored private var pourStatsTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        let grid = Grid(width: settings.gridWidth, height: settings.gridHeight)
        threshold = settings.threshold
        randomGrid = grid
        pourGrid = grid
        masses = Array(repeating: 0, count: grid.count)
        snapshot = RenderSnapshot(grid: grid, threshold: settings.threshold, version: 0)
    }

    var gridWidth: Int { randomGrid.width }
    var gridHeight: Int { randomGrid.height }

    /// Vrai si une des expériences a déjà des résultats (pour confirmer avant de tout effacer).
    var hasContent: Bool {
        stats.drops > 0 || pouredGrains > 0 || divisibleReport != nil || !comparison.isEmpty
    }

    // MARK: - Réglages

    /// Recrée toutes les grilles avec la taille et le seuil des réglages.
    func applyGridSettings() {
        cancel()
        threshold = settings.threshold
        let grid = Grid(width: settings.gridWidth, height: settings.gridHeight)
        randomGrid = grid
        pourGrid = grid
        masses = Array(repeating: 0, count: grid.count)
        stats = AvalancheStats()
        lastAvalanche = nil
        cancelPourStats()
        pourStats = AvalancheStats()
        pourStatsDone = 0
        pourStatsTotal = 0
        pourStatsMatchGPU = nil
        pouredGrains = 0
        lastPourSeconds = nil
        abelianReport = nil
        divisibleReport = nil
        comparison = []
        errorMessage = nil
        publish()
    }

    func cancel() {
        task?.cancel()
        task = nil
        isDroppingContinuously = false
        state = .idle
    }

    // MARK: - Ajout aléatoire

    func resetRandom() {
        cancel()
        randomGrid = Grid(width: randomGrid.width, height: randomGrid.height)
        stats = AvalancheStats()
        lastAvalanche = nil
        publish()
    }

    /// Ajoute `count` grains, chacun en une case tirée au hasard.
    func drop(_ count: Int) {
        guard !state.isBusy else { return }
        state = .dropping
        task = Task {
            await runDrops(count)
            state = .idle
        }
    }

    /// Vrai pendant l'ajout continu de grains.
    private(set) var isDroppingContinuously = false

    func startContinuousDrop() {
        guard !state.isBusy else { return }
        state = .dropping
        isDroppingContinuously = true
        task = Task {
            while !Task.isCancelled {
                await runDrops(dropsPerTick)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stopContinuousDrop() {
        cancel()
    }

    private func runDrops(_ count: Int) async {
        let dropper = RandomDropper(grid: randomGrid, threshold: threshold)
        let (grid, avalanches) = await Task.detached(priority: .userInitiated) {
            var working = dropper
            let avalanches = working.drop(count)
            return (working.grid, avalanches)
        }.value
        randomGrid = grid
        stats.record(avalanches)
        lastAvalanche = avalanches.last { !$0.isQuiet } ?? avalanches.last
        if mode == .randomDrop { publish() }
    }

    // MARK: - Versement central

    func resetPour() {
        cancel()
        cancelPourStats()
        pourStats = AvalancheStats()
        pourStatsDone = 0
        pourStatsTotal = 0
        pourStatsMatchGPU = nil
        pourGrid = Grid(width: pourGrid.width, height: pourGrid.height)
        pouredGrains = 0
        lastPourSeconds = nil
        abelianReport = nil
        publish()
    }

    /// Verse `settings.pourAmount` grains au centre, en plus de ceux déjà présents
    /// (par la propriété abélienne : stab(a + b) = stab(stab(a) + stab(b))).
    func pourCenter() {
        guard !state.isBusy else { return }
        let count = settings.pourAmount
        let base = pourGrid
        let threshold = threshold
        state = .pouring
        task = Task {
            do {
                let gpu = try gpu()
                let start = ContinuousClock.now
                var result = try await gpu.pourCenter(count: count, width: base.width, height: base.height,
                                                      threshold: threshold)
                if !base.isEmpty {
                    result = try await gpu.relax(base + result, threshold: threshold)
                }
                pourGrid = result
                pouredGrains += count
                lastPourSeconds = (ContinuousClock.now - start).seconds
                publish()
                startPourStats(base: base, count: count, expected: result)
            } catch is CancellationError {
            } catch {
                errorMessage = message(for: error)
            }
            state = .idle
        }
    }

    /// Verse les mêmes grains un par un au centre, sur le CPU et en arrière-plan, pour obtenir les
    /// avalanches du versement. Les statistiques sont publiées par lots d'environ 100 ms. Une
    /// nouvelle série remplace la précédente ; à la fin, la grille est comparée à celle du GPU.
    private func startPourStats(base: Grid, count: Int, expected: Grid) {
        cancelPourStats()
        if base.isEmpty || pourStatsDone != pourStatsTotal {
            pourStats = AvalancheStats()          // nouvelle série, ou série précédente incomplète
            pourStatsDone = 0
            pourStatsTotal = 0
        }
        let previousDone = pourStatsDone
        pourStatsTotal += count
        pourStatsMatchGPU = nil
        isComputingPourStats = true
        let threshold = threshold
        pourStatsTask = Task {
            var dropper = CenterDropper(grid: base, threshold: threshold)
            var done = 0
            var chunk = 500
            while done < count && !Task.isCancelled {
                let n = min(chunk, count - done)
                let input = dropper
                let start = ContinuousClock.now
                let (output, partial) = await Task.detached(priority: .utility) {
                    var working = input
                    var batch = AvalancheStats()
                    working.drop(n, into: &batch)
                    return (working, batch)
                }.value
                guard !Task.isCancelled else { return }
                dropper = output
                pourStats.merge(partial)
                done += n
                pourStatsDone = previousDone + done
                let elapsed = (ContinuousClock.now - start).seconds
                chunk = max(1, min(1_000_000, Int(Double(n) * 0.1 / max(elapsed, 1e-4))))
            }
            if done == count {
                pourStatsMatchGPU = dropper.grid == expected
            }
            isComputingPourStats = false
        }
    }

    /// Arrête le versement grain par grain en cours ; les statistiques déjà obtenues restent affichées.
    func cancelPourStats() {
        pourStatsTask?.cancel()
        pourStatsTask = nil
        isComputingPourStats = false
    }

    /// Stabilise les mêmes grains au centre de trois façons et compare les résultats case par case.
    func verifyAbelian() {
        guard !state.isBusy else { return }
        let count = settings.pourAmount
        let width = pourGrid.width
        let height = pourGrid.height
        let threshold = threshold
        state = .verifying
        task = Task {
            do {
                let gpu = try gpu()
                var initial = Grid(width: width, height: height)
                initial.cells[initial.centerIndex] = UInt32(count)

                let cpuStart = ContinuousClock.now
                let (queue, random) = try await Task.detached(priority: .userInitiated) {
                    let queue = try await CPUSandpile(order: .queue).relax(initial, threshold: threshold)
                    let random = try await CPUSandpile(order: .random).relax(initial, threshold: threshold)
                    return (queue, random)
                }.value
                let cpuSeconds = (ContinuousClock.now - cpuStart).seconds / 2

                let gpuStart = ContinuousClock.now
                let parallel = try await gpu.pourCenter(count: count, width: width, height: height,
                                                        threshold: threshold)
                let gpuSeconds = (ContinuousClock.now - gpuStart).seconds
                let rounds = await gpu.lastRounds

                let differing = zip(queue.cells, parallel.cells).filter { $0 != $1 }.count
                abelianReport = AbelianReport(grains: count, queueEqualsRandom: queue == random,
                                              queueEqualsGPU: queue == parallel, differingCells: differing,
                                              remaining: queue.totalGrains, cpuSeconds: cpuSeconds,
                                              gpuSeconds: gpuSeconds, gpuRounds: rounds)
            } catch is CancellationError {
            } catch {
                errorMessage = message(for: error)
            }
            state = .idle
        }
    }

    // MARK: - Tas divisible

    func runDivisible() {
        guard !state.isBusy else { return }
        let mass = settings.pourAmount
        let width = gridWidth
        let height = gridHeight
        state = .relaxing
        task = Task {
            do {
                let gpu = try gpu()
                let start = ContinuousClock.now
                let result = try await gpu.divisibleCenter(mass: Double(mass), width: width, height: height)
                masses = result
                divisibleReport = DivisibleReport(
                    mass: mass,
                    fullCells: result.filter { $0 >= 1 - 1e-3 }.count,
                    remainingMass: result.reduce(0.0) { $0 + Double($1) },
                    seconds: (ContinuousClock.now - start).seconds)
                publish()
            } catch is CancellationError {
            } catch {
                errorMessage = message(for: error)
            }
            state = .idle
        }
    }

    // MARK: - Comparaison des quatre tas

    /// Plus grand nombre de grains d'un tas de la comparaison.
    nonisolated static let comparisonLimit = 2_000_000

    /// Quantités des quatre tas : N, 10 N, 100 N, 1 000 N, ramenées sous `comparisonLimit`.
    nonisolated static func comparisonAmounts(for amount: Int) -> [Int] {
        let largest = min(amount.multipliedReportingOverflow(by: 1000).partialValue, comparisonLimit)
        return [largest / 1000, largest / 100, largest / 10, largest].map { max($0, 1) }
    }

    /// Côté d'une grille assez grande pour que `grains` versés au centre ne touchent pas le bord.
    /// La densité moyenne d'un tas central est d'environ 2,125 grains par case pour T = 4.
    nonisolated static func comparisonSide(for grains: Int, threshold: Int) -> Int {
        let density = Double(threshold) - 1.875
        let radius = (Double(grains) / (density * .pi)).squareRoot()
        return Int(2.2 * radius) + 8
    }

    func runComparison() {
        guard !state.isBusy else { return }
        let amounts = Self.comparisonAmounts(for: settings.pourAmount)
        let threshold = threshold
        comparison = []
        state = .comparing
        task = Task {
            do {
                let gpu = try gpu()
                for grains in amounts {
                    var side = Self.comparisonSide(for: grains, threshold: threshold)
                    let start = ContinuousClock.now
                    var grid: Grid
                    // Si des grains sortent par le bord, la grille était trop petite : on l'agrandit.
                    repeat {
                        grid = try await gpu.pourCenter(count: grains, width: side, height: side,
                                                        threshold: threshold)
                        side = side * 5 / 4 + 2
                    } while grid.totalGrains < UInt64(grains)
                    comparison.append(ComparisonPile(grains: grains, grid: grid,
                                                     seconds: (ContinuousClock.now - start).seconds))
                }
            } catch is CancellationError {
            } catch {
                errorMessage = message(for: error)
            }
            state = .idle
        }
    }

    func dismissError() { errorMessage = nil }

    /// Message d'une erreur, dans la langue de l'interface.
    private func message(for error: any Error) -> String {
        if let gpuError = error as? GPUSandpileError {
            return settings.language.localized(gpuError.message)
        }
        return error.localizedDescription
    }

    /// Lancement avec `-demo <mode>` (randomDrop, centralPour, divisible, comparison) :
    /// ouvre ce mode et lance son expérience, pour les captures d'écran et les essais.
    func runDemoIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let flag = arguments.firstIndex(of: "-demo"), flag + 1 < arguments.count,
              let demo = SimulationMode(rawValue: arguments[flag + 1]) else { return }
        mode = demo
        switch demo {
        case .randomDrop: drop(50_000)
        case .centralPour: pourCenter()
        case .divisible: runDivisible()
        case .comparison: runComparison()
        }
    }

    // MARK: - Rendu

    private func publish() {
        version += 1
        switch mode {
        case .randomDrop:
            snapshot = RenderSnapshot(grid: randomGrid, threshold: threshold, version: version)
        case .centralPour, .comparison:
            snapshot = RenderSnapshot(grid: pourGrid, threshold: threshold, version: version)
        case .divisible:
            snapshot = RenderSnapshot(masses: masses, width: gridWidth, height: gridHeight,
                                      threshold: threshold, version: version)
        }
    }

    private func gpu() throws -> GPUSandpile {
        if let gpuEngine { return gpuEngine }
        let engine = try GPUSandpile()
        gpuEngine = engine
        return engine
    }
}

extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
