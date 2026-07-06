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
}
