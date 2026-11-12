import CoreGraphics
import SwiftUI

/// Couleurs des cases, identiques à celles du shader `Render.metal`.
enum Palette {
    private static let stops: [SIMD3<Float>] = [
        SIMD3(0.10, 0.16, 0.35), SIMD3(0.10, 0.55, 0.60),
        SIMD3(0.95, 0.78, 0.25), SIMD3(0.85, 0.25, 0.20),
    ]

    /// Dégradé bleu nuit → sarcelle → or → rouge pour t dans [0, 1].
    static func ramp(_ t: Float) -> SIMD3<Float> {
        let x = min(max(t, 0), 1) * 3
        let i = min(Int(x), 2)
        let f = x - Float(i)
        return stops[i] * (1 - f) + stops[i + 1] * f
    }

    /// Couleur d'une case portant `grains` grains (0 à T − 1).
    static func grains(_ grains: Int, threshold: Int) -> SIMD3<Float> {
        ramp(Float(grains) / Float(max(threshold, 2) - 1))
    }

    /// Couleur d'une case du tas divisible.
    static func mass(_ value: Float) -> SIMD3<Float> {
        if value >= 0.999 { return SIMD3(0.95, 0.78, 0.25) }
        let t = min(max(value, 0), 1)
        return SIMD3(0.08, 0.09, 0.12) * (1 - t) + SIMD3(0.10, 0.55, 0.60) * t
    }

    static func color(_ rgb: SIMD3<Float>) -> Color {
        Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }

    /// Image vue de dessus, un pixel par case.
    static func image(width: Int, height: Int, color: (Int) -> SIMD3<Float>) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let c = color(i)
            pixels[i * 4] = UInt8(c.x * 255)
            pixels[i * 4 + 1] = UInt8(c.y * 255)
            pixels[i * 4 + 2] = UInt8(c.z * 255)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func image(of grid: Grid, threshold: Int) -> CGImage? {
        image(width: grid.width, height: grid.height) { grains(Int(grid.cells[$0]), threshold: threshold) }
    }

    static func image(masses: [Float], width: Int, height: Int) -> CGImage? {
        image(width: width, height: height) { mass(masses[$0]) }
    }
}

/// Légende des couleurs : une pastille par nombre de grains.
struct PaletteLegend: View {
    let threshold: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<threshold, id: \.self) { level in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.color(Palette.grains(level, threshold: threshold)))
                        .frame(width: 12, height: 12)
                    Text("\(level)").font(.caption.monospacedDigit())
                }
            }
        }
        .accessibilityLabel("Couleurs de 0 à \(threshold - 1) grains")
    }
}
