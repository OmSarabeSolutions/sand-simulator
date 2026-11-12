import SwiftUI

/// Tas divisible : la masse est partagée au lieu de rester en grains entiers.
struct DivisiblePanel: View {
    @Environment(SimulationModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Une masse est posée au centre. Chaque case qui dépasse 1 garde 1 et partage le reste également entre ses quatre voisines. Les cases pleines forment presque un disque.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Text("Masse : \(settings.pourAmount, format: .number)")
                    .font(.headline.monospacedDigit())
                Spacer()
                SettingsLink { Text("Modifier…") }
            }

            Button("Partager", systemImage: "circle.dotted") { model.runDivisible() }
                .buttonStyle(.borderedProminent)
                .disabled(model.state.isBusy)

            if model.state == .relaxing {
                HStack {
                    ProgressView().controlSize(.small)
                    Button("Annuler") { model.cancel() }
                }
            }

            if let report = model.divisibleReport {
                Divider()
                StatRow("Cases pleines", Text(report.fullCells, format: .number))
                StatRow("Rayon équivalent", Text(report.fullRadius, format: .number.precision(.fractionLength(2))))
                StatRow("Rayon du disque d'aire N",
                        Text(report.discRadius, format: .number.precision(.fractionLength(2))))
                StatRow("Masse restante", Text(report.remainingMass, format: .number.precision(.fractionLength(1))))
                StatRow("Durée GPU", secondsText(report.seconds))

                Text("Vue de dessus, avec le cercle d'aire N").font(.headline)
                DiscOverlay(masses: model.masses, width: model.gridWidth, height: model.gridHeight,
                            radius: report.discRadius, palette: Palette(settings.paletteColors))
                    .frame(height: 260)
            }
        }
    }
}

/// Image des cases du tas divisible avec, superposé, le cercle d'aire égale à la masse.
struct DiscOverlay: View {
    let masses: [Float]
    let width: Int
    let height: Int
    let radius: Double
    let palette: Palette

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / Double(width), geometry.size.height / Double(height))
            let size = CGSize(width: Double(width) * scale, height: Double(height) * scale)
            ZStack {
                if let image = palette.image(masses: masses, width: width, height: height) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                }
                Circle()
                    .stroke(.white.opacity(0.85), lineWidth: 1.5)
                    .frame(width: 2 * radius * scale, height: 2 * radius * scale)
                    .offset(x: (Double(width / 2) + 0.5 - Double(width) / 2) * scale,
                            y: (Double(height / 2) + 0.5 - Double(height) / 2) * scale)
            }
            .frame(width: size.width, height: size.height)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}
