import XCTest
@testable import MolVisApp

final class ModelTests: XCTestCase {
    func testSceneDefaultValue() {
        let s = Scene()
        XCTAssertTrue(s.atoms.isEmpty)
        XCTAssertEqual(s.displayMode, .ballStick)
        XCTAssertEqual(s.superCell.n1, 1)
        XCTAssertNil(s.slab)
    }
    func testSuperCellIdentity() {
        let sc = SuperCell(n1: 1, n2: 1, n3: 1)
        XCTAssertEqual(sc.total, 1)
    }
}
