import Foundation
import simd

/// H-bond detection (XCrySDen parity): a donor atom (N, O, F) with a bound
/// hydrogen and an acceptor atom (N, O, F) where the H…A distance is below
/// `settings.maxDistance` and the D−H…A angle is at least `minAngleDegrees`.
/// Periodic images are considered for crystalline scenes.
///
/// Accepted simplifications (no behavior change):
///  - A hydrogen shared between two donors is attributed to both, so a single H
///    may appear in more than one HbondPair (double attribution).
///  - For crystals only the nearest periodic image of each acceptor is accepted;
///    farther images that also satisfy the criteria are not reported.
///
/// Contract (fixed):
///  - Detection is bounded: scenes above `maxBondedAtoms` return [] (fail-fast
///    non-fatal, matching supercell caps) and never trap.
///  - Donor/acceptor elements: N, O, F. A hydrogen is considered "bound to the
///    donor" when donor–H distance < covalent(donor)+covalent(H)+0.4 Å.
///  - The returned array is deterministic (sorted by donor, then acceptor,
///    then hydrogen) and never contains a self-bond (acceptor != donor).
enum HbondAnalysis {
    static let maxBondedAtoms = 20_000
    static let donorAcceptorZ: Set<Int> = [7, 8, 9]

    /// Maximum donor–H distance cutoff across N, O, F: the longest of
    /// covalentRadius(Z)+covalentRadius(H)+0.4. Used as the spatial-grid cell
    /// size so every candidate within any cutoff lies in a neighboring bucket.
    static let maxDonorHCutoff: Float = {
        let rH = ElementTable.covalentRadius(1)
        guard rH.isFinite, rH > 0 else { return 1.42 }
        var maxCut: Float = 0
        for z in donorAcceptorZ {
            let rD = ElementTable.covalentRadius(z)
            if rD.isFinite, rD > 0 { maxCut = max(maxCut, rD + rH + 0.4) }
        }
        return maxCut > 0 ? maxCut : 1.42
    }()

    /// Detect H bonds in the given scene's displayed atoms. Acceptors may be a
    /// periodic image of a displayed atom; the stored acceptor index is the
    /// displayed atom's index (the image used is the one nearest the hydrogen).
    static func detect(scene: Scene) -> [HbondPair] {
        guard scene.hbondSettings.enabled else { return [] }
        guard scene.atoms.count <= maxBondedAtoms else { return [] }
        let settings = scene.hbondSettings
        let cell = scene.cell
        let periodicDim = scene.periodicDim

        var donors: [Int] = []
        var acceptors: [Int] = []
        for i in scene.atoms.indices {
            if HbondAnalysis.donorAcceptorZ.contains(scene.atoms[i].atomicNumber) {
                donors.append(i)
                acceptors.append(i)
            }
        }

        let cutoff = max(settings.maxDistance, maxDonorHCutoff)
        let grid = SpatialGrid(atoms: scene.atoms, cellSize: cutoff, cell: cell, periodicDim: periodicDim)

        var raw: [(donor: Int, hydrogen: Int, acceptor: Int, acceptorImage: SIMD3<Float>?)] = []
        raw.reserveCapacity(donors.count)
        for d in donors {
            let dCoord = scene.atoms[d].coord
            let bondedH = bondedHydrogens(scene: scene, donorIndex: d, grid: grid)
            for h in bondedH {
                let hCoord = scene.atoms[h].coord
                let nearby = grid?.indicesNear(hCoord) ?? acceptors
                for a in nearby {
                    guard a != d else { continue }
                    guard HbondAnalysis.donorAcceptorZ.contains(scene.atoms[a].atomicNumber) else { continue }
                    let aBase = scene.atoms[a].coord
                    let aWorld: SIMD3<Float>
                    let aImage: SIMD3<Float>?
                    if let cell = cell {
                        guard let disp = PeriodicGeometry.minimumImageDisplacement(from: hCoord, to: aBase,
                                                                                   cell: cell, periodicDim: periodicDim) else { continue }
                        aWorld = hCoord + disp
                        aImage = aWorld
                    } else {
                        aWorld = aBase
                        aImage = nil
                    }
                    let dHA = length(aWorld - hCoord)
                    guard dHA < settings.maxDistance else { continue }
                    let vHD = dCoord - hCoord
                    let vHA = aWorld - hCoord
                    let l1 = length(vHD)
                    let l2 = length(vHA)
                    guard l1 > 1e-5, l2 > 1e-5 else { continue }
                    let cosA = simd_dot(vHD, vHA) / (l1 * l2)
                    let angle = acos(simd_clamp(cosA, -1, 1)) * (180.0 / .pi)
                    if angle >= settings.minAngleDegrees {
                        raw.append((d, h, a, aImage))
                    }
                }
            }
        }

        raw.sort { lhs, rhs in
            if lhs.donor != rhs.donor { return lhs.donor < rhs.donor }
            if lhs.acceptor != rhs.acceptor { return lhs.acceptor < rhs.acceptor }
            return lhs.hydrogen < rhs.hydrogen
        }
        let stride = maxBondedAtoms + 1
        var seen = Set<Int>()
        var out: [HbondPair] = []
        out.reserveCapacity(raw.count)
        for t in raw {
            let key = t.donor * stride * stride + t.acceptor * stride + t.hydrogen
            if seen.insert(key).inserted {
                out.append(HbondPair(donor: t.donor, hydrogen: t.hydrogen, acceptor: t.acceptor,
                                     acceptorImage: t.acceptorImage))
            }
        }
        return out
    }

