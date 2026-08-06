import Foundation
import simd
import SwiftUI
import AppKit

struct FrameMetric: Equatable {
    let frameIndex: Int
    let volume: Float?
    let totalEnergy: Float?
    let totalForce: Float?
    let rmsdFromPrevious: Float?
}

/// Selectable per-frame scalar for the plot view. The raw value is read off a
/// `FrameMetric` via `FrameMetric.value(for:)`.
enum FrameMetricField: Int, CaseIterable {
    case volume, energy, force, rmsd
    var label: String {
        switch self {
        case .volume: return "Volume (Å³)"
        case .energy: return "Energy (eV)"
        case .force: return "Force (eV/Å)"
        case .rmsd: return "RMSD (Å)"
        }
    }
    fileprivate func value(from metric: FrameMetric) -> Float? {
        switch self {
        case .volume: return metric.volume
        case .energy: return metric.totalEnergy
        case .force: return metric.totalForce
        case .rmsd: return metric.rmsdFromPrevious
        }
    }
}

extension FrameMetric {
    /// The raw value for `field`, or nil when that field is unavailable.
    func value(for field: FrameMetricField) -> Float? { field.value(from: self) }
}

enum FrameMetrics {
    static func compute(frames: [Scene]) -> [FrameMetric] {
        var result: [FrameMetric] = []
        result.reserveCapacity(frames.count)
        var prevCoords: [SIMD3<Float>]? = nil
        for (i, scene) in frames.enumerated() {
            let volume: Float? = scene.cell.map { abs(simd_dot($0.a, simd_cross($0.b, $0.c))) }
            let energy = scene.forceSet?.totalEnergy
            let force = scene.forceSet?.totalForce
            let coords = scene.atoms.map(\.coord)
            let rmsd: Float?
            if let prev = prevCoords, prev.count == coords.count {
                rmsd = FrameMetrics.rmsd(between: prev, and: coords)
            } else {
                rmsd = nil
            }
            result.append(FrameMetric(frameIndex: i, volume: volume,
                                      totalEnergy: energy, totalForce: force,
                                      rmsdFromPrevious: rmsd))
            prevCoords = coords
        }
        return result
    }

    static func rmsd(between a: [SIMD3<Float>], and b: [SIMD3<Float>]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var sum: Float = 0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            sum += simd_dot(d, d)
        }
        return sqrt(sum / Float(a.count))
    }

    static func interpolate(between a: Scene, and b: Scene, t: Float) -> Scene? {
        guard a.atoms.count == b.atoms.count, !a.atoms.isEmpty else { return nil }
        let tc = min(1, max(0, t))
        var out = a
        out.atoms = zip(a.atoms, b.atoms).map { ai, bi in
            var an = ai
            an.coord = ai.coord + (bi.coord - ai.coord) * tc
            return an
        }
        return out
    }

    static func csv(_ metrics: [FrameMetric]) -> String {
        guard !metrics.isEmpty else { return "" }
        var lines: [String] = ["frame_index,volume_ang3,totalEnergy_eV,totalForce_eV_per_ang,rmsd_ang"]
        for m in metrics {
            lines.append("\(m.frameIndex)\(csvOpt(m.volume))\(csvOpt(m.totalEnergy))\(csvOpt(m.totalForce))\(csvOpt(m.rmsdFromPrevious))")
        }
        return lines.joined(separator: "\n")
    }

    private static func csvOpt(_ v: Float?) -> String {
        guard let v, v.isFinite else { return "," }
        return ",\(v)"
    }

    /// Area-weighted centroid of a coordinate set. nil when empty or any
    /// coordinate is non-finite.
    static func centroid(_ coords: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard !coords.isEmpty else { return nil }
        var sum = SIMD3<Float>.zero
        for c in coords {
            guard c.isFinite else { return nil }
            sum += c
        }
        return sum / Float(coords.count)
    }

    /// Translate every frame so its atom-coordinate centroid matches the
    /// reference frame's centroid (pure translation, no rotation). Returns nil
    /// when frames are empty, atom counts differ across frames, referenceIndex
    /// is out of range, or any coordinate is non-finite. Every other Scene
    /// field is preserved; only atom coords are shifted.
    static func alignCentroid(frames: [Scene], to referenceIndex: Int = 0) -> [Scene]? {
        guard !frames.isEmpty else { return nil }
        guard frames.indices.contains(referenceIndex) else { return nil }
        let atomCount = frames[0].atoms.count
        guard atomCount > 0 else { return nil }
        guard frames.allSatisfy({ $0.atoms.count == atomCount }) else { return nil }
        guard let refCentroid = centroid(frames[referenceIndex].atoms.map(\.coord)) else { return nil }
        var result: [Scene] = []
        result.reserveCapacity(frames.count)
        for frame in frames {
            guard let c = centroid(frame.atoms.map(\.coord)) else { return nil }
            let shift = refCentroid - c
            var aligned = frame
            aligned.atoms = frame.atoms.map { atom in
                var a = atom
                a.coord = atom.coord + shift
                return a
            }
            result.append(aligned)
        }
        return result
    }
}

