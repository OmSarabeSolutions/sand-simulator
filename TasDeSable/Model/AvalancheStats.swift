import Foundation

/// Une classe de l'histogramme des tailles d'avalanche, en échelle logarithmique.
struct HistogramBin: Identifiable, Sendable {
    let id: Int
    /// Taille représentative de la classe (moyenne géométrique de ses bornes).
    let size: Double
    /// Fréquence par unité de taille : nombre d'avalanches / largeur de la classe / nombre d'ajouts.
    let frequency: Double
    let count: Int
}

/// Statistiques cumulées des avalanches déclenchées par les ajouts de grains.
struct AvalancheStats: Sendable {
    private(set) var drops = 0
    private(set) var quietDrops = 0
    private(set) var largestArea = 0
    private(set) var largestTopples = 0
    private(set) var lostGrains = 0
    private(set) var totalTopples = 0
    /// `bins[b]` compte les avalanches dont le nombre de bascules s est dans [2^b, 2^(b+1)).
    private(set) var bins: [Int] = Array(repeating: 0, count: 64)

    mutating func record(_ avalanche: Avalanche) {
        drops += 1
        lostGrains += avalanche.lost
        totalTopples += avalanche.topples
        guard !avalanche.isQuiet else {
            quietDrops += 1
            return
        }
        largestArea = max(largestArea, avalanche.area)
        largestTopples = max(largestTopples, avalanche.topples)
        let bin = Int.bitWidth - 1 - avalanche.topples.leadingZeroBitCount
        bins[bin] += 1
    }

    mutating func record(_ avalanches: [Avalanche]) {
        for avalanche in avalanches { record(avalanche) }
    }

    /// Ajoute les statistiques d'un autre lot d'ajouts.
    mutating func merge(_ other: AvalancheStats) {
        drops += other.drops
        quietDrops += other.quietDrops
        largestArea = max(largestArea, other.largestArea)
        largestTopples = max(largestTopples, other.largestTopples)
        lostGrains += other.lostGrains
        totalTopples += other.totalTopples
        for i in bins.indices { bins[i] += other.bins[i] }
    }

    /// Part des ajouts qui ne font basculer aucune case.
    var quietFraction: Double { drops == 0 ? 0 : Double(quietDrops) / Double(drops) }

    /// Classes non vides de l'histogramme, pour un tracé log-log.
    var histogram: [HistogramBin] {
        guard drops > 0 else { return [] }
        return bins.enumerated().compactMap { bin, count in
            guard count > 0 else { return nil }
            let low = pow(2.0, Double(bin))
            let width = low                    // [2^b, 2^(b+1)) a pour largeur 2^b
            return HistogramBin(id: bin, size: low * 2.0.squareRoot(),
                                frequency: Double(count) / width / Double(drops), count: count)
        }
    }
}
