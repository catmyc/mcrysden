import Foundation
import simd

struct StructureSummary {
    let latticeA: Double?
    let latticeB: Double?
    let latticeC: Double?
    let alpha: Double?
    let beta: Double?
    let gamma: Double?
    let cellVolume: Double?
    let atomCount: Int
    let elementCounts: [Int: Int]
    let formula: String
    let density: Double?
    let spaceGroupNumber: Int?
    let spaceGroupSymbol: String?
    let crystalSystem: String?
    let bravaisLattice: String?
    let pointGroup: String?
    let symmetryOperationCount: Int?
    let isCrystal: Bool
    let isAsymmetricUnit: Bool

    init?(_ scene: Scene, symmetry: CrystalSymmetryAnalysis?) {
        guard !scene.atoms.isEmpty else { return nil }

        isAsymmetricUnit = symmetry?.unavailableReason?.isAsymmetricUnitInput == true

        // For periodic crystals, use the base atoms/cell so density and counts
        // stay correct across supercell expansion and frame reloads.
        let useBase = scene.cell != nil && !scene.baseAtoms.isEmpty
        let atoms = useBase ? scene.baseAtoms : scene.atoms
        atomCount = atoms.count

        var counts: [Int: Int] = [:]
        let allValidZ = atoms.allSatisfy { (1...118).contains($0.atomicNumber) }
        for atom in atoms {
            counts[atom.atomicNumber, default: 0] += 1
        }
        elementCounts = counts
        formula = StructureSummary.hillFormula(counts: counts)
        let incomplete = symmetry?.unavailableReason?.isIncompleteInput ?? false
        let is3D = scene.isCrystal && scene.periodicDim == 3

        if let cell = scene.cell {
            let a = cell.a, b = cell.b, c = cell.c
            let la = Double(simd_length(a)), lb = Double(simd_length(b)), lc = Double(simd_length(c))

            func angle(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> Double? {
                let lu = Double(simd_length(u)), lv = Double(simd_length(v))
                guard lu > 1e-12, lv > 1e-12 else { return nil }
                let cosTheta = max(-1, min(1, Double(simd_dot(u, v)) / (lu * lv)))
                return acos(cosTheta) * 180 / .pi
            }

            guard la.isFinite, lb.isFinite, lc.isFinite,
                  let aVal = angle(b, c), let bVal = angle(a, c), let gVal = angle(a, b) else {
                latticeA = nil; latticeB = nil; latticeC = nil
                alpha = nil; beta = nil; gamma = nil
                cellVolume = nil; density = nil
                (spaceGroupNumber, spaceGroupSymbol, crystalSystem, bravaisLattice,
                 pointGroup, symmetryOperationCount) = Self.symmetryFields(from: symmetry)
                isCrystal = scene.isCrystal
                return
            }
            latticeA = la; latticeB = lb; latticeC = lc
            alpha = aVal; beta = bVal; gamma = gVal

            let vol = Double(abs(simd_dot(a, simd_cross(b, c))))
            if vol.isFinite, vol > 1e-16 {
                cellVolume = vol
                density = (is3D && !incomplete && allValidZ) ? {
                    var totalMass = 0.0
                    for (z, n) in counts { totalMass += ElementTable.mass(z) * Double(n) }
                    return totalMass / (vol * 0.602214076)
                }() : nil
            } else {
                cellVolume = nil; density = nil
            }
        } else {
            latticeA = nil; latticeB = nil; latticeC = nil
            alpha = nil; beta = nil; gamma = nil
            cellVolume = nil; density = nil
        }

        (spaceGroupNumber, spaceGroupSymbol, crystalSystem, bravaisLattice,
         pointGroup, symmetryOperationCount) = Self.symmetryFields(from: symmetry)
        isCrystal = scene.isCrystal
    }

    private static func symmetryFields(from analysis: CrystalSymmetryAnalysis?)
        -> (Int?, String?, String?, String?, String?, Int?) {
        guard let sym = analysis?.symmetry else {
            return (nil, nil, nil, nil, nil, nil)
        }
        return (sym.spaceGroupNumber, sym.internationalSymbol,
                sym.crystalSystem.label, sym.bravaisLattice.label,
                sym.pointGroupSymbol, sym.symmetryOperations.count)
    }

    private static func hillFormula(counts: [Int: Int]) -> String {
        let entries = counts.keys.map { ($0, ElementTable.symbol($0)) }
        let hasCarbon = counts.keys.contains(6)

        let ordered: [(Int, String)]
        if hasCarbon {
            let carbon = entries.filter { $0.0 == 6 }
            let hydrogen = entries.filter { $0.0 == 1 }
            let rest = entries.filter { $0.0 != 6 && $0.0 != 1 }.sorted { $0.1 < $1.1 }
            ordered = carbon + hydrogen + rest
        } else {
            ordered = entries.sorted { $0.1 < $1.1 }
        }

        return ordered.map { z, sym in
            let n = counts[z]!
            return n == 1 ? sym : "\(sym)\(n)"
        }.joined()
    }
}
