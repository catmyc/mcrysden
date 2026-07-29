import XCTest
@testable import MolVisApp

/// Bounded adversarial tests for the CIF symmetry-operation expansion path.
/// These define the safety contract: malformed operation expressions must be
/// rejected with a useful ParseError, operation count and expansion candidates
/// are capped, and a valid CIF with declared operations parses unchanged with
/// `.unknown` completeness (no applicability regression).
final class CIFSymmetrySafetyTests: XCTestCase {

    // MARK: - Teardown

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tempFiles.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private let cubicCell = """
        _cell_length_a 5.0
        _cell_length_b 5.0
        _cell_length_c 5.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0

        """

    /// Large cell keeps the expansion-cap test's bond heuristic practical:
    /// atoms are spread far apart so few bonds form despite the O(n^2) scan.
    private let largeCell = """
        _cell_length_a 10000.0
        _cell_length_b 10000.0
        _cell_length_c 10000.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0

        """

    private let fracAtomLoop = """
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        """

    private let cartAtomLoop = """
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_Cartn_x
        _atom_site_Cartn_y
        _atom_site_Cartn_z
        """

    /// Quote a CIF value if it contains whitespace and is not already quoted
    /// or a semicolon-delimited text field. Unquoted values with whitespace
    /// (e.g. ``x, y, z``) are invalid CIF; callers must never emit them.
    private func quoteOperation(_ op: String) -> String {
        let trimmed = op.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) ||
            (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) {
            return op
        }
        if trimmed.hasPrefix(";") {
            return op
        }
        if op.contains(" ") || op.contains("\t") {
            return "'\(op)'"
        }
        return op
    }

    /// Write a CIF file with the given symmetry operations and atom sites.
    @discardableResult
    private func writeCIF(
        filename: String,
        operations: [String],
        atomLoop: String,
        atomRows: [String],
        cell: String? = nil
    ) -> URL {
        let unique = "cif_\(UUID().uuidString)_\(filename)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(unique)
        var content = "data_test\n"
        if let cell { content += cell }
        content += "\nloop_\n_symmetry_equiv_pos_as_xyz\n"
        for op in operations { content += quoteOperation(op) + "\n" }
        content += "\nloop_\n\(atomLoop)\n"
        for row in atomRows { content += row + "\n" }
        try! content.write(to: url, atomically: true, encoding: .utf8)
        tempFiles.append(url)
        return url
    }

    /// Write a CIF file with single-tag symmetry operations (not in a loop).
    @discardableResult
    private func writeCIFFlat(
        filename: String,
        operations: [String],
        atomLoop: String,
        atomRows: [String],
        cell: String? = nil
    ) -> URL {
        let unique = "cif_\(UUID().uuidString)_\(filename)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(unique)
        var content = "data_test\n"
        if let cell { content += cell }
        for op in operations {
            content += "_symmetry_equiv_pos_as_xyz \(quoteOperation(op))\n"
        }
        content += "\nloop_\n\(atomLoop)\n"
        for row in atomRows { content += row + "\n" }
        try! content.write(to: url, atomically: true, encoding: .utf8)
        tempFiles.append(url)
        return url
    }

    /// Write a CIF file with raw content (full control over layout).
    @discardableResult
    private func writeCIFRaw(
        filename: String,
        content: String
    ) -> URL {
        let unique = "cif_\(UUID().uuidString)_\(filename)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(unique)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        tempFiles.append(url)
        return url
    }

    /// Assert that loading the CIF throws a ParseError.parse with a non-empty reason
    /// that mentions at most one stable keyword.
    private func assertCIFParseError(
        _ url: URL,
        keyword: String? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try Parser.load(url), file: file, line: line) { err in
            guard case ParseError.parse(_, _, let reason) = err else {
                return XCTFail("expected ParseError.parse, got \(err)", file: file, line: line)
            }
            XCTAssertFalse(reason.isEmpty, "error reason must be non-empty", file: file, line: line)
            if let keyword = keyword {
                XCTAssertTrue(
                    reason.lowercased().contains(keyword.lowercased()),
                    "error reason should mention \"\(keyword)\", got: \(reason)",
                    file: file, line: line
                )
            }
        }
    }

    // MARK: - Adversarial: malformed operation expressions

    /// A non-affine term (product of two variables) is not a valid symmetry
    /// operation and must be rejected.
    func testMalformedNonAffineExpressionThrows() {
        let url = writeCIF(
            filename: "cif_malformed_affine.cif",
            operations: ["x*y, y, z"],
            atomLoop: fracAtomLoop,
            atomRows: ["Fe1 Fe 0.0 0.0 0.0"],
            cell: cubicCell
        )
        assertCIFParseError(url, keyword: "operation")
    }

    /// An operation line with fewer than three components is malformed.
    func testWrongComponentCountThrows() {
        let url = writeCIF(
            filename: "cif_wrong_components.cif",
            operations: ["x, y"],
            atomLoop: fracAtomLoop,
            atomRows: ["Fe1 Fe 0.0 0.0 0.0"],
            cell: cubicCell
        )
        assertCIFParseError(url, keyword: "component")
    }

    /// A fraction with a zero denominator (e.g. the constant 1/0) is undefined.
    func testZeroDenominatorThrows() {
        let url = writeCIF(
            filename: "cif_zero_denominator.cif",
            operations: ["x/0, y, z"],
            atomLoop: fracAtomLoop,
            atomRows: ["Fe1 Fe 0.0 0.0 0.0"],
            cell: cubicCell
        )
        assertCIFParseError(url, keyword: "denominator")
    }

    /// A rotation matrix with determinant zero (two identical rows) is singular
    /// and cannot be a symmetry operation.
    func testSingularRotationThrows() {
        let url = writeCIF(
            filename: "cif_singular_rotation.cif",
            operations: ["x, x, z"],
            atomLoop: fracAtomLoop,
            atomRows: ["Fe1 Fe 0.0 0.0 0.0"],
            cell: cubicCell
        )
        assertCIFParseError(url, keyword: "singular")
    }

    /// A translation component that is infinite is not a valid operation.
    func testNonfiniteTranslationThrows() {
        let url = writeCIF(
            filename: "cif_nonfinite_translation.cif",
            operations: ["x+inf, y, z"],
            atomLoop: fracAtomLoop,
            atomRows: ["Fe1 Fe 0.0 0.0 0.0"],
            cell: cubicCell
        )
        assertCIFParseError(url, keyword: "non-finite")
    }

    // MARK: - Adversarial: operation count and expansion caps

    /// No space group has more than 192 operations; 193 distinct valid
    /// operations must be rejected.
    func testMoreThan192OperationsThrows() {
        let operations = (0..<193).map { i in
            "x+\(String(format: "%.3f", Double(i) * 0.001)), y, z"
        }
        let url = writeCIF(
            filename: "cif_too_many_operations.cif",
            operations: operations,
            atomLoop: fracAtomLoop,
            atomRows: ["Fe1 Fe 0.0 0.0 0.0"],
            cell: cubicCell
        )
        assertCIFParseError(url, keyword: "192")
    }

    /// 193 repeated single-tag operations (not in a loop) must be rejected
    /// rather than silently truncated.
    func test193SingleTagOperationsRejects() {
        let operations = (0..<193).map { i in
            "'x+\(String(format: "%.3f", Double(i) * 0.001)), y, z'"
        }
        let url = writeCIFFlat(
            filename: "cif_193_singletag.cif",
            operations: operations,
            atomLoop: fracAtomLoop,
            atomRows: ["Fe1 Fe 0.0 0.0 0.0"],
            cell: cubicCell
        )
        assertCIFParseError(url, keyword: "192")
    }

    /// The expansion candidate count (atoms × operations) is capped at
    /// MOLENV_ATOM_CAP (500,000). 192 operations × 3000 atoms = 576,000 must
    /// be rejected, and the multiplication must be overflow-safe.
    func testOverflowSafeExpansionCandidateCap() {
        let operations = (0..<192).map { i in
            "x+\(String(format: "%.3f", Double(i) * 0.001)), y, z"
        }
        let atomRows = (0..<3000).map { i in
            "Fe\(i) Fe \(String(format: "%.4f", Double(i % 100) / 100.0)) 0.0 0.0"
        }
        let url = writeCIF(
            filename: "cif_expansion_cap.cif",
            operations: operations,
            atomLoop: fracAtomLoop,
            atomRows: atomRows,
            cell: largeCell
        )
        assertCIFParseError(url, keyword: "cap")
    }

    // MARK: - Adversarial: unterminated quoted operation

    /// An operation with an unterminated single quote must be rejected.
    func testUnterminatedQuotedOperationRejects() {
        let url = writeCIFRaw(
            filename: "cif_unterminated_quote.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z
            '-x, -y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.0 0.0 0.0
            """
        )
        assertCIFParseError(url, keyword: "unterminated")
    }

    // MARK: - Adversarial: missing operation values (. and ?)

    /// Unquoted `.` and `?` operation rows set the missing flag, so completeness
    /// stays `.unknown` and the structure is NOT partially expanded.
    func testMissingOperationRowsStayUnknownAndDontExpand() {
        let url = writeCIFRaw(
            filename: "cif_missing_ops.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'
            .
            '-x, -y, z'
            ?

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("CIF with . and ? operations should parse without error")
        }
        // symop_missing prevents expansion: atom count stays at the input count.
        XCTAssertEqual(scene.atoms.count, 1)
        XCTAssertEqual(scene.symmetryInputCompleteness, .unknown)
    }

    // MARK: - Adversarial: quoted markers are literal operation values

    // Quoted ``'.'`` / ``'?'`` / ``'x,y,z;'`` are written with explicit bytes
    // via a helper because single-char Swift string literals adjacent to the
    // ``.`` character can lose a closing quote (compiler quirk); building the
    // operation value from concatenated parts avoids the issue entirely.
    private func singleQuotedOp(_ inner: String) -> String {
        return "'" + inner + "'"
    }

    /// A quoted ``'.'`` is a literal operation value, not a missing marker.
    /// It must be rejected as a malformed operation rather than setting the
    /// missing flag.
    func testQuotedDotIsLiteralOperationValueRejects() {
        let url = writeCIF(
            filename: "cif_quoted_dot_op.cif",
            operations: [singleQuotedOp(".")],
            atomLoop: fracAtomLoop,
            atomRows: ["Fe1 Fe 0.1 0.2 0.3"],
            cell: cubicCell
        )
        assertCIFParseError(url, keyword: "operation")
    }

    /// A quoted ``'?'`` is a literal operation value, not a missing marker.
    /// It must be rejected as a malformed operation rather than setting the
    /// missing flag.
    func testQuotedQuestionMarkIsLiteralOperationValueRejects() {
        let url = writeCIF(
            filename: "cif_quoted_question_op.cif",
            operations: [singleQuotedOp("?")],
            atomLoop: fracAtomLoop,
            atomRows: ["Fe1 Fe 0.1 0.2 0.3"],
            cell: cubicCell
        )
        assertCIFParseError(url, keyword: "operation")
    }

    /// A quoted ``'x,y,z;'`` must be rejected: the trailing semicolon makes it
    /// a malformed operation that cannot be silently normalized to the identity.
    func testQuotedSemicolonTerminatedOpRejectsAndCannotNormalizeToIdentity() {
        let url = writeCIF(
            filename: "cif_quoted_semicolon_op.cif",
            operations: [singleQuotedOp("x,y,z;")],
            atomLoop: fracAtomLoop,
            atomRows: ["Fe1 Fe 0.1 0.2 0.3"],
            cell: cubicCell
        )
        assertCIFParseError(url, keyword: "operation")
    }

    // MARK: - Adversarial: malformed atom coordinates

    /// A `.` in a required fractional coordinate must be rejected.
    func testAtomCoordinateDotRejects() {
        let url = writeCIF(
            filename: "cif_atom_dot.cif",
            operations: ["x, y, z"],
            atomLoop: fracAtomLoop,
            atomRows: ["Fe1 Fe . 0.0 0.0"],
            cell: cubicCell
        )
        assertCIFParseError(url, keyword: "coordinate")
    }

    /// A `?` in a required fractional coordinate must be rejected.
    func testAtomCoordinateQuestionMarkRejects() {
        let url = writeCIF(
            filename: "cif_atom_question.cif",
            operations: ["x, y, z"],
            atomLoop: fracAtomLoop,
            atomRows: ["Fe1 Fe 0.0 ? 0.0"],
            cell: cubicCell
        )
        assertCIFParseError(url, keyword: "coordinate")
    }

    /// Garbage in a required fractional coordinate must be rejected.
    func testAtomCoordinateGarbageRejects() {
        let url = writeCIF(
            filename: "cif_atom_garbage.cif",
            operations: ["x, y, z"],
            atomLoop: fracAtomLoop,
            atomRows: ["Fe1 Fe 0.0 abc 0.0"],
            cell: cubicCell
        )
        assertCIFParseError(url, keyword: "coordinate")
    }

    // MARK: - Valid symop loop with blank and comment lines

    /// A valid symmetry-operation loop that contains blank lines and comment
    /// lines between operations must still read every operation and expand.
    func testValidSymopLoopWithBlankAndCommentLinesExpands() {
        let url = writeCIFRaw(
            filename: "cif_blank_comment_loop.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            # mirror plane comment
            '-x, -y, z'

            '-x, y, -z'
            'x, -y, -z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("valid CIF with blank/comment lines should parse without error")
        }
        // 4 distinct operations on (0.1, 0.2, 0.3) in a cubic cell produce 4
        // distinct positions after expansion.
        XCTAssertEqual(scene.atoms.count, 4)
        XCTAssertTrue(scene.isCrystal)
        XCTAssertNotNil(scene.cell)
    }
    // MARK: - Token-stream atom-loop: legal forms accepted

    /// A legal atom row split across physical lines must parse as one logical
    /// row rather than being rejected.
    func testAtomRowSplitAcrossLinesParsesAsOneRow() {
        let url = writeCIFRaw(
            filename: "cif_split_row.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            Fe2 Fe 0.4
            0.5 0.6
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("split atom row should parse as one logical row")
        }
        XCTAssertEqual(scene.atoms.count, 2)
    }

    /// Multiple complete atom rows on one line must both parse rather than
    /// silently dropping the trailing row.
    func testMultipleAtomRowsOnOneLineBothParse() {
        let url = writeCIFRaw(
            filename: "cif_multi_row.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            Fe2 Fe 0.4 0.5 0.6 Fe3 Fe 0.7 0.8 0.9
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("two complete atom rows on one line should both parse")
        }
        XCTAssertEqual(scene.atoms.count, 3)
    }

    /// A trailing inline comment on an atom row must be ignored and the row
    /// retained rather than rejected.
    func testTrailingInlineCommentIgnoredRowRetained() {
        let url = writeCIFRaw(
            filename: "cif_inline_comment.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            Fe2 Fe 0.4 0.5 0.6 # trailing comment
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("trailing inline comment should be ignored and row retained")
        }
        XCTAssertEqual(scene.atoms.count, 2)
    }

    // MARK: - Token-stream atom-loop: incomplete row rejected

    /// A truly incomplete atom row (fewer tokens than columns) at EOF must throw
    /// rather than silently truncating the data.
    func testIncompleteAtomRowAtEOFThrows() {
        let url = writeCIFRaw(
            filename: "cif_incomplete_row.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            Fe2 Fe 0.4 0.5
            """
        )
        assertCIFParseError(url)
    }

    // MARK: - Single-tag operation token-stream

    /// A single-tag operation whose value is on the following line must be
    /// accepted rather than silently dropped.
    func testSingleTagOpValueOnNextLineAccepted() {
        let url = writeCIFRaw(
            filename: "cif_tag_value_next_line.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("single-tag operation value on following line should parse")
        }
        XCTAssertEqual(scene.atoms.count, 1)
    }

    /// A true CIF semicolon text field starts with `;` at column 1 on its own
    /// line and ends with `;` at column 1; that form must be accepted as the
    /// operation value (not the inline `;x;` form).
    func testSemicolonTextFieldOpValueAccepted() {
        let url = writeCIFRaw(
            filename: "cif_semicolon_op.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            _symmetry_equiv_pos_as_xyz
            ;
            x, y, z
            ;

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("proper semicolon text field op value should parse")
        }
        XCTAssertEqual(scene.atoms.count, 1)
    }

    /// A quoted operation followed immediately by non-whitespace must reject
    /// the surplus token rather than silently ignoring it.
    func testQuotedOpFollowedByNonWhitespaceThrows() {
        let url = writeCIFRaw(
            filename: "cif_quoted_op_nonws.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            _symmetry_equiv_pos_as_xyz 'x, y, z'extra

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        assertCIFParseError(url)
    }

    /// A surplus value after a single-tag operation must reject rather than
    /// silently ignore the extra token.
    func testSurplusValueAfterSingleTagOpThrows() {
        let url = writeCIFRaw(
            filename: "cif_surplus_op_value.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            _symmetry_equiv_pos_as_xyz 'x, y, z' extra

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        assertCIFParseError(url)
    }

    // MARK: - Adversarial: numeric grammar

    /// A valid uncertainty-before-exponent value `1.234(5)e1` must be accepted
    /// (= 12.34) rather than rejected as trailing garbage.
    func testUncertaintyBeforeExponentAccepted() {
        let url = writeCIFRaw(
            filename: "cif_uncertainty_exponent.cif",
            content: """
            data_test
            _cell_length_a 1.234(5)e1
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("uncertainty-before-exponent value should parse without error")
        }
        XCTAssertNotNil(scene.cell)
        XCTAssertEqual(scene.cell!.a.x, 12.34, accuracy: 0.01)
    }

    /// A hexadecimal float (e.g. `0x1.8p3`) must be rejected; CIF numerics are
    /// decimal only.
    func testHexadecimalFloatRejected() {
        let url = writeCIFRaw(
            filename: "cif_hex_float.cif",
            content: """
            data_test
            _cell_length_a 0x1.8p3
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        assertCIFParseError(url)
    }

    // MARK: - No applicability regression

    /// A valid CIF that declares symmetry operations alongside Cartesian
    /// atom-site coordinates must still parse: atoms are read unchanged and the
    /// completeness stays `.unknown` (expansion is deferred, so declaring
    /// operations does not by itself make the input "complete").
    func testValidCartesianWithOperationsParsesUnchanged() {
        let url = writeCIF(
            filename: "cif_valid_cartesian.cif",
            operations: ["x, y, z", "-x, -y, z"],
            atomLoop: cartAtomLoop,
            atomRows: ["Fe1 Fe 0.0 0.0 0.0", "O1  O  1.0 2.0 3.0"]
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("valid CIF with operations should parse without error")
        }
        XCTAssertEqual(scene.atoms.count, 2)
        XCTAssertEqual(scene.atoms[0].atomicNumber, 26) // Fe
        XCTAssertEqual(scene.atoms[1].atomicNumber, 8)  // O
        // Cartesian coordinates are stored unchanged (no cell conversion).
        XCTAssertEqual(scene.atoms[0].coord.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[0].coord.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[0].coord.z, 0.0, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[1].coord.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[1].coord.y, 2.0, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[1].coord.z, 3.0, accuracy: 0.001)
        // No cell for a Cartesian (molecule) CIF.
        XCTAssertNil(scene.cell)
        XCTAssertFalse(scene.isCrystal)
        // Completeness stays .unknown — declaring operations does not regress.
        XCTAssertEqual(scene.symmetryInputCompleteness, .unknown)
    }

    // MARK: - Third-review: loop column limit

    /// A loop with more than 64 columns must be rejected safely rather than
    /// silently truncating or overflowing the row token buffer.
    func testMoreThan64ColumnsInLoopRejects() {
        let columns = (0..<65).map { i in "_col_\(i)" }.joined(separator: "\n")
        let url = writeCIFRaw(
            filename: "cif_65cols.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            \(columns)
            """
        )
        assertCIFParseError(url, keyword: "columns")
    }

    // MARK: - Third-review: semicolon text field

    /// A semicolon text field must preserve content after the opening `;`.
    /// The terminator is `;` at column 1 on a subsequent line. The value
    /// `-x, -y, z` (with leading space in the text body) must be read intact
    /// and applied as a valid symop.
    func testSemicolonTextPreservesContentAfterOpener() {
        let url = writeCIFRaw(
            filename: "cif_semicolon_content.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            _symmetry_equiv_pos_as_xyz 'x, y, z'
            _symmetry_equiv_pos_as_xyz
            ;
             -x, -y, z
            ;

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("semicolon text should preserve content after opener")
        }
        // x,y,z and -x,-y,z on (0.1,0.2,0.3) produce 2 distinct atoms.
        XCTAssertEqual(scene.atoms.count, 2)
    }

    /// A semicolon text field without a closing `;` terminator must reject
    /// (reader runs to EOF, parse_symop fails on the over-long value).
    func testSemicolonTextWithoutTerminatorRejects() {
        let url = writeCIFRaw(
            filename: "cif_semicolon_no_term.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            _symmetry_equiv_pos_as_xyz
            ;
            x, y, z
            """
        )
        assertCIFParseError(url)
    }

    // MARK: - Embedded apostrophe regression

    /// A single-quoted CIF value with an embedded apostrophe: ``'O'Brien'``.
    /// The internal ``'`` is followed by non-whitespace, so it is literal and
    /// never mistaken for a closing quote; the final ``'`` closes the value at
    /// the whitespace token boundary. The decoded label is ``O'Brien`` (7 chars,
    /// fits ``MolEnvAtom.label[8]`` with no truncation). No
    /// ``_atom_site_type_symbol`` column, so the label is preserved rather than
    /// being overwritten by a resolved element symbol.
    func testEmbeddedApostropheInQuotedValueDecodesCorrectly() {
        let url = writeCIFRaw(
            filename: "cif_apostrophe.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_Cartn_x
            _atom_site_Cartn_y
            _atom_site_Cartn_z
            'O'Brien' 0.0 0.0 0.0
            Fe1 0.5 0.5 0.5
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("embedded-apostrophe row must parse without error")
        }
        XCTAssertEqual(scene.atoms.count, 2)
        // 'O'Brien' decodes to O'Brien: literal apostrophe, closing quote at boundary.
        XCTAssertEqual(scene.atoms[0].label, "O'Brien")
        XCTAssertEqual(scene.atoms[0].coord.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[0].coord.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[0].coord.z, 0.0, accuracy: 0.001)
        // Following row intact: element resolves and coordinates are correct.
        XCTAssertEqual(scene.atoms[1].atomicNumber, 26) // Fe
        XCTAssertEqual(scene.atoms[1].coord.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[1].coord.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[1].coord.z, 0.5, accuracy: 0.001)
    }

    // MARK: - Third-review: hash in tokens

    /// `#` at a token boundary (start of line) starts a comment; the rest of
    /// the line is ignored. A comment line between data rows must not break
    /// parsing.
    func testBoundaryHashStartsComment() {
        let url = writeCIFRaw(
            filename: "cif_hash_comment.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            # this is a comment line between atom rows
            Fe2 Fe 0.4 0.5 0.6
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("boundary hash should start a comment")
        }
        XCTAssertEqual(scene.atoms.count, 2)
    }

    /// `#` inside an unquoted token is data: the token is NOT truncated at `#`
    /// and the rest of the line is NOT treated as a comment. The atom label
    /// containing `#` must be preserved intact.
    func testHashInsideUnquotedTokenIsData() {
        let url = writeCIFRaw(
            filename: "cif_hash_inside_token.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            C#1 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("hash inside unquoted token should be data")
        }
        XCTAssertEqual(scene.atoms.count, 1)
        XCTAssertEqual(scene.atoms[0].label, "C#1")
    }

    // MARK: - Ninth-review: global_ after a complete selected data block

    /// A complete selected data block (cell + symops + atoms) followed by a
    /// `global_` block must not let the global block's cell/symop/atom data
    /// contaminate the returned first block. The parser must break cleanly:
    /// first-block cell length and atom count are preserved, global values
    /// are ignored.
    func testGlobalAfterCompleteFirstBlockDoesNotContaminate() {
        let url = writeCIFRaw(
            filename: "cif_global_after_block.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3

            global_
            _cell_length_a 999.0
            loop_
            _symmetry_equiv_pos_as_xyz
            '-x, -y, -z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            O1 O 0.4 0.5 0.6
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("first block must parse cleanly despite trailing global_ block")
        }
        // First-block cell is preserved; global_ cell value is ignored.
        XCTAssertEqual(scene.cell!.a.x, 5.0, accuracy: 0.001)
        // Only the first-block atom is returned; the global_ atom is ignored.
        XCTAssertEqual(scene.atoms.count, 1)
        XCTAssertEqual(scene.atoms[0].atomicNumber, 26) // Fe
        // Fractional (0.1,0.2,0.3) in a cubic cell a=5.0 -> Cartesian (0.5,1.0,1.5).
        XCTAssertEqual(scene.atoms[0].coord.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[0].coord.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[0].coord.z, 1.5, accuracy: 0.001)
    }

    /// A complete selected data block followed by a `global_` block AND a second
    /// `data_second` block with conflicting cell/symop/atom data must not let
    /// either trailing block contaminate the returned first block. The parser
    /// must break cleanly: first-block cell length and atom count are preserved,
    /// global_ and data_second values are ignored.
    func testGlobalAndSecondDataBlockAfterFirstDoNotContaminate() {
        let url = writeCIFRaw(
            filename: "cif_global_then_second_block.cif",
            content: """
            data_first
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3

            global_
            _cell_length_a 999.0
            loop_
            _symmetry_equiv_pos_as_xyz
            '-x, -y, -z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            O1 O 0.4 0.5 0.6

            data_second
            _cell_length_a 10.0
            _cell_length_b 10.0
            _cell_length_c 10.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            '-x, -y, -z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            C1 C 0.5 0.5 0.5
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("first block must parse cleanly despite trailing global_ and data_second blocks")
        }
        // First-block cell is preserved; global_ and data_second cell values are ignored.
        XCTAssertEqual(scene.cell!.a.x, 5.0, accuracy: 0.001)
        // Only the first-block atom is returned; global_ and data_second atoms are ignored.
        XCTAssertEqual(scene.atoms.count, 1)
        XCTAssertEqual(scene.atoms[0].atomicNumber, 26) // Fe
        // Fractional (0.1,0.2,0.3) in a cubic cell a=5.0 -> Cartesian (0.5,1.0,1.5).
        XCTAssertEqual(scene.atoms[0].coord.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[0].coord.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[0].coord.z, 1.5, accuracy: 0.001)
    }

    // MARK: - Ninth-review: quote immediately followed by `#`

    /// A closing quote immediately followed by `#` without any intervening
    /// whitespace must be treated as a literal continuation / malformed token
    /// rather than a closing quote plus comment. The surplus `#...` is not a
    /// valid second value, so parsing must reject.
    func testQuoteImmediatelyFollowedByHashRejects() {
        let url = writeCIFRaw(
            filename: "cif_quote_hash_no_ws.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            _symmetry_equiv_pos_as_xyz 'x, y, z'#comment

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        assertCIFParseError(url)
    }

    /// Control: a closing quote followed by whitespace then `#` is a valid
    /// value followed by a comment. The value parses, the comment is ignored,
    /// and the atom row is retained.
    func testQuoteFollowedByWhitespaceThenHashIsValidValueWithComment() {
        let url = writeCIFRaw(
            filename: "cif_quote_ws_hash.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            _symmetry_equiv_pos_as_xyz 'x, y, z' # comment

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("quote + whitespace + # must be a valid value followed by a comment")
        }
        XCTAssertEqual(scene.atoms.count, 1)
        XCTAssertEqual(scene.atoms[0].atomicNumber, 26) // Fe
    }

    // MARK: - Third-review: oversized token

    /// A token longer than the reader's buffer must reject rather than
    /// silently truncating.
    func testOversizedTokenRejects() {
        let longValue = String(repeating: "a", count: 3000)
        let url = writeCIFRaw(
            filename: "cif_oversized_token.cif",
            content: """
            data_test
            _cell_length_a \(longValue)
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0
            """
        )
        assertCIFParseError(url)
    }

    // MARK: - Third-review: mixed-case controls and tags

    /// CIF control keywords and tags are case-insensitive: mixed-case
    /// ``GLOBAL_``, ``SAVE_name``, ``SAVE_``, ``STOP_``, ``DATA_``, ``LOOP_``
    /// must behave the same as lowercase, and mixed-case column tags must still
    /// resolve. Each control here exercises a distinct state transition:
    /// ``GLOBAL_``/``SAVE_name``/``SAVE_``/``STOP_`` are all skipped before the
    /// first ``DATA_`` block, which then parses its atoms unchanged.
    func testMixedCaseControlsAndTags() {
        let url = writeCIFRaw(
            filename: "cif_mixed_case.cif",
            content: """
            GLOBAL_
            SAVE_name
            _cell_length_a 999.0
            SAVE_
            STOP_
            DATA_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            Loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            LOOP_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("mixed-case controls and tags should parse")
        }
        XCTAssertEqual(scene.atoms.count, 1)
        XCTAssertEqual(scene.atoms[0].atomicNumber, 26) // Fe
        XCTAssertEqual(scene.cell!.a.x, 5.0, accuracy: 0.001)
    }

    // MARK: - Third-review: symop component count

    /// A symop with a fourth component must reject, not silently drop it.
    func testSymopFourthComponentRejects() {
        let url = writeCIFRaw(
            filename: "cif_fourth_component.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z, w'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        assertCIFParseError(url, keyword: "component")
    }

    /// A symop with a trailing comma must reject (empty last component).
    func testSymopTrailingCommaRejects() {
        let url = writeCIFRaw(
            filename: "cif_trailing_comma.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z,'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        assertCIFParseError(url, keyword: "component")
    }

    // MARK: - Third-review: numeric grammar

    /// A leading decimal point (``.5``) must be accepted as a valid numeric.
    func testLeadingDecimalPointAccepted() {
        let url = writeCIFRaw(
            filename: "cif_leading_decimal.cif",
            content: """
            data_test
            _cell_length_a .5
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("leading decimal point .5 should parse")
        }
        XCTAssertNotNil(scene.cell)
        XCTAssertEqual(scene.cell!.a.x, 0.5, accuracy: 0.001)
    }

    /// A signed hexadecimal float (``+0x1.8p3``) must be rejected; only bare
    /// ``0x``/``0o``/``0b`` prefixes are caught by the leading-zero check.
    func testSignedHexadecimalRejected() {
        let url = writeCIFRaw(
            filename: "cif_signed_hex.cif",
            content: """
            data_test
            _cell_length_a +0x1.8p3
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        assertCIFParseError(url)
    }

    // MARK: - Fourth-review: control keywords and framing

    /// A ``loop_`` with zero data-name headers must reject rather than
    /// underflowing the row buffer or looping forever.
    func testLoopWithZeroHeadersRejects() {
        let url = writeCIFRaw(
            filename: "cif_loop_zero_headers.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            1.0 2.0 3.0
            """
        )
        assertCIFParseError(url, keyword: "header")
    }

    /// A control keyword encountered in the middle of a partial loop row must
    /// reject the partial row rather than silently dropping it.
    func testControlInPartialRowRejects() {
        let url = writeCIFRaw(
            filename: "cif_control_partial_row.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _col_a
            _col_b
            1.0
            data_foo
            """
        )
        assertCIFParseError(url, keyword: "partial")
    }

    /// ``global_`` before the first ``data_`` block must not consume the block:
    /// the data block that follows still parses normally.
    func testGlobalBeforeDataDoesNotPreventParsing() {
        let url = writeCIFRaw(
            filename: "cif_global_before_data.cif",
            content: """
            global_
            _cell_length_a 999.0
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("data_ block after global_ should parse")
        }
        XCTAssertEqual(scene.atoms.count, 1)
        XCTAssertEqual(scene.cell!.a.x, 5.0, accuracy: 0.001)
    }

    /// Unquoted ``global_foo`` as loop data must NOT be treated as the exact
    /// ``global_`` control keyword: control matching is exact, not prefix-based.
    /// If it were a false match, the row would be dropped and parsing would
    /// error or produce fewer atoms. The atom count and following coordinates
    /// prove the row was accepted as data. (The 8-byte ``MolEnvAtom.label``
    /// buffer truncates "global_foo" to "global_"; this assertion documents
    /// that limit while the count/coordinates prove non-control handling.)
    func testUnquotedGlobalFooInLoopDataIsNotControl() {
        let url = writeCIFRaw(
            filename: "cif_global_foo_data.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_Cartn_x
            _atom_site_Cartn_y
            _atom_site_Cartn_z
            global_foo 0.1 0.2 0.3
            Fe1 0.4 0.5 0.6
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("unquoted global_foo in loop data should not be treated as global_ control")
        }
        // Two atoms parsed proves the global_foo row was accepted as data.
        XCTAssertEqual(scene.atoms.count, 2)
        // global_foo does not match the exact "global_" control keyword.
        XCTAssertEqual(scene.atoms[0].label, "global_")
        XCTAssertEqual(scene.atoms[0].coord.x, 0.1, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[0].coord.y, 0.2, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[0].coord.z, 0.3, accuracy: 0.001)
        // Following row intact.
        XCTAssertEqual(scene.atoms[1].atomicNumber, 26) // Fe
        XCTAssertEqual(scene.atoms[1].coord.x, 0.4, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[1].coord.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(scene.atoms[1].coord.z, 0.6, accuracy: 0.001)
    }

    /// ``stop_`` terminates the current loop but leaves the data block active,
    /// so a later atom loop in the same block still parses.
    func testStopTerminatesLoopButBlockContinues() {
        let url = writeCIFRaw(
            filename: "cif_stop_in_block.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'
            stop_

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("atom loop after stop_ in same block should parse")
        }
        XCTAssertEqual(scene.atoms.count, 1)
    }

    /// A ``save_name``/``save_`` frame nested in a data block must not discard
    /// the parent block: parsing resumes after the closing ``save_``.
    func testSaveFrameDoesNotDiscardParentBlock() {
        let url = writeCIFRaw(
            filename: "cif_save_frame.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            save_name
            loop_
            _foo
            bar
            save_

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("parent block should resume parsing after save_")
        }
        XCTAssertEqual(scene.atoms.count, 1)
        XCTAssertEqual(scene.cell!.a.x, 5.0, accuracy: 0.001)
    }

    /// An empty semicolon text field must tokenize as an empty value without
    /// swallowing the following data token. Uses an unknown tag because an
    /// empty symop value would rightly fail operation parsing.
    func testEmptySemicolonFieldDoesNotSwallowNextToken() {
        let url = writeCIFRaw(
            filename: "cif_empty_semicolon.cif",
            content: """
            data_test
            _phony_tag
            ;
            ;
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("empty semicolon field should not swallow the next token")
        }
        // The cell tag after the empty semicolon must still parse.
        XCTAssertNotNil(scene.cell)
        XCTAssertEqual(scene.cell!.a.x, 5.0, accuracy: 0.001)
        // And the atom loop after it must parse too.
        XCTAssertEqual(scene.atoms.count, 1)
    }

    /// A single tag followed by only whitespace/EOF (no value) must report a
    /// ParseError rather than silently succeeding.
    func testSingleTagFollowedByEOFReportsParseError() {
        let url = writeCIFRaw(
            filename: "cif_tag_eof.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0
            _orphan_tag
            """
        )
        assertCIFParseError(url, keyword: "missing value")
    }

    // MARK: - CRLF line endings and unterminated save frame

    /// A CIF file with CRLF line endings and a semicolon-delimited symmetry
    /// operation must parse and expand successfully rather than choking on `\r`.
    func testCRLFSemicolonOpExpandsSuccessfully() {
        let crlfContent = [
            "data_test",
            "_cell_length_a 5.0",
            "_cell_length_b 5.0",
            "_cell_length_c 5.0",
            "_cell_angle_alpha 90.0",
            "_cell_angle_beta 90.0",
            "_cell_angle_gamma 90.0",
            "",
            "loop_",
            "_symmetry_equiv_pos_as_xyz",
            ";",
            "x, y, z",
            ";",
            "",
            "loop_",
            "_atom_site_label",
            "_atom_site_type_symbol",
            "_atom_site_fract_x",
            "_atom_site_fract_y",
            "_atom_site_fract_z",
            "Fe1 Fe 0.1 0.2 0.3",
        ].joined(separator: "\r\n")
        let url = writeCIFRaw(
            filename: "cif_crlf_semicolon.cif",
            content: crlfContent
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("CRLF CIF with semicolon-delimited op should parse")
        }
        XCTAssertEqual(scene.atoms.count, 1)
        XCTAssertEqual(scene.atoms[0].atomicNumber, 26)
    }

    /// A CIF that enters ``save_name`` after valid parent atom data and then
    /// reaches EOF without a closing ``save_`` must report a ParseError rather
    /// than silently returning a scene built from partial state.
    func testUnterminatedSaveFrameAtEOFRejects() {
        let url = writeCIFRaw(
            filename: "cif_save_eof.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3

            save_name
            loop_
            _foo
            bar
            """
        )
        assertCIFParseError(url)
    }

    // MARK: - Regression: single-tag missing value before unquoted data_ block

    /// A valid first data block followed by ``_unknown_tag`` immediately before
    /// unquoted ``data_second`` must be rejected with "missing value after
    /// single tag": the parser must not swallow ``data_second`` as the tag's
    /// value, and the second block must not be parsed or contaminate the
    /// result. The ParseError is the proof: parsing never reaches the second
    /// block, so its cell/atom data cannot leak into the first block.
    func testSingleTagMissingValueBeforeUnquotedDataSecondRejects() {
        let url = writeCIFRaw(
            filename: "cif_missing_value_before_data_second.cif",
            content: """
            data_first
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3

            _unknown_tag
            data_second
            _cell_length_a 10.0
            _cell_length_b 10.0
            _cell_length_c 10.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            loop_
            _symmetry_equiv_pos_as_xyz
            '-x, -y, -z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            C1 C 0.5 0.5 0.5
            """
        )
        assertCIFParseError(url, keyword: "missing value")
    }

    /// A quoted ``'data_second'`` is a valid literal value for a single tag:
    /// quoted control keywords are never interpreted as controls. The tag
    /// accepts the value, and parsing continues without error.
    func testQuotedControlValueRemainsLiteralTagValue() {
        let url = writeCIFRaw(
            filename: "cif_quoted_control_value.cif",
            content: """
            data_test
            _cell_length_a 5.0
            _cell_length_b 5.0
            _cell_length_c 5.0
            _cell_angle_alpha 90.0
            _cell_angle_beta 90.0
            _cell_angle_gamma 90.0

            _unknown_tag 'data_second'

            loop_
            _symmetry_equiv_pos_as_xyz
            'x, y, z'

            loop_
            _atom_site_label
            _atom_site_type_symbol
            _atom_site_fract_x
            _atom_site_fract_y
            _atom_site_fract_z
            Fe1 Fe 0.1 0.2 0.3
            """
        )
        guard let scene = try? Parser.load(url) else {
            return XCTFail("quoted 'data_second' must be a valid literal tag value")
        }
        XCTAssertEqual(scene.cell!.a.x, 5.0, accuracy: 0.001)
        XCTAssertEqual(scene.atoms.count, 1)
        XCTAssertEqual(scene.atoms[0].atomicNumber, 26) // Fe
    }
}
