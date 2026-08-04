import Foundation
import simd

/// Configurable scalar-field colormaps for the color-plane / volumetric features.
enum Colormap: String, CaseIterable, Codable {
    case viridis, turbo, inferno, gray

    var displayName: String {
        switch self {
        case .viridis: return "Viridis"
        case .turbo: return "Turbo"
        case .inferno: return "Inferno"
        case .gray: return "Grayscale"
        }
    }

    /// Map t∈[0,1] to an RGB triplet in [0,1]³. Non-finite and out-of-range
    /// inputs are clamped to the endpoints.
    func rgb(_ t: Float) -> SIMD3<Float> {
        let tt = t.isFinite ? max(0, min(1, t)) : 0
        switch self {
        case .viridis:
            let r = max(0, min(1, 0.267004 + tt*(0.003295 + tt*(-0.227411 + tt*(2.787674 + tt*(-2.719152 + tt*0.815994))))))
            let g = max(0, min(1, 0.004874 + tt*(0.104041 + tt*(0.546790 + tt*(-1.248878 + tt*(0.745538 + tt*0.207481))))))
            let b = max(0, min(1, 0.329415 + tt*(1.015680 + tt*(-2.129948 + tt*(2.600750 + tt*(-1.737255 + tt*0.472965))))))
            return SIMD3<Float>(r, g, b)
        case .turbo:
            // Polynomial approximation of Google's Turbo colormap
            // (Anton Mikhailov, 2019; licensed CC-BY 4.0). Visually
            // faithful across the range with monotone blue→red endpoints.
            let r = max(0, min(1, 0.135721 + tt*(6.851133 + tt*(-62.302925 + tt*(246.377670 + tt*(-491.486603 + tt*459.570526))))))
            let g = max(0, min(1, 0.091402 + tt*(2.194061 + tt*(4.842926 + tt*(-14.185680 + tt*(4.277242 + tt*2.829351))))))
            let b = max(0, min(1, 0.106673 + tt*(12.641636 + tt*(-60.640862 + tt*(110.362778 + tt*(-89.903107 + tt*27.348503))))))
            return SIMD3<Float>(r, g, b)
        case .inferno:
            // Polynomial approximation of the Matplotlib Inferno colormap
            // (Stefan van der Walt & Nathaniel Smith; CC0 / public domain).
            let r = max(0, min(1, 0.001241 + tt*(0.177574 + tt*(5.054568 + tt*(-18.451599 + tt*(25.052103 + tt*(-11.758932)))))))
            let g = max(0, min(1, 0.000257 + tt*(-0.021034 + tt*(0.747928 + tt*(-1.513443 + tt*(1.587477 + tt*(-0.522048)))))))
            let b = max(0, min(1, 0.013351 + tt*(1.403422 + tt*(-5.873056 + tt*(10.316330 + tt*(-7.922852 + tt*2.213052))))))
            return SIMD3<Float>(r, g, b)
        case .gray:
            return SIMD3<Float>(tt, tt, tt)
        }
    }

    /// Map t∈[0,1] to 8-bit RGB, using the same `UInt8(v*255.5)` rounding
    /// as the legacy ColorPlaneView.viridis helper.
    func rgb8(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let c = rgb(t)
        return (UInt8(c.x * 255.5), UInt8(c.y * 255.5), UInt8(c.z * 255.5))
    }
}

/// Contour-generation parameters shared by the color-plane and future
/// volumetric renderers.
struct ContourConfig: Codable, Equatable {
    var enabled: Bool = true
    var count: Int = 6

    /// Linearly-spaced contour levels strictly between min and max.
    /// Replicates the MainWindowController.defaultContourLevels formula:
    ///   levels(i) = min + (max-min) * i / count   for i in 1..<count
    /// Returns [] when max <= min or count < 2; count is clamped to 2...24.
    static func levels(min: Float, max: Float, count: Int) -> [Float] {
        guard max > min, count >= 2 else { return [] }
        let n = Swift.min(24, Swift.max(2, count))
        return (1..<n).map { i in min + (max - min) * Float(i) / Float(n) }
    }

    /// Six default levels (matches the legacy behavior).
    static func defaultLevels(min: Float, max: Float) -> [Float] {
        levels(min: min, max: max, count: 6)
    }
}
