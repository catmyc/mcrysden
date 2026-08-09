import Foundation
import simd

enum CellRepresentation: String, Equatable, CaseIterable {
    case input
    case primitive
    case conventional

    var label: String {
        switch self {
        case .input: return "Input cell"
        case .primitive: return "Primitive cell"
        case .conventional: return "Conventional cell"
        }
    }
}

enum StructureToolError: Error, Equatable, CustomStringConvertible {
    case notThreeDimensionalCrystal
    case missingCell
    case noAtoms
    case symmetryUnavailable(String)
    case nonFiniteDeformation
    case singularDeformation
    case excessiveDeformation
    case nonFiniteCenter
    case invalidRadius
    case emptyCluster
    case notASurfaceSlab
    case vacuumBelowSlabExtent(Float, Float)
    case nonFiniteVacuum

    var description: String {
        switch self {
        case .notThreeDimensionalCrystal: return "requires a 3D periodic crystal"
        case .missingCell: return "no unit cell"
        case .noAtoms: return "no atoms"
        case .symmetryUnavailable(let reason): return reason
        case .nonFiniteDeformation: return "deformation matrix contains a non-finite value"
        case .singularDeformation: return "deformation matrix is singular"
        case .excessiveDeformation: return "deformation matrix entries must be within ±100"
        case .nonFiniteCenter: return "cluster center contains a non-finite value"
        case .invalidRadius: return "cluster radius must be positive and finite"
        case .emptyCluster: return "no atoms within the cluster radius"
        case .notASurfaceSlab: return "vacuum control requires a 2D surface slab"
        case .vacuumBelowSlabExtent(let required, let available):
            return "vacuum too small: needs \(required) Å but slab occupies \(available) Å"
        case .nonFiniteVacuum: return "vacuum thickness must be finite and non-negative"
        }
    }
}

extension Scene {

    func transformed(to representation: CellRepresentation) -> Result<Scene, StructureToolError> {
        if representation == .input { return .success(self) }
        guard isCrystal, periodicDim == 3 else { return .failure(.notThreeDimensionalCrystal) }
        guard cell != nil else { return .failure(.missingCell) }
        guard !atoms.isEmpty else { return .failure(.noAtoms) }
        guard let symmetry = crystalSymmetry?.symmetry else {
            return .failure(.symmetryUnavailable(crystalSymmetry?.reasonDescription
                                                ?? "symmetry analysis unavailable"))
        }

        let structure = representation == .primitive
            ? symmetry.primitiveStructure
            : symmetry.conventionalStructure
        let rows = structure.latticeRows
        let r0 = SIMD3<Double>(rows[0, 0], rows[0, 1], rows[0, 2])
        let r1 = SIMD3<Double>(rows[1, 0], rows[1, 1], rows[1, 2])
        let r2 = SIMD3<Double>(rows[2, 0], rows[2, 1], rows[2, 2])
        let newCell = Cell(a: SIMD3<Float>(Float(r0.x), Float(r0.y), Float(r0.z)),
                           b: SIMD3<Float>(Float(r1.x), Float(r1.y), Float(r1.z)),
                           c: SIMD3<Float>(Float(r2.x), Float(r2.y), Float(r2.z)))

        let mapping = symmetry.inputToPrimitiveMapping
        var newAtoms: [Atom] = []
        newAtoms.reserveCapacity(structure.atomCount)
        for j in 0..<structure.atomCount {
            let frac = structure.fractionalPositions[j]
            let cart = frac.x * r0 + frac.y * r1 + frac.z * r2
            let number = structure.atomicTypes[j]
            var label = ElementTable.symbol(number)
            let primitiveIndex = representation == .primitive
                ? j
                : structure.mappingToPrimitive?[j]
            if let p = primitiveIndex, let i = mapping.firstIndex(of: p) {
                label = atoms[i].label
            }
            newAtoms.append(Atom(coord: SIMD3<Float>(Float(cart.x), Float(cart.y), Float(cart.z)),
                                 atomicNumber: number, label: label))
        }

        var out = self
        out.cell = newCell
        out.atoms = newAtoms
        out.bonds = Scene.rebond(newAtoms, cell: newCell, isCrystal: true, periodicDim: 3)
        out.isCrystal = true
        out.periodicDim = 3
        out.superCell = SuperCell()
        out.slab = nil
        out.selectedAtoms = []
        out.measurementResult = nil
        out.baseAtoms = newAtoms
        out.baseBonds = out.bonds
        out.preslabAtoms = newAtoms
        out.crystalSymmetry = CrystalSymmetryAnalyzer.analyze(
            cell: newCell, atoms: newAtoms, isCrystal: true, periodicDim: 3,
            inputCompleteness: crystalSymmetry?.inputCompleteness ?? .complete)
        // A user-edited route is data, not a request to regenerate. Remap it
        // through the new reciprocal basis instead of replacing it with the
        // canonical path (which would destroy the user's edits).
        if out.kPathProvenance == .generated {
            out.installCanonicalPath(cell: newCell)
        } else {
            out.transferKPathAcrossGeometryChange(from: self)
        }
        out.title = (out.title.isEmpty ? "" : out.title + " ")
            + (representation == .primitive ? "(primitive)" : "(conventional)")
        return .success(out)
    }

