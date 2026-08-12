import Foundation
import simd

// Band-surface construction: sample a chosen band's energy over a parallelogram
// patch of reciprocal space, given a detected axis-aligned mesh. Built purely on
// BandMeshInterpolator + KPath; the UI/CLI layers consume BandSurface's gridded values.

/// One gridded sheet of the surface: a single band/spin sampled over the patch.
struct BandSurfaceSheet: Codable, Equatable {
    /// Band index within the energies arrays.
    var band: Int
    /// Spin channel.
    var spin: Int
    /// Human-readable label, e.g. "band 3 (spin up)".
    var label: String
    /// gridSize*gridSize values, row-major over (s,t) in [0,1]^2.
    var values: [Float]
}

/// A band-surface region with all its sampled sheets.
struct BandSurface: Codable, Equatable {
    /// Exactly 4 parallelogram corners (fractional): p0, p1, p2, p0+(p1-p0)+(p2-p0).
    var region: [SIMD3<Float>]
    /// Exactly 4 labels (4th may be "").
    var regionLabels: [String]
    /// Samples per side.
    var gridSize: Int
    /// Sampled sheets (spin-major, band-minor).
    var sheets: [BandSurfaceSheet]
    /// Fermi energy in eV, if the source reported one.
    var fermiEnergy: Float?
    /// Number of spin channels in the source.
    var spinCount: Int
    /// Min energy across ALL sheet values.
    var energyMin: Float
    /// Max energy across ALL sheet values.
    var energyMax: Float
}

/// Construction options. Defaults match the typical UI surface panel.
struct BandSurfaceOptions {
    /// Half-width around E_f (used only when E_f exists).
    var energyWindowEV: Float
    /// Max total sheets when no Fermi level drives selection.
    var maxBands: Int
    /// Samples per side of the patch.
    var gridSize: Int

    init(energyWindowEV: Float = 3.0, maxBands: Int = 16, gridSize: Int = 56) {
        self.energyWindowEV = energyWindowEV
        self.maxBands = maxBands
        self.gridSize = gridSize
    }
}

/// Errors thrown by band-surface construction.
enum BandSurfaceError: Error, CustomStringConvertible {
    case notMesh
    case notAxisAlignedGrid
    case malformedBandStructure
    case degenerateRegion
    case noBandsNearFermi
    case invalidOptions

    var description: String {
        switch self {
        case .notMesh:
            return "band interpolation requires a uniform k-point mesh"
        case .notAxisAlignedGrid:
            return "band interpolation requires an axis-aligned Monkhorst-Pack-style mesh"
        case .malformedBandStructure:
            return "band structure has malformed or non-finite data"
        case .degenerateRegion:
            return "surface region points are collinear"
        case .noBandsNearFermi:
            return "no bands intersect the energy window around the Fermi level"
        case .invalidOptions:
            return "invalid surface construction options"
        }
    }
}

/// Surface construction entry points.
enum BandSurfaceBuilder {

    /// First 3 non-collinear route points of `path` (fractional), or nil if the
    /// path has fewer than 3 points or no non-collinear triple exists. Scans in
    /// route order (lexicographic triples), so a route whose first two edges are
    /// collinear (e.g. Gamma-X-X2-M) still yields Gamma-X-M rather than nil.
    static func defaultRegion(path: KPath) -> [SIMD3<Float>]? {
        guard path.points.count >= 3 else { return nil }
        for i in 0..<path.points.count {
            guard i + 2 < path.points.count else { return nil }
            for j in (i + 1)..<path.points.count {
                for k in (j + 1)..<path.points.count {
                    let p0 = path.points[i].frac
                    let p1 = path.points[j].frac
                    let p2 = path.points[k].frac
                    guard p0.x.isFinite, p0.y.isFinite, p0.z.isFinite,
                          p1.x.isFinite, p1.y.isFinite, p1.z.isFinite,
                          p2.x.isFinite, p2.y.isFinite, p2.z.isFinite else { continue }
                    if !areCollinear(p0, p1, p2) { return [p0, p1, p2] }
                }
            }
        }
        return nil
    }

