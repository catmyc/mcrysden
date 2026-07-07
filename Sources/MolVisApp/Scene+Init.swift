import Foundation
import simd

extension Scene {
    init(loaded: LoadedScene, displayMode: DisplayMode = .ballStick) {
        self.atoms = loaded.atoms
        self.bonds = loaded.bonds
        self.cell = loaded.cell
        self.title = loaded.title
        self.displayMode = displayMode
        self.isCrystal = loaded.isCrystal
        self.periodicDim = loaded.periodicDim
    }

    var centroid: SIMD3<Float> {
        guard !atoms.isEmpty else { return SIMD3(0,0,0) }
        var sum = SIMD3<Float>.zero
        for a in atoms { sum += a.coord }
        return sum / Float(atoms.count)
    }

    func boundingSphere() -> (center: SIMD3<Float>, radius: Float) {
        let c = centroid
        var r: Float = 0
        for a in atoms { r = max(r, distance(a.coord, c)) }
        return (c, r)
    }

    static let superCellAtomCap = 500_000

    func widenSuperCell(_ sc: SuperCell) -> Scene {
        guard let cell else { return self }
        let total = sc.n1 * sc.n2 * sc.n3
        if total <= 1 { return self }
        if total * atoms.count > Scene.superCellAtomCap { return self }   // refused — caller alerts
        var out = self
        var newAtoms: [Atom] = []
        newAtoms.reserveCapacity(atoms.count * total)
        for i in 0..<sc.n1 { for j in 0..<sc.n2 { for k in 0..<sc.n3 {
            let t = cell.a * Float(i) + cell.b * Float(j) + cell.c * Float(k)
            for a in atoms { newAtoms.append(Atom(coord: a.coord + t, atomicNumber: a.atomicNumber, label: a.label))
            }
        }}}
        // recompute bonds against the expanded atom set through the C bridge
        // (we expose a thin rebond() for this — added in this task)
        out.atoms = newAtoms
        out.bonds = Self.rebond(newAtoms, cell: cell)
        out.superCell = SuperCell(n1: sc.n1*self.superCell.n1, n2: sc.n2*self.superCell.n2, n3: sc.n3*self.superCell.n3)
        return out
    }

    // Mark this unavailable for v1 bonds cross images without a C bridge — but
    // provide a pure-Swift fallback using covalent radii for v1. Task 8 wires the
    // real C bridge; for now keep it simple:
    static func rebond(_ atoms: [Atom], cell: Cell) -> [Bond] {
        // v1 fallback: no cross-image bonds. Renderer will still draw atoms.
        // TODO(Task 8): replace with C make_bonds bridge
        return []
    }

    func applySlab(_ slab: Slab?) -> Scene {
        guard let slab, let cell else { var s = self; s.slab = slab; return s }
        let nA = SIMD3(Float(slab.planeA.h), Float(slab.planeA.k), Float(slab.planeA.l))
        let nB = SIMD3(Float(slab.planeB.h), Float(slab.planeB.k), Float(slab.planeB.l))
        let dA = slab.planeA.distance
        let dB = slab.planeB.distance
        var kept: [Atom] = []
        for a in atoms {
            let frac = cartesianToFractional(a.coord, cell: cell)
            let projA = frac.x*nA.x + frac.y*nA.y + frac.z*nA.z
            let projB = frac.x*nB.x + frac.y*nB.y + frac.z*nB.z
            if projA >= dA && projB <= dB { kept.append(a) }
        }
        var out = self
        out.atoms = kept
        out.bonds = []   // v1: drop bonds across slab cut
        out.slab = slab
        return out
    }

    private func cartesianToFractional(_ p: SIMD3<Float>, cell: Cell) -> SIMD3<Float> {
        // Cramer's rule on the 3x3 [a b c] system: p = frac.x*a + frac.y*b + frac.z*c.
        // Columns of the matrix are the cell vectors a, b, c.
        let det = cell.a.x*(cell.b.y*cell.c.z - cell.c.y*cell.b.z)
                - cell.b.x*(cell.a.y*cell.c.z - cell.c.y*cell.a.z)
                + cell.c.x*(cell.a.y*cell.b.z - cell.b.y*cell.a.z)
        if abs(det) < 1e-6 { return SIMD3(0,0,0) }   // singular cell
        // det([col b c]) — replace column a with col
        func det1(_ col: SIMD3<Float>) -> Float {
            return col.x*(cell.b.y*cell.c.z - cell.c.y*cell.b.z)
                 - cell.b.x*(col.y*cell.c.z - cell.c.y*col.z)
                 + cell.c.x*(col.y*cell.b.z - cell.b.y*col.z)
        }
        // det([a col c]) — replace column b with col
        func det2(_ col: SIMD3<Float>) -> Float {
            return cell.a.x*(col.y*cell.c.z - cell.c.y*col.z)
                 - col.x*(cell.a.y*cell.c.z - cell.c.y*cell.a.z)
                 + cell.c.x*(cell.a.y*col.z - col.y*cell.a.z)
        }
        // det([a b col]) — replace column c with col
        func det3(_ col: SIMD3<Float>) -> Float {
            return cell.a.x*(cell.b.y*col.z - col.y*cell.b.z)
                 - cell.b.x*(cell.a.y*col.z - col.y*cell.a.z)
                 + col.x*(cell.a.y*cell.b.z - cell.b.y*cell.a.z)
        }
        return SIMD3(det1(p)/det, det2(p)/det, det3(p)/det)
    }
}
