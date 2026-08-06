import Foundation
import simd

enum StructureEditError: Error, Equatable, CustomStringConvertible {
    case notEditable(String)
    case noSelection
    case invalidElement(Int)
    case nonFinitePosition
    case singularCell
    case invalidLattice(String)
    case nonFiniteDisplacement
    case excessiveDisplacement
    case atomCapExceeded(Int, Int)
    case wouldRemoveAllAtoms
    case emptyInput

    var description: String {
        switch self {
        case .notEditable(let reason): return reason
        case .noSelection: return "no atoms selected"
        case .invalidElement(let z): return "atomic number \(z) is out of range (1...118)"
        case .nonFinitePosition: return "position contains a non-finite value"
        case .singularCell: return "fractional position requires a nonsingular unit cell"
        case .invalidLattice(let reason): return reason
        case .nonFiniteDisplacement: return "displacement contains a non-finite value"
        case .excessiveDisplacement: return "displacement magnitude exceeds 1000 Å"
        case .atomCapExceeded(let count, let cap): return "result would exceed \(count) atoms (cap \(cap))"
        case .wouldRemoveAllAtoms: return "cannot remove every atom"
        case .emptyInput: return "no atoms to edit"
        }
    }
}

extension Scene {
    /// True when structure editing is allowed: pristine geometry (no supercell,
    /// no slab) and the atom count is within the edit cap.
    var isStructureEditable: Bool { structureEditRejectionReason == nil }

    static let structureEditAtomCap = 10_000

    /// The reason editing is currently disabled, or nil when editing is allowed.
    /// Mirrors the coordinate-edit gating messages in the controller.
    private var structureEditRejectionReason: String? {
        if superCell.total > 1 {
            return "Editing disabled: supercell active. "
                + "Reset the supercell to 1×1×1 to edit atom coordinates."
        }
        if slab != nil {
            return "Editing disabled: slab active. "
                + "Remove the slab to edit atom coordinates."
        }
        if atoms.count > Self.structureEditAtomCap {
            return "Editing disabled: structure has \(atoms.count) atoms "
                + "(editable cap \(Self.structureEditAtomCap))."
        }
        return nil
    }

    /// Cell parameters a, b, c (Å) and alpha, beta, gamma (degrees), or nil
    /// when the cell is missing/non-finite/singular.
    var cellParameters: (a: Float, b: Float, c: Float, alpha: Float, beta: Float, gamma: Float)? {
        guard let cell, cell.isNonsingular else { return nil }
        let da = cell.a.double, db = cell.b.double, dc = cell.c.double
        let a = simd_length(da), b = simd_length(db), c = simd_length(dc)
        guard a.isFinite, b.isFinite, c.isFinite, a > 0, b > 0, c > 0 else { return nil }
        func angle(_ u: SIMD3<Double>, _ v: SIMD3<Double>) -> Double {
            let cos = simd_dot(u, v) / (simd_length(u) * simd_length(v))
            return acos(min(1, max(-1, cos))) * 180 / .pi
        }
        let alpha = angle(db, dc)
        let beta = angle(da, dc)
        let gamma = angle(da, db)
        guard alpha.isFinite, beta.isFinite, gamma.isFinite else { return nil }
        return (Float(a), Float(b), Float(c), Float(alpha), Float(beta), Float(gamma))
    }

    /// Insert an atom. `position` is Cartesian when `fractional` is false,
    /// fractional otherwise (converted through the cell). `label` defaults to
    /// ElementTable.symbol(atomicNumber) when nil. The new atom is appended at
    /// the end of `atoms`.
    func insertingAtom(element atomicNumber: Int, label: String?,
                       position: SIMD3<Float>, fractional: Bool) -> Result<Scene, StructureEditError> {
        if let reason = structureEditRejectionReason { return .failure(.notEditable(reason)) }
        return performInsert(element: atomicNumber, label: label, position: position, fractional: fractional)
    }

