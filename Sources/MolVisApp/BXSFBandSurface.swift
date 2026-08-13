import Foundation
import simd

// Band-surface construction from a Band-XCRYSDEN-Structure-File (.bxsf).
//
// `fs.x` writes every band as a full Brillouin-zone grid (one ScalarField per
// band). For 2D-slab grids exactly two span vectors are in-plane and the third
// is the (typically single-node) vacuum direction, so the per-band grids can
// be sliced into a 3D band-surface plot: k1/k2 in the slab plane, energy
// vertical, one sheet per band.
//
// The grid nodes are placed at fractional coordinates 0...1 along the two
// in-plane axes (the span vectors cover the full extent), matching the
// existing BandMeshInterpolator periodic convention where the closing cell
// maps frac = 1 back to frac = 0.

/// Convert a parsed BXSF FermiSurface into a band-surface plot.
enum BXSFBandSurface {

    /// Build a BandSurface from a BXSF FermiSurface. The two in-plane axes
    /// are the two grid axes with the largest span vectors; the remaining
    /// (vacuum) axis must have a single node. A 3D BXSF grid is rejected
    /// because a band surface requires a 2D k-mesh.
    static func build(
        from fs: FermiSurface,
        cell: Cell? = nil,
        options: BandSurfaceOptions = BandSurfaceOptions()
    ) throws -> BandSurface {
        var options = options
        // Preserve the BXSF band numbering (e.g. bands 6..8) in sheet labels
        // and selection keys instead of renumbering them from zero.
        options.bandOffset = fs.bandIndices.first ?? 0
        guard let first = fs.bands.first else {
            throw BandSurfaceError.malformedBandStructure
        }
        // All bands share the grid metadata; require it to be consistent.
        for band in fs.bands {
            guard band.nx == first.nx, band.ny == first.ny, band.nz == first.nz,
                  band.values.count == first.values.count else {
                throw BandSurfaceError.malformedBandStructure
            }
        }

        let counts = [first.nx, first.ny, first.nz]
        let spans = first.vec
        guard spans.count == 3 else { throw BandSurfaceError.malformedBandStructure }

        // Fractional sample positions use the DATAGRID convention
        // k_cart = origin + sum_a vec[a] * i_a/(n_a-1), converted to fractional
        // coordinates through the span matrix B (rows = vec). fs.x writes the
        // reciprocal basis as the spans, so B is non-singular for real files.
        let bRows = spans
        let bMatrix = simd_float3x3(rows: bRows)
        let bDet = bMatrix.determinant
        guard bDet.isFinite, abs(bDet) > 1e-12 else {
            throw BandSurfaceError.malformedBandStructure
        }
        let bInverse = bMatrix.inverse
        func fractionalPosition(_ indices: [Int]) -> SIMD3<Float> {
            var cart = first.origin
            for a in 0..<3 {
                let denom = Float(max(1, counts[a] - 1))
                cart += spans[a] * (Float(indices[a]) / denom)
            }
            let frac = bInverse * cart
            func wrap(_ x: Float) -> Float {
                var c = x - floor(x)
                if 1 - c < 1e-4 { c = 0 }
                return c
            }
            return SIMD3<Float>(wrap(frac.x), wrap(frac.y), wrap(frac.z))
        }

        // A 2D slab grid has exactly one degenerate axis. fs.x writes the
        // periodic endpoint twice on that axis (nz = nk3+1 = 2), so accept a
        // count of 1 or 2, and for 2 require the two samples to coincide
        // modulo a reciprocal-lattice vector. All three axes with >= 3 samples
        // is a 3D band grid, which a band surface cannot show.
        var vacuum: Int? = nil
        for a in 0..<3 {
            if counts[a] <= 2 {
                if vacuum != nil { throw BandSurfaceError.requiresTwoDimensionalMesh }
                if counts[a] == 2 {
                    var i0 = [0, 0, 0]
                    var i1 = [0, 0, 0]
                    i0[a] = 0
                    i1[a] = 1
                    let d = fractionalPosition(i1) - fractionalPosition(i0)
                    let equivalence = d - SIMD3<Float>(d.x.rounded(), d.y.rounded(), d.z.rounded())
                    guard max(abs(equivalence.x), abs(equivalence.y), abs(equivalence.z)) < 1e-3 else {
                        throw BandSurfaceError.requiresTwoDimensionalMesh
                    }
                    // The two samples are the SAME plane, so fs.x stores the
                    // same eigenvalues on both; differing slices mean the grid
                    // is genuinely 3D along this axis.
                    let inPlaneAxes = (0..<3).filter { $0 != a }
                    for band in fs.bands {
                        for iy in 0..<counts[inPlaneAxes[1]] {
                            for ix in 0..<counts[inPlaneAxes[0]] {
                                var idx0 = [0, 0, 0]
                                var idx1 = [0, 0, 0]
                                idx0[inPlaneAxes[0]] = ix
                                idx0[inPlaneAxes[1]] = iy
                                idx1 = idx0
                                idx1[a] = 1
                                let v0 = band.value(idx0[0], idx0[1], idx0[2])
                                let v1 = band.value(idx1[0], idx1[1], idx1[2])
                                guard abs(v0 - v1) <= 1e-3 * max(1, abs(v0)) else {
                                    throw BandSurfaceError.requiresTwoDimensionalMesh
                                }
                            }
                        }
                    }
                }
                vacuum = a
            }
        }
        guard let vacuum else { throw BandSurfaceError.requiresTwoDimensionalMesh }
        let inPlane = (0..<3).filter { $0 != vacuum }
        // The BXSF grid stores BOTH endpoints of each periodic span, so node
        // nx-1 at frac = 1 duplicates node 0 at frac = 0. Use one fewer unique
        // node per in-plane axis: nodes land at 0, 1/(n-1), ..., (n-2)/(n-1),
        // a complete periodic mesh with dims (nx-1, ny-1, 1).
        let nA = counts[inPlane[0]] - 1
        let nB = counts[inPlane[1]] - 1
        guard nA > 1, nB > 1, nA <= 256, nB <= 256 else {
            throw BandSurfaceError.malformedBandStructure
        }
        let perSpin = nA * nB

        // Build the shared k-point mesh in fractional coordinates. The two
        // in-plane axes span the full Brillouin zone; the vacuum axis stays at
        // its single (degenerate) plane from the actual origin/span values.
        var kPoints: [BandKPoint] = []
        kPoints.reserveCapacity(perSpin)
        for iB in 0..<nB {
            for iA in 0..<nA {
                var indices = [0, 0, 0]
                indices[inPlane[0]] = iA
                indices[inPlane[1]] = iB
                indices[vacuum] = 0
                let frac = fractionalPosition(indices)
                kPoints.append(BandKPoint(k: frac, weight: 0, label: "", energies: []))
            }
        }

        // One energy per BXSF band at each k-point. ScalarField.value uses
        // x-fastest flat indexing (ix + nx*(iy + ny*iz)).
        for band in fs.bands {
            for iB in 0..<nB {
                for iA in 0..<nA {
                    var ijk = [0, 0, 0]
                    ijk[inPlane[0]] = iA
                    ijk[inPlane[1]] = iB
                    ijk[vacuum] = 0
                    let e = band.value(ijk[0], ijk[1], ijk[2])
                    guard e.isFinite else { throw BandSurfaceError.malformedBandStructure }
                    kPoints[iB * nA + iA].energies.append(e)
                }
            }
        }

        let bands = BandStructure(
            kPoints: kPoints,
            fermiEnergy: fs.fermiEnergy,
            nSpin: 1,
            kPointsAreCrystal: true,
            kPointsPerSpin: perSpin,
            isMesh: true,
            cell: cell,
            periodicDim: 2,
            // The grid is complete, so no unfolding ever runs; do not claim a
            // symmetry the file did not establish.
            timeReversalSymmetric: false
        )

        // Presentation region: metric-aware quadrant for square/rectangular
        // cells, full cell for hexagonal cells, and the full reciprocal
        // primitive cell when no cell (or an unclassifiable one) is available.
        let fullRegion: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
        ]
        let fullLabels = ["Γ", "Γ+b₁", "Γ+b₂", "Γ+b₁+b₂"]
        let region: [SIMD3<Float>]
        let labels: [String]
        if let cell, let presentation = BandSurfaceRegion.presentationRegion(for: cell) {
            region = presentation.region
            labels = presentation.labels
        } else {
            region = fullRegion
            labels = fullLabels
        }

        // BandSurfaceBuilder preserves an explicit fourth label, so pass the
        // full 4-entry list (square/rectangular M, hexagonal M', generic
        // Gamma+b1+b2).
        return try BandSurfaceBuilder.build(
            bands: bands,
            region: region,
            regionLabels: labels,
            options: options
        )
    }
}
