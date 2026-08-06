import Foundation
import simd
import SwiftUI

struct FrameMetric: Equatable {
    let frameIndex: Int
    let volume: Float?
    let totalEnergy: Float?
    let totalForce: Float?
    let rmsdFromPrevious: Float?
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
}
