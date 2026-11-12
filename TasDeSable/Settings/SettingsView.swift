import AppKit
import SwiftUI

/// Page de configuration (menu TasDeSable › Réglages…, ⌘,).
///
/// La taille et le seuil sont édités dans un brouillon et appliqués d'un coup, car ils
/// réinitialisent la grille. La langue, l'affichage, la palette et le nombre de grains
/// s'appliquent tout de suite.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SimulationModel.self) private var model

    @State private var width = AppSettings.defaultSide
    @State private var height = AppSettings.defaultSide
    @State private var threshold = AppSettings.defaultThreshold
    @State private var confirmingReset = false

    private var hasPendingGridChange: Bool {
        width != settings.gridWidth || height != settings.gridHeight || threshold != settings.threshold
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Langue") {
                Picker("Langue de l'interface", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.name).tag(language)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                sideField("Largeur", value: $width)
                sideField("Hauteur", value: $height)
                LabeledContent("Préréglages") {
                    HStack {
                        ForEach(AppSettings.sizePresets, id: \.self) { side in
                            Button { width = side; height = side } label: { Text(verbatim: "\(side)") }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                Stepper(value: $threshold, in: AppSettings.thresholdRange) {
                    LabeledContent("Grains par case") { Text(verbatim: "\(threshold)") }
                }
                Text("Une case qui porte \(threshold) grains ou plus bascule : elle en perd 4 et en donne un à chacune de ses quatre voisines. Les cases stables gardent de 0 à \(threshold - 1) grains.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Grille actuelle : \(model.gridWidth) × \(model.gridHeight), seuil \(model.threshold)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Appliquer et réinitialiser") {
                        if model.hasContent { confirmingReset = true } else { apply() }
                    }
                    .disabled(!hasPendingGridChange && model.threshold == settings.threshold)
                    .keyboardShortcut(.defaultAction)
                }
            } header: {
                Text("Grille")
            }

            Section("Affichage") {
                Picker("Cases", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Picker("Palette", selection: $settings.palette) {
                    ForEach(CellPalette.allCases) { palette in
                        Text(palette.title).tag(palette)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Couleurs") {
                    PaletteSwatch(colors: settings.paletteColors)
                }
                if settings.palette == .custom {
                    ForEach(0..<4, id: \.self) { level in
                        ColorPicker(selection: customColor(level), supportsOpacity: false) {
                            Text(level == 3 ? "Couleur 4 — niveau 3 et plus" : "Couleur \(level + 1) — niveau \(level)")
                        }
                    }
                    Button("Partir de la palette Sable") { settings.customColors = CellPalette.sandColors }
                    Button("Partir de la palette Classique") { settings.customColors = CellPalette.classicColors }
                }
                Text("Les quatre couleurs vont de 0 grain au seuil moins un ; au-delà de 4 grains par case, les niveaux intermédiaires sont des mélanges. Pour le tas divisible : 1re couleur vide, 2e partielle, 4e pleine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Versement") {
                TextField("Grains à déverser", value: $settings.pourAmount,
                          format: .number.locale(settings.language.locale))
                    .multilineTextAlignment(.trailing)
                LabeledContent("Préréglages") {
                    HStack {
                        ForEach(AppSettings.pourPresets, id: \.self) { amount in
                            Button { settings.pourAmount = amount } label: { Text(amount, format: .number) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                Text("Utilisé par le versement central, le tas divisible et la comparaison des quatre tas (de \(AppSettings.pourRange.lowerBound, format: .number) à \(AppSettings.pourRange.upperBound, format: .number) grains).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Rétablir les valeurs par défaut") {
                    width = AppSettings.defaultSide
                    height = AppSettings.defaultSide
                    threshold = AppSettings.defaultThreshold
                    settings.displayMode = AppSettings.defaultDisplayMode
                    settings.pourAmount = AppSettings.defaultPourAmount
                    settings.palette = AppSettings.defaultPalette
                    settings.customColors = CellPalette.classicColors
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            width = settings.gridWidth
            height = settings.gridHeight
            threshold = settings.threshold
        }
        .onChange(of: settings.displayMode) { settings.save() }
        .onChange(of: settings.pourAmount) { settings.save() }
        .onChange(of: settings.language) { settings.save() }
        .onChange(of: settings.palette) { settings.save() }
        .onChange(of: settings.customColors) { settings.save() }
        .confirmationDialog("Réinitialiser les grilles ?", isPresented: $confirmingReset) {
            Button("Réinitialiser", role: .destructive) { apply() }
        } message: {
            Text("Les grains et les statistiques en cours seront effacés.")
        }
    }

    /// Lien entre un ColorPicker et une couleur de la palette personnalisée (0xRRGGBB).
    private func customColor(_ index: Int) -> Binding<Color> {
        Binding {
            Palette.color(SIMD3<Float>(hex: settings.customColors[index]))
        } set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            settings.customColors[index] = SIMD3<Float>(Float(rgb.redComponent), Float(rgb.greenComponent),
                                                        Float(rgb.blueComponent)).hex
        }
    }

    private func sideField(_ title: LocalizedStringKey, value: Binding<Int>) -> some View {
        Stepper(value: value, in: AppSettings.sideRange) {
            LabeledContent(title) {
                TextField(title, value: value, format: .number.locale(settings.language.locale))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onSubmit { value.wrappedValue = AppSettings.clamp(value.wrappedValue, to: AppSettings.sideRange) }
            }
        }
    }

    private func apply() {
        settings.gridWidth = AppSettings.clamp(width, to: AppSettings.sideRange)
        settings.gridHeight = AppSettings.clamp(height, to: AppSettings.sideRange)
        settings.threshold = AppSettings.clamp(threshold, to: AppSettings.thresholdRange)
        settings.save()
        width = settings.gridWidth
        height = settings.gridHeight
        model.applyGridSettings()
    }
}
