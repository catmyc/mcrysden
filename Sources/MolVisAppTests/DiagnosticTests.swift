import XCTest
import simd
@testable import MolVisApp

final class DiagnosticTests: XCTestCase {
    private func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }
    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func loadCIF(_ content: String) throws -> LoadedScene {
        let url = tmp("diag_\(UUID().uuidString).cif")
        try write(content, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Parser.load(url)
    }
    private let cubicCell = """
        _cell_length_a 5.0
        _cell_length_b 5.0
        _cell_length_c 5.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        """
    private func atomLoop(_ rows: String) -> String {
        """
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        \(rows)
        """
    }

    func testDiagLongLabels() throws {
        let s = try loadCIF("""
            data_diag
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("ABCDEFGH XX 0.1 0.2 0.3\nABCDEFGX XX 0.1 0.2 0.3"))
            """)
        print("LONG_LABELS COUNT: \(s.atoms.count)")
        for (i, a) in s.atoms.enumerated() {
            print("  atom[\(i)] z=\(a.atomicNumber) label='\(a.label)' coord=\(a.coord)")
        }
    }

    func testDiagMissingTypeLongLabels() throws {
        let s = try loadCIF("""
            data_diag_miss
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("ABCDEFGH . 0.1 0.2 0.3\nABCDEFGX . 0.1 0.2 0.3"))
            """)
        print("MISSING_TYPE_LONG_LABELS COUNT: \(s.atoms.count)")
        for (i, a) in s.atoms.enumerated() {
            print("  atom[\(i)] z=\(a.atomicNumber) label='\(a.label)' coord=\(a.coord)")
        }
    }

    func testDiagTypeOverridesLabel() throws {
        // Type "XX" is unresolved, label "Fe1" looks like Fe
        let s = try loadCIF("""
            data_diag_override
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("Fe1 XX 0.1 0.2 0.3\nO1 XX 0.4 0.5 0.6"))
            """)
        print("TYPE_OVERRIDE COUNT: \(s.atoms.count)")
        for (i, a) in s.atoms.enumerated() {
            print("  atom[\(i)] z=\(a.atomicNumber) label='\(a.label)' coord=\(a.coord)")
        }
    }

    func testDiagMissingTypeFallback() throws {
        // No type column: label "Fe1" should resolve to Fe
        let s = try loadCIF("""
            data_diag_fb
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            loop_
            _atom_site_label
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 0.1 0.2 0.3
            """)
        print("MISSING_TYPE_FALLBACK COUNT: \(s.atoms.count)")
        for (i, a) in s.atoms.enumerated() {
            print("  atom[\(i)] z=\(a.atomicNumber) label='\(a.label)' coord=\(a.coord)")
        }
    }

    func testDiagLargeCell() throws {
        // Large cell: 0.12345678901234 and 0.12345678901235 should round to same float
        let s = try loadCIF("""
            data_diag_large
            _cell_length_a 100.0
            _cell_length_b 100.0
            _cell_length_c 100.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("Fe1 Fe 0.12345678901234 0.2 0.3\nFe2 Fe 0.12345678901235 0.2 0.3"))
            """)
        print("LARGE_CELL COUNT: \(s.atoms.count)")
        for (i, a) in s.atoms.enumerated() {
            print("  atom[\(i)] z=\(a.atomicNumber) label='\(a.label)' coord=\(a.coord)")
        }
    }

    func testDiagCharged() throws {
        let s = try loadCIF("""
            data_diag_charged
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("A1 Fe3+ 0.1 0.2 0.3\nB1 O2- 0.4 0.5 0.6"))
            """)
        print("CHARGED COUNT: \(s.atoms.count)")
        for (i, a) in s.atoms.enumerated() {
            print("  atom[\(i)] z=\(a.atomicNumber) label='\(a.label)' coord=\(a.coord)")
        }
    }
}
