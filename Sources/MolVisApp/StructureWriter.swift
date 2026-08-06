
import Foundation
import simd

/// A structure-export format. `label`/`fileExtension` feed the export UI's
/// picker and the on-disk filename; the writer matches each format exactly to
/// what its parser accepts so files round-trip.
enum StructureExportFormat: String, CaseIterable, Equatable {
    case xsf, cif, poscar, xyz, qeInput
    var label: String {
        switch self {
        case .xsf: return "XSF"
        case .cif: return "CIF"
        case .poscar: return "POSCAR"
        case .xyz: return "XYZ"
        case .qeInput: return "QE PWscf input"
        }
    }
    var fileExtension: String {
        switch self {
        case .xsf: return "xsf"
        case .cif: return "cif"
        case .poscar: return "poscar"
        case .xyz: return "xyz"
        case .qeInput: return "in"
        }
    }
}

/// Errors from `StructureWriter`. `description` is user-facing (CLI/UI), so it
/// names the offending format/atom rather than exposing internals.
enum StructureWriteError: Error, Equatable, CustomStringConvertible {
    case emptyAtoms
    case requiresCrystal(String)
    case nonFiniteGeometry
    case singularCell
    case invalidElement(Int)
    var description: String {
        switch self {
        case .emptyAtoms: return "no atoms to export"
        case .requiresCrystal(let name): return "\(name) export requires a unit cell"
        case .nonFiniteGeometry: return "structure contains a non-finite value"
        case .singularCell: return "unit cell is singular"
        case .invalidElement(let i): return "atom \(i) has an invalid atomic number"
        }
    }
}

/// Serializes a structure to text in any of the supported formats. Coordinates
/// are Å throughout; fractional formats convert via the cell's inverse.
enum StructureWriter {
    /// Serialize a scene.
    static func write(_ scene: Scene, as format: StructureExportFormat) throws -> String {
        try write(atoms: scene.atoms, cell: scene.cell, title: scene.title,
                  isCrystal: scene.isCrystal, periodicDim: scene.periodicDim, as: format)
    }

    /// Lower-level variant for callers without a Scene.
    static func write(atoms: [Atom], cell: Cell?, title: String, isCrystal: Bool,
                      periodicDim: Int, as format: StructureExportFormat) throws -> String {
        guard !atoms.isEmpty else { throw StructureWriteError.emptyAtoms }
        for (i, a) in atoms.enumerated() {
            guard a.atomicNumber >= 1 && a.atomicNumber <= 118 else {
                throw StructureWriteError.invalidElement(i)
            }
            guard a.coord.x.isFinite && a.coord.y.isFinite && a.coord.z.isFinite else {
                throw StructureWriteError.nonFiniteGeometry
            }
        }
        switch format {
        case .xsf:
            return writeXSF(atoms, cell: cell)
        case .xyz:
            return writeXYZ(atoms, title: title)
        case .cif:
            let cell = try requireCell(cell, format)
            try validateCell(cell)
            return writeCIF(atoms, cell: cell, title: title)
        case .poscar:
            let cell = try requireCell(cell, format)
            try validateCell(cell)
            return writePOSCAR(atoms, cell: cell, title: title)
        case .qeInput:
            let cell = try requireCell(cell, format)
            try validateCell(cell)
            return writeQE(atoms, cell: cell)
        }
    }

    private static func requireCell(_ cell: Cell?, _ format: StructureExportFormat) throws -> Cell {
        guard let cell else { throw StructureWriteError.requiresCrystal(format.label) }
        return cell
    }

    /// Reject a non-finite or zero-volume (scale-invariant) cell.
    private static func validateCell(_ cell: Cell) throws {
        let comps = [cell.a.x, cell.a.y, cell.a.z, cell.b.x, cell.b.y, cell.b.z,
                     cell.c.x, cell.c.y, cell.c.z]
        guard comps.allSatisfy({ $0.isFinite }) else { throw StructureWriteError.nonFiniteGeometry }
        let vol = abs(dot(cell.a, cross(cell.b, cell.c)))
        let scale = length(cell.a) * length(cell.b) * length(cell.c)
        guard scale > 0, vol / scale > 1e-12 else { throw StructureWriteError.singularCell }
    }

    private static func writeXSF(_ atoms: [Atom], cell: Cell?) -> String {
        var out = ""
        if let cell {
            out += "CRYSTAL\nPRIMVEC\n"
            out += row(cell.a) + "\n"
            out += row(cell.b) + "\n"
            out += row(cell.c) + "\n"
            out += "PRIMCOORD\n\(atoms.count) 1\n"
            for a in atoms {
                out += "\(a.atomicNumber) \(row(a.coord))\n"
            }
        } else {
            // The parser reads an ATOMS block as a stream of atom lines (no
            // count line), so emit exactly that.
            out += "ATOMS\n"
            for a in atoms {
                out += "\(a.atomicNumber) \(row(a.coord))\n"
            }
        }
        return out
    }

    private static func writeXYZ(_ atoms: [Atom], title: String) -> String {
        var out = "\(atoms.count)\n\(title)\n"
        for a in atoms {
            out += "\(ElementTable.symbol(a.atomicNumber)) \(row(a.coord))\n"
        }
        return out
    }

