import SwiftUI

/// Versement de grains au centre et vérification de la propriété abélienne.
struct CentralPourPanel: View {
    @Environment(SimulationModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Les grains sont posés sur la case centrale, puis toutes les cases instables basculent en parallèle sur le GPU jusqu'à stabilité.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Text("\(settings.pourAmount, format: .number) grains")
                    .font(.headline.monospacedDigit())
                Spacer()
                SettingsLink { Text("Modifier…") }
            }

            HStack {
                Button("Verser au centre", systemImage: "drop.fill") { model.pourCenter() }
                    .buttonStyle(.borderedProminent)
                Button("Vider", systemImage: "trash", role: .destructive) { model.resetPour() }
            }
            .disabled(model.state.isBusy)

            if model.state == .pouring || model.state == .verifying {
                HStack {
                    ProgressView().controlSize(.small)
                    Button("Annuler") { model.cancel() }
                }
            }

            Divider()

            StatRow("Grains versés", Text(model.pouredGrains, format: .number))
            StatRow("Grains sur la grille", Text(model.pourGrid.totalGrains, format: .number))
            StatRow("Grains perdus au bord",
                    Text(UInt64(model.pouredGrains) - model.pourGrid.totalGrains, format: .number))
            if let seconds = model.lastPourSeconds {
                StatRow("Durée GPU", secondsText(seconds))
            }

            Divider()

            Text("Tailles des avalanches (log-log)").font(.headline)
            Text("Les mêmes grains, versés un par un au centre sur le CPU : chaque grain déclenche sa propre avalanche.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.pourStatsTotal > 0 {
                if model.isComputingPourStats {
                    ProgressView(value: Double(model.pourStatsDone), total: Double(model.pourStatsTotal)) {
                        Text("\(model.pourStatsDone, format: .number) / \(model.pourStatsTotal, format: .number) grains")
                            .font(.caption.monospacedDigit())
                    }
                    Button("Arrêter le calcul", systemImage: "stop.fill") { model.cancelPourStats() }
                        .controlSize(.small)
                }
                AvalancheHistogram(stats: model.pourStats)
                StatRow("Ajouts sans bascule",
                        Text(model.pourStats.quietFraction, format: .percent.precision(.fractionLength(1))))
                StatRow("Plus grande avalanche", cellsText(model.pourStats.largestArea))
                StatRow("Bascules (record)", Text(model.pourStats.largestTopples, format: .number))
                if let match = model.pourStatsMatchGPU {
                    Label(match ? "Grille identique à celle du GPU" : "Grille différente de celle du GPU",
                          systemImage: match ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(match ? .green : .red)
                        .font(.callout)
                } else if !model.isComputingPourStats && model.pourStatsDone < model.pourStatsTotal {
                    Text("Calcul arrêté : histogramme partiel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Versez des grains pour voir l'histogramme.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Propriété abélienne").font(.headline)
            Text("Les mêmes grains, sur une grille vide, stabilisés dans trois ordres : file sur le CPU, ordre aléatoire sur le CPU, toutes les cases à la fois sur le GPU.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Vérifier", systemImage: "checkmark.seal") { model.verifyAbelian() }
                .disabled(model.state.isBusy)

            if let report = model.abelianReport {
                Label(report.isAbelian ? "Configurations identiques" : "Configurations différentes",
                      systemImage: report.isAbelian ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(report.isAbelian ? .green : .red)
                StatRow("Grains", Text(report.grains, format: .number))
                StatRow("File = aléatoire", report.queueEqualsRandom ? Text("oui") : Text("non"))
                StatRow("File = GPU", report.queueEqualsGPU
                        ? Text("oui") : Text("non") + Text(verbatim: " (") + cellsText(report.differingCells) + Text(verbatim: ")"))
                StatRow("Grains restants", Text(report.remaining, format: .number))
                StatRow("CPU (par ordre)", secondsText(report.cpuSeconds))
                StatRow("GPU", secondsText(report.gpuSeconds))
                StatRow("Rondes parallèles", Text(report.gpuRounds, format: .number))
            }
        }
    }
}
