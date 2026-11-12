import Foundation
import Observation

/// Façon de représenter chaque case dans la vue 3D.
enum DisplayMode: String, CaseIterable, Identifiable, Sendable {
    /// Colonne dont la hauteur et la couleur dépendent du nombre de grains.
    case heightAndColor
    /// Carré plat dont seule la couleur dépend du nombre de grains.
    case colorOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .heightAndColor: "Hauteur + couleur"
        case .colorOnly: "Couleur seule"
        }
    }
}

/// Réglages de l'application, conservés dans `UserDefaults`.
///
/// La taille de la grille et le seuil ne sont modifiés que par `SettingsView`, au moment où
/// l'utilisateur les applique (la grille est alors réinitialisée).
@MainActor
@Observable
final class AppSettings {
    static let sideRange = 8...1024
    static let thresholdRange = 4...10
    static let pourRange = 1...10_000_000
    static let sizePresets = [32, 64, 128, 256, 512]
    static let pourPresets = [1_000, 10_000, 100_000, 1_000_000]

    static let defaultSide = 64
    static let defaultThreshold = 4
    static let defaultDisplayMode = DisplayMode.heightAndColor
    static let defaultPourAmount = 1_000

    private enum Key {
        static let width = "grid.width"
        static let height = "grid.height"
        static let threshold = "grid.threshold"
        static let displayMode = "display.mode"
        static let pourAmount = "pour.amount"
    }

    /// Nombre de cases par ligne.
    var gridWidth: Int
    /// Nombre de lignes.
    var gridHeight: Int
    /// Nombre de grains à partir duquel une case bascule (4 à 10).
    var threshold: Int
    var displayMode: DisplayMode
    /// Grains versés au centre (versement central, tas divisible, comparaison).
    var pourAmount: Int

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func integer(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            guard defaults.object(forKey: key) != nil else { return fallback }
            return Self.clamp(defaults.integer(forKey: key), to: range)
        }
        gridWidth = integer(Key.width, Self.defaultSide, Self.sideRange)
        gridHeight = integer(Key.height, Self.defaultSide, Self.sideRange)
        threshold = integer(Key.threshold, Self.defaultThreshold, Self.thresholdRange)
        pourAmount = integer(Key.pourAmount, Self.defaultPourAmount, Self.pourRange)
        displayMode = defaults.string(forKey: Key.displayMode).flatMap(DisplayMode.init(rawValue:))
            ?? Self.defaultDisplayMode
    }

    /// Ramène les valeurs dans leurs plages et les enregistre.
    func save() {
        gridWidth = Self.clamp(gridWidth, to: Self.sideRange)
        gridHeight = Self.clamp(gridHeight, to: Self.sideRange)
        threshold = Self.clamp(threshold, to: Self.thresholdRange)
        pourAmount = Self.clamp(pourAmount, to: Self.pourRange)
        defaults.set(gridWidth, forKey: Key.width)
        defaults.set(gridHeight, forKey: Key.height)
        defaults.set(threshold, forKey: Key.threshold)
        defaults.set(displayMode.rawValue, forKey: Key.displayMode)
        defaults.set(pourAmount, forKey: Key.pourAmount)
    }

    func restoreDefaults() {
        gridWidth = Self.defaultSide
        gridHeight = Self.defaultSide
        threshold = Self.defaultThreshold
        displayMode = Self.defaultDisplayMode
        pourAmount = Self.defaultPourAmount
        save()
    }

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
