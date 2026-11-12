import SwiftUI

/// Ajout lent de grains au hasard et statistiques des avalanches (criticalité auto-organisée).
struct RandomDropPanel: View {
    @Environment(SimulationModel.self) private var model

    private static let speeds = [1, 10, 100, 1_000]

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("Un grain tombe sur une case tirée au hasard. Une case qui atteint le seuil bascule et en donne un à chacune de ses voisines ; ceux qui sortent par le bord sont perdus.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button { model.drop(1) } label: { Text(verbatim: "+1") }
                Button { model.drop(100) } label: { Text("+\(100, format: .number)") }
                Button { model.drop(10_000) } label: { Text("+\(10_000, format: .number)") }
            }
            .disabled(model.state.isBusy)

            HStack {
                if model.isDroppingContinuously {
                    Button("Arrêter", systemImage: "pause.fill") { model.stopContinuousDrop() }
                } else {
                    Button("Continu", systemImage: "play.fill") { model.startContinuousDrop() }
                        .disabled(model.state.isBusy)
                }
                Picker("Grains par pas", selection: $model.dropsPerTick) {
                    ForEach(Self.speeds, id: \.self) { Text($0, format: .number).tag($0) }
                }
                .frame(width: 170)
            }

            Button("Vider la grille", systemImage: "trash", role: .destructive) { model.resetRandom() }

            Divider()

            let stats = model.stats
            let cells = model.gridWidth * model.gridHeight
            StatRow("Grains ajoutés", Text(stats.drops, format: .number))
            StatRow("Ajouts sans bascule", Text(stats.quietFraction, format: .percent.precision(.fractionLength(1))))
            if let last = model.lastAvalanche {
                StatRow("Dernière avalanche", cellsText(last.area) + Text(verbatim: ", ") + topplesText(last.topples))
            }
            StatRow("Plus grande avalanche",
                    Text("\(stats.largestArea, format: .number) / \(cells, format: .number) cases"))
            StatRow("Bascules (record)", Text(stats.largestTopples, format: .number))
            StatRow("Grains perdus au bord", Text(stats.lostGrains, format: .number))
            StatRow("Densité moyenne", Text(Double(model.randomGrid.totalGrains) / Double(cells),
                                            format: .number.precision(.fractionLength(3))))

            Divider()

            Text("Tailles des avalanches (log-log)").font(.headline)
            if stats.histogram.count >= 2 {
                AvalancheHistogram(stats: stats)
                Text("À l'état critique, les points s'alignent : la loi de taille est une loi de puissance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Ajoutez quelques milliers de grains pour voir l'histogramme.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