    /// Hydrogen atoms bonded to atom `donorIndex` by the covalent-distance rule.
    /// For crystals the nearest periodic image of each candidate hydrogen is used.
    fileprivate static func bondedHydrogens(scene: Scene, donorIndex: Int, grid: SpatialGrid? = nil) -> [Int] {
        guard scene.atoms.count <= maxBondedAtoms else { return [] }
        guard scene.atoms.indices.contains(donorIndex) else { return [] }
        let donor = scene.atoms[donorIndex]
        guard HbondAnalysis.donorAcceptorZ.contains(donor.atomicNumber) else { return [] }
        let rD = ElementTable.covalentRadius(donor.atomicNumber)
        let rH = ElementTable.covalentRadius(1)
        guard rD.isFinite, rH.isFinite, rD > 0, rH > 0 else { return [] }
        let cutoff = rD + rH + 0.4
        let cell = scene.cell
        let periodicDim = scene.periodicDim
        var result: [Int] = []

        let candidates: [Int]
        if let grid = grid {
            candidates = grid.indicesNear(donor.coord)
        } else {
            candidates = Array(scene.atoms.indices)
        }

        for i in candidates {
            let a = scene.atoms[i]
            guard a.atomicNumber == 1 else { continue }
            let dist: Float
            if let cell = cell {
                guard let disp = PeriodicGeometry.minimumImageDisplacement(from: donor.coord, to: a.coord,
                                                                           cell: cell, periodicDim: periodicDim) else { continue }
                dist = length(disp)
            } else {
                dist = length(donor.coord - a.coord)
            }
            if dist < cutoff { result.append(i) }
        }
        return result.sorted()
    }
}

// MARK: - Spatial acceleration grid