    private func performInsert(element atomicNumber: Int, label: String?,
                               position: SIMD3<Float>, fractional: Bool) -> Result<Scene, StructureEditError> {
        guard !atoms.isEmpty else { return .failure(.emptyInput) }
        guard (1...118).contains(atomicNumber) else {
            return .failure(.invalidElement(atomicNumber))
        }
        guard position.isFinite else { return .failure(.nonFinitePosition) }
        let coord: SIMD3<Float>
        if fractional {
            guard let cell, cell.isNonsingular else { return .failure(.singularCell) }
            coord = cell.cartesian(position)
        } else {
            coord = position
        }
        guard coord.isFinite else { return .failure(.nonFinitePosition) }
        let atom = Atom(coord: coord, atomicNumber: atomicNumber,
                        label: label ?? ElementTable.symbol(atomicNumber))
        return buildResult(atoms: atoms + [atom], cell: cell)
    }

    /// Remove the atoms at the given (current displayed-array) indices.
    func removingAtoms(at indices: [Int]) -> Result<Scene, StructureEditError> {
        guard let reason = structureEditRejectionReason else {
            return performRemove(at: indices)
        }
        return .failure(.notEditable(reason))
    }

    private func performRemove(at indices: [Int]) -> Result<Scene, StructureEditError> {
        guard !atoms.isEmpty else { return .failure(.emptyInput) }
        guard let valid = sanitizeIndices(indices) else { return .failure(.noSelection) }
        let removeSet = Set(valid)
        let kept = atoms.enumerated().filter { !removeSet.contains($0.offset) }.map { $0.element }
        guard kept.count >= 1 else { return .failure(.wouldRemoveAllAtoms) }
        return buildResult(atoms: kept, cell: cell)
    }

    /// Substitute the species of the atoms at the given indices. `label`
    /// defaults to ElementTable.symbol(atomicNumber) when nil.
    func substitutingAtoms(at indices: [Int], element atomicNumber: Int, label: String?)
        -> Result<Scene, StructureEditError> {
        guard let reason = structureEditRejectionReason else {
            return performSubstitute(at: indices, element: atomicNumber, label: label)
        }
        return .failure(.notEditable(reason))
    }

    private func performSubstitute(at indices: [Int], element atomicNumber: Int, label: String?)
        -> Result<Scene, StructureEditError> {
        guard !atoms.isEmpty else { return .failure(.emptyInput) }
        guard let valid = sanitizeIndices(indices) else { return .failure(.noSelection) }
        guard (1...118).contains(atomicNumber) else {
            return .failure(.invalidElement(atomicNumber))
        }
        let newLabel = label ?? ElementTable.symbol(atomicNumber)
        var newAtoms = atoms
        for i in valid {
            newAtoms[i] = Atom(coord: newAtoms[i].coord, atomicNumber: atomicNumber,
                               label: newLabel, force: newAtoms[i].force)
        }
        return buildResult(atoms: newAtoms, cell: cell)
    }

    /// Bulk-displace atoms by `delta` (Å, Cartesian). `indices` nil = all atoms.
    func displacingAtoms(at indices: [Int]?, by delta: SIMD3<Float>) -> Result<Scene, StructureEditError> {
        guard let reason = structureEditRejectionReason else {
            return performDisplace(at: indices, by: delta)
        }
        return .failure(.notEditable(reason))
    }

    private func performDisplace(at indices: [Int]?, by delta: SIMD3<Float>) -> Result<Scene, StructureEditError> {
        guard !atoms.isEmpty else { return .failure(.emptyInput) }
        guard delta.isFinite else { return .failure(.nonFiniteDisplacement) }
        guard simd_length(delta) <= 1000 else { return .failure(.excessiveDisplacement) }
        let target: Set<Int>
        if let indices {
            guard let valid = sanitizeIndices(indices) else { return .failure(.noSelection) }
            target = Set(valid)
        } else {
            target = Set(atoms.indices)
        }
        var newAtoms = atoms
        for i in target { newAtoms[i].coord += delta }
        return buildResult(atoms: newAtoms, cell: cell)
    }

