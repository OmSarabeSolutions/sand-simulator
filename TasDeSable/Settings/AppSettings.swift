import Foundation
import Observation
import simd
import SwiftUI

/// Façon de représenter chaque case dans la vue 3D.
enum DisplayMode: String, CaseIterable, Identifiable, Sendable {
    /// Colonne dont la hauteur et la couleur dépendent du nombre de grains.
    case heightAndColor
    /// Carré plat dont seule la couleur dépend du nombre de grains.
    case colorOnly

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .heightAndColor: "Hauteur + couleur"
        case .colorOnly: "Couleur seule"
        }
    }
}

/// Langue de l'interface, choisie dans les réglages et appliquée sans relancer l'application.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case fr
    case en

    var id: Self { self }

    /// Nom de la langue dans cette langue.
    var name: String {
        switch self {
        case .fr: "Français"
        case .en: "English"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Langue par défaut : l'anglais si c'est la première langue préférée du système, sinon le français.
    static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("en") == true ? .en : .fr
    }

    /// Texte traduit dans cette langue, pour ce qui n'est pas affiché par une vue SwiftUI
    /// (messages d'erreur, textes construits par le modèle).
    func localized(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }
}

/// Palette des quatre couleurs des cases (0 grain, puis les niveaux suivants).
enum CellPalette: String, CaseIterable, Identifiable, Sendable {
    /// Palette 1 : tons de terre et de sable.
    case sand
    /// Palette 2 : bleu nuit, sarcelle, or, rouge.
    case classic
    /// Palette 3 : quatre couleurs choisies dans les réglages.
    case custom

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .sand: "Sable"
        case .classic: "Classique"
        case .custom: "Personnalisée"
        }
    }

    static let sandColors: [UInt32] = [0x2B2722, 0x634731, 0xbb8665, 0xD1B58C]
    static let classicColors: [UInt32] = [0x1A295A, 0x1A8C99, 0xF2C740, 0xD94033]
}

extension SIMD3 where Scalar == Float {
    /// Couleur RVB à partir d'un entier 0xRRGGBB.
    init(hex: UInt32) {
        self.init(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255)
    }

    /// Entier 0xRRGGBB de cette couleur (composantes bornées à [0, 1]).
    var hex: UInt32 {
        func byte(_ v: Float) -> UInt32 { UInt32((Swift.min(Swift.max(v, 0), 1) * 255).rounded()) }
        return byte(x) << 16 | byte(y) << 8 | byte(z)
    }
}

/// Stockage des réglages : `UserDefaults` dans l'application, un dictionnaire en mémoire dans les
/// tests (un `UserDefaults(suiteName:)` lirait aussi, par repli, les préférences de l'application).
protocol SettingsStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: SettingsStore {}

/// Stockage en mémoire, sans aucun repli.
final class MemorySettingsStore: SettingsStore {
    private var values: [String: Any] = [:]

    init() {}

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
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
    static let sizePresets = [32, 64, 128, 256, 512, 1024]
    static let pourPresets = [1_000, 10_000, 100_000, 1_000_000, 2_000_000]

    static let defaultSide = 512
    static let defaultThreshold = 4
    static let defaultDisplayMode = DisplayMode.heightAndColor
    static let defaultPourAmount = 1_000_000
    static let defaultPalette = CellPalette.sand

    private enum Key {
        static let width = "grid.width"
        static let height = "grid.height"
        static let threshold = "grid.threshold"
        static let displayMode = "display.mode"
        static let pourAmount = "pour.amount"
        static let language = "app.language"
        static let palette = "display.palette"
        static let customColors = "display.customColors"
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
    /// Langue de l'interface.
    var language: AppLanguage
    /// Palette des cases.
    var palette: CellPalette
    /// Les quatre couleurs de la palette personnalisée (0xRRGGBB).
    var customColors: [UInt32]

    /// Les quatre couleurs de la palette choisie.
    var paletteColors: [SIMD3<Float>] {
        let hex: [UInt32] = switch palette {
        case .sand: CellPalette.sandColors
        case .classic: CellPalette.classicColors
        case .custom: customColors
        }
        return hex.map { SIMD3<Float>(hex: $0) }
    }

    @ObservationIgnored private let defaults: any SettingsStore

    init(defaults: any SettingsStore = UserDefaults.standard) {
        self.defaults = defaults
        func integer(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            // Un argument de lancement (-grid.width 64) arrive sous forme de texte.
            let raw = defaults.object(forKey: key)
            guard let value = raw as? Int ?? (raw as? String).flatMap({ Int($0) }) else { return fallback }
            return Self.clamp(value, to: range)
        }
        func string(_ key: String) -> String? { defaults.object(forKey: key) as? String }
        gridWidth = integer(Key.width, Self.defaultSide, Self.sideRange)
        gridHeight = integer(Key.height, Self.defaultSide, Self.sideRange)
        threshold = integer(Key.threshold, Self.defaultThreshold, Self.thresholdRange)
        pourAmount = integer(Key.pourAmount, Self.defaultPourAmount, Self.pourRange)
        displayMode = string(Key.displayMode).flatMap(DisplayMode.init(rawValue:))
            ?? Self.defaultDisplayMode
        language = string(Key.language).flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.systemDefault
        palette = string(Key.palette).flatMap(CellPalette.init(rawValue:)) ?? Self.defaultPalette
        let stored = (defaults.object(forKey: Key.customColors) as? [Int])?.map { UInt32(clamping: $0) & 0xFFFFFF }
        customColors = stored?.count == 4 ? stored! : CellPalette.classicColors
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
        defaults.set(language.rawValue, forKey: Key.language)
        defaults.set(palette.rawValue, forKey: Key.palette)
        defaults.set(customColors.map { Int($0) }, forKey: Key.customColors)
    }

    func restoreDefaults() {
        gridWidth = Self.defaultSide
        gridHeight = Self.defaultSide
        threshold = Self.defaultThreshold
        displayMode = Self.defaultDisplayMode
        pourAmount = Self.defaultPourAmount
        palette = Self.defaultPalette
        customColors = CellPalette.classicColors
        save()
    }

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
