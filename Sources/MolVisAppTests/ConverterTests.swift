import XCTest
import simd
@testable import MolVisApp

/// Headless conversion coverage for `Converter` and the new CLI verbs.
final class ConverterTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-convtest-\(UUID().uuidString)")
    }

    // MARK: - Single-file conversion + verb flags

    func testConvertSingleAndVerbs() throws {
        let si = fixtureURL("si110.xsf")
        let original = try Parser.load(si, as: .xsf)
        XCTAssertEqual(original.atoms.count, 2)

        // --convert to .xsf round-trips through the parser.
        let xsfOut = tempDir().appendingPathComponent("out.xsf")
        try FileManager.default.createDirectory(at: xsfOut.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Converter.convert(url: si, to: xsfOut, forcedFormat: .xsf)
        let xsfBack = try Parser.load(xsfOut, as: .xsf)
        XCTAssertEqual(xsfBack.atoms.count, original.atoms.count)
        XCTAssertNotNil(xsfBack.cell, "crystal must keep its cell through XSF")

        // --convert to .cif (crystal format) round-trips through the parser.
        let cifOut = tempDir().appendingPathComponent("out.cif")
        try FileManager.default.createDirectory(at: cifOut.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Converter.convert(url: si, to: cifOut, forcedFormat: .xsf)
        let cifBack = try Parser.load(cifOut, as: .cif)
        XCTAssertEqual(cifBack.atoms.count, original.atoms.count)
        XCTAssertNotNil(cifBack.cell, "crystal must keep its cell through CIF")

        // A molecule (no cell) must NOT write a crystal format.
        let mol = fixtureURL("h2o.xyz")
        let cifFromMol = tempDir().appendingPathComponent("mol.cif")
        try FileManager.default.createDirectory(at: cifFromMol.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertThrowsError(try Converter.convert(url: mol, to: cifFromMol, forcedFormat: .xyz)) { e in
            guard case StructureWriteError.requiresCrystal = e else {
                return XCTFail("expected requiresCrystal, got \(e)")
            }
        }

        // Verb flags set the forced format + convert URL.
        let pwi = try App.parseArguments(["in.pwi", "--pwi2xsf", "out.xsf"])
        XCTAssertEqual(pwi.convertURL?.lastPathComponent, "out.xsf")
        XCTAssertEqual(pwi.format, .pwi)

        let pwo = try App.parseArguments(["relax.pwo", "--pwo2xsf", "out.xsf"])
        XCTAssertEqual(pwo.format, .pwo)

        let str = try App.parseArguments(["gaas.struct", "--struct2xsf", "out.xsf"])
        XCTAssertEqual(str.format, .struct_)

        // A verb flag with a non-xsf output is rejected with a clear error.
        XCTAssertThrowsError(try App.parseArguments(["in.pwi", "--pwi2xsf", "out.gif"])) { e in
            let msg = (e as? App.CLIError)?.description ?? ""
            XCTAssertTrue(msg.contains(".xsf"), "expected .xsf hint, got: \(msg)")
        }

        // --convert requires an input file.
        XCTAssertThrowsError(try App.parseArguments(["--convert", "out.xsf"]))
        // Output aliasing the input is rejected.
        XCTAssertThrowsError(try App.parseArguments(["si110.xsf", "--convert", "si110.xsf"]))
    }

    // MARK: - Batch conversion

    func testConvertAllBatch() throws {
        let src = tempDir().appendingPathComponent("in")
        let dst = tempDir().appendingPathComponent("out")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

        let a = "2\nA\nSi  0.0 0.0 0.0\nSi  1.35 0.0 0.0\n"
        let b = "3\nB\nO  0.0 0.0 0.0\nH  0.757 0.586 0.0\nH  -0.757 0.586 0.0\n"
        try a.write(to: src.appendingPathComponent("a.xyz"), atomically: true, encoding: .utf8)
        try b.write(to: src.appendingPathComponent("b.xyz"), atomically: true, encoding: .utf8)

        let count = try Converter.convertAll(inputDirectory: src, outputDirectory: dst,
                                             targetFormat: .xsf, forcedFormat: nil)
        XCTAssertEqual(count, 2)

        let outputs = try FileManager.default.contentsOfDirectory(atPath: dst.path)
            .filter { $0.hasSuffix(".xsf") }
            .sorted()
        XCTAssertEqual(outputs, ["a.xsf", "b.xsf"])

        // Re-parse both outputs: atom counts match the sources.
        let aBack = try Parser.load(dst.appendingPathComponent("a.xsf"), as: .xsf)
        XCTAssertEqual(aBack.atoms.count, 2)
        let bBack = try Parser.load(dst.appendingPathComponent("b.xsf"), as: .xsf)
        XCTAssertEqual(bBack.atoms.count, 3)

        // maxFiles cap: 3 files with cap 2 throws .tooManyFiles.
        let capped = tempDir().appendingPathComponent("capped")
        try FileManager.default.createDirectory(at: capped, withIntermediateDirectories: true)
        for i in 0..<3 { try "1\n\nH 0 0 0\n".write(to: capped.appendingPathComponent("f\(i).xyz"), atomically: true, encoding: .utf8) }
        XCTAssertThrowsError(try Converter.convertAll(inputDirectory: capped, outputDirectory: dst,
                                                      targetFormat: .xsf, forcedFormat: nil, maxFiles: 2)) { e in
            guard case ConverterError.tooManyFiles(let n) = e else {
                return XCTFail("expected tooManyFiles, got \(e)")
            }
            XCTAssertEqual(n, 3)
        }

        // An unparseable file is skipped (count reflects only successes).
        let mixed = tempDir().appendingPathComponent("mixed")
        try FileManager.default.createDirectory(at: mixed, withIntermediateDirectories: true)
        try a.write(to: mixed.appendingPathComponent("good.xyz"), atomically: true, encoding: .utf8)
        try "not a structure at all".write(to: mixed.appendingPathComponent("bad.xyz"), atomically: true, encoding: .utf8)
        let partialDir = tempDir().appendingPathComponent("partial")
        let partial = try Converter.convertAll(inputDirectory: mixed, outputDirectory: partialDir,
                                               targetFormat: .xsf, forcedFormat: nil)
        XCTAssertEqual(partial, 1, "only the parseable file should be converted")
    }
}
