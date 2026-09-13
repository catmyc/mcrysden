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
    /// Band-numbering offset of the source (0 for QE band arrays; nonzero for
    /// BXSF files whose bands start above 1). Displayed band numbers and
    /// selection keys include it.
    var bandOffset: Int = 0

    /// Renderability limits. Finite Float energies can still overflow a Float
    /// range subtraction (for example -3e38...3e38), which previously produced
    /// infinite scales and NaN AppKit geometry. Values above these limits are
    /// deemed malformed rather than passed through to the 3D view.
    static let maxRenderableEnergyMagnitude: Double = 1e12
    static let maxRenderableEnergySpan: Double = 1e12

    private enum CodingKeys: String, CodingKey {
        case region, regionLabels, gridSize, sheets, fermiEnergy, spinCount,
             energyMin, energyMax, kBasis, bandOffset
    }

    init(region: [SIMD3<Float>], regionLabels: [String], gridSize: Int,
         sheets: [BandSurfaceSheet], fermiEnergy: Float?, spinCount: Int,
         energyMin: Float, energyMax: Float, kBasis: [SIMD3<Float>?]? = nil,
         bandOffset: Int = 0) {
        self.region = region
        self.regionLabels = regionLabels
        self.gridSize = gridSize
        self.sheets = sheets
        self.fermiEnergy = fermiEnergy
        self.spinCount = spinCount
        self.energyMin = energyMin
        self.energyMax = energyMax
        self.kBasis = kBasis?.compactMap { $0 }
        self.bandOffset = bandOffset
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
        bandOffset = try c.decodeIfPresent(Int.self, forKey: .bandOffset) ?? 0

        // Low-level sanity so malformed persisted data can't trap the view.
        guard gridSize >= 2, gridSize <= 256 else {
            let ctx = DecodingError.Context(codingPath: c.codingPath,
                debugDescription: "gridSize \(gridSize) out of [2,256]")
            throw DecodingError.dataCorrupted(ctx)
        }
        guard region.count == 4, region.allSatisfy({
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
        }) else {
            let ctx = DecodingError.Context(codingPath: c.codingPath,
                debugDescription: "region must be exactly 4 finite SIMD3 corners")
            throw DecodingError.dataCorrupted(ctx)
        }
        guard regionLabels.count == 4 else {
            let ctx = DecodingError.Context(codingPath: c.codingPath,
                debugDescription: "regionLabels must have exactly 4 entries")
            throw DecodingError.dataCorrupted(ctx)
        }
        guard energyMin.isFinite, energyMax.isFinite, energyMin <= energyMax else {
            let ctx = DecodingError.Context(codingPath: c.codingPath,
                debugDescription: "energyMin/energyMax non-finite or inverted")
            throw DecodingError.dataCorrupted(ctx)
        }
        let energySpanD = Double(energyMax) - Double(energyMin)
        guard energySpanD.isFinite,
              energySpanD <= BandSurface.maxRenderableEnergySpan,
              abs(Double(energyMin)) <= BandSurface.maxRenderableEnergyMagnitude,
              abs(Double(energyMax)) <= BandSurface.maxRenderableEnergyMagnitude else {
            let ctx = DecodingError.Context(codingPath: c.codingPath,
                debugDescription: "energyMin/energyMax outside renderable bounds")
            throw DecodingError.dataCorrupted(ctx)
        }
        for sheet in sheets {
            guard sheet.values.count == gridSize * gridSize,
                  sheet.values.allSatisfy(\.isFinite) else {
                let ctx = DecodingError.Context(codingPath: c.codingPath,
                    debugDescription: "sheet '\(sheet.label)' values count/finiteness mismatch")
                throw DecodingError.dataCorrupted(ctx)
            }
        }
        if let kBasis = kBasis {
            guard kBasis.count == 3, kBasis.allSatisfy({
                $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
            }) else {
                let ctx = DecodingError.Context(codingPath: c.codingPath,
                    debugDescription: "kBasis must be exactly 3 finite SIMD3 vectors")
                throw DecodingError.dataCorrupted(ctx)
            }
        }
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
        try c.encode(bandOffset, forKey: .bandOffset)
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
    /// Offset added to the zero-based band index for sources whose band
    /// numbering does not start at 1 (e.g. BXSF files that begin at band 6).
    /// Selection keys, sheet bands, and labels all use the offset numbering.
    var bandOffset: Int

    init(energyWindowEV: Float = 1.0, maxBands: Int = 32, gridSize: Int = 56,
         bandCount: Int = 2, selectedBands: Set<Int>? = nil, bandOffset: Int = 0) {
        self.energyWindowEV = energyWindowEV
        self.maxBands = maxBands
        self.gridSize = gridSize
        self.bandCount = bandCount
        self.selectedBands = selectedBands
        self.bandOffset = bandOffset
    }
}

