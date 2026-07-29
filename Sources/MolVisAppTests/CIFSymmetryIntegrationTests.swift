import XCTest
import simd
@testable import MolVisApp

/// Integration tests for the declared-operation CIF expansion and completeness
/// bridging feature. These tests verify that the CIF parser reads declared
/// symmetry operations (`_symmetry_equiv_pos_as_xyz`), expands the asymmetric
/// unit by applying those operations, and only marks the scene `.complete`
/// when the declared operations form a valid group compatible with the
/// declared lattice. Operations that are not a valid group — missing identity,
/// not closed under composition, or lattice-incompatible — must not be
/// promoted to `.complete` or reach symmetry analysis.
final class CIFSymmetryIntegrationTests: XCTestCase {

    private func writeCIF(_ content: String, name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)_\(name)")
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Asserts that a CIF whose declared symmetry operations are not a valid
    /// group (or are lattice-incompatible) is either rejected with a
    /// ParseError, or — if parsed — is not promoted to `.complete` and does
    /// not reach symmetry analysis. When the load throws, the error must be a
    /// `ParseError.parse` whose reason is nonempty and contains
    /// `expectedConcept` — this stops an unrelated parser failure (e.g. a
    /// malformed-cell error) from satisfying a group-validation case.
    private func assertInvalidOperationsNotPromoted(
        _ content: String, name: String,
        expectedConcept: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        let url = writeCIF(content, name: name)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let loaded = try Parser.load(url)
            XCTAssertNotEqual(loaded.symmetryInputCompleteness, .complete,
                              "invalid operations must not be promoted to complete",
                              file: file, line: line)
            let scene = Scene(loaded: loaded)
            XCTAssertNil(scene.crystalSymmetry?.symmetry,
                         "invalid operations must not reach symmetry analysis",
                         file: file, line: line)
        } catch {
            guard case let ParseError.parse(_, _, reason) = error else {
                XCTFail("expected ParseError.parse for invalid operations, got \(error)",
                        file: file, line: line)
                return
            }
            XCTAssertFalse(reason.isEmpty,
                           "ParseError.parse reason must be nonempty",
                           file: file, line: line)
            XCTAssertTrue(reason.localizedCaseInsensitiveContains(expectedConcept),
                          "expected ParseError.parse reason to contain '\(expectedConcept)', got '\(reason)'",
                          file: file, line: line)
        }
    }

    /// A CIF declaring P-1 operations (identity + inversion) with one atom at a
    /// general position should expand to two atoms, be marked `.complete`, and
    /// reach spglib with a non-nil, inversion-capable result.
    func testP1InversionCIFExpandsAndReachesSpglib() throws {
        let url = writeCIF("""
        data_p1_inversion
        _cell_length_a 5.0
        _cell_length_b 6.0
        _cell_length_c 7.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -x,-y,-z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "p1_inversion.cif")
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try Parser.load(url)
        XCTAssertEqual(loaded.symmetryInputCompleteness, .complete)
        XCTAssertEqual(loaded.atoms.count, 2, "P-1 expansion should double a general-position atom")

        let scene = Scene(loaded: loaded)
        let symmetry = try XCTUnwrap(scene.crystalSymmetry?.symmetry, "P-1 should reach spglib")
        XCTAssertEqual(symmetry.spaceGroupNumber, 2, "expected P-1 (space group 2)")
        XCTAssertEqual(symmetry.crystalSystem, .triclinic)

        // P-1 has two operations: identity and inversion. Inversion carries a
        // -1 determinant rotation.
        let hasInversion = symmetry.symmetryOperations.contains { op in
            guard op.rotation.count == 9 else { return false }
            let r = op.rotation
            let det = r[0] * (r[4] * r[8] - r[5] * r[7])
                    - r[1] * (r[3] * r[8] - r[5] * r[6])
                    + r[2] * (r[3] * r[7] - r[4] * r[6])
            return det == -1
        }
        XCTAssertTrue(hasInversion, "P-1 must contain an inversion operation")
    }

    /// A CIF declaring only the identity operation with a simple-cubic atom
    /// arrangement should be marked `.complete`, get a symmetry analysis, and
    /// seed a nonempty canonical k-path.
    func testIdentityDeclaredSimpleCubicIsCompleteAndSeedsKPath() throws {
        let url = writeCIF("""
        data_identity_sc
        _cell_length_a 4.0
        _cell_length_b 4.0
        _cell_length_c 4.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Na1 Na 0.0 0.0 0.0
        """, name: "identity_sc.cif")
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try Parser.load(url)
        XCTAssertEqual(loaded.symmetryInputCompleteness, .complete)

        let scene = Scene(loaded: loaded)
        let symmetry = try XCTUnwrap(scene.crystalSymmetry?.symmetry, "identity-declared cubic should analyze")
        XCTAssertEqual(symmetry.crystalSystem, .cubic)
        XCTAssertGreaterThan(scene.kPathPoints.count, 0, "cubic crystal should seed a nonempty k-path")
    }

    /// A CIF with no declared symmetry operations should remain `.unknown`,
    /// leave symmetry unavailable, and produce an empty generated k-path.
    func testNoDeclaredOperationsRemainsUnknown() throws {
        let url = writeCIF("""
        data_no_operations
        _cell_length_a 4.0
        _cell_length_b 4.0
        _cell_length_c 4.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Pt1 Pt 0.0 0.0 0.0
        """, name: "no_operations.cif")
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try Parser.load(url)
        XCTAssertEqual(loaded.symmetryInputCompleteness, .unknown)

        let scene = Scene(loaded: loaded)
        XCTAssertNil(scene.crystalSymmetry?.symmetry, "no operations -> symmetry unavailable")
        XCTAssertEqual(scene.crystalSymmetry?.unavailableReason, .incompleteInput(.unknown))
        XCTAssertTrue(scene.kPathPoints.isEmpty, "no symmetry -> empty generated k-path")
    }

    /// After P-1 expansion, the structure summary should reflect the expanded
    /// atom count and the detected symmetry.
    func testStructureSummaryReflectsExpandedCountAndSymmetry() throws {
        let url = writeCIF("""
        data_p1_summary
        _cell_length_a 5.0
        _cell_length_b 6.0
        _cell_length_c 7.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -x,-y,-z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "p1_summary.cif")
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try Parser.load(url)
        let scene = Scene(loaded: loaded)
        let summary = try XCTUnwrap(StructureSummary(scene, symmetry: scene.crystalSymmetry))

        XCTAssertEqual(summary.atomCount, 2, "summary should reflect the expanded count")
        XCTAssertEqual(summary.formula, "Fe2")
        XCTAssertEqual(summary.spaceGroupNumber, 2, "summary should reflect P-1")
        XCTAssertEqual(summary.crystalSystem, "Triclinic")
        XCTAssertFalse(summary.isAsymmetricUnit, "expanded structure is not an asymmetric unit")
    }

    // MARK: - Invalid operation sets must not be promoted to complete

    /// A CIF that declares only a non-identity operation (inversion) without
    /// the identity does not form a group and must not be promoted to
    /// `.complete` or reach symmetry analysis.
    func testMissingIdentityNotPromoted() throws {
        assertInvalidOperationsNotPromoted("""
        data_missing_identity
        _cell_length_a 5.0
        _cell_length_b 5.0
        _cell_length_c 5.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 -x,-y,-z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "missing_identity.cif", expectedConcept: "identity")
    }

    /// A CIF that declares an operation set that is not closed under
    /// composition (identity + 90° rotation about z, but missing the 180° and
    /// 270° rotations) does not form a group and must not be promoted.
    func testNonClosedOperationsNotPromoted() throws {
        assertInvalidOperationsNotPromoted("""
        data_non_closed
        _cell_length_a 5.0
        _cell_length_b 5.0
        _cell_length_c 5.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -y,x,z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "non_closed.cif", expectedConcept: "closed")
    }

    /// A CIF that declares a 4-fold rotation about z on a cell where a != b
    /// (orthorhombic, not tetragonal) has operations incompatible with the
    /// declared lattice and must not be promoted.
    func testLatticeIncompatibleOperationsNotPromoted() throws {
        assertInvalidOperationsNotPromoted("""
        data_incompatible_lattice
        _cell_length_a 5.0
        _cell_length_b 6.0
        _cell_length_c 7.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -y,x,z
        3 -x,-y,z
        4 y,-x,z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "incompatible_lattice.cif", expectedConcept: "metric")
    }

    /// A CIF that declares a single non-identity translation (no identity, not
    /// a group) must not be promoted to `.complete` or reach symmetry.
    func testIncompleteNonGroupNotPromoted() throws {
        assertInvalidOperationsNotPromoted("""
        data_incomplete_nongroup
        _cell_length_a 5.0
        _cell_length_b 5.0
        _cell_length_c 5.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x+1/2,y,z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "incomplete_nongroup.cif", expectedConcept: "identity")
    }

    // MARK: - Second-review completeness and metric regressions

    /// A CIF that declares symmetry operations but omits one or more cell angles
    /// must not be promoted to `.complete` or reach symmetry analysis. The
    /// parser defaults missing angles to 90°, so an omitted angle would silently
    /// produce a metric the analyser treats as known unless completeness guards
    /// against it.
    func testMissingCellAngleNotPromoted() throws {
        assertInvalidOperationsNotPromoted("""
        data_missing_gamma
        _cell_length_a 5.0
        _cell_length_b 6.0
        _cell_length_c 7.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -x,-y,-z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "missing_gamma.cif", expectedConcept: "cell")
    }

    /// An extreme anisotropic cell (one axis far longer than the others) must
    /// still reject an operation that swaps two inequivalent short axes, even
    /// though the dominant axis inflates the metric tolerance (`mtol` scales
    /// with `gmax`, the largest metric diagonal element). A naive per-tolerance
    /// check lets a b/c swap slip through when `a` is huge.
    func testExtremeAnisotropicRejectsAxisSwap() throws {
        assertInvalidOperationsNotPromoted("""
        data_anisotropic_swap
        _cell_length_a 100000.0
        _cell_length_b 3.0
        _cell_length_c 4.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 x,z,y
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "anisotropic_swap.cif", expectedConcept: "metric")
    }

    /// A valid identity/inversion group on a moderately anisotropic cell
    /// (non-orthogonal angles) must still expand and reach symmetry analysis.
    /// The metric check must not be so strict that legitimate operations on
    /// anisotropic lattices are rejected: inversion preserves any metric.
    func testModeratelyAnisotropicP1ExpandsAndAnalyzes() throws {
        let url = writeCIF("""
        data_anisotropic_p1
        _cell_length_a 5.0
        _cell_length_b 6.0
        _cell_length_c 7.0
        _cell_angle_alpha 80.0
        _cell_angle_beta 85.0
        _cell_angle_gamma 87.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -x,-y,-z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "anisotropic_p1.cif")
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try Parser.load(url)
        XCTAssertEqual(loaded.symmetryInputCompleteness, .complete)
        XCTAssertEqual(loaded.atoms.count, 2, "P-1 expansion should double a general-position atom")

        let scene = Scene(loaded: loaded)
        let symmetry = try XCTUnwrap(scene.crystalSymmetry?.symmetry,
                                     "P-1 on an anisotropic cell should reach spglib")
        XCTAssertEqual(symmetry.spaceGroupNumber, 2, "expected P-1 (space group 2)")
        XCTAssertEqual(symmetry.crystalSystem, .triclinic)
    }

    // MARK: - Invalid cell geometry must not be promoted to complete or reach symmetry

    /// Asserts that a CIF with invalid cell geometry (non-positive lengths,
    /// out-of-range angles, or a degenerate/impossible metric) is either
    /// rejected with a ParseError, or — if parsed — is not promoted to
    /// `.complete` and does not reach symmetry analysis. When the load
    /// throws, the error must be a `ParseError.parse` whose reason is
    /// nonempty and contains `expectedConcept` (a metric/cell concept) so an
    /// unrelated group-validation failure cannot satisfy the case.
    private func assertInvalidCellGeometryNotPromoted(
        _ content: String, name: String,
        expectedConcept: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        let url = writeCIF(content, name: name)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let loaded = try Parser.load(url)
            XCTAssertNotEqual(loaded.symmetryInputCompleteness, .complete,
                              "invalid cell geometry must not be promoted to complete",
                              file: file, line: line)
            let scene = Scene(loaded: loaded)
            XCTAssertNil(scene.crystalSymmetry?.symmetry,
                         "invalid cell geometry must not reach symmetry analysis",
                         file: file, line: line)
        } catch {
            guard case let ParseError.parse(_, _, reason) = error else {
                XCTFail("expected ParseError.parse for invalid cell geometry, got \(error)",
                        file: file, line: line)
                return
            }
            XCTAssertFalse(reason.isEmpty,
                           "ParseError.parse reason must be nonempty",
                           file: file, line: line)
            XCTAssertTrue(reason.localizedCaseInsensitiveContains(expectedConcept),
                          "expected ParseError.parse reason to contain '\(expectedConcept)', got '\(reason)'",
                          file: file, line: line)
        }
    }

    /// A CIF with a zero-length cell axis must be rejected or not promoted.
    func testZeroCellLengthNotPromoted() throws {
        assertInvalidCellGeometryNotPromoted("""
        data_zero_length
        _cell_length_a 0.0
        _cell_length_b 6.0
        _cell_length_c 7.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -x,-y,-z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "zero_length.cif", expectedConcept: "cell")
    }

    /// A CIF with a negative cell length must be rejected or not promoted.
    func testNegativeCellLengthNotPromoted() throws {
        assertInvalidCellGeometryNotPromoted("""
        data_negative_length
        _cell_length_a -5.0
        _cell_length_b 6.0
        _cell_length_c 7.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -x,-y,-z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "negative_length.cif", expectedConcept: "cell")
    }

    /// A CIF with a cell angle of exactly 0° must be rejected or not promoted.
    func testZeroCellAngleNotPromoted() throws {
        assertInvalidCellGeometryNotPromoted("""
        data_zero_angle
        _cell_length_a 5.0
        _cell_length_b 6.0
        _cell_length_c 7.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 0.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -x,-y,-z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "zero_angle.cif", expectedConcept: "cell")
    }

    /// A CIF with a cell angle of exactly 180° must be rejected or not promoted.
    func test180CellAngleNotPromoted() throws {
        assertInvalidCellGeometryNotPromoted("""
        data_180_angle
        _cell_length_a 5.0
        _cell_length_b 6.0
        _cell_length_c 7.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 180.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -x,-y,-z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "180_angle.cif", expectedConcept: "cell")
    }

    /// A CIF with an impossible angle triple (negative Gram determinant, e.g.
    /// 10°/10°/170°) produces a degenerate cell and must be rejected.
    func testImpossibleAngleTripleNotPromoted() throws {
        assertInvalidCellGeometryNotPromoted("""
        data_impossible_angles
        _cell_length_a 5.0
        _cell_length_b 6.0
        _cell_length_c 7.0
        _cell_angle_alpha 10.0
        _cell_angle_beta 10.0
        _cell_angle_gamma 170.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -x,-y,-z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "impossible_angles.cif", expectedConcept: "cell")
    }

    /// A CIF with a near-degenerate cell — all angles 179° on equal lengths
    /// gives a clearly negative Gram determinant and must be rejected.
    func testNearDegenerateCellGeometryNotPromoted() throws {
        assertInvalidCellGeometryNotPromoted("""
        data_near_degenerate_cell
        _cell_length_a 5.0
        _cell_length_b 5.0
        _cell_length_c 5.0
        _cell_angle_alpha 179.0
        _cell_angle_beta 179.0
        _cell_angle_gamma 179.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -x,-y,-z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "near_degenerate_cell.cif", expectedConcept: "cell")
    }

    /// A valid but highly anisotropic cell (1:10:50 with non-orthogonal
    /// angles) with identity + inversion must still expand and reach symmetry
    /// analysis. Guards against over-rejection of extreme but valid metrics.
    func testHighlyAnisotropicIdentityInversionAnalyzes() throws {
        let url = writeCIF("""
        data_highly_anisotropic_p1
        _cell_length_a 1.0
        _cell_length_b 10.0
        _cell_length_c 50.0
        _cell_angle_alpha 80.0
        _cell_angle_beta 85.0
        _cell_angle_gamma 87.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -x,-y,-z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "highly_anisotropic_p1.cif")
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try Parser.load(url)
        XCTAssertEqual(loaded.symmetryInputCompleteness, .complete)
        XCTAssertEqual(loaded.atoms.count, 2, "P-1 expansion should double a general-position atom")

        let scene = Scene(loaded: loaded)
        let symmetry = try XCTUnwrap(scene.crystalSymmetry?.symmetry,
                                     "P-1 on a highly anisotropic cell should reach spglib")
        XCTAssertEqual(symmetry.spaceGroupNumber, 2, "expected P-1 (space group 2)")
        XCTAssertEqual(symmetry.crystalSystem, .triclinic)
    }

    /// A valid non-orthogonal hexagonal cell (a = b, gamma = 120 degrees) with a
    /// closed C6 rotation group declared explicitly must pass the float-rounded
    /// metric validation, expand a general-position atom to six images, be marked
    /// `.complete`, and reach symmetry analysis. The generator `x-y,x,z`
    /// produces a 6-fold rotation about z; all powers and the identity are
    /// declared so the set is closed under composition.
    func testHexagonalC6DeclaredGroupExpandsAndAnalyzes() throws {
        let url = writeCIF("""
        data_hex_c6
        _cell_length_a 4.0
        _cell_length_b 4.0
        _cell_length_c 5.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 120.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 x-y,x,z
        3 -y,x-y,z
        4 -x,-y,z
        5 -x+y,-x,z
        6 y,-x+y,z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "hex_c6.cif")
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try Parser.load(url)
        XCTAssertEqual(loaded.symmetryInputCompleteness, .complete)
        XCTAssertEqual(loaded.atoms.count, 6,
                       "C6 expansion should produce six images of a general-position atom")

        let scene = Scene(loaded: loaded)
        let symmetry = try XCTUnwrap(scene.crystalSymmetry?.symmetry,
                                     "hexagonal C6 group should reach spglib despite float-rounded metric")
        XCTAssertEqual(symmetry.crystalSystem, .hexagonal)
    }

    // MARK: - Quoted-underscore loop-value regression

    /// A quoted atom label that begins with an underscore (e.g. `'_site'`) must
    /// be parsed as row DATA, not reinterpreted as a loop_ header. The header
    /// detection in `LOOP_HDRS` gates on `!ctx.quoted`, so a quoted
    /// underscore-prefixed token falls through to the data row. If that guard
    /// were dropped, the token would be consumed as a spurious column header
    /// and the row would fail to parse.
    func testQuotedUnderscoreLabelParsedAsRowData() throws {
        let url = writeCIF("""
        data_quoted_label
        _cell_length_a 5.0
        _cell_length_b 6.0
        _cell_length_c 7.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        loop_
        _atom_site_label
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        '_site' 0.1 0.2 0.3
        """, name: "quoted_label.cif")
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try Parser.load(url)
        XCTAssertEqual(loaded.atoms.count, 1,
                       "quoted '_site' must be consumed as a data row, not a header")
        XCTAssertEqual(loaded.atoms[0].label, "_site",
                       "the quoted label must reach the atom unchanged")
    }

    // MARK: - Component-scale-relative metric validation on a tiny cell

    /// A cell with tiny positive lengths (0.001, 0.002, 0.003 Å) is geometrically
    /// valid, yet a 4-fold rotation about z still requires a == b and must be
    /// rejected as lattice-incompatible. The metric tolerance is component-local
    /// (`mtol = 8*eps*sqrt(G[i][i]*G[j][j])`), so it scales DOWN with a tiny cell
    /// and rejects a swap that a naive global-gmax tolerance would wrongly admit.
    /// Proves the validation is scale-relative rather than absolute.
    func testTinyPositiveCellRejectsLatticeIncompatibleOperation() throws {
        assertInvalidOperationsNotPromoted("""
        data_tiny_incompatible
        _cell_length_a 0.001
        _cell_length_b 0.002
        _cell_length_c 0.003
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0
        loop_
        _symmetry_equiv_pos_site_id
        _symmetry_equiv_pos_as_xyz
        1 x,y,z
        2 -y,x,z
        3 -x,-y,z
        4 y,-x,z
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.1 0.2 0.3
        """, name: "tiny_incompatible.cif", expectedConcept: "metric")
    }
}
