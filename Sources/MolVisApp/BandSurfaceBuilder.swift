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

/// One candidate band offered by the band-surface band picker: identity,
/// label, energy range, and occupancy relative to the Fermi level (nil when
/// E_f is unknown). `selectionKey` is the stable key used by
/// `BandSurfaceOptions.selectedBands` (spin*10_000+band).
struct BandSurfaceBandInfo: Equatable, Identifiable {
    var spin: Int
    var band: Int
    var label: String
    var minEnergy: Float
    var maxEnergy: Float
    var isOccupied: Bool?
    var selectionKey: Int { spin * 10_000 + band }
    var id: Int { selectionKey }
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
    /// Reciprocal-lattice basis rows in Angstrom^-1 (3 vectors) when the source
    /// carried a real-space cell; the 3D view uses it to draw the k_x/k_y axes
    /// in physical units. nil -> the view falls back to fractional units.
    var kBasis: [SIMD3<Float>]? = nil

    private enum CodingKeys: String, CodingKey {
        case region, regionLabels, gridSize, sheets, fermiEnergy, spinCount,
             energyMin, energyMax, kBasis
    }

    init(region: [SIMD3<Float>], regionLabels: [String], gridSize: Int,
         sheets: [BandSurfaceSheet], fermiEnergy: Float?, spinCount: Int,
         energyMin: Float, energyMax: Float, kBasis: [SIMD3<Float>?]? = nil) {
        self.region = region
        self.regionLabels = regionLabels
        self.gridSize = gridSize
        self.sheets = sheets
        self.fermiEnergy = fermiEnergy
        self.spinCount = spinCount
        self.energyMin = energyMin
        self.energyMax = energyMax
        self.kBasis = kBasis?.compactMap { $0 }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        region = try c.decode([SIMD3<Float>].self, forKey: .region)
        regionLabels = try c.decode([String].self, forKey: .regionLabels)
        gridSize = try c.decode(Int.self, forKey: .gridSize)
        sheets = try c.decode([BandSurfaceSheet].self, forKey: .sheets)
        fermiEnergy = try c.decodeIfPresent(Float.self, forKey: .fermiEnergy)
        spinCount = try c.decode(Int.self, forKey: .spinCount)
        energyMin = try c.decode(Float.self, forKey: .energyMin)
        energyMax = try c.decode(Float.self, forKey: .energyMax)
        kBasis = try c.decodeIfPresent([SIMD3<Float>].self, forKey: .kBasis)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(region, forKey: .region)
        try c.encode(regionLabels, forKey: .regionLabels)
        try c.encode(gridSize, forKey: .gridSize)
        try c.encode(sheets, forKey: .sheets)
        try c.encodeIfPresent(fermiEnergy, forKey: .fermiEnergy)
        try c.encode(spinCount, forKey: .spinCount)
        try c.encode(energyMin, forKey: .energyMin)
        try c.encode(energyMax, forKey: .energyMax)
        try c.encodeIfPresent(kBasis, forKey: .kBasis)
    }
}

/// Construction options. Defaults match the typical UI surface panel.
struct BandSurfaceOptions {
    /// Half-width around E_f (kept for compatibility). Band selection no longer
    /// uses it; `bandCount` / `selectedBands` drives selection instead.
    var energyWindowEV: Float
    /// Max total sheets when no Fermi level drives selection.
    var maxBands: Int
    /// Samples per side of the patch.
    var gridSize: Int
    /// Number of bands closest to E_f selected when `selectedBands` is nil.
    /// Clamped to 1...maxBands inside build(). Default 2 = the spec default
    /// ("plot only the 2 bands closest to the Fermi level").
    var bandCount: Int
    /// Explicit (spin,band) selection keys (spin*10_000+band), or nil for the
    /// `bandCount`-closest rule. An EMPTY set is a valid request: build() then
    /// returns a BandSurface with NO sheets (the view draws axes only).
    var selectedBands: Set<Int>?

    init(energyWindowEV: Float = 3.0, maxBands: Int = 16, gridSize: Int = 56,
         bandCount: Int = 2, selectedBands: Set<Int>? = nil) {
        self.energyWindowEV = energyWindowEV
        self.maxBands = maxBands
        self.gridSize = gridSize
        self.bandCount = bandCount
        self.selectedBands = selectedBands
    }
}

