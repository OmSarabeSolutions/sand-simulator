/// Bilan d'une cascade.
struct Avalanche: Sendable, Equatable {
    /// Nombre de bascules (une case qui bascule k fois compte pour k).
    var topples = 0
    /// Nombre de cases distinctes qui ont basculé au moins une fois.
    var area = 0
    /// Grains sortis par le bord.
    var lost = 0

    var isQuiet: Bool { topples == 0 }
}

/// Ordre dans lequel on traite les cases instables. Le modèle étant abélien,
/// l'état final ne dépend pas de cet ordre.
enum ToppleOrder: Sendable {
    /// La dernière case devenue instable bascule la première (pile).
    case stack
    /// La première case devenue instable bascule la première (file). Les grains ont le temps de
    /// s'accumuler, une case bascule alors plusieurs fois d'un coup : c'est l'ordre le plus rapide
    /// pour un gros versement.
    case queue
    /// Une case instable tirée au hasard bascule.
    case random
}

/// Mémoire de travail réutilisée d'une cascade à l'autre pour éviter les allocations.
struct ToppleScratch: Sendable {
    var stack: [Int32] = []
    /// `stamps[i] == stamp` signifie que la case i a déjà basculé pendant la cascade courante.
    var stamps: [UInt32]
    var stamp: UInt32 = 0

    init(count: Int) {
        stamps = Array(repeating: 0, count: count)
        stack.reserveCapacity(256)
    }

    mutating func nextStamp() {
        stamp &+= 1
        if stamp == 0 {
            for i in stamps.indices { stamps[i] = 0 }
            stamp = 1
        }
    }
}

/// Tas de sable abélien sur le processeur, exact grain par grain.
///
/// Une case qui porte `threshold` grains ou plus bascule : elle perd 4 grains et en donne un
/// à chacune de ses quatre voisines. Une case qui doit basculer k fois le fait d'un coup.
struct CPUSandpile: SandpileEngine {
    var order: ToppleOrder = .queue

    func relax(_ grid: Grid, threshold: Int) async throws -> Grid {
        var result = grid
        var scratch = ToppleScratch(count: grid.count)
        _ = Self.relax(&result, threshold: threshold, scratch: &scratch, order: order)
        return result
    }

    /// Ajoute un grain sur la case `index` puis fait basculer jusqu'à stabilité.
    static func addGrain(at index: Int, to grid: inout Grid, threshold: Int,
                         scratch: inout ToppleScratch) -> Avalanche {
        let t = UInt32(threshold)
        grid.cells[index] &+= 1
        guard grid.cells[index] >= t else { return Avalanche() }
        scratch.stack.append(Int32(index))
        return run(&grid, threshold: t, scratch: &scratch, order: .stack)
    }

    /// Fait basculer toutes les cases instables de `grid` jusqu'à stabilité.
    @discardableResult
    static func relax(_ grid: inout Grid, threshold: Int, scratch: inout ToppleScratch,
                      order: ToppleOrder = .queue) -> Avalanche {
        let t = UInt32(threshold)
        for i in grid.cells.indices where grid.cells[i] >= t {
            scratch.stack.append(Int32(i))
        }
        return run(&grid, threshold: t, scratch: &scratch, order: order)
    }

    private static func run(_ grid: inout Grid, threshold t: UInt32, scratch: inout ToppleScratch,
                            order: ToppleOrder) -> Avalanche {
        var avalanche = Avalanche()
        scratch.nextStamp()
        let width = grid.width
        let height = grid.height
        let stamp = scratch.stamp

        grid.cells.withUnsafeMutableBufferPointer { cells in
            // Ajoute k grains à la case j et l'empile si elle vient de devenir instable.
            // Chaque case instable est ainsi dans la pile une seule fois.
            func give(_ k: UInt32, to j: Int) {
                let before = cells[j]
                let after = before &+ k
                cells[j] = after
                if before < t && after >= t { scratch.stack.append(Int32(j)) }
            }

            var head = 0                         // début de la file pour l'ordre .queue
            while head < scratch.stack.count {
                let i: Int
                switch order {
                case .stack:
                    i = Int(scratch.stack.removeLast())
                case .random:
                    let j = Int.random(in: 0..<scratch.stack.count)
                    scratch.stack.swapAt(j, scratch.stack.count - 1)
                    i = Int(scratch.stack.removeLast())
                case .queue:
                    i = Int(scratch.stack[head])
                    head += 1
                    if head > 4096 && head * 2 > scratch.stack.count {
                        scratch.stack.removeFirst(head)
                        head = 0
                    }
                }
                let value = cells[i]
                guard value >= t else { continue }

                let k = (value - t) / 4 + 1          // nombre de bascules d'un coup
                cells[i] = value - 4 * k
                avalanche.topples += Int(k)
                if scratch.stamps[i] != stamp {
                    scratch.stamps[i] = stamp
                    avalanche.area += 1
                }

                let x = i % width
                let y = i / width
                if x > 0 { give(k, to: i - 1) } else { avalanche.lost += Int(k) }
                if x < width - 1 { give(k, to: i + 1) } else { avalanche.lost += Int(k) }
                if y > 0 { give(k, to: i - width) } else { avalanche.lost += Int(k) }
                if y < height - 1 { give(k, to: i + width) } else { avalanche.lost += Int(k) }
            }
            scratch.stack.removeAll(keepingCapacity: true)
        }
        return avalanche
    }
}

/// Ajout lent de grains en des cases tirées au hasard (expérience de Bak, Tang et Wiesenfeld).
struct RandomDropper: Sendable {
    private(set) var grid: Grid
    let threshold: Int
    private var scratch: ToppleScratch

    init(grid: Grid, threshold: Int) {
        self.grid = grid
        self.threshold = threshold
        self.scratch = ToppleScratch(count: grid.count)
    }

    /// Ajoute `count` grains un par un, chacun suivi de sa cascade complète.
    mutating func drop(_ count: Int) -> [Avalanche] {
        var avalanches: [Avalanche] = []
        avalanches.reserveCapacity(count)
        for _ in 0..<count {
            let index = Int.random(in: 0..<grid.count)
            avalanches.append(CPUSandpile.addGrain(at: index, to: &grid, threshold: threshold,
                                                   scratch: &scratch))
        }
        return avalanches
    }
}

/// Versement grain par grain sur la case centrale : chaque grain est suivi de sa cascade, ce qui
/// donne les statistiques d'avalanches du versement central (que le GPU calcule d'un bloc).
struct CenterDropper: Sendable {
    private(set) var grid: Grid
    let threshold: Int
    private var scratch: ToppleScratch

    init(grid: Grid, threshold: Int) {
        self.grid = grid
        self.threshold = threshold
        self.scratch = ToppleScratch(count: grid.count)
    }

    /// Verse `count` grains au centre, un par un, et enregistre chaque avalanche dans `stats`.
    mutating func drop(_ count: Int, into stats: inout AvalancheStats) {
        let center = grid.centerIndex
        for _ in 0..<count {
            stats.record(CPUSandpile.addGrain(at: center, to: &grid, threshold: threshold, scratch: &scratch))
        }
    }
}
