import Charts
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
                Button("+1") { model.drop(1) }
                Button("+100") { model.drop(100) }
                Button("+10 000") { model.drop(10_000) }
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
                    ForEach(Self.speeds, id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(width: 150)
            }

            Button("Vider la grille", systemImage: "trash", role: .destructive) { model.resetRandom() }

            Divider()

            let stats = model.stats
            let cells = model.gridWidth * model.gridHeight
            StatRow("Grains ajoutés", stats.drops.formatted())
            StatRow("Ajouts sans bascule", stats.quietFraction.formatted(.percent.precision(.fractionLength(1))))
            if let last = model.lastAvalanche {
                StatRow("Dernière avalanche", "\(last.area.formatted()) cases, \(last.topples.formatted()) bascules")
            }
            StatRow("Plus grande avalanche", "\(stats.largestArea.formatted()) / \(cells.formatted()) cases")
            StatRow("Bascules (record)", stats.largestTopples.formatted())
            StatRow("Grains perdus au bord", stats.lostGrains.formatted())
            StatRow("Densité moyenne",
                    (Double(model.randomGrid.totalGrains) / Double(cells)).formatted(.number.precision(.fractionLength(3))))

            Divider()

            Text("Tailles des avalanches (log-log)").font(.headline)
            if stats.histogram.count >= 2 {
                Chart(stats.histogram) { bin in
                    LineMark(x: .value("Bascules", bin.size), y: .value("Fréquence", bin.frequency))
                        .foregroundStyle(.teal)
                    PointMark(x: .value("Bascules", bin.size), y: .value("Fréquence", bin.frequency))
                        .foregroundStyle(.teal)
                }
                .chartXScale(type: .log)
                .chartYScale(type: .log)
                .chartXAxisLabel("bascules par avalanche")
                .chartYAxisLabel("fréquence")
                .frame(height: 200)
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