/// Errors thrown by band-surface construction.
enum BandSurfaceError: Error, Equatable, CustomStringConvertible {
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
            return "band surfaces are drawn on a 2D k-mesh (exactly two non-degenerate sampling axes, e.g. a slab calculation); this mesh is not a 2D k-grid"
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
    /// Band surfaces require a 2D k-MESH: exactly two non-degenerate sampling
    /// axes (the typical slab calculation). The gate is on the k-mesh sampling,
    /// NOT the physical dimensionality — QE slab outputs usually report 3D
    /// periodicity (`periodicDim == 3`) with a vacuum axis while sampling only
    /// two k directions, and those are accepted. Bulk 3D meshes throw
    /// `.requiresTwoDimensionalMesh` — a band surface of a 3D BZ would need an
    /// arbitrary slice plane, which is out of scope.
    ///
    /// The region is validated against the sampled plane: degenerate-axis
    /// components of both edge vectors must be integer (mod 1), and the
    /// 2D determinant on the two active mesh axes must be nonzero. This
    /// rejects patches that vary along a direction the mesh does not sample,
    /// or that project to a degenerate line in the sampling plane.
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
        // Accept a 3-label list or a 4-label list; an explicit fourth label is
        // preserved, otherwise the computed corner keeps "".
        guard regionLabels.count >= 3 else { throw BandSurfaceError.degenerateRegion }

        let d0 = p1 - p0
        let d1 = p2 - p0

        // Validate the region against the sampled 2D plane. The degenerate
        // axes (count <= 1) must stay fixed modulo a reciprocal-lattice
        // translation (their edge components must be integers), otherwise the
        // patch varies along a direction the mesh does not sample. The 2D
        // determinant on the two active mesh axes must be nonzero, so the patch
        // is a genuine parallelogram in the sampling plane, not a line.
        let active = (0..<3).filter { grid.dims[$0] > 1 }
        for d in 0..<3 where grid.dims[d] <= 1 {
            guard abs(d0[d] - d0[d].rounded()) < 1e-3,
                  abs(d1[d] - d1[d].rounded()) < 1e-3 else {
                throw BandSurfaceError.degenerateRegion
            }
        }
        let det = d0[active[0]] * d1[active[1]] - d0[active[1]] * d1[active[0]]
        guard abs(det) > 1e-4 else {
            throw BandSurfaceError.degenerateRegion
        }

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
        struct Sel { let spin: Int; let baseBand: Int; let displayBand: Int }
        var selected: [Sel]
        if let keys = options.selectedBands {
            // Explicit selection (possibly empty). Keep keys present in the set,
            // spin-major then band-minor, capped at maxBands.
            var out: [Sel] = []
            for s in 0..<nSpin {
                for b in 0..<nBands {
                    if keys.contains(s * 10_000 + b + options.bandOffset) {
                        out.append(Sel(spin: s, baseBand: b, displayBand: b + options.bandOffset))
                        if out.count >= options.maxBands { break }
                    }
                }
                if out.count >= options.maxBands { break }
            }
            selected = out
        } else {
            // fs.x convention: with a Fermi level, include every band whose
            // energy range intersects [Ef - window, Ef + window]. Without one
            // (an insulating output), select the manifolds adjacent to the
            // largest inter-band gap instead: the valence band(s) at the gap's
            // lower bound and the conduction band(s) at its upper bound. An
            // empty selection falls back to the bandCount bands closest to the
            // reference so pathological inputs still produce a useful plot.
            var keys: [Int] = []
            if let ef = bands.fermiEnergy, options.energyWindowEV > 0 {
                let lo = ef - options.energyWindowEV
                let hi = ef + options.energyWindowEV
                for s in 0..<nSpin {
                    for b in 0..<nBands {
                        let idx = s * nBands + b
                        guard bandMins[idx].isFinite, bandMaxs[idx].isFinite else { continue }
                        if bandMins[idx] <= hi && bandMaxs[idx] >= lo {
                            keys.append(s * 10_000 + b + options.bandOffset)
                        }
                    }
                }
            } else if let gap = largestGapBounds(bands) {
                for s in 0..<nSpin {
                    for b in 0..<nBands {
                        let idx = s * nBands + b
                        guard bandMins[idx].isFinite, bandMaxs[idx].isFinite else { continue }
                        let atVBM = abs(bandMaxs[idx] - gap.lower) < 1e-3
                        let atCBM = abs(bandMins[idx] - gap.upper) < 1e-3
                        if atVBM || atCBM {
                            keys.append(s * 10_000 + b + options.bandOffset)
                        }
                    }
                }
            }
            if keys.isEmpty {
                // Legacy bandCount-closest fallback; clamped 1...maxBands.
                let count = min(options.maxBands, max(1, options.bandCount))
                keys = closestBands(bands, count: count, bandOffset: options.bandOffset)
            } else if keys.count > options.maxBands {
                keys = Array(keys.prefix(options.maxBands))
            }
            guard !keys.isEmpty else { throw BandSurfaceError.noBandsNearFermi }
            // Window keys are already spin-major/band-minor; closest-band keys
            // are re-sorted by (spin, band) for a stable sheet order.
            selected = keys.compactMap { key in
                let s = key / 10_000
                let b = key % 10_000 - options.bandOffset
                guard s >= 0, s < nSpin, b >= 0, b < nBands else { return nil }
                return Sel(spin: s, baseBand: b, displayBand: b + options.bandOffset)
            }.sorted { $0.spin != $1.spin ? $0.spin < $1.spin : $0.baseBand < $1.baseBand }
        }

