import Foundation
import AppKit

enum ExportOptionsError: Error, LocalizedError {
    case invalidWidth(Int)
    case invalidHeight(Int)
    case invalidMSAA(Int)
    case tooManyPixels(Int)

    var errorDescription: String? {
        switch self {
        case .invalidWidth(let w):
            return "Width \(w) is out of range (\(ExportOptions.minDimension)–\(ExportOptions.maxDimension))"
        case .invalidHeight(let h):
            return "Height \(h) is out of range (\(ExportOptions.minDimension)–\(ExportOptions.maxDimension))"
        case .invalidMSAA(let v):
            return "MSAA \(v)x is not supported; choose Off, 2x, 4x, or 8x"
        case .tooManyPixels(let count):
            return "Export dimensions exceed the maximum pixel count (\(count.formatted()))"
        }
    }
}

final class ExportOptions: ObservableObject {
    static let minDimension = 64
    static let maxDimension = 16_384
    static let defaultDimension = 800

    /// Valid MSAA export-override values for the picker, in display order.
    /// `nil` = Use Document (no override; export uses Scene.msaaSampleCount, which
    /// may itself be 1/2/4/8); 1 = force Off; 2/4/8 = override for export only.
    /// `nil` is NOT "Off": a scene already at 4x stays at 4x unless an explicit
    /// value is picked. Derived from all cases of `MSAASampleCount`.
    static let msaaOptions: [Int?] = [nil, 1, 2, 4, 8]
    static let validMSAAValues: Set<Int> = [1, 2, 4, 8]

    @Published var width: Int = ExportOptions.defaultDimension
    @Published var height: Int = ExportOptions.defaultDimension
    @Published var backgroundColor: NSColor = NSColor(deviceRed: 0.063, green: 0.063, blue: 0.078, alpha: 1.0)
    @Published var isTransparent: Bool = false
    /// MSAA sample-count override for export. `nil` = Use Document (no override;
    /// export uses Scene.msaaSampleCount, which may differ from Off); 1 = force Off;
    /// 2/4/8 = override applied at export time WITHOUT changing the document scene.
    @Published var msaaSampleCount: Int? = nil

    convenience init(backgroundHex: String, transparent: Bool) {
        self.init()
        self.backgroundColor = NSColor(hex: backgroundHex) ?? NSColor(deviceRed: 0.063, green: 0.063, blue: 0.078, alpha: 1.0)
        self.isTransparent = transparent
    }

    func validate() throws {
        guard width >= Self.minDimension, width <= Self.maxDimension else {
            throw ExportOptionsError.invalidWidth(width)
        }
        guard height >= Self.minDimension, height <= Self.maxDimension else {
            throw ExportOptionsError.invalidHeight(height)
        }
        // Total pixel count must not exceed the exporter ceiling.
        guard pixelCount <= 16_000_000 else {
            throw ExportOptionsError.tooManyPixels(pixelCount)
        }
        // Only validate when an explicit override is set; nil = Use Document (no
        // override), which is always valid and needs no check.
        if let msaa = msaaSampleCount {
            guard Self.validMSAAValues.contains(msaa) else {
                throw ExportOptionsError.invalidMSAA(msaa)
            }
        }
    }

    var pixelCount: Int {
        let product = width.multipliedReportingOverflow(by: height)
        return product.overflow ? Int.max : product.partialValue
    }

    var backgroundHex: String {
        let rgb = backgroundColor.usingColorSpace(.deviceRGB) ?? backgroundColor
        // Clamp each component to [0,1] before scaling: wide-gamut (Display P3 /
        // extended-range) colors can exceed 1.0, which would otherwise format to a
        // >2-digit hex value and produce a corrupt export header.
        func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
        let r = Int((clamp01(rgb.redComponent) * 255).rounded())
        let g = Int((clamp01(rgb.greenComponent) * 255).rounded())
        let b = Int((clamp01(rgb.blueComponent) * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    var clearColor: (r: Double, g: Double, b: Double, a: Double) {
        if isTransparent { return (0, 0, 0, 0) }
        let c = backgroundColor.usingColorSpace(.deviceRGB) ?? backgroundColor
        return (c.redComponent, c.greenComponent, c.blueComponent, 1.0)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(deviceRed: Double((v >> 16) & 0xFF) / 255.0,
                  green: Double((v >> 8) & 0xFF) / 255.0,
                  blue: Double(v & 0xFF) / 255.0,
                  alpha: 1.0)
    }
}