/// Minimal AppKit plot of a selected per-frame metric vs frame index. Used both
/// for the live pop-out window and for headless (test) rendering. Nil metric
/// values leave gaps in the polyline. `csv()` reuses `FrameMetrics.csv`.
class FrameMetricsPlotView: NSView {
    var metrics: [FrameMetric] = []
    var metric: FrameMetricField = .volume
    var showLabels = true
    var exportBackground: NSColor = .white
    var isExportTransparent = false

    func csv() -> String { FrameMetrics.csv(metrics) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        // Background.
        ctx.clear(bounds)
        if !isExportTransparent {
            ctx.setFillColor(exportBackground.cgColor)
            ctx.fill(bounds)
        }

        let values = metrics.map { $0.value(for: metric) }
        let finite = values.compactMap { $0 }
        guard !finite.isEmpty else { return }

        let minV = finite.min()!
        let maxV = finite.max()!
        let span = maxV - minV

        let padLeft: CGFloat = 36, padBottom: CGFloat = 22
        let padTop: CGFloat = showLabels ? 18 : 6, padRight: CGFloat = 8
        let plotW = max(1, bounds.width - padLeft - padRight)
        let plotH = max(1, bounds.height - padTop - padBottom)
        let n = metrics.count

        func xFor(_ i: Int) -> CGFloat {
            guard n > 1 else { return padLeft + plotW * 0.5 }
            return padLeft + CGFloat(i) * plotW / CGFloat(n - 1)
        }
        func yFor(_ v: Float) -> CGFloat {
            let norm = span > 0 ? CGFloat((v - minV) / span) : 0.5
            return padTop + plotH - norm * plotH
        }

        // Axes.
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: NSPoint(x: padLeft, y: padTop))
        ctx.addLine(to: NSPoint(x: padLeft, y: padTop + plotH))
        ctx.addLine(to: NSPoint(x: padLeft + plotW, y: padTop + plotH))
        ctx.strokePath()

        // Polyline, skipping gaps (nil values break the segment).
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5)
        var iterating = false
        for (i, v) in values.enumerated() {
            guard let v else { iterating = false; continue }
            let pt = NSPoint(x: xFor(i), y: yFor(v))
            if iterating { ctx.addLine(to: pt) } else { ctx.move(to: pt) }
            iterating = true
        }
        ctx.strokePath()

        // Axis labels (metric name + frame range).
        if showLabels {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            (metric.label as NSString).draw(at: NSPoint(x: padLeft + 2, y: 2), withAttributes: attrs)
            if n > 0 {
                ("0" as NSString).draw(at: NSPoint(x: padLeft - 2, y: bounds.height - 12), withAttributes: attrs)
                ("\(n - 1)" as NSString).draw(
                    at: NSPoint(x: bounds.width - padRight - 18, y: bounds.height - 12), withAttributes: attrs)
            }
        }
    }
}
