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

    /// Detect H bonds in the given scene's displayed atoms. Acceptors may be a
    /// periodic image of a displayed atom; the stored acceptor index is the
    /// displayed atom's index (the image used is the one nearest the hydrogen).
    static func detect(scene: Scene) -> [HbondPair] {
        guard scene.hbondSettings.enabled else { return [] }
        guard scene.atoms.count <= maxBondedAtoms else { return [] }
        let settings = scene.hbondSettings
        let cell = scene.cell

        var donors: [Int] = []
        var acceptors: [Int] = []
        for i in scene.atoms.indices {
            if HbondAnalysis.donorAcceptorZ.contains(scene.atoms[i].atomicNumber) {
                donors.append(i)
                acceptors.append(i)
            }
        }

        var raw: [(donor: Int, hydrogen: Int, acceptor: Int, acceptorImage: SIMD3<Float>?)] = []
        raw.reserveCapacity(donors.count)
        for d in donors {
            let dCoord = scene.atoms[d].coord
            let bondedH = bondedHydrogens(scene: scene, donorIndex: d)
            for h in bondedH {
                let hCoord = scene.atoms[h].coord
                for a in acceptors {
                    // No self-bonding of a donor to itself (identity image).
                    guard a != d else { continue }
                    let aBase = scene.atoms[a].coord
                    let aWorld: SIMD3<Float>
                    let aImage: SIMD3<Float>?
                    if let c = cell {
                        guard let img = nearestImageCoord(of: aBase, relativeTo: hCoord, cell: c) else { continue }
                        aWorld = img
                        aImage = img
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
    static func bondedHydrogens(scene: Scene, donorIndex: Int) -> [Int] {
        guard scene.atoms.count <= maxBondedAtoms else { return [] }
        guard scene.atoms.indices.contains(donorIndex) else { return [] }
        let donor = scene.atoms[donorIndex]
        guard HbondAnalysis.donorAcceptorZ.contains(donor.atomicNumber) else { return [] }
        let rD = ElementTable.covalentRadius(donor.atomicNumber)
        let rH = ElementTable.covalentRadius(1)
        guard rD.isFinite, rH.isFinite, rD > 0, rH > 0 else { return [] }
        let cutoff = rD + rH + 0.4
        let cell = scene.cell
        var result: [Int] = []
        for i in scene.atoms.indices {
            let a = scene.atoms[i]
            guard a.atomicNumber == 1 else { continue }
            let dist: Float
            if let c = cell {
                guard let img = nearestImageCoord(of: a.coord, relativeTo: donor.coord, cell: c) else { continue }
                dist = length(donor.coord - img)
            } else {
                dist = length(donor.coord - a.coord)
            }
            if dist < cutoff { result.append(i) }
        }
        return result.sorted()
    }
}

/// Cartesian position of the periodic image of `point` that lies closest to
/// `ref`, computed by wrapping the fractional offset to the nearest integer.
/// Returns nil if the cell is singular (no meaningful image exists).
fileprivate func nearestImageCoord(of point: SIMD3<Float>, relativeTo ref: SIMD3<Float>, cell: Cell) -> SIMD3<Float>? {
    let fracs = Lattice.fractional([point, ref], cell: cell)
    let fp = fracs[0]
    let fr = fracs[1]
    let delta = fp - fr
    let off = SIMD3<Float>(delta.x.rounded(), delta.y.rounded(), delta.z.rounded())
    let fNear = fp - off
    let world = fNear.x * cell.a + fNear.y * cell.b + fNear.z * cell.c
    return world.x.isFinite && world.y.isFinite && world.z.isFinite ? world : nil
}
