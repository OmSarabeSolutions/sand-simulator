import CoreGraphics
import SwiftUI

/// Couleurs des cases, calculées comme dans le shader `Render.metal` à partir des quatre
/// couleurs de la palette choisie (`AppSettings.paletteColors`).
struct Palette: Sendable {
    /// Les quatre couleurs : 0 grain, puis les niveaux suivants.
    let stops: [SIMD3<Float>]

    init(_ stops: [SIMD3<Float>]) {
        precondition(stops.count == 4, "Une palette a quatre couleurs")
        self.stops = stops
    }

    /// Dégradé entre les quatre couleurs pour t dans [0, 1] (t = 0, 1/3, 2/3, 1 donnent les couleurs
    /// exactes : c'est le cas des 4 niveaux quand le seuil vaut 4).
    func ramp(_ t: Float) -> SIMD3<Float> {
        let x = min(max(t, 0), 1) * 3
        let i = min(Int(x), 2)
        let f = x - Float(i)
        return stops[i] * (1 - f) + stops[i + 1] * f
    }

    /// Couleur d'une case portant `grains` grains (0 à T − 1).
    func grains(_ grains: Int, threshold: Int) -> SIMD3<Float> {
        ramp(Float(grains) / Float(max(threshold, 2) - 1))
    }

    /// Couleur d'une case du tas divisible : 4e couleur si elle est pleine, sinon un mélange
    /// de la 1re et de la 2e selon sa masse.
    func mass(_ value: Float) -> SIMD3<Float> {
        if value >= 0.999 { return stops[3] }
        let t = min(max(value, 0), 1)
        return stops[0] * (1 - t) + stops[1] * t
    }

    static func color(_ rgb: SIMD3<Float>) -> Color {
        Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }

    /// Image vue de dessus, un pixel par case.
    static func image(width: Int, height: Int, color: (Int) -> SIMD3<Float>) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let c = color(i)
            pixels[i * 4] = UInt8(min(max(c.x, 0), 1) * 255)
            pixels[i * 4 + 1] = UInt8(min(max(c.y, 0), 1) * 255)
            pixels[i * 4 + 2] = UInt8(min(max(c.z, 0), 1) * 255)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func image(of grid: Grid, threshold: Int) -> CGImage? {
        Self.image(width: grid.width, height: grid.height) { grains(Int(grid.cells[$0]), threshold: threshold) }
    }

    func image(masses: [Float], width: Int, height: Int) -> CGImage? {
        Self.image(width: width, height: height) { mass(masses[$0]) }
    }
}

/// Légende des couleurs : une pastille par nombre de grains.
struct PaletteLegend: View {
    let threshold: Int
    let palette: Palette

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<threshold, id: \.self) { level in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.color(palette.grains(level, threshold: threshold)))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.5), lineWidth: 0.5))
                        .frame(width: 12, height: 12)
                    Text(verbatim: "\(level)").font(.caption.monospacedDigit())
                }
            }
        }
        .accessibilityLabel(Text("Couleurs de 0 à \(threshold - 1) grains"))
    }
}

/// Aperçu des quatre couleurs d'une palette (page de réglages).
struct PaletteSwatch: View {
    let colors: [SIMD3<Float>]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(colors.indices, id: \.self) { i in
                Rectangle().fill(Palette.color(colors[i])).frame(width: 18, height: 14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.5), lineWidth: 0.5))
    }
}