    /// Lattice-parameter edit: at least one of a/b/c (Å) or alpha/beta/gamma
    /// (degrees) must be non-nil. Builds a new cell in the standard convention
    /// and repositions all atoms to the same fractional coordinates.
    func editingLattice(a: Float?, b: Float?, c: Float?,
                        alpha: Float?, beta: Float?, gamma: Float?) -> Result<Scene, StructureEditError> {
        guard let reason = structureEditRejectionReason else {
            return performLatticeEdit(a: a, b: b, c: c, alpha: alpha, beta: beta, gamma: gamma)
        }
        return .failure(.notEditable(reason))
    }

    private func performLatticeEdit(a: Float?, b: Float?, c: Float?,
                                    alpha: Float?, beta: Float?, gamma: Float?)
        -> Result<Scene, StructureEditError> {
        guard !atoms.isEmpty else { return .failure(.emptyInput) }
        guard let cell, cell.isNonsingular else { return .failure(.singularCell) }
        let params = cellParameters  // non-nil: cell is nonsingular
        let newA = a ?? params?.a ?? 0
        let newB = b ?? params?.b ?? 0
        let newC = c ?? params?.c ?? 0
        let newAlpha = alpha ?? params?.alpha ?? 0
        let newBeta = beta ?? params?.beta ?? 0
        let newGamma = gamma ?? params?.gamma ?? 0
        guard newA.isFinite, newB.isFinite, newC.isFinite,
              newAlpha.isFinite, newBeta.isFinite, newGamma.isFinite else {
            return .failure(.invalidLattice("lattice parameters must be finite"))
        }
        guard newA > 0, newA <= 10000, newB > 0, newB <= 10000, newC > 0, newC <= 10000 else {
            return .failure(.invalidLattice("lattice constants must be positive and at most 10000 Å"))
        }
        guard newAlpha > 0, newAlpha < 180, newBeta > 0, newBeta < 180,
              newGamma > 0, newGamma < 180 else {
            return .failure(.invalidLattice("lattice angles must be between 0 and 180 degrees"))
        }
        let newCell = Cell.fromLattice(a: newA, b: newB, c: newC,
                                       alpha: newAlpha, beta: newBeta, gamma: newGamma)
        guard newCell.isNonsingular else {
            return .failure(.invalidLattice("lattice parameters produce a singular cell"))
        }
        let na = newCell.a.double, nb = newCell.b.double, nc = newCell.c.double
        var newAtoms: [Atom] = []
        newAtoms.reserveCapacity(atoms.count)
        for atom in atoms {
            guard let frac = fractionalDouble(atom.coord.double, cell: cell) else {
                return .failure(.singularCell)
            }
            let cart = SIMD3<Double>(
                na.x * frac.x + nb.x * frac.y + nc.x * frac.z,
                na.y * frac.x + nb.y * frac.y + nc.y * frac.z,
                na.z * frac.x + nb.z * frac.y + nc.z * frac.z)
            newAtoms.append(Atom(coord: SIMD3<Float>(Float(cart.x), Float(cart.y), Float(cart.z)),
                                 atomicNumber: atom.atomicNumber, label: atom.label, force: atom.force))
        }
        return buildResult(atoms: newAtoms, cell: newCell)
    }

    /// Direct cell-vector edit: `a`, `b`, `c` are the new direct basis vectors
    /// (Å). Fractional coordinates of all atoms are preserved (atoms move with
    /// the cell).
    func editingCellVectors(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>)
        -> Result<Scene, StructureEditError> {
        guard let reason = structureEditRejectionReason else {
            return performCellVectorEdit(a, b, c)
        }
        return .failure(.notEditable(reason))
    }

