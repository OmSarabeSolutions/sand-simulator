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
                Text("\(settings.pourAmount.formatted()) grains")
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

            StatRow("Grains versés", model.pouredGrains.formatted())
            StatRow("Grains sur la grille", model.pourGrid.totalGrains.formatted())
            StatRow("Grains perdus au bord",
                    (UInt64(model.pouredGrains) - model.pourGrid.totalGrains).formatted())
            if let seconds = model.lastPourSeconds {
                StatRow("Durée GPU", seconds.formatted(.number.precision(.fractionLength(3))) + " s")
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
                StatRow("Grains", report.grains.formatted())
                StatRow("File = aléatoire", report.queueEqualsRandom ? "oui" : "non")
                StatRow("File = GPU", report.queueEqualsGPU ? "oui" : "non (\(report.differingCells) cases)")
                StatRow("Grains restants", report.remaining.formatted())
                StatRow("CPU (par ordre)", report.cpuSeconds.formatted(.number.precision(.fractionLength(3))) + " s")
                StatRow("GPU", report.gpuSeconds.formatted(.number.precision(.fractionLength(3))) + " s")
                StatRow("Rondes parallèles", report.gpuRounds.formatted())
            }
        }
    }
}