        // Adaptive sampling density: keep the triangle count interactive when
        // the window selects many sheets, while preserving the requested
        // resolution for 1-2 sheets.
        let maxGridByTriangles = Int(floor(sqrt(160_000 / Float(2 * max(1, selected.count))))) - 1
        let gridSize = min(options.gridSize, max(16, maxGridByTriangles))

        // Sample each selected sheet over (s,t) in [0,1]^2.
        var sheets: [BandSurfaceSheet] = []
        var sampleMin = Float.infinity
        var sampleMax = -Float.infinity
        for sel in selected {
            let base = sel.spin * perSpin
            let channel = Array(bands.kPoints[base..<base + perSpin])
            let values = channel.map { $0.energies[sel.baseBand] }
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
            sheets.append(BandSurfaceSheet(band: sel.displayBand, spin: sel.spin,
                                           label: "band \(sel.displayBand + 1)\(spinLabel)",
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
        let energySpanD = Double(energyMax) - Double(energyMin)
        guard energyMin.isFinite, energyMax.isFinite, energyMin <= energyMax,
              energySpanD.isFinite,
              energySpanD <= BandSurface.maxRenderableEnergySpan,
              abs(Double(energyMin)) <= BandSurface.maxRenderableEnergyMagnitude,
              abs(Double(energyMax)) <= BandSurface.maxRenderableEnergyMagnitude else {
            throw BandSurfaceError.malformedBandStructure
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
        // Preserve an explicit fourth label when the caller supplied a full
        // 4-entry list (e.g. the hexagonal full-cell presentation region);
        // legacy 3-entry callers keep the computed-corner "" label.
        let fourthLabel = regionLabels.count >= 4 ? regionLabels[3] : ""
        return BandSurface(
            region: [p0, p1, p2, p3],
            regionLabels: [regionLabels[0], regionLabels[1], regionLabels[2], fourthLabel],
            gridSize: gridSize,
            sheets: sheets,
            fermiEnergy: bands.fermiEnergy,
            spinCount: nSpin,
            energyMin: energyMin,
            energyMax: energyMax,
            kBasis: kBasis,
            bandOffset: options.bandOffset
        )
    }

    /// Candidate bands for the UI band picker: every (spin, band) whose
    /// [minEnergy, maxEnergy] intersects [Ef-windowEV, Ef+windowEV] when E_f
    /// exists (windowEV > 0, default 4.0), ordered spin-major then band-minor,
    /// capped at maxCandidates (default 32). Without E_f, the first
    /// maxCandidates bands. Uses the SAME per-channel min/max pass as build().
    static func bandInfos(_ bands: BandStructure, windowEV: Float = 1.0,
                          maxCandidates: Int = 32, bandOffset: Int = 0) -> [BandSurfaceBandInfo] {
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
                    spin: s, band: b + bandOffset,
                    label: "band \(b + 1 + bandOffset)\(spinLabel)",
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
    static func closestBands(_ bands: BandStructure, count: Int, bandOffset: Int = 0) -> [Int] {
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
                cands.append(Cand(key: s * 10_000 + b + bandOffset, dist: dist, spin: s, band: b))
            }
        }
        cands.sort { $0.dist != $1.dist ? $0.dist < $1.dist
                  : ($0.spin != $1.spin ? $0.spin < $1.spin : $0.band < $1.band) }
        return cands.prefix(clampedCount).map { $0.key }
    }

    /// Bounds of the largest gap between consecutive band MAX energies. For an
    /// insulator this is the valence/conduction boundary: `lower` is the VBM
    /// manifold maximum and `upper` the CBM manifold minimum.
    static func largestGapBounds(_ bands: BandStructure) -> (lower: Float, upper: Float)? {
        guard bands.hasValidChannelLayout, bands.nBands > 0 else { return nil }
        let perSpin = bands.kPointsPerSpin
        let nBands = bands.nBands
        let nSpin = bands.nSpin
        guard perSpin > 0, nSpin > 0 else { return nil }

        // Per-(spin,band) extrema, ordered by band maximum.
        var extents: [(min: Float, max: Float)] = []
        for s in 0..<nSpin {
            let base = s * perSpin
            guard base + perSpin <= bands.kPoints.count else { return nil }
            for b in 0..<nBands {
                var mn = Float.infinity
                var mx = -Float.infinity
                for kp in bands.kPoints[base..<base + perSpin] where kp.energies[b].isFinite {
                    mn = min(mn, kp.energies[b])
                    mx = max(mx, kp.energies[b])
                }
                if mn.isFinite, mx.isFinite { extents.append((min: mn, max: mx)) }
            }
        }
        guard extents.count >= 2 else { return nil }
        let sorted = extents.sorted { $0.max < $1.max }
        // The gap between consecutive band-maxima uses the NEXT band's MINIMUM
        // as the conduction bound; overlapping manifolds produce non-positive
        // gaps and are skipped (a metal has no positive inter-band gap).
        var best: (lower: Float, upper: Float)? = nil
        var bestGap = -Float.infinity
        for i in 0..<(sorted.count - 1) {
            let gap = sorted[i + 1].min - sorted[i].max
            if gap.isFinite, gap > 0, gap > bestGap {
                bestGap = gap
                best = (lower: sorted[i].max, upper: sorted[i + 1].min)
            }
        }
        return best
    }

    /// Midpoint of `largestGapBounds` (kept as a convenience for callers that
    /// only need an energy reference).
    static func largestGapReference(_ bands: BandStructure) -> Float? {
        guard let gap = largestGapBounds(bands) else { return nil }
        return (gap.lower + gap.upper) / 2
    }

    /// Derive a band-surface region spanning exactly one reciprocal primitive
    /// cell from a 2D mesh grid. The two non-degenerate axes define the cell;
    /// the degenerate axis is carried verbatim. Returns 3 parallelogram corners
    /// (p0, p0+b₁, p0+b₂) and 4 labels (the 4th corner label is "").
    ///
    /// p0 is the mesh minimum corner ((nodes[0][0], nodes[1][0], nodes[2][0]));
    /// the edge vectors are full reciprocal-lattice steps (+1.0 along each
    /// active axis). All corners are equivalent modulo 1 in the degenerate
    /// direction, so the patch samples exactly one reciprocal primitive cell of
    /// the 2D mesh. Labels describe the origin and the two active reciprocal
    /// basis directions (b₁, b₂) — NOT high-symmetry points, since the mesh
    /// origin need not be Γ.
    ///
    /// Throws `.requiresTwoDimensionalMesh` when the grid is not 2D (not
    /// exactly two non-degenerate sampling axes).
    static func meshRegion(grid: BandMeshGrid) throws -> (region: [SIMD3<Float>], labels: [String]) {
        let active = (0..<3).filter { grid.dims[$0] > 1 }
        guard active.count == 2 else { throw BandSurfaceError.requiresTwoDimensionalMesh }
        let a0 = active[0]
        let a1 = active[1]
        let p0 = SIMD3<Float>(grid.nodes[0][0], grid.nodes[1][0], grid.nodes[2][0])
        func unit(_ i: Int) -> SIMD3<Float> {
            var v = SIMD3<Float>.zero
            v[i] = 1
            return v
        }
        let labels = ["origin", "origin+b₁", "origin+b₂", ""]
        return (region: [p0, p0 + unit(a0), p0 + unit(a1)], labels: labels)
    }

    /// Convenience: derive the mesh region directly from a band structure by
    /// first detecting its mesh grid. Propagates mesh-detection errors.
    static func meshRegion(
        from bands: BandStructure
    ) throws -> (region: [SIMD3<Float>], labels: [String]) {
        let grid = try BandMeshInterpolator.meshGrid(from: bands)
        return try meshRegion(grid: grid)
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
