import XCTest
@testable import MolVisApp
final class SceneTests: XCTestCase {
    func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }
    func testXSFHappyPath() throws {
        let s = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        XCTAssertEqual(s.atoms.count, 2)
        XCTAssertTrue(s.isCrystal)
        XCTAssertNotNil(s.cell)
        XCTAssertEqual(s.atoms[0].atomicNumber, 14)
    }
    func testPDBHappyPath() throws {
        let s = Scene(loaded: try Parser.load(fixture("ala.pdb")))
        XCTAssertEqual(s.atoms.count, 5)
        XCTAssertFalse(s.isCrystal)
    }
    func testAXSFFrameSelection() throws {
        let s0 = try Parser.load(fixture("si.latch.axsf"))
        XCTAssertEqual(s0.atoms.count, 2)
        let s1 = try Parser.load(fixture("si.latch.axsf"), frameIndex: 1)
        XCTAssertEqual(s1.atoms.count, 2)
        XCTAssertNotEqual(s1.atoms[0].coord.x, s0.atoms[0].coord.x, accuracy: 0.0001)
    }
    func testDATAGRIDRejected() throws {
        let url = fixture("si.grid.xsf")      // you create this small fixture with a BEGIN_DATAGRID_3D block
        XCTAssertThrowsError(try Parser.load(url)) { err in
            guard case ParseError.parse = err else { return XCTFail("expected parse error") }
        }
    }
    func testSupercellDoubles() throws {
        var s = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        s = s.widenSuperCell(SuperCell(n1: 2, n2: 1, n3: 1))
        XCTAssertEqual(s.atoms.count, 4)
    }
    func testSupercellDoublesAtoms() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        var s = Scene(loaded: try Parser.load(url))
        s = s.widenSuperCell(SuperCell(n1: 2, n2: 1, n3: 1))
        XCTAssertEqual(s.atoms.count, 4)
    }
    func testSlabPreservesSubset() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        var s = Scene(loaded: try Parser.load(url))
        let before = s.atoms.count
        s = s.applySlab(Slab(planeA: Plane(h:0,k:1,l:0,distance:0), planeB: Plane(h:0,k:-1,l:0,distance:1e9)))
        XCTAssertLessThanOrEqual(s.atoms.count, before)
    }
}