/// Errors thrown by band-surface construction.
enum BandSurfaceError: Error, CustomStringConvertible {
    case notMesh
    case notAxisAlignedGrid
    case requiresTwoDimensionalMesh
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
        case .requiresTwoDimensionalMesh:
            return "band surfaces are limited to 2D k-point meshes (slabs); this mesh is not a 2D k-grid"
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
    /// `regionLabels` must have at least 3 entries (the 4th is set to "").
    ///
    /// Band surfaces are LIMITED TO 2D SYSTEMS: the mesh must be a 2D k-grid
    /// (exactly two non-degenerate sampling axes, e.g. a slab). Bulk 3D meshes
    /// throw `.requiresTwoDimensionalMesh` — a band surface of a 3D BZ would
    /// need an arbitrary slice plane, which is out of scope.
    ///
    /// Default selection = the `bandCount` (default 2) bands closest to E_f. An
    /// explicit `selectedBands` set (including empty) overrides: the keys are
    /// `spin*10_000+band`. An empty set builds a surface with no sheets (axes
    /// only). Selection keys outside range are silently ignored.
    static func build(
        bands: BandStructure,
        region: [SIMD3<Float>],
        regionLabels: [String],
        options: BandSurfaceOptions
    ) throws -> BandSurface {
        // Option validation.
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

        // 2D-only gate: band surfaces require a k-grid with exactly two
        // non-degenerate sampling axes (a slab). A 3D bulk mesh is rejected;
        // 1D point sets never reach this check (meshGrid rejects them).
        guard grid.dims.filter({ $0 > 1 }).count == 2 else {
            throw BandSurfaceError.requiresTwoDimensionalMesh
        }

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

        // Per-(spin,band) min/max in one pass over channels.
        var bandMins = [Float](repeating: .infinity, count: nSpin * nBands)
        var bandMaxs = [Float](repeating: -.infinity, count: nSpin * nBands)
        for s in 0..<nSpin {
            let base = s * perSpin
            for kp in bands.kPoints[base..<base + perSpin] {
                for b in 0..<nBands {
                    let e = kp.energies[b]
                    let idx = s * nBands + b
                    if e < bandMins[idx] { bandMins[idx] = e }
                    if e > bandMaxs[idx] { bandMaxs[idx] = e }
                }
            }
        }

        // Band selection.
        struct Sel { let spin: Int; let band: Int }
        var selected: [Sel]
        if let keys = options.selectedBands {
            // Explicit selection (possibly empty). Keep keys present in the set,
            // spin-major then band-minor, capped at maxBands.
            var out: [Sel] = []
            for s in 0..<nSpin {
                for b in 0..<nBands {
                    if keys.contains(s * 10_000 + b) {
                        out.append(Sel(spin: s, band: b))
                        if out.count >= options.maxBands { break }
                    }
                }
                if out.count >= options.maxBands { break }
            }
            selected = out
        } else {
            // bandCount-closest rule; clamped 1...maxBands.
            let count = min(options.maxBands, max(1, options.bandCount))
            let keys = closestBands(bands, count: count)
            guard !keys.isEmpty else { throw BandSurfaceError.noBandsNearFermi }
            // closestBands keys already sort by distance; re-sort by (spin, band).
            selected = keys.compactMap { key in
                let s = key / 10_000
                let b = key % 10_000
                guard s >= 0, s < nSpin, b >= 0, b < nBands else { return nil }
                return Sel(spin: s, band: b)
            }.sorted { $0.spin != $1.spin ? $0.spin < $1.spin : $0.band < $1.band }
        }

        // Sample each selected sheet over (s,t) in [0,1]^2.
        var sheets: [BandSurfaceSheet] = []
        var sampleMin = Float.infinity
        var sampleMax = -Float.infinity
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
                    if v < sampleMin { sampleMin = v }
                    if v > sampleMax { sampleMax = v }
                }
            }
            let spinLabel: String
            if nSpin > 1 { spinLabel = sel.spin == 0 ? " (spin up)" : " (spin down)" } else { spinLabel = "" }
            sheets.append(BandSurfaceSheet(band: sel.band, spin: sel.spin,
                                           label: "band \(sel.band + 1)\(spinLabel)",
                                           values: gridVals))
        }

        // energyMin/energyMax: sampled range when sheets non-empty, else the
        // global min/max over all bands so the view's energy axis is well-defined.
        let energyMin: Float
        let energyMax: Float
        if sheets.isEmpty {
            energyMin = bandMins.min() ?? 0
            energyMax = bandMaxs.max() ?? 0
        } else {
            energyMin = sampleMin
            energyMax = sampleMax
        }

        // kBasis from the source cell when all 9 components are finite.
        let kBasis: [SIMD3<Float>]? = bands.cell.map { cell -> [SIMD3<Float>] in
            let rv = cell.reciprocalVectors
            let vecs = [rv.a, rv.b, rv.c]
            guard vecs.allSatisfy({ v in v.x.isFinite && v.y.isFinite && v.z.isFinite }) else {
                return []
            }
            return vecs
        } ?? nil

        let p3 = p0 + d0 + d1
        return BandSurface(
            region: [p0, p1, p2, p3],
            regionLabels: [regionLabels[0], regionLabels[1], regionLabels[2], ""],
            gridSize: gridSize,
            sheets: sheets,
            fermiEnergy: bands.fermiEnergy,
            spinCount: nSpin,
            energyMin: energyMin,
            energyMax: energyMax,
            kBasis: kBasis
        )
    }

    /// Candidate bands for the UI band picker: every (spin, band) whose
    /// [minEnergy, maxEnergy] intersects [Ef-windowEV, Ef+windowEV] when E_f
    /// exists (windowEV > 0, default 4.0), ordered spin-major then band-minor,
    /// capped at maxCandidates (default 32). Without E_f, the first
    /// maxCandidates bands. Uses the SAME per-channel min/max pass as build().
    static func bandInfos(_ bands: BandStructure, windowEV: Float = 4.0,
                          maxCandidates: Int = 32) -> [BandSurfaceBandInfo] {
        guard bands.hasValidChannelLayout, bands.nBands > 0 else { return [] }
        let perSpin = bands.kPointsPerSpin
        let nBands = bands.nBands
        let nSpin = bands.nSpin
        guard perSpin > 0, nSpin > 0 else { return [] }

        // Per-(spin,band) min/max.
        var bandMins = [Float](repeating: .infinity, count: nSpin * nBands)
        var bandMaxs = [Float](repeating: -.infinity, count: nSpin * nBands)
        for s in 0..<nSpin {
            let base = s * perSpin
            guard base + perSpin <= bands.kPoints.count else { return [] }
            for kp in bands.kPoints[base..<base + perSpin] {
                for b in 0..<nBands {
                    let e = kp.energies[b]
                    guard e.isFinite else { continue }
                    let idx = s * nBands + b
                    if e < bandMins[idx] { bandMins[idx] = e }
                    if e > bandMaxs[idx] { bandMaxs[idx] = e }
                }
            }
        }

        let ef = bands.fermiEnergy
        var out: [BandSurfaceBandInfo] = []
        for s in 0..<nSpin {
            for b in 0..<nBands {
                let idx = s * nBands + b
                let mn = bandMins[idx]
                let mx = bandMaxs[idx]
                // Skip bands with non-finite min/max (all non-finite energies).
                guard mn.isFinite, mx.isFinite else { continue }

                var include: Bool
                if let ef = ef, windowEV > 0 {
                    let lo = ef - windowEV
                    let hi = ef + windowEV
                    include = mn <= hi && mx >= lo
                } else {
                    include = true
                }
                guard include else { continue }

                let spinLabel: String
                if nSpin > 1 { spinLabel = s == 0 ? " (spin up)" : " (spin down)" } else { spinLabel = "" }
                let info = BandSurfaceBandInfo(
                    spin: s, band: b,
                    label: "band \(b + 1)\(spinLabel)",
                    minEnergy: mn, maxEnergy: mx,
                    isOccupied: ef.map { mx <= $0 }
                )
                out.append(info)
                if out.count >= maxCandidates { return out }
            }
        }
        return out
    }

    /// Selection keys (spin*10_000+band) of the `count` bands closest to E_f:
    /// distance = 0 when the band crosses E_f, Ef - maxE when fully occupied,
    /// minE - Ef when fully unoccupied; sorted by (distance, spin, band).
    /// Without E_f the `count` lowest-energy bands. count clamped 1...64;
    /// returns [] when the mesh has no bands.
    static func closestBands(_ bands: BandStructure, count: Int) -> [Int] {
        guard bands.hasValidChannelLayout, bands.nBands > 0 else { return [] }
        let perSpin = bands.kPointsPerSpin
        let nBands = bands.nBands
        let nSpin = bands.nSpin
        guard perSpin > 0, nSpin > 0 else { return [] }

        // Per-(spin,band) min/max.
        var bandMins = [Float](repeating: .infinity, count: nSpin * nBands)
        var bandMaxs = [Float](repeating: -.infinity, count: nSpin * nBands)
        for s in 0..<nSpin {
            let base = s * perSpin
            guard base + perSpin <= bands.kPoints.count else { return [] }
            for kp in bands.kPoints[base..<base + perSpin] {
                for b in 0..<nBands {
                    let e = kp.energies[b]
                    guard e.isFinite else { continue }
                    let idx = s * nBands + b
                    if e < bandMins[idx] { bandMins[idx] = e }
                    if e > bandMaxs[idx] { bandMaxs[idx] = e }
                }
            }
        }

        let clampedCount = min(64, max(1, count))
        let ef = bands.fermiEnergy
        struct Cand { let key: Int; let dist: Float; let spin: Int; let band: Int }
        var cands: [Cand] = []
        for s in 0..<nSpin {
            for b in 0..<nBands {
                let idx = s * nBands + b
                let mn = bandMins[idx]
                let mx = bandMaxs[idx]
                // Non-finite energies -> distance +inf (sorted last).
                let dist: Float
                if !mn.isFinite || !mx.isFinite {
                    dist = .infinity
                } else if let ef = ef {
                    if mx <= ef {
                        dist = ef - mx       // fully occupied
                    } else if mn >= ef {
                        dist = mn - ef       // fully unoccupied
                    } else {
                        dist = 0             // crosses E_f
                    }
                } else {
                    dist = mn               // lowest-energy bands
                }
                cands.append(Cand(key: s * 10_000 + b, dist: dist, spin: s, band: b))
            }
        }
        cands.sort { $0.dist != $1.dist ? $0.dist < $1.dist
                  : ($0.spin != $1.spin ? $0.spin < $1.spin : $0.band < $1.band) }
        return cands.prefix(clampedCount).map { $0.key }
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