/// A uniform spatial grid for accelerating nearest-neighbor lookups. Buckets
/// atom indices into cells of size >= `cutoff`, so any atom within `cutoff` of
/// a query point lies in the same or one of the 27 neighboring cells. Returns
/// nil from init when the bucket count would exceed `maxBuckets` (caller falls
/// back to brute force).
fileprivate struct SpatialGrid {
    private let cellSize: Float
    private let invCellSize: Float
    private let dims: SIMD3<Int>
    private let buckets: [[Int]]
    private let fractional: Bool
    private let invCell: simd_double3x3?
    private let origin: SIMD3<Float>
    private let wrapX: Bool
    private let wrapY: Bool
    private let wrapZ: Bool

    init?(atoms: [Atom], cellSize: Float, cell: Cell?, periodicDim: Int, maxBuckets: Int = 4_000_000) {
        guard cellSize > 0, !atoms.isEmpty else { return nil }
        self.cellSize = cellSize
        self.invCellSize = 1.0 / cellSize
        self.wrapX = periodicDim >= 1
        self.wrapY = periodicDim >= 2
        self.wrapZ = periodicDim >= 3

        if let cell = cell, periodicDim > 0, let inv = cell.inverseMatrix {
            // Periodic: build grid in fractional space.
            self.fractional = true
            self.invCell = inv
            self.origin = .zero

            let la = simd_length(cell.a)
            let lb = simd_length(cell.b)
            let lc = simd_length(cell.c)
            let nA = max(1, Int((la / cellSize).rounded(.up)))
            let nB = max(1, Int((lb / cellSize).rounded(.up)))
            let nC = max(1, Int((lc / cellSize).rounded(.up)))
            self.dims = SIMD3<Int>(nA, nB, nC)
            let total = nA * nB * nC
            guard total > 0, total <= maxBuckets else { return nil }

            var buckets = [[Int]](repeating: [], count: total)
            for (idx, atom) in atoms.enumerated() {
                let frac = inv * atom.coord.double
                let wf = SIMD3<Double>(frac.x - floor(frac.x), frac.y - floor(frac.y), frac.z - floor(frac.z))
                let bx = min(nA - 1, max(0, Int(wf.x * Double(nA))))
                let by = min(nB - 1, max(0, Int(wf.y * Double(nB))))
                let bz = min(nC - 1, max(0, Int(wf.z * Double(nC))))
                let flat = bx * nB * nC + by * nC + bz
                buckets[flat].append(idx)
            }
            self.buckets = buckets
        } else {
            // Non-periodic: build Cartesian grid.
            self.fractional = false
            self.invCell = nil

            var minCoord = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
            var maxCoord = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
            for atom in atoms {
                minCoord = simd_min(minCoord, atom.coord)
                maxCoord = simd_max(maxCoord, atom.coord)
            }
            let extent = maxCoord - minCoord
            let nX = max(1, Int((extent.x * invCellSize).rounded(.up)))
            let nY = max(1, Int((extent.y * invCellSize).rounded(.up)))
            let nZ = max(1, Int((extent.z * invCellSize).rounded(.up)))
            self.dims = SIMD3<Int>(nX, nY, nZ)
            let total = nX * nY * nZ
            guard total > 0, total <= maxBuckets else { return nil }

            var buckets = [[Int]](repeating: [], count: total)
            self.origin = minCoord
            for (idx, atom) in atoms.enumerated() {
                let rel = atom.coord - origin
                let bx = min(nX - 1, max(0, Int(rel.x * invCellSize)))
                let by = min(nY - 1, max(0, Int(rel.y * invCellSize)))
                let bz = min(nZ - 1, max(0, Int(rel.z * invCellSize)))
                let flat = bx * nY * nZ + by * nZ + bz
                buckets[flat].append(idx)
            }
            self.buckets = buckets
        }
    }

    /// All atom indices in the 27 buckets neighboring the bucket containing `point`.
    func indicesNear(_ point: SIMD3<Float>) -> [Int] {
        guard point.isFinite else { return [] }
        let bx: Int, by: Int, bz: Int
        if fractional, let inv = invCell {
            let frac = inv * point.double
            let wf = SIMD3<Double>(frac.x - floor(frac.x), frac.y - floor(frac.y), frac.z - floor(frac.z))
            bx = min(dims.x - 1, max(0, Int(wf.x * Double(dims.x))))
            by = min(dims.y - 1, max(0, Int(wf.y * Double(dims.y))))
            bz = min(dims.z - 1, max(0, Int(wf.z * Double(dims.z))))
        } else {
            let rel = point - origin
            bx = min(dims.x - 1, max(0, Int(rel.x * invCellSize)))
            by = min(dims.y - 1, max(0, Int(rel.y * invCellSize)))
            bz = min(dims.z - 1, max(0, Int(rel.z * invCellSize)))
        }

        var result: [Int] = []
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let nx = bx + dx, ny = by + dy, nz = bz + dz
                    let wx: Int, wy: Int, wz: Int
                    if fractional {
                        // Wrap in periodic dimensions, clamp (skip) in non-periodic ones.
                        wx = wrapX ? ((nx % dims.x) + dims.x) % dims.x : (nx >= 0 && nx < dims.x ? nx : -1)
                        wy = wrapY ? ((ny % dims.y) + dims.y) % dims.y : (ny >= 0 && ny < dims.y ? ny : -1)
                        wz = wrapZ ? ((nz % dims.z) + dims.z) % dims.z : (nz >= 0 && nz < dims.z ? nz : -1)
                        if wx < 0 || wy < 0 || wz < 0 { continue }
                    } else {
                        guard nx >= 0 && nx < dims.x && ny >= 0 && ny < dims.y && nz >= 0 && nz < dims.z else { continue }
                        wx = nx; wy = ny; wz = nz
                    }
                    let flat = wx * dims.y * dims.z + wy * dims.z + wz
                    result.append(contentsOf: buckets[flat])
                }
            }
        }
        return result
    }
}