    private static func writeCIF(_ atoms: [Atom], cell: Cell, title: String) -> String {
        let (a, b, c) = cellLengths(cell)
        let (alpha, beta, gamma) = cellAngles(cell)
        var out = "data_\(sanitizeTitle(title))\n"
        out += "_cell_length_a    \(fmt(a))\n"
        out += "_cell_length_b    \(fmt(b))\n"
        out += "_cell_length_c    \(fmt(c))\n"
        out += "_cell_angle_alpha \(fmt(alpha))\n"
        out += "_cell_angle_beta  \(fmt(beta))\n"
        out += "_cell_angle_gamma \(fmt(gamma))\n"
        out += "_symmetry_space_group_name_H-M  'P 1'\n"
        out += "_symmetry_Int_Tables_number     1\n"
        out += "loop_\n"
        out += "_atom_site_label\n"
        out += "_atom_site_type_symbol\n"
        out += "_atom_site_fract_x\n"
        out += "_atom_site_fract_y\n"
        out += "_atom_site_fract_z\n"
        let inv = cellInverse(cell)
        for (i, atom) in atoms.enumerated() {
            let f = inv * SIMD3(Double(atom.coord.x), Double(atom.coord.y), Double(atom.coord.z))
            let sym = ElementTable.symbol(atom.atomicNumber)
            out += "\(sym)\(i + 1) \(sym) \(fmt(f.x)) \(fmt(f.y)) \(fmt(f.z))\n"
        }
        return out
    }

    private static func writePOSCAR(_ atoms: [Atom], cell: Cell, title: String) -> String {
        var out = "\(title)\n1.0\n"
        out += row(cell.a) + "\n"
        out += row(cell.b) + "\n"
        out += row(cell.c) + "\n"
        var species: [Int] = []
        var counts: [Int] = []
        for a in atoms {
            if let j = species.firstIndex(of: a.atomicNumber) {
                counts[j] += 1
            } else {
                species.append(a.atomicNumber)
                counts.append(1)
            }
        }
        out += species.map { ElementTable.symbol($0) }.joined(separator: " ") + "\n"
        out += counts.map { String($0) }.joined(separator: " ") + "\n"
        out += "Direct\n"
        let inv = cellInverse(cell)
        for s in species {
            for a in atoms where a.atomicNumber == s {
                let f = inv * SIMD3(Double(a.coord.x), Double(a.coord.y), Double(a.coord.z))
                out += "\(fmt(f.x)) \(fmt(f.y)) \(fmt(f.z))\n"
            }
        }
        return out
    }

    private static func writeQE(_ atoms: [Atom], cell: Cell) -> String {
        var species: [Int] = []
        for a in atoms where !species.contains(a.atomicNumber) { species.append(a.atomicNumber) }
        var out = "&CONTROL\n"
        out += "  calculation = 'scf'\n"
        out += "  prefix = 'mcrysden'\n"
        out += "  pseudo_dir = './'\n"
        out += "  outdir = './'\n"
        out += "/\n"
        out += "&SYSTEM\n"
        out += "  ibrav = 0\n"
        out += "  nat = \(atoms.count)\n"
        out += "  ntyp = \(species.count)\n"
        out += "  ecutwfc = 40\n"
        out += "/\n"
        out += "&ELECTRONS\n"
        out += "  conv_thr = 1.0d-8\n"
        out += "/\n"
        out += "ATOMIC_SPECIES\n"
        for z in species {
            let sym = ElementTable.symbol(z)
            out += "  \(sym) \(fmt(ElementTable.mass(z))) \(sym).UPF\n"
        }
        out += "ATOMIC_POSITIONS crystal\n"
        let inv = cellInverse(cell)
        for a in atoms {
            let f = inv * SIMD3(Double(a.coord.x), Double(a.coord.y), Double(a.coord.z))
            out += "  \(ElementTable.symbol(a.atomicNumber)) \(fmt(f.x)) \(fmt(f.y)) \(fmt(f.z))\n"
        }
        out += "CELL_PARAMETERS angstrom\n"
        out += "  \(row(cell.a))\n"
        out += "  \(row(cell.b))\n"
        out += "  \(row(cell.c))\n"
        out += "K_POINTS gamma\n"
        return out
    }

    // MARK: - Geometry helpers

    private static func cellLengths(_ cell: Cell) -> (Double, Double, Double) {
        (Double(length(cell.a)), Double(length(cell.b)), Double(length(cell.c)))
    }

    private static func cellAngles(_ cell: Cell) -> (Double, Double, Double) {
        (angle(cell.b, cell.c), angle(cell.a, cell.c), angle(cell.a, cell.b))
    }

    private static func cellInverse(_ cell: Cell) -> simd_double3x3 {
        simd_double3x3(columns: (
            SIMD3(Double(cell.a.x), Double(cell.a.y), Double(cell.a.z)),
            SIMD3(Double(cell.b.x), Double(cell.b.y), Double(cell.b.z)),
            SIMD3(Double(cell.c.x), Double(cell.c.y), Double(cell.c.z)))).inverse
    }

    /// Keep only alphanumerics + underscore for a CIF `data_` block; fall back to
    /// "exported" when nothing survives.
    private static func sanitizeTitle(_ title: String) -> String {
        let kept = title.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
        let out = String(String.UnicodeScalarView(kept))
        return out.isEmpty ? "exported" : out
    }
}

private func angle(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> Double {
    let cos = simd_dot(u, v) / (length(u) * length(v))
    return acos(Double(max(-1, min(1, cos)))) * 180 / .pi
}

private func row(_ v: SIMD3<Float>) -> String { "\(fmt(Double(v.x))) \(fmt(Double(v.y))) \(fmt(Double(v.z)))" }

private func fmt(_ v: Double) -> String { String(format: "%.6f", v) }
