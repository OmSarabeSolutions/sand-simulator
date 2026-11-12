import Charts
import SwiftUI

/// Histogramme log-log des tailles d'avalanche (nombre de bascules), partagé par l'ajout aléatoire
/// et le versement central. Les deux axes sont gradués en puissances de 10 (10⁰, 10¹… ; 10⁻¹, 10⁻²…).
struct AvalancheHistogram: View {
    let stats: AvalancheStats

    var body: some View {
        let bins = stats.histogram
        if bins.count >= 2 {
            let largest = bins.map(\.size).max() ?? 1
            let exponents = Array(0...max(1, Int(log10(largest).rounded(.up))))
            let frequencies = bins.map(\.frequency)
            let yExponents = Self.decades(from: frequencies.min() ?? 1e-3, to: frequencies.max() ?? 1)
            Chart(bins) { bin in
                LineMark(x: .value("Bascules", bin.size), y: .value("Fréquence", bin.frequency))
                    .foregroundStyle(.teal)
                PointMark(x: .value("Bascules", bin.size), y: .value("Fréquence", bin.frequency))
                    .foregroundStyle(.teal)
            }
            .chartXScale(domain: 1...pow(10, Double(exponents.last!)), type: .log)
            .chartYScale(domain: pow(10, Double(yExponents.first!))...pow(10, Double(yExponents.last!)), type: .log)
            .chartXAxis {
                AxisMarks(values: exponents.map { pow(10, Double($0)) }) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let x = value.as(Double.self) {
                            Text(verbatim: Self.powerOfTen(Int(log10(x).rounded())))
                        }
                    }
                }
            }
            .chartYAxis {
                // Une ligne par décade ; au-delà de 8 décades, une étiquette sur deux.
                let step = yExponents.count > 8 ? 2 : 1
                AxisMarks(position: .trailing, values: yExponents.map { pow(10, Double($0)) }) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let y = value.as(Double.self) {
                            let e = Int(log10(y).rounded())
                            if (e - yExponents.last!) % step == 0 {
                                Text(verbatim: Self.powerOfTen(e))
                            }
                        }
                    }
                }
            }
            .chartXAxisLabel("bascules par avalanche")
            .chartYAxisLabel("fréquence")
            .frame(height: 200)
        }
    }

    private nonisolated static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "-": "⁻",
    ]

    /// Exposants des puissances de 10 qui encadrent [low, high] : decades(2e-7, 0.3) = -7…0.
    nonisolated static func decades(from low: Double, to high: Double) -> [Int] {
        let first = Int(log10(max(low, .leastNormalMagnitude)).rounded(.down))
        let last = max(first + 1, Int(log10(max(high, .leastNormalMagnitude)).rounded(.up)))
        return Array(first...last)
    }

    /// « 10ⁿ » avec l'exposant en exposant typographique : 10⁰, 10³, 10⁻².
    nonisolated static func powerOfTen(_ exponent: Int) -> String {
        "10" + String(String(exponent).map { superscripts[$0] ?? $0 })
    }
}