    /// 4 labels for a 3-point region: the three route-point labels matched by
    /// fractional proximity + "" for the computed 4th corner.
    static func regionLabels(for path: KPath, region: [SIMD3<Float>]) -> [String] {
        guard region.count == 3 else { return ["", "", "", ""] }
        func maxabs(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z))
        }
        let labels = region.map { r in
            for p in path.points {
                if maxabs(r, p.frac) < 1e-5 { return p.label }
            }
            return ""
        }
        return [labels[0], labels[1], labels[2], ""]
    }

    /// Build the band surface. `region` = exactly 3 non-collinear fractional
    /// points (p0,p1,p2); the 4th parallelogram corner is computed inside.
    /// `regionLabels` must have exactly 3 entries (the 4th is set to "").
    static func build(
        bands: BandStructure,
        region: [SIMD3<Float>],
        regionLabels: [String],
        options: BandSurfaceOptions
    ) throws -> BandSurface {
        // Option validation.
        if bands.fermiEnergy != nil {
            guard options.energyWindowEV.isFinite, options.energyWindowEV > 0 else {
                throw BandSurfaceError.invalidOptions
            }
        }
        guard options.gridSize >= 2, options.gridSize <= 256 else {
            throw BandSurfaceError.invalidOptions
        }
        guard options.maxBands >= 1, options.maxBands <= 64 else {
            throw BandSurfaceError.invalidOptions
        }

        guard bands.isMesh else { throw BandSurfaceError.notMesh }
        guard bands.hasValidChannelLayout else { throw BandSurfaceError.malformedBandStructure }
        let perSpin = bands.kPointsPerSpin
        let nBands = bands.nBands
        let nSpin = bands.nSpin
        guard perSpin > 0, nBands > 0 else { throw BandSurfaceError.malformedBandStructure }

        let grid = try BandMeshInterpolator.meshGrid(from: bands)

        // Region: exactly 3 finite, non-collinear points.
        guard region.count == 3,
              region[0].x.isFinite, region[0].y.isFinite, region[0].z.isFinite,
              region[1].x.isFinite, region[1].y.isFinite, region[1].z.isFinite,
              region[2].x.isFinite, region[2].y.isFinite, region[2].z.isFinite else {
            throw BandSurfaceError.degenerateRegion
        }
        let p0 = region[0], p1 = region[1], p2 = region[2]
        guard !areCollinear(p0, p1, p2) else { throw BandSurfaceError.degenerateRegion }
        // Accept a 3-label list or a 4-label list (the 4th computed-corner label
        // from `regionLabels(for:)` is ignored here and reset to "" below).
        guard regionLabels.count >= 3 else { throw BandSurfaceError.degenerateRegion }

        let d0 = p1 - p0
        let d1 = p2 - p0
        let gridSize = options.gridSize

        // Band selection: Fermi-window filter when E_f exists, else all bands
        // capped at maxBands total (spin-major, band-minor).
        struct Sel { let spin: Int; let band: Int }
        var selected: [Sel] = []
        if let Ef = bands.fermiEnergy {
            let lo = Ef - options.energyWindowEV
            let hi = Ef + options.energyWindowEV
            for s in 0..<nSpin {
                let base = s * perSpin
                let channel = Array(bands.kPoints[base..<base + perSpin])
                for b in 0..<nBands {
                    var bandMin = Float.infinity, bandMax = -Float.infinity
                    for kp in channel {
                        let e = kp.energies[b]
                        if e < bandMin { bandMin = e }
                        if e > bandMax { bandMax = e }
                    }
                    // Include iff [bandMin, bandMax] intersects [lo, hi].
                    if bandMin <= hi && bandMax >= lo {
                        selected.append(Sel(spin: s, band: b))
                        if selected.count >= options.maxBands { break }
                    }
                }
                if selected.count >= options.maxBands { break }
            }
        } else {
            for s in 0..<nSpin {
                for b in 0..<nBands {
                    selected.append(Sel(spin: s, band: b))
                    if selected.count >= options.maxBands { break }
                }
                if selected.count >= options.maxBands { break }
            }
        }
        guard !selected.isEmpty else { throw BandSurfaceError.noBandsNearFermi }

        // Sample each selected sheet over (s,t) in [0,1]^2.
        var sheets: [BandSurfaceSheet] = []
        var globalMin = Float.infinity
        var globalMax = -Float.infinity
        for sel in selected {
            let base = sel.spin * perSpin
            let channel = Array(bands.kPoints[base..<base + perSpin])
            let values = channel.map { $0.energies[sel.band] }
            var gridVals: [Float] = []
            gridVals.reserveCapacity(gridSize * gridSize)
            for ti in 0..<gridSize {
                let t = Float(ti) / Float(gridSize - 1)
                for si in 0..<gridSize {
                    let s = Float(si) / Float(gridSize - 1)
                    let k = p0 + s * d0 + t * d1
                    guard let v = grid.interpolate(values, at: k), v.isFinite else {
                        throw BandSurfaceError.malformedBandStructure
                    }
                    gridVals.append(v)
                    if v < globalMin { globalMin = v }
                    if v > globalMax { globalMax = v }
                }
            }
            let spinLabel: String
            if nSpin > 1 { spinLabel = sel.spin == 0 ? " (spin up)" : " (spin down)" } else { spinLabel = "" }
            sheets.append(BandSurfaceSheet(band: sel.band, spin: sel.spin,
                                           label: "band \(sel.band + 1)\(spinLabel)",
                                           values: gridVals))
        }

        let p3 = p0 + d0 + d1
        return BandSurface(
            region: [p0, p1, p2, p3],
            regionLabels: [regionLabels[0], regionLabels[1], regionLabels[2], ""],
            gridSize: gridSize,
            sheets: sheets,
            fermiEnergy: bands.fermiEnergy,
            spinCount: nSpin,
            energyMin: globalMin,
            energyMax: globalMax
        )
    }
}

// MARK: - Geometry helpers

/// True when 3 points are collinear within a sine-based tolerance (~1e-3).
private func areCollinear(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Bool {
    let ab = b - a
    let ac = c - a
    let lab = simd_length(ab)
    let lac = simd_length(ac)
    guard lab > 1e-6, lac > 1e-6 else { return true }
    let sine = simd_length(simd_cross(ab, ac)) / (lab * lac)
    return sine < 1e-3
}
