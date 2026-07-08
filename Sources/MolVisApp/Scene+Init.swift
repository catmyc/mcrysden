import Foundation
import simd
import MolEnvParse

extension Scene {
    /// Compute a distance / angle / dihedral from selected atoms.
    /// pick order matters: angle uses the middle atom as vertex; dihedral is
    /// signed by the plane normals of (a,b,c) and (b,c,d).
    static func computeMeasurement(mode: MeasurementMode, atoms: [Atom], selected: [Int]) -> MeasurementResult? {
        let sel = selected.map { atoms[$0].coord }
        var value: Float = 0
        switch mode {
        case .distance:
            value = length(sel[1] - sel[0])
        case .angle:
            let v0 = normalize(sel[0] - sel[1]), v2 = normalize(sel[2] - sel[1])
            value = acos(min(max(dot(v0, v2), -1), 1)) * 180 / .pi
        case .dihedral:
            let ba = normalize(sel[0] - sel[1]), cb = normalize(sel[1] - sel[2]), dc = normalize(sel[2] - sel[3])
            let n1 = cross(ba, cb), n2 = cross(cb, dc)
            value = acos(min(max(dot(normalize(n1), normalize(n2)), -1), 1)) * 180 / .pi
        case .none:
            return nil
        }
        let idxStr = selected.map { "\($0 + 1)" }.joined(separator: "-")
        let unit = (mode == .distance) ? "Å" : "°"
        let summary = "\(mode.label) (\(idxStr)): \(String(format: mode == .distance ? "%.3f" : "%.1f", value)) \(unit)"
        return MeasurementResult(mode: mode, atomIndices: selected, value: value, summary: summary)
    }

    init(loaded: LoadedScene, displayMode: DisplayMode = .ballStick) {
        self.atoms = loaded.atoms
        self.bonds = loaded.bonds
        self.cell = loaded.cell
        self.title = loaded.title
        self.displayMode = displayMode
        self.isCrystal = loaded.isCrystal
        self.periodicDim = loaded.periodicDim
        self.baseAtoms = loaded.atoms
        self.baseBonds = loaded.bonds
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
        // When reducing to (1,1,1) restore the pristine base set.
        if total <= 1 {
            var out = self
            out.atoms = baseAtoms
            out.bonds = baseBonds
            out.preslabAtoms = baseAtoms      // so slab always has a full set
            out.superCell = SuperCell()
            return out
        }
        // Always expand from the base atoms so the operation is idempotent
        // and reversible: calling widen(2) → widen(1) returns the original.
        let src = baseAtoms.isEmpty ? atoms : baseAtoms
        if total * src.count > Scene.superCellAtomCap { return self }   // refused — caller alerts
        var newAtoms: [Atom] = []
        newAtoms.reserveCapacity(src.count * total)
        for i in 0..<sc.n1 { for j in 0..<sc.n2 { for k in 0..<sc.n3 {
            let t = cell.a * Float(i) + cell.b * Float(j) + cell.c * Float(k)
            for a in src { newAtoms.append(Atom(coord: a.coord + t, atomicNumber: a.atomicNumber, label: a.label))
            }
        }}}
        var out = self
        out.atoms = newAtoms
        out.bonds = Self.rebond(newAtoms, cell: cell)
        out.preslabAtoms = newAtoms    // snapshot for `applySlab`
        out.superCell = sc
        return out
    }

    // Mark this unavailable for v1 bonds cross images without a C bridge — but
    // provide a pure-Swift fallback using covalent radii for v1. Task 8 wires the
    // real C bridge; for now keep it simple:
    /// Recompute bonds for the given atom set and unit cell using the C
    /// covalent-radii heuristic (the same `make_bonds` that parsers call).
    static func rebond(_ atoms: [Atom], cell: Cell) -> [Bond] {
        let nat = atoms.count
        guard nat > 0 else { return [] }

        // Build a temporary MolEnvScene so we can call the C bond heuristic.
        let cAtoms = UnsafeMutablePointer<MolEnvAtom>.allocate(capacity: nat)
        for (i, a) in atoms.enumerated() {
            cAtoms[i].coord = (a.coord.x, a.coord.y, a.coord.z)
            cAtoms[i].atomic_number = Int32(a.atomicNumber)
            // label is char[8]; copy via pointer rebind
            withUnsafeMutablePointer(to: &cAtoms[i].label) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, 8)
                let len = min(7, a.label.utf8.count)
                for (j, byte) in a.label.utf8.prefix(len).enumerated() { raw[j] = CChar(byte) }
            }
        }
        var scene = MolEnvScene()
        scene.natoms = Int32(nat)
        scene.atoms = cAtoms
        scene.cell = ((cell.a.x, cell.a.y, cell.a.z),
                      (cell.b.x, cell.b.y, cell.b.z),
                      (cell.c.x, cell.c.y, cell.c.z))
        scene.is_crystal = 1
        scene.periodic_dim = 3

        var nb: Int32 = 0
        var bondPtr: UnsafeMutablePointer<MolEnvBond>? = nil
        // factor 1.0 — same as the parsers use
        bondPtr = molenv_make_bonds(&scene, 1.0, &nb)
        defer {
            if let bp = bondPtr { molenv_free_bonds(bp) }
            cAtoms.deallocate()
        }

        guard nb > 0, let bp = bondPtr else { return [] }
        return (0..<Int(nb)).map { Bond(i: Int(bp[$0].i), j: Int(bp[$0].j)) }
    }

    func applySlab(_ slab: Slab?) -> Scene {
        guard let slab, let cell else {
            // Removing the slab — restore the full pre-slab atom set.
            var s = self
            s.atoms = preslabAtoms.isEmpty ? s.atoms : preslabAtoms
            if let c = s.cell { s.bonds = Self.rebond(s.atoms, cell: c) } else { s.bonds = [] }
            s.slab = nil
            return s
        }
        let nA = SIMD3(Float(slab.planeA.h), Float(slab.planeA.k), Float(slab.planeA.l))
        let nB = SIMD3(Float(slab.planeB.h), Float(slab.planeB.k), Float(slab.planeB.l))
        let dA = slab.planeA.distance
        let dB = slab.planeB.distance
        // Filter from the pre-slab (widened) set so that changing the slab
        // distance does not compound on a previous slab result.
        let src = preslabAtoms.isEmpty ? atoms : preslabAtoms
        var kept: [Atom] = []
        for a in src {
            let frac = cartesianToFractional(a.coord, cell: cell)
            let projA = frac.x*nA.x + frac.y*nA.y + frac.z*nA.z
            let projB = frac.x*nB.x + frac.y*nB.y + frac.z*nB.z
            if projA >= dA && projB <= dB { kept.append(a) }
        }
        var out = self
        out.atoms = kept
        out.bonds = Self.rebond(kept, cell: cell)
        out.slab = slab
        return out
    }

    /// Convert a Cartesian coordinate to fractional (crystal) coordinates for
    /// the given unit cell.  Returns nil if the cell is singular.
    func fractionalCoord(_ p: SIMD3<Float>) -> SIMD3<Float>? {
        guard let cell else { return nil }
        return cartesianToFractional(p, cell: cell)
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
