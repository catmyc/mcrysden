import Foundation
import simd

/// Molecular (solvent-accessible style) surface — the union of atomic surfaces
/// inflated by a probe radius (van der Waals + probe, a water-sized probe by
/// default). Produces a closed triangle mesh for the renderer.
///
/// Contract (fixed):
///  - `mesh(atoms:probeRadius:overrides:)` returns nil when disabled, empty, or
///    over the atom cap; the result is cached by the controller against the
///    settings + atom set.
///  - Bounded: capped at 8 192 input atoms and ≤ 65 527 output vertices (the
///    vertex buffer is indexed by UInt16, so the budget is capped at
///    UInt16.max − 8). Fails non-fatally (nil) beyond the caps.
///  - The mesh is closed (watertight) up to float tolerance; normals face
///    outward.
enum MolecularSurface {
    static let maxAtoms = 8_192
    /// Soft vertex budget before coarsening; the hard limit is UInt16.max − 8
    /// because `Mesh.indices` is [UInt16].
    static let maxVertices = 524_288
    /// Hard vertex ceiling imposed by the UInt16 index buffer.
    static let vertexIndexCap = Int(UInt16.max) - 8
    /// Field-evaluation work budget (grid points × atoms). Coarsening keeps the
    /// build bounded; beyond it the call fails non-fatally (nil).
    private static let workBudget = 300_000_000
    private static let minGridCells = 2

    /// Build the probe-inflated union surface mesh in world coordinates. Per-element
    /// van der Waals overrides (from `scene.elementOverrides`) are applied when
    /// present; an empty `overrides` dictionary preserves the default CPK radii.
    static func mesh(atoms: [Atom], probeRadius: Float,
                     overrides: [Int: ElementOverride] = [:]) -> Mesh? {
        guard !atoms.isEmpty, atoms.count <= maxAtoms else { return nil }
        let probe = max(0, probeRadius)
        let radii = atoms.map { AtomSchemeMetrics.elementVdwRadius(z: $0.atomicNumber, overrides: overrides) + probe }
        guard radii.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }

        // Bounding box of the inflated spheres, padded by one cell on each side.
        var lo = SIMD3<Float>(repeating: Float.infinity)
        var hi = SIMD3<Float>(repeating: -Float.infinity)
        for i in atoms.indices {
            let c = atoms[i].coord
            guard c.x.isFinite, c.y.isFinite, c.z.isFinite else { return nil }
            let r = radii[i]
            lo = min(lo, c - SIMD3(repeating: r))
            hi = max(hi, c + SIMD3(repeating: r))
        }
        guard lo.x < hi.x, lo.y < hi.y, lo.z < hi.z else { return nil }

        let extent = hi - lo
        let longest = max(extent.x, extent.y, extent.z)
        guard longest.isFinite, longest > 0 else { return nil }

        // Choose a spacing that keeps the longest axis near 64 cells (within the
        // 64³→128³ bounded range) while honouring the work budget; coarsen if
        // needed, and fail non-fatally if even a coarse grid is too expensive.
        var spacing = longest / 64.0
        var nx = 0, ny = 0, nz = 0
        var gridPoints = 0
        for _ in 0..<5 {
            let cellsX = max(minGridCells, Int((extent.x / spacing).rounded()))
            let cellsY = max(minGridCells, Int((extent.y / spacing).rounded()))
            let cellsZ = max(minGridCells, Int((extent.z / spacing).rounded()))
            nx = cellsX + 1; ny = cellsY + 1; nz = cellsZ + 1
            gridPoints = nx * ny * nz
            if gridPoints * atoms.count <= workBudget { break }
            spacing *= 1.5
        }
        guard gridPoints * atoms.count <= workBudget else { return nil }
        guard nx >= 2, ny >= 2, nz >= 2 else { return nil }

        let origin = lo - SIMD3(repeating: spacing)
        let dx = spacing, dy = spacing, dz = spacing
        let index: (Int, Int, Int) -> Int = { ix, iy, iz in ix + nx * (iy + ny * iz) }

        // Scalar field: distance to the nearest inflated-sphere surface.
        // f < 0 inside the union, f > 0 outside; the f = 0 isosurface is the
        // solvent-accessible boundary.
        var field = [Float](repeating: 0, count: gridPoints)
        for iz in 0..<nz {
            let wz = origin.z + Float(iz) * dz
            for iy in 0..<ny {
                let wy = origin.y + Float(iy) * dy
                for ix in 0..<nx {
                    let p = SIMD3<Float>(origin.x + Float(ix) * dx, wy, wz)
                    var best = Float.infinity
                    for k in atoms.indices {
                        let d = length(p - atoms[k].coord) - radii[k]
                        if d < best { best = d }
                    }
                    field[index(ix, iy, iz)] = best
                }
            }
        }

        // Per-vertex field gradient (world space) for outward-facing normals.
        var grad = [SIMD3<Float>](repeating: .zero, count: gridPoints)
        for iz in 0..<nz {
            let izLo = max(0, iz - 1), izHi = min(nz - 1, iz + 1)
            for iy in 0..<ny {
                let iyLo = max(0, iy - 1), iyHi = min(ny - 1, iy + 1)
                for ix in 0..<nx {
                    let ixLo = max(0, ix - 1), ixHi = min(nx - 1, ix + 1)
                    let gx = (field[index(ixHi, iy, iz)] - field[index(ixLo, iy, iz)]) / (Float(ixHi - ixLo) * dx)
                    let gy = (field[index(ix, iyHi, iz)] - field[index(ix, iyLo, iz)]) / (Float(iyHi - iyLo) * dy)
                    let gz = (field[index(ix, iy, izHi)] - field[index(ix, iy, izLo)]) / (Float(izHi - izLo) * dz)
                    grad[index(ix, iy, iz)] = SIMD3<Float>(gx, gy, gz)
                }
            }
        }

