import XCTest
import simd
@testable import MolVisApp

/// Parser-level tests for CIF symmetry-operation expansion.
///
/// These verify the production CIF path:
///   (a) parses declared `_symmetry_equiv_pos_as_xyz` operations from both the
///       modern `loop_` form and the legacy single-tag form,
///   (b) expands each asymmetric-unit site by applying every operation,
///       wrapping the resulting fractional coordinates to [0, 1) and
///       deduplicating coincident positions,
///   (c) marks `LoadedScene.symmetryInputCompleteness == .complete` when
///       operations were present and expanded.
final class CIFSymmetryParserTests: XCTestCase {

    // MARK: - Helpers

    private func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A 5 Å cubic cell: fractional (x, y, z) maps to Cartesian (5x, 5y, 5z).
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

    private func loadCIF(_ content: String) throws -> LoadedScene {
        let url = tmp("cif_symmetry_\(UUID().uuidString).cif")
        try write(content, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Parser.load(url)
    }

    // MARK: - Modern loop form

    /// Modern loop: inversion expands a general site into two positions in
    /// deterministic declaration order.
    func testModernLoopInversionExpandsGeneralSite() throws {
        let s = try loadCIF("""
            data_modern_inv
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            2 '-x, -y, -z'
            \(atomLoop("Fe1 Fe 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertNotNil(s.cell)
        XCTAssertEqual(s.cell!.a.x, 5.0, accuracy: 0.001)
        XCTAssertEqual(s.atoms.count, 2)
        XCTAssertTrue(s.atoms.allSatisfy { $0.atomicNumber == 26 })
        // Identity  -> (0.1, 0.2, 0.3) -> (0.5, 1.0, 1.5)
        XCTAssertEqual(s.atoms[0].coord.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(s.atoms[0].coord.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[0].coord.z, 1.5, accuracy: 0.001)
        // Inversion -> (-0.1, -0.2, -0.3) -> wrapped (0.9, 0.8, 0.7) -> (4.5, 4.0, 3.5)
        XCTAssertEqual(s.atoms[1].coord.x, 4.5, accuracy: 0.001)
        XCTAssertEqual(s.atoms[1].coord.y, 4.0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[1].coord.z, 3.5, accuracy: 0.001)
    }

    // MARK: - Legacy tag form

    /// Legacy single-tag form expands identically to the loop form.
    func testLegacyTagInversionExpandsGeneralSite() throws {
        let s = try loadCIF("""
            data_legacy_inv
            \(cubicCell)
            _symmetry_equiv_pos_site_id 1
            _symmetry_equiv_pos_as_xyz 'x, y, z'
            _symmetry_equiv_pos_site_id 2
            _symmetry_equiv_pos_as_xyz '-x, -y, -z'
            \(atomLoop("Fe1 Fe 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 2)
        XCTAssertTrue(s.atoms.allSatisfy { $0.atomicNumber == 26 })
        XCTAssertEqual(s.atoms[0].coord.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(s.atoms[0].coord.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[0].coord.z, 1.5, accuracy: 0.001)
        XCTAssertEqual(s.atoms[1].coord.x, 4.5, accuracy: 0.001)
        XCTAssertEqual(s.atoms[1].coord.y, 4.0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[1].coord.z, 3.5, accuracy: 0.001)
    }

    // MARK: - Identity only

    /// Identity-only operation marks the input complete and does not duplicate.
    func testIdentityOnlyMarksCompleteWithoutDuplication() throws {
        let s = try loadCIF("""
            data_identity
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("Fe1 Fe 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].atomicNumber, 26)
        XCTAssertEqual(s.atoms[0].coord.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(s.atoms[0].coord.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[0].coord.z, 1.5, accuracy: 0.001)
    }

    // MARK: - Deduplication

    /// Duplicate operations collapse to a single site.
    func testDuplicateOperationsDeduplicate() throws {
        let s = try loadCIF("""
            data_dup_ops
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            2 'x, y, z'
            \(atomLoop("Fe1 Fe 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].coord.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(s.atoms[0].coord.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[0].coord.z, 1.5, accuracy: 0.001)
    }

    /// Inversion on a special position (origin) deduplicates to one site.
    func testInversionSpecialPositionDeduplicates() throws {
        let s = try loadCIF("""
            data_inv_origin
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            2 '-x, -y, -z'
            \(atomLoop("Fe1 Fe 0.0 0.0 0.0"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].coord.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[0].coord.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[0].coord.z, 0.0, accuracy: 0.001)
    }

    // MARK: - Nonsymmorphic translation + axis permutation

    /// A complete finite lattice-compatible group with an order-two operation
    /// (identity plus a signed-axis inversion with fractional translation) parses
    /// and expands.
    func testNonsymmorphicTranslationAndPermutation() throws {
        let s = try loadCIF("""
            data_nonsymmorphic_screw
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            2 '-x, -y, -z+1/2'
            \(atomLoop("Fe1 Fe 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 2)
        XCTAssertTrue(s.atoms.allSatisfy { $0.atomicNumber == 26 })
        // Identity             -> (0.1, 0.2, 0.3)     -> (0.5, 1.0, 1.5)
        XCTAssertEqual(s.atoms[0].coord.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(s.atoms[0].coord.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[0].coord.z, 1.5, accuracy: 0.001)
        // -x,-y,-z+1/2 -> (-0.1, -0.2, 0.2) -> wrapped (0.9, 0.8, 0.2) -> (4.5, 4.0, 1.0)
        XCTAssertEqual(s.atoms[1].coord.x, 4.5, accuracy: 0.001)
        XCTAssertEqual(s.atoms[1].coord.y, 4.0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[1].coord.z, 1.0, accuracy: 0.001)
    }

    // MARK: - Different species not merged

    /// Different species declared at the same site are not collapsed.
    func testDifferentSpeciesAtSameSiteNotMerged() throws {
        let s = try loadCIF("""
            data_mixed_species
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("Fe1 Fe 0.1 0.2 0.3\nO1  O  0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 2)
        let species = s.atoms.map { $0.atomicNumber }.sorted()
        XCTAssertEqual(species, [8, 26])  // O and Fe
        for a in s.atoms {
            XCTAssertEqual(a.coord.x, 0.5, accuracy: 0.001)
            XCTAssertEqual(a.coord.y, 1.0, accuracy: 0.001)
            XCTAssertEqual(a.coord.z, 1.5, accuracy: 0.001)
        }
    }

    // MARK: - Periodic dedup beyond exact bins

    /// Two input sites straddling a 1e-4 quantization boundary are not merged
    /// by global periodic dedup: they land in different buckets and are
    /// genuinely distinct.
    func testQuantizationBoundaryDistinctSitesKeptSeparate() throws {
        let s = try loadCIF("""
            data_quant_boundary
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("Fe1 Fe 0.12344 0.2 0.3\nFe2 Fe 0.12346 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        // 0.12344 and 0.12346 differ by 1e-4 Å — well outside 1e-5 tolerance.
        XCTAssertEqual(s.atoms.count, 2)
    }

    /// Positions equivalent across the 0/1 periodic boundary deduplicate.
    func testPositionsEquivalentAcrossZeroOneDeduplicated() throws {
        let s = try loadCIF("""
            data_wrap_zero_one
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("Fe1 Fe 0.0001 0.2 0.3\nFe2 Fe 1.0001 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        // 0.0001 and 1.0001 wrap to the same site, so deduplicated to one.
        XCTAssertEqual(s.atoms.count, 1)
    }

    /// Non-equivalent positions near 0 and 1 are not merged.
    func testNonEquivalentPositionsNearZeroOneNotMerged() throws {
        let s = try loadCIF("""
            data_near_zero_one
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("Fe1 Fe 0.9999 0.2 0.3\nFe2 Fe 0.0001 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        // 0.9999 and 0.0001 (min-image 0.0002) are distinct positions.
        XCTAssertEqual(s.atoms.count, 2)
    }

    /// In a small cell, positions in different fractional buckets are not
    /// merged even though they are close in Cartesian space.
    func testCartesianToleranceSmallCellNotMerged() throws {
        let s = try loadCIF("""
            data_small_cell
            _cell_length_a 1.0
            _cell_length_b 1.0
            _cell_length_c 1.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("Fe1 Fe 0.1 0.2 0.3\nFe2 Fe 0.10002 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        // 2e-5 Å apart in a 1 Å cell — outside 1e-5 tolerance, not merged.
        XCTAssertEqual(s.atoms.count, 2)
    }

    /// In a 10,000 Å cell, two distinct fractional positions that collapse to
    /// the same Float32 value must still remain separate after identity
    /// expansion if their Cartesian separation exceeds the 1e-5 Å dedup
    /// tolerance. This guards against a naive dedup that truncates coordinates
    /// to Float before comparing: 0.1 and 0.100000002 both round to Float32
    /// 0.10000000149011612, yet are ~2e-5 Å apart in this cell.
    func testLargeCellFloatCollapseKeptSeparate() throws {
        let s = try loadCIF("""
            data_large_float_collapse
            _cell_length_a 10000.0
            _cell_length_b 10000.0
            _cell_length_c 10000.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("Fe1 Fe 0.1 0.2 0.3\nFe2 Fe 0.100000002 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        // Distinct doubles that collapse to the same Float32.
        XCTAssertEqual(Float(0.1), Float(0.100000002))
        // ~2e-5 Å apart in a 10,000 Å cell — outside 1e-5 tolerance, not merged.
        XCTAssertEqual(s.atoms.count, 2)
    }

    // MARK: - Unknown elements

    /// Unknown-element sites with the same label at the same position
    /// deduplicate because the label is part of the dedup key when z == 0.
    func testUnknownElementSameLabelDeduplicates() throws {
        let s = try loadCIF("""
            data_unknown_same
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("X1 XX 0.1 0.2 0.3\nX1 XX 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 1)
    }

    /// Distinct unknown-element labels at the same coordinate remain separate.
    /// Type symbol column is present but missing (`.`) so the label — not a
    /// present-but-unresolved token — drives element resolution.
    func testUnknownElementDistinctLabelsRemainSeparate() throws {
        let s = try loadCIF("""
            data_unknown_distinct
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("X1 . 0.1 0.2 0.3\nX2 . 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 2)
    }

    // MARK: - Type symbol authority

    /// `_atom_site_type_symbol` is authoritative: a label that would resolve to
    /// carbon ("C1") is overridden by the explicit type ("Ca" -> calcium).
    func testTypeSymbolOverridesElementLookingLabel() throws {
        let s = try loadCIF("""
            data_type_override
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("C1 Ca 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].atomicNumber, 20)
    }

    /// When no `_atom_site_type_symbol` column is present, the label resolves
    /// the element ("Fe1" -> iron).
    func testMissingTypeSymbolFallsBackToLabel() throws {
        let s = try loadCIF("""
            data_no_type_col
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
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].atomicNumber, 26)
    }

    // MARK: - Long unknown-identifier dedup

    /// Unknown identifiers longer than seven bytes that share a seven-byte prefix
    /// but differ thereafter are stored in full and must NOT be merged by dedup.
    /// Type symbol column is present but missing (`.`) so the label — not a
    /// present-but-unresolved token — drives element resolution.
    func testDistinctLongUnknownIdentifiersNotMerged() throws {
        let s = try loadCIF("""
            data_long_unknown_distinct
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("ABCDEFGH . 0.1 0.2 0.3\nABCDEFGX . 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 2)
    }

    /// Identical unknown identifiers longer than seven bytes still dedup at the
    /// same site.
    func testIdenticalLongUnknownIdentifiersDeduplicated() throws {
        let s = try loadCIF("""
            data_long_unknown_identical
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("ABCDEFGH . 0.1 0.2 0.3\nABCDEFGH . 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 1)
    }

    // MARK: - Charged type symbols

    /// Charged type symbols `Fe3+` and `O2-` resolve to the neutral element
    /// after trailing digit/charge stripping.
    func testChargedTypeSymbolsResolveToNeutralElement() throws {
        let s = try loadCIF("""
            data_charged_type
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("A1 Fe3+ 0.1 0.2 0.3\nA2 O2- 0.4 0.5 0.6"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 2)
        let species = s.atoms.map { $0.atomicNumber }.sorted()
        XCTAssertEqual(species, [8, 26])  // O and Fe
    }

    // MARK: - Long unresolved type tokens

    /// Two distinct unresolved type tokens longer than seven bytes that share a
    /// seven-byte prefix remain separate: the present-but-unresolved type is
    /// authoritative, so the full token becomes the dedup label.
    func testDistinctLongUnresolvedTypeTokensRemainSeparate() throws {
        let s = try loadCIF("""
            data_long_type_distinct
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("A1 ABCDEFGH 0.1 0.2 0.3\nA2 ABCDEFGX 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 2)
    }

    /// Identical unresolved type tokens longer than seven bytes dedup at the
    /// same site.
    func testIdenticalLongUnresolvedTypeTokensDeduplicated() throws {
        let s = try loadCIF("""
            data_long_type_identical
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("A1 ABCDEFGH 0.1 0.2 0.3\nA2 ABCDEFGH 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 1)
    }

    // MARK: - Present unresolved type does not fall back to element-looking label

    /// A present-but-unresolved type symbol is authoritative even when the
    /// label would resolve to a real element: "Fe1" must NOT be used because
    /// the type column is populated, so the atomic number stays 0.
    func testPresentUnresolvedTypeWithElementLabelDoesNotFallback() throws {
        let s = try loadCIF("""
            data_type_authoritative
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("Fe1 XX 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].atomicNumber, 0)
    }

    // MARK: - Large-cell exact-duplicate guards float-precision dedup

    /// Exact-duplicate fractional sites in a large cell must collapse to one.
    /// If dedup coordinates were truncated to Float before the tolerance check,
    /// quantization across the wide cell would leave two sites behind.
    func testLargeCellExactDuplicateDeduplicated() throws {
        let s = try loadCIF("""
            data_large_exact_dup
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
            \(atomLoop("Fe1 Fe 0.12345678 0.2 0.3\nFe2 Fe 0.12345678 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].atomicNumber, 26)
    }

    // MARK: - Quoted missing markers are literal unresolved type identities

    /// A quoted ``'.'`` in the type-symbol column is a literal unresolved type
    /// identity: it must NOT fall back to an element-looking label ("Fe1"), so
    /// the atom stays Z=0.
    func testQuotedDotTypeIsLiteralUnresolvedIdentity() throws {
        let s = try loadCIF("""
            data_quoted_dot
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("Fe1 '.' 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].atomicNumber, 0)
    }

    /// A quoted ``'?'`` in the type-symbol column is a literal unresolved type
    /// identity: it must NOT fall back to an element-looking label ("Fe1"), so
    /// the atom stays Z=0.
    func testQuotedQuestionMarkTypeIsLiteralUnresolvedIdentity() throws {
        let s = try loadCIF("""
            data_quoted_question
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("Fe1 '?' 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].atomicNumber, 0)
    }

    /// Quoted ``'.'`` and quoted ``'?'`` at the same site are distinct
    /// unresolved type identities (different labels), so they must NOT merge.
    func testQuotedDotAndQuestionMarkAreDistinctIdentities() throws {
        let s = try loadCIF("""
            data_quoted_dot_question_distinct
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("A1 '.' 0.1 0.2 0.3\nA2 '?' 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 2)
        XCTAssertTrue(s.atoms.allSatisfy { $0.atomicNumber == 0 })
    }

    /// A quoted ``'.'`` is distinguishable from an unquoted ``.``: the quoted
    /// form is a present-but-unresolved type (Z=0), while the unquoted form is
    /// a missing marker that falls back to the element-looking label (Fe2 →
    /// Z=26). At the same site they carry different Z, so they must NOT merge.
    func testQuotedDotDiffersFromUnquotedDotFallback() throws {
        let s = try loadCIF("""
            data_quoted_vs_unquoted_dot
            \(cubicCell)
            loop_
            _symmetry_equiv_pos_site_id
            _symmetry_equiv_pos_as_xyz
            1 'x, y, z'
            \(atomLoop("Fe1 '.' 0.1 0.2 0.3\nFe2 . 0.1 0.2 0.3"))
            """)
        XCTAssertEqual(s.symmetryInputCompleteness, .complete)
        XCTAssertEqual(s.atoms.count, 2)
        let zs = s.atoms.map { $0.atomicNumber }.sorted()
        XCTAssertEqual(zs, [0, 26])
    }
}