    private func performCellVectorEdit(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>)
        -> Result<Scene, StructureEditError> {
        guard !atoms.isEmpty else { return .failure(.emptyInput) }
        guard let cell, cell.isNonsingular else { return .failure(.singularCell) }
        guard a.isFinite, b.isFinite, c.isFinite else {
            return .failure(.invalidLattice("cell vectors must be finite"))
        }
        let newCell = Cell(a: a, b: b, c: c)
        guard newCell.isNonsingular else {
            return .failure(.invalidLattice("cell vectors are linearly dependent"))
        }
        let na = newCell.a.double, nb = newCell.b.double, nc = newCell.c.double
        var newAtoms: [Atom] = []
        newAtoms.reserveCapacity(atoms.count)
        for atom in atoms {
            guard let frac = fractionalDouble(atom.coord.double, cell: cell) else {
                return .failure(.singularCell)
            }
            let cart = SIMD3<Double>(
                na.x * frac.x + nb.x * frac.y + nc.x * frac.z,
                na.y * frac.x + nb.y * frac.y + nc.y * frac.z,
                na.z * frac.x + nb.z * frac.y + nc.z * frac.z)
            newAtoms.append(Atom(coord: SIMD3<Float>(Float(cart.x), Float(cart.y), Float(cart.z)),
                                 atomicNumber: atom.atomicNumber, label: atom.label, force: atom.force))
        }
        return buildResult(atoms: newAtoms, cell: newCell)
    }

    // MARK: - Shared result construction

    /// Assemble the result scene from a new atom set and (optional) cell.
    /// Rebonds, mirrors the base snapshots, clears selection/measurement,
    /// re-analyzes symmetry, and regenerates the canonical k-path only for
    /// complete 3D crystals with a generated route.
    private func buildResult(atoms newAtoms: [Atom], cell newCell: Cell?) -> Result<Scene, StructureEditError> {
        guard newAtoms.count <= Self.structureEditAtomCap else {
            return .failure(.atomCapExceeded(newAtoms.count, Self.structureEditAtomCap))
        }
        var out = self
        out.atoms = newAtoms
        out.cell = newCell
        out.bonds = Scene.rebond(newAtoms, cell: newCell, isCrystal: isCrystal, periodicDim: periodicDim)
        out.baseAtoms = newAtoms
        out.baseBonds = out.bonds
        out.preslabAtoms = newAtoms
        out.selectedAtoms = []
        out.measurementResult = nil
        let priorCompleteness = crystalSymmetry?.inputCompleteness ?? .complete
        out.crystalSymmetry = CrystalSymmetryAnalyzer.analyze(
            cell: newCell, atoms: newAtoms, isCrystal: isCrystal, periodicDim: periodicDim,
            inputCompleteness: priorCompleteness)
        let isComplete3D = isCrystal && periodicDim == 3 && priorCompleteness == .complete
        if out.kPathProvenance == .generated, let c = newCell, isComplete3D {
            out.installCanonicalPath(cell: c)
        }
        return .success(out)
    }

    /// Filter indices to the valid, in-range, deduplicated set. Returns nil
    /// when no valid index remains.
    private func sanitizeIndices(_ indices: [Int]) -> [Int]? {
        var seen = Set<Int>()
        var result: [Int] = []
        for i in indices where i >= 0 && i < atoms.count && !seen.contains(i) {
            seen.insert(i)
            result.append(i)
        }
        return result.isEmpty ? nil : result
    }

    /// Cartesian → fractional in Double precision. Returns nil when the cell
    /// is singular.
    private func fractionalDouble(_ p: SIMD3<Double>, cell: Cell) -> SIMD3<Double>? {
        guard cell.isNonsingular else { return nil }
        let a = cell.a.double, b = cell.b.double, c = cell.c.double
        let det = a.x * (b.y * c.z - c.y * b.z)
                - b.x * (a.y * c.z - c.y * a.z)
                + c.x * (a.y * b.z - b.y * a.z)
        func det1(_ col: SIMD3<Double>) -> Double {
            col.x * (b.y * c.z - c.y * b.z)
                - b.x * (col.y * c.z - c.y * col.z)
                + c.x * (col.y * b.z - b.y * col.z)
        }
        func det2(_ col: SIMD3<Double>) -> Double {
            a.x * (col.y * c.z - c.y * col.z)
                - col.x * (a.y * c.z - c.y * a.z)
                + c.x * (a.y * col.z - col.y * a.z)
        }
        func det3(_ col: SIMD3<Double>) -> Double {
            a.x * (b.y * col.z - col.y * b.z)
                - b.x * (a.y * col.z - col.y * a.z)
                + col.x * (a.y * b.z - b.y * a.z)
        }
        return SIMD3(det1(p) / det, det2(p) / det, det3(p) / det)
    }
}
