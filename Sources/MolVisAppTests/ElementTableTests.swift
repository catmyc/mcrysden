import XCTest
import simd
@testable import MolVisApp

// Locks down Important #1 of the final review: ElementTable must never trap a
// Swift bounds error for any Z in 0..118. Before the fix, covalent (118
// entries) and vdw (98 entries) were shorter than colors (119), so a single
// clamp against colors.count let Z=118 (covalent) and Z>=98 (vdw) read past the
// end. All arrays are now padded to a shared capacity of 119.
final class ElementTableTests: XCTestCase {
    func testHeavyElementDoesNotCrash() {
        // Z=118 (Oganesson) is the heaviest tabulated element.
        XCTAssertEqual(ElementTable.covalentRadius(118), 1.34, accuracy: 0.001)
        XCTAssertEqual(ElementTable.vdwRadius(118), 2.07, accuracy: 0.001)
        let c = ElementTable.color(118)
        XCTAssertEqual(c.x, 0.26, accuracy: 0.001)
        XCTAssertEqual(ElementTable.symbol(118), "Og")
    }

    func testBoundaryLookups() {
        // color(0) is the dummy entry (white), exactly colors[0].
        XCTAssertEqual(ElementTable.color(0), SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(ElementTable.symbol(0), "X")
        XCTAssertEqual(ElementTable.symbol(1), "H")
        XCTAssertEqual(ElementTable.covalentRadius(1), 0.31, accuracy: 0.001)
        XCTAssertEqual(ElementTable.vdwRadius(1), 1.20, accuracy: 0.001)
    }

    func testClampIsSymmetricAcrossRange() {
        // Every valid Z must resolve without a bounds trap.
        for z in 0...118 {
            _ = ElementTable.color(z)
            _ = ElementTable.covalentRadius(z)
            _ = ElementTable.vdwRadius(z)
            _ = ElementTable.symbol(z)
        }
        // Out-of-range inputs clamp, never crash.
        _ = ElementTable.color(-1)
        _ = ElementTable.vdwRadius(9999)
    }
}
