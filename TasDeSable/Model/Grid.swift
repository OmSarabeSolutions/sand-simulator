/// Grille rectangulaire de cases portant chacune un nombre entier de grains.
///
/// Les cases sont rangées ligne par ligne : la case `(x, y)` est à l'indice `y * width + x`.
/// Les bords sont ouverts : un grain envoyé hors de la grille est perdu.
struct Grid: Sendable, Equatable {
    let width: Int
    let height: Int
    var cells: [UInt32]

    init(width: Int, height: Int) {
        precondition(width > 0 && height > 0, "La grille doit avoir au moins une case")
        self.width = width
        self.height = height
        self.cells = Array(repeating: 0, count: width * height)
    }

    var count: Int { cells.count }

    /// Indice de la case centrale (arrondi vers le haut à gauche pour les tailles paires).
    var centerIndex: Int { (height / 2) * width + width / 2 }

    func index(x: Int, y: Int) -> Int { y * width + x }

    subscript(x: Int, y: Int) -> UInt32 {
        get { cells[index(x: x, y: y)] }
        set { cells[index(x: x, y: y)] = newValue }
    }

    /// Nombre total de grains présents sur la grille.
    var totalGrains: UInt64 { cells.reduce(0) { $0 + UInt64($1) } }

    var isEmpty: Bool { !cells.contains { $0 != 0 } }

    /// Vrai si aucune case ne porte `threshold` grains ou plus.
    func isStable(threshold: Int) -> Bool {
        let t = UInt32(threshold)
        return cells.allSatisfy { $0 < t }
    }

    /// Somme case par case de deux grilles de même taille.
    static func + (lhs: Grid, rhs: Grid) -> Grid {
        precondition(lhs.width == rhs.width && lhs.height == rhs.height, "Grilles de tailles différentes")
        var sum = lhs
        for i in sum.cells.indices { sum.cells[i] &+= rhs.cells[i] }
        return sum
    }
}

/// Un moteur capable de stabiliser une grille : toutes les cases instables basculent
/// jusqu'à ce qu'aucune ne porte `threshold` grains ou plus.
protocol SandpileEngine: Sendable {
    func relax(_ grid: Grid, threshold: Int) async throws -> Grid
}
