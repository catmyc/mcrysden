import XCTest
@testable import MolVisApp
import MolEnvParse

final class ParserTests: XCTestCase {
    func testLastErrorEmptyByDefault() {
        XCTAssertEqual(String(cString: molenv_last_error()), "")
    }
    func testUnknownExtThrows() {
        let url = URL(fileURLWithPath: "/tmp/foo.weird")
        XCTAssertThrowsError(try Parser.load(url)) { err in
            guard case ParseError.io = err else { return XCTFail("wrong error") }
        }
    }
    func testBadPathThrows() {
        let url = URL(fileURLWithPath: "/no/such/file.xyz")
        XCTAssertThrowsError(try Parser.load(url)) { err in
            guard case ParseError.io = err else { return XCTFail("wrong error") }
        }
    }
    func testXYZHappyPath() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si.xyz")
        let s = try Parser.load(url)
        XCTAssertEqual(s.atoms.count, 2)
        XCTAssertFalse(s.isCrystal)
        XCTAssertEqual(s.atoms[0].atomicNumber, 14)
        XCTAssertEqual(s.atoms[1].coord.x, 1.35, accuracy: 0.001)
        XCTAssertEqual(s.title.trimmingCharacters(in:.whitespacesAndNewlines), "Silicon dimer test")
    }
    func testXYZHappyPathWater() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/h2o.xyz")
        let s = try Parser.load(url)
        XCTAssertEqual(s.atoms.count, 3)
        XCTAssertEqual(s.atoms[0].atomicNumber, 8)
        XCTAssertEqual(s.atoms[1].atomicNumber, 1)
    }
    func testXYZMalformed() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/bad.xyz")
        XCTAssertThrowsError(try Parser.load(url)) { err in
            guard case ParseError.parse = err else { return XCTFail("expected parse error") }
        }
    }
}