        return march(field: field, grad: grad, nx: nx, ny: ny, nz: nz,
                      origin: origin, dx: dx, dy: dy, dz: dz, index: index)
    }

    /// Single sphere inflated by the probe (for debugging/tests).
    static func inflatedSphereMesh(center: SIMD3<Float>, radius: Float, lat: Int, lon: Int) -> Mesh? {
        guard lat >= 4, lon >= 6, radius > 0 else { return nil }
        let unit = Geometry.unitSphere(latSegments: lat, lonSegments: lon)
        let positions = unit.positions.map { $0 * radius + center }
        return Mesh(positions: positions, normals: unit.normals, indices: unit.indices)
    }
}

// MARK: - Marching cubes

/// Standard cube-corner layout (matches MarchingCubesTables.swift).
private let mcCornerOffset: [(Int, Int, Int)] = [
    (0, 0, 0), (0, 1, 0), (1, 1, 0), (1, 0, 0),
    (0, 0, 1), (0, 1, 1), (1, 1, 1), (1, 0, 1),
]
/// Edge endpoint indices into `mcCornerOffset` (12 edges).
private let mcEdgeEnds: [(Int, Int)] = [
    (0, 1), (1, 2), (2, 3), (3, 0),
    (4, 5), (5, 6), (6, 7), (7, 4),
    (0, 4), (1, 5), (2, 6), (3, 7),
]

/// Run marching cubes over the scalar field and emit a closed, outward-normaled
/// triangle mesh. Returns nil if the output would exceed `maxVertices`.
private func march(field: [Float], grad: [SIMD3<Float>], nx: Int, ny: Int, nz: Int,
                   origin: SIMD3<Float>, dx: Float, dy: Float, dz: Float,
                   index: (Int, Int, Int) -> Int) -> Mesh? {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt16] = []
    positions.reserveCapacity(65536)
    normals.reserveCapacity(65536)

    var vertCache = [SIMD3<Float>?](repeating: nil, count: 12)
    var gradCache = [SIMD3<Float>?](repeating: nil, count: 12)

    let world: (Int, Int, Int) -> SIMD3<Float> = { ix, iy, iz in
        origin + SIMD3(Float(ix) * dx, Float(iy) * dy, Float(iz) * dz)
    }

    for iz in 0..<(nz - 1) {
        for iy in 0..<(ny - 1) {
            for ix in 0..<(nx - 1) {
                var cube = [Float](repeating: 0, count: 8)
                for c in 0..<8 {
                    let (cx, cy, cz) = mcCornerOffset[c]
                    cube[c] = field[index(ix + cx, iy + cy, iz + cz)]
                }
                // Corner is "inside" the union when the field is negative.
                var cubeindex = 0
                for c in 0..<8 where cube[c] < 0 { cubeindex |= (1 << c) }

                let edges = marchingCubeEdgeTable[cubeindex]
                if edges == 0 { continue }

                for e in 0..<12 where edges & (1 << e) != 0 {
                    if vertCache[e] == nil {
                        let (a, b) = mcEdgeEnds[e]
                        let (ax, ay, az) = mcCornerOffset[a]
                        let (bx, by, bz) = mcCornerOffset[b]
                        let va = cube[a], vb = cube[b]
                        let denom = vb - va
                        let t = abs(denom) > 1e-9 ? (0 - va) / denom : 0.5
                        let gx = Float(ax) + t * Float(bx - ax)
                        let gy = Float(ay) + t * Float(by - ay)
                        let gz = Float(az) + t * Float(bz - az)
                        vertCache[e] = world(ix, iy, iz) + SIMD3(gx * dx, gy * dy, gz * dz)
                        let ga = grad[index(ix + ax, iy + ay, iz + az)]
                        let gb = grad[index(ix + bx, iy + by, iz + bz)]
                        gradCache[e] = ga + (gb - ga) * t
                    }
                }

                let tri = marchingCubeTriTable[cubeindex]
                var ti = 0
                while ti < 15 && tri[ti] >= 0 {
                    let e0 = Int(tri[ti]), e1 = Int(tri[ti + 1]), e2 = Int(tri[ti + 2])
                    guard let p0 = vertCache[e0], let p1 = vertCache[e1], let p2 = vertCache[e2],
                          let g0 = gradCache[e0], let g1 = gradCache[e1], let g2 = gradCache[e2] else { return nil }
                    if positions.count + 3 > MolecularSurface.vertexIndexCap { return nil }
                    let base = UInt16(positions.count)
                    positions.append(p0); positions.append(p1); positions.append(p2)
                    normals.append(normalizeOrUp(g0))
                    normals.append(normalizeOrUp(g1))
                    normals.append(normalizeOrUp(g2))
                    indices.append(base); indices.append(base + 1); indices.append(base + 2)
                    ti += 3
                }

                for e in 0..<12 { vertCache[e] = nil; gradCache[e] = nil }
            }
        }
    }

    guard !positions.isEmpty else { return nil }
    return Mesh(positions: positions, normals: normals, indices: indices)
}

/// Outward-facing normal from the field gradient (the field rises outward).
/// Falls back to +Z when the gradient is degenerate.
private func normalizeOrUp(_ g: SIMD3<Float>) -> SIMD3<Float> {
    let len = length(g)
    return len > 1e-6 ? g / len : SIMD3<Float>(0, 0, 1)
}