    func deformed(byRows rows: [SIMD3<Float>]) -> Result<Scene, StructureToolError> {
        guard isCrystal else { return .failure(.notThreeDimensionalCrystal) }
        guard let cell else { return .failure(.missingCell) }
        guard !atoms.isEmpty else { return .failure(.noAtoms) }
        guard rows.count == 3 else { return .failure(.nonFiniteDeformation) }

        for v in rows {
            guard v.x.isFinite && v.y.isFinite && v.z.isFinite else {
                return .failure(.nonFiniteDeformation)
            }
        }
        let maxAbs = rows.flatMap { [$0.x, $0.y, $0.z] }.map { abs(Double($0)) }.max() ?? 0
        guard maxAbs <= 100 else { return .failure(.excessiveDeformation) }

        let m = rows.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        if maxAbs > 0 {
            let det = dot(m[0], cross(m[1], m[2]))
            let normalized = det / (maxAbs * maxAbs * maxAbs)
            guard normalized.isFinite && abs(normalized) >= 1e-6 else {
                return .failure(.singularDeformation)
            }
        } else {
            return .failure(.singularDeformation)
        }

        func apply(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let d = SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))
            return SIMD3<Float>(Float(dot(m[0], d)), Float(dot(m[1], d)), Float(dot(m[2], d)))
        }

        let newCell = Cell(a: apply(cell.a), b: apply(cell.b), c: apply(cell.c))
        var newAtoms: [Atom] = []
        newAtoms.reserveCapacity(atoms.count)
        for atom in atoms {
            newAtoms.append(Atom(coord: apply(atom.coord), atomicNumber: atom.atomicNumber,
                                 label: atom.label, force: atom.force))
        }

        var out = self
        out.cell = newCell
        out.atoms = newAtoms
        out.bonds = Scene.rebond(newAtoms, cell: newCell, isCrystal: isCrystal, periodicDim: periodicDim)
        out.superCell = SuperCell()
        out.slab = nil
        out.selectedAtoms = []
        out.measurementResult = nil
        out.baseAtoms = newAtoms
        out.baseBonds = out.bonds
        out.preslabAtoms = newAtoms
        out.crystalSymmetry = CrystalSymmetryAnalyzer.analyze(
            cell: newCell, atoms: newAtoms, isCrystal: isCrystal, periodicDim: periodicDim,
            inputCompleteness: crystalSymmetry?.inputCompleteness ?? .complete)
        if isCrystal, let c = out.cell {
            // A user-edited route is data, not a request to regenerate. Remap it
            // through the new reciprocal basis instead of replacing it.
            if out.kPathProvenance == .generated {
                out.installCanonicalPath(cell: c)
            } else {
                out.transferKPathAcrossGeometryChange(from: self)
            }
        }
        out.title = (out.title.isEmpty ? "" : out.title + " ") + "(deformed)"
        return .success(out)
    }

    func cutCluster(center: SIMD3<Float>, radius: Float) -> Result<Scene, StructureToolError> {
        guard !atoms.isEmpty else { return .failure(.noAtoms) }
        guard center.x.isFinite && center.y.isFinite && center.z.isFinite else {
            return .failure(.nonFiniteCenter)
        }
        guard radius.isFinite, radius > 0, radius <= 1e6 else {
            return .failure(.invalidRadius)
        }

        let kept = atoms.filter { simd_distance($0.coord, center) <= radius }
        guard !kept.isEmpty else { return .failure(.emptyCluster) }

        var out = self
        out.cell = nil
        out.isCrystal = false
        out.periodicDim = 0
        out.atoms = kept
        out.bonds = Scene.rebond(kept, cell: nil, isCrystal: false, periodicDim: 0)
        out.superCell = SuperCell()
        out.slab = nil
        out.selectedAtoms = []
        out.measurementResult = nil
        out.baseAtoms = kept
        out.baseBonds = out.bonds
        out.preslabAtoms = kept
        out.crystalSymmetry = nil
        out.kPathPoints = []
        out.kPathBreaks = []
        out.kPathProvenance = .generated
        out.kPathSignature = nil
        out.title = (out.title.isEmpty ? "" : out.title + " ") + "(cluster)"
        return .success(out)
    }

    /// Geometric slab thickness (maxZ - minZ over atoms) for a z-parallel 2D slab
    /// whose atoms lie inside the cell. nil when the scene is not such a slab —
    /// the prerequisite for vacuum control.
    var surfaceSlabExtent: Float? {
        guard isCrystal, periodicDim == 2, let cell else { return nil }
        let cLen = length(cell.c)
        guard cLen > 0 else { return nil }
        guard abs(cell.c.x) <= 1e-6 * cLen, abs(cell.c.y) <= 1e-6 * cLen else { return nil }
        var minZ = Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude
        for atom in atoms {
            guard atom.coord.z >= -1e-3, atom.coord.z <= cLen + 1e-3 else { return nil }
            minZ = min(minZ, atom.coord.z)
            maxZ = max(maxZ, atom.coord.z)
        }
        guard maxZ >= minZ else { return nil }
        return maxZ - minZ
    }

    func withVacuum(_ vacuum: Float) -> Result<Scene, StructureToolError> {
        guard let cell, let extent = surfaceSlabExtent else {
            return .failure(.notASurfaceSlab)
        }
        guard vacuum.isFinite, vacuum >= 0 else { return .failure(.nonFiniteVacuum) }
        var maxZ = -Float.greatestFiniteMagnitude
        for atom in atoms { maxZ = max(maxZ, atom.coord.z) }

        let newLength = Double(extent) + Double(vacuum)
        if newLength < Double(maxZ) - 1e-3 {
            return .failure(.vacuumBelowSlabExtent(Float(newLength), maxZ))
        }

        var out = self
        out.cell = Cell(a: cell.a, b: cell.b, c: SIMD3<Float>(0, 0, Float(newLength)))
        return .success(out)
    }
}
