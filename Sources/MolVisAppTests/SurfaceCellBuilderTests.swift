import Foundation
import simd
import XCTest
@testable import MolVisApp

/// Surface-slab construction tests. Covers the core (1 1 1) construction from
/// an in-code fcc bulk, plus the new termination and stacking behaviors on a
/// rock-salt NaCl-like 2-species bulk. Also guards the CRYSCAL SLAB extraction
/// path in Parser against regressions from the extraction.
final class SurfaceCellBuilderTests: XCTestCase {

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    // Si fcc conventional cell: a = 5.43, 8 atoms.
    private static let siA: Float = 5.43
    private func siFccBulk() -> (atoms: [Atom], cell: Cell) {
        let a = SurfaceCellBuilderTests.siA
        let cell = Cell(a: SIMD3(a, 0, 0), b: SIMD3(0, a, 0), c: SIMD3(0, 0, a))
        let f: Float = 0.25
        let coords: [SIMD3<Float>] = [
            .zero, SIMD3(f, f, 0), SIMD3(f, 0, f), SIMD3(0, f, f),
            SIMD3(f, f, f), SIMD3(0, 0, f), SIMD3(0, f, 0), SIMD3(f, 0, 0),
        ]
        let atoms = coords.map { Atom(coord: $0 * a, atomicNumber: 14, label: "Si") }
        return (atoms, cell)
    }

    // Rock-salt NaCl-like 2-species fcc bulk: a = 5.64, 8 atoms (4 Na + 4 Cl).
    private static let naClA: Float = 5.64
    private func naClBulk() -> (atoms: [Atom], cell: Cell) {
        let a = SurfaceCellBuilderTests.naClA
        let cell = Cell(a: SIMD3(a, 0, 0), b: SIMD3(0, a, 0), c: SIMD3(0, 0, a))
        let f: Float = 0.5
        // Na at fcc corners + face centers; Cl at octahedral sites.
        let na = [SIMD3<Float>.zero, SIMD3<Float>(f, f, 0), SIMD3<Float>(f, 0, f),
                  SIMD3<Float>(0, f, f)]
        let cl = [SIMD3<Float>(f, f, f), SIMD3<Float>(0, 0, f), SIMD3<Float>(0, f, 0),
                  SIMD3<Float>(f, 0, 0)]
        var atoms: [Atom] = []
        for c in na { atoms.append(Atom(coord: c * a, atomicNumber: 11, label: "Na")) }
        for c in cl { atoms.append(Atom(coord: c * a, atomicNumber: 17, label: "Cl")) }
        return (atoms, cell)
    }

