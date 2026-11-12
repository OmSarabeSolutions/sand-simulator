import SwiftUI

/// Page de configuration (menu TasDeSable › Réglages…, ⌘,).
///
/// La taille et le seuil sont édités dans un brouillon et appliqués d'un coup, car ils
/// réinitialisent la grille. L'affichage et le nombre de grains s'appliquent tout de suite.
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
            Section {
                sideField("Largeur", value: $width)
                sideField("Hauteur", value: $height)
                LabeledContent("Préréglages") {
                    HStack {
                        ForEach(AppSettings.sizePresets, id: \.self) { side in
                            Button("\(side)") { width = side; height = side }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                Stepper(value: $threshold, in: AppSettings.thresholdRange) {
                    LabeledContent("Grains par case", value: "\(threshold)")
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
            }

            Section("Versement") {
                TextField("Grains à déverser", value: $settings.pourAmount, format: .number)
                    .multilineTextAlignment(.trailing)
                LabeledContent("Préréglages") {
                    HStack {
                        ForEach(AppSettings.pourPresets, id: \.self) { amount in
                            Button(amount.formatted()) { settings.pourAmount = amount }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                Text("Utilisé par le versement central, le tas divisible et la comparaison des quatre tas (de \(AppSettings.pourRange.lowerBound) à \(AppSettings.pourRange.upperBound.formatted()) grains).")
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
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            width = settings.gridWidth
            height = settings.gridHeight
            threshold = settings.threshold
        }
        .onChange(of: settings.displayMode) { settings.save() }
        .onChange(of: settings.pourAmount) { settings.save() }
        .confirmationDialog("Réinitialiser les grilles ?", isPresented: $confirmingReset) {
            Button("Réinitialiser", role: .destructive) { apply() }
        } message: {
            Text("Les grains et les statistiques en cours seront effacés.")
        }
    }

    private func sideField(_ title: String, value: Binding<Int>) -> some View {
        Stepper(value: value, in: AppSettings.sideRange) {
            LabeledContent(title) {
                TextField(title, value: value, format: .number)
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
