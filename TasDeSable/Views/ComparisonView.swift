import SwiftUI

/// Quatre tas de N, 10 N, 100 N et 1 000 N grains versés au centre, ramenés à la même taille.
struct ComparisonView: View {
    @Environment(SimulationModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let amounts = SimulationModel.comparisonAmounts(for: settings.pourAmount)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chaque tas est calculé sur une grille assez grande pour qu'aucun grain ne sorte, puis affiché dans le même cadre. Leurs grandes zones se ressemblent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.state == .comparing {
                    ProgressView().controlSize(.small)
                    Button("Annuler") { model.cancel() }
                }
                Button("Calculer", systemImage: "square.grid.2x2") { model.runComparison() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.state.isBusy)
            }
            PaletteLegend(threshold: model.threshold)

            // Les quatre vignettes sont carrées et tiennent ensemble dans l'espace restant.
            GeometryReader { geometry in
                let spacing = 12.0
                let captionHeight = 22.0
                let side = max(40, min((geometry.size.width - spacing) / 2,
                                       (geometry.size.height - spacing) / 2 - captionHeight))
                SwiftUI.Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                    ForEach(0..<2, id: \.self) { row in
                        GridRow {
                            ForEach(amounts[(row * 2)..<(row * 2 + 2)], id: \.self) { grains in
                                tile(grains: grains, pile: model.comparison.first { $0.grains == grains },
                                     side: side)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding()
    }

    private func tile(grains: Int, pile: ComparisonPile?, side: Double) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.85))
                if let pile, let image = Palette.image(of: pile.grid, threshold: model.threshold) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                } else if model.state == .comparing {
                    ProgressView()
                }
            }
            .frame(width: side, height: side)
            Text(caption(grains: grains, pile: pile))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func caption(grains: Int, pile: ComparisonPile?) -> String {
        guard let pile else { return "\(grains.formatted()) grains" }
        return "\(grains.formatted()) grains · grille \(pile.grid.width) × \(pile.grid.height) · "
            + pile.seconds.formatted(.number.precision(.fractionLength(2))) + " s"
    }
}