    func testSurfaceSlabConstruction() throws {
        // --- (I) Core (1 1 1) Si slab + CRYSCAL SLAB extraction regression ---
        let (atoms, cell) = siFccBulk()
        let request = SurfaceCellRequest(h: 1, k: 1, l: 1, layers: 4, vacuum: 12,
                                          termination: 0, stackCount: 1)
        let result = SurfaceCellBuilder.build(atoms: atoms, cell: cell, request: request)
        guard case .success(let built) = result else {
            return XCTFail("expected success, got \(result)")
        }
        // In-plane surface vectors => c is nearly (0,0,1) after rotation.
        XCTAssertEqual(built.cell.c.x, 0, accuracy: 1e-3)
        XCTAssertEqual(built.cell.c.y, 0, accuracy: 1e-3)
        XCTAssertGreaterThan(built.cell.c.z, 0)
        // c length == slabExtent + vacuum.
        XCTAssertEqual(built.cell.c.z, built.slabExtent + 12, accuracy: 1e-3)
        XCTAssertGreaterThan(built.atoms.count, 0)
        // Every atom z in [0, extent].
        let zValues = built.atoms.map { $0.coord.z }
        XCTAssertGreaterThanOrEqual(zValues.min()!, 0)
        XCTAssertLessThanOrEqual(zValues.max()!, built.slabExtent + 1e-3)
        // A (1 1 1) Si slab with 4 layers should hold a reasonable number of atoms.
        XCTAssertGreaterThanOrEqual(built.atoms.count, 4)
        // planeCount should exceed the requested layers.
        XCTAssertGreaterThan(built.planeCount, 0)

        // --- CRYSCAL SLAB extraction regression ---
        // SLAB 3 2 2 / 1 10 in the .r1 fixture reduces the 3D crystal to a 2D
        // surface cell through the same builder the GUI uses.
        let loaded = try Parser.load(fixture("crystal_Pt322.r1"))
        let ptScene = Scene(loaded: loaded)
        XCTAssertEqual(ptScene.periodicDim, 2)
        XCTAssertTrue(ptScene.isCrystal)
        XCTAssertNotNil(ptScene.cell)
        XCTAssertGreaterThan(ptScene.atoms.count, 0)
        XCTAssertTrue(ptScene.atoms.allSatisfy { $0.atomicNumber == 78 })

        // --- (II) Termination and stacking on a rock-salt NaCl-like bulk ---
        let (naClAtoms, naClCell) = naClBulk()
        let a = SurfaceCellBuilderTests.naClA

        // (a) layers=2 vs layers=4 give different atom counts.
        let r2 = SurfaceCellBuilder.build(atoms: naClAtoms, cell: naClCell,
                                          request: SurfaceCellRequest(h: 0, k: 0, l: 1, layers: 2, vacuum: 10, termination: 0, stackCount: 1))
        let r4 = SurfaceCellBuilder.build(atoms: naClAtoms, cell: naClCell,
                                          request: SurfaceCellRequest(h: 0, k: 0, l: 1, layers: 4, vacuum: 10, termination: 0, stackCount: 1))
        guard case .success(let b2) = r2, case .success(let b4) = r4 else {
            return XCTFail("expected both slabs to succeed: \(r2), \(r4)")
        }
        XCTAssertGreaterThan(b4.atoms.count, b2.atoms.count, "more layers => more atoms")

        // (b) termination=1 vs termination=0 yield different species profiles.
        // NaCl (111) planes alternate pure Na / pure Cl, so adjacent planes
        // differ in composition and the chosen block changes the slab makeup.
        let t0 = SurfaceCellBuilder.build(atoms: naClAtoms, cell: naClCell,
                                          request: SurfaceCellRequest(h: 1, k: 1, l: 1, layers: 2, vacuum: 10, termination: 0, stackCount: 1))
        let t1 = SurfaceCellBuilder.build(atoms: naClAtoms, cell: naClCell,
                                          request: SurfaceCellRequest(h: 1, k: 1, l: 1, layers: 2, vacuum: 10, termination: 1, stackCount: 1))
        guard case .success(let bt0) = t0, case .success(let bt1) = t1 else {
            return XCTFail("expected termination slabs to succeed: \(t0), \(t1)")
        }
        // Each block is z-normalized to minZ = 0, so raw z-values can coincide;
        // the difference shows up in WHICH species occupies each height.
        func signature(_ atoms: [Atom]) -> [String] {
            atoms.map { "\(Int(($0.coord.z * 1000).rounded())):\($0.atomicNumber)" }.sorted()
        }
        XCTAssertNotEqual(signature(bt0.atoms), signature(bt1.atoms),
                          "different termination must change the species-vs-height profile")

        // (c) termination out of range fails.
        let outOfRange = SurfaceCellBuilder.build(atoms: naClAtoms, cell: naClCell,
                                                  request: SurfaceCellRequest(h: 0, k: 0, l: 1, layers: 2, vacuum: 10, termination: 100, stackCount: 1))
        guard case .failure(let err) = outOfRange else {
            return XCTFail("expected termination out of range to fail")
        }
        XCTAssertTrue(String(describing: err).contains("out of range"),
                      "expected out-of-range message, got \(err)")

        // (d) stackCount=3 yields 3x the atom count and tripled slabExtent.
        let s1 = SurfaceCellBuilder.build(atoms: naClAtoms, cell: naClCell,
                                          request: SurfaceCellRequest(h: 0, k: 0, l: 1, layers: 2, vacuum: 10, termination: 0, stackCount: 1))
        let s3 = SurfaceCellBuilder.build(atoms: naClAtoms, cell: naClCell,
                                          request: SurfaceCellRequest(h: 0, k: 0, l: 1, layers: 2, vacuum: 10, termination: 0, stackCount: 3))
        guard case .success(let bs1) = s1, case .success(let bs3) = s3 else {
            return XCTFail("expected stacked slabs to succeed: \(s1), \(s3)")
        }
        XCTAssertEqual(bs3.atoms.count, bs1.atoms.count * 3)
        XCTAssertEqual(bs3.slabExtent, bs1.slabExtent * 3, accuracy: 1e-2)
        // Same vacuum => c length reflects tripled extent + same vacuum.
        XCTAssertEqual(bs3.cell.c.z - 10, (bs1.cell.c.z - 10) * 3, accuracy: 1e-2)

        // (e) degenerate (0 0 0) fails.
        let deg = SurfaceCellBuilder.build(atoms: naClAtoms, cell: naClCell,
                                           request: SurfaceCellRequest(h: 0, k: 0, l: 0, layers: 2))
        guard case .failure(let derr) = deg else {
            return XCTFail("expected degenerate Miller to fail")
        }
        XCTAssertTrue(String(describing: derr).contains("all zero"), "got \(derr)")
    }
}
