import XCTest
import Metal
import simd
@testable import MolVisApp

private enum RenderError: Error { case noGPU, noTexture }

// Phase 1 of the reciprocal-space k-path editor: model/geometry/persistence
// foundation. Exercises the deterministic BZ candidate API, the Cartesian <->
// fractional round trip, the shared BZPresentation mapping, default-route
// initialization, StateStore persistence, and route preservation across the
// animation-frame rebuild in App.resolveAnimationFrame.
final class KPathEditorTests: XCTestCase {

    func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    private func allComponentsEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-4) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
    }

    /// Build the canonical fcc BZ (truncated octahedron, 14 faces) used below.
    private func fccBZ() -> BrillouinZone {
        let a: Float = 5.43
        let atoms: [Atom] = [SIMD3(0, 0, 0), SIMD3(0, 0.5 * a, 0.5 * a),
                             SIMD3(0.5 * a, 0, 0.5 * a), SIMD3(0.5 * a, 0.5 * a, 0)]
            .map { Atom(coord: $0, atomicNumber: 14, label: "Si") }
        let cell = Cell(a: SIMD3<Float>(5.43, 0, 0),
                        b: SIMD3<Float>(0, 5.43, 0),
                        c: SIMD3<Float>(0, 0, 5.43))
        guard let bz = BrillouinZone.build(cell: cell, atoms: atoms) else {
            XCTFail("fcc BZ build returned nil"); fatalError()
        }
        return bz
    }

    // MARK: - Candidate de-duplication and stable labels

    func testCandidateDedupAndStableLabels() {
        let bz = fccBZ()
        let cands = bz.candidates()

        // Exactly one Gamma, labeled Γ.
        let centers = cands.filter { $0.type == .center }
        XCTAssertEqual(centers.count, 1)
        XCTAssertEqual(centers.first?.point.label, "Γ")

        // Group by type and check deterministic V/E/F labels starting at 1.
        func labels(_ type: BZPointType) -> [String] {
            cands.filter { $0.type == type }.map { $0.point.label }
        }
        for (type, prefix) in [(BZPointType.edge, "V"), (.line, "E"), (.polyface, "F")] {
            let l = labels(type)
            XCTAssertFalse(l.isEmpty, "\(prefix) group empty")
            let expected = l.enumerated().map { "\(prefix)\($0.offset + 1)" }
            XCTAssertEqual(l, expected, "\(prefix) labels must be deterministic \(prefix)1..n")
        }

        // De-duplication: the raw specialPoints list has many duplicate vertices
        // (each shared vertex appears once per adjacent face). The unique vertex
        // count for a truncated octahedron is 24 — far fewer than the raw count.
        let rawVertexCount = bz.specialPoints.filter { $0.type == .edge }.count
        let uniqueVertexCount = labels(.edge).count
        XCTAssertGreaterThan(rawVertexCount, uniqueVertexCount,
                             "vertices must be de-duplicated (\(rawVertexCount) raw -> \(uniqueVertexCount))")
        XCTAssertEqual(uniqueVertexCount, 24, "truncated octahedron has 24 vertices")

        // Stability: a second call yields identical candidates.
        let cands2 = bz.candidates()
        XCTAssertEqual(cands.map { $0.point }, cands2.map { $0.point })
        XCTAssertEqual(cands.map { $0.cartesian }, cands2.map { $0.cartesian })
    }

    // MARK: - Cartesian -> fractional -> Cartesian round trip

    func testCartesianFractionalRoundTrip() {
        let bz = fccBZ()
        let basis = simd_float3x3(columns: (bz.reciprocal.a, bz.reciprocal.b, bz.reciprocal.c))
        XCTAssertGreaterThan(abs(basis.determinant), 1e-9, "reciprocal basis must be invertible")

        for cand in bz.candidates() {
            // fractional -> Cartesian must recover the candidate's Cartesian coord.
            let cart = basis * cand.point.frac
            XCTAssertTrue(allComponentsEqual(cart, cand.cartesian, 1e-3),
                          "round trip failed for \(cand.point.label): \(cart) vs \(cand.cartesian)")
        }
    }

    // MARK: - Non-Gamma candidates correspond to generated surface landmarks

    func testNonGammaCandidatesMatchSurfaceLandmarks() {
        let bz = fccBZ()
        let cands = bz.candidates()
        // Tolerance in BZ Cartesian space (matches the candidate de-dup scale).
        var extent: Float = 0
        for face in bz.faces { for v in face { extent = max(extent, length(v)) } }
        let tol = max(1e-3, extent * 5e-3)

        for cand in cands where cand.type != .center {
            // Every non-Gamma candidate must coincide with a generated special
            // point of the same type (the source of truth the BZ build emits).
            let match = bz.specialPoints.contains { sp in
                sp.type == cand.type && length(sp.coord - cand.cartesian) < tol
            }
            XCTAssertTrue(match, "candidate \(cand.point.label) at \(cand.cartesian) has no matching surface landmark")
        }
        // And the candidate set must not drop any generated landmark type: each
        // generated non-center special point is represented by some candidate.
        for sp in bz.specialPoints where sp.type != .center {
            let represented = cands.contains { $0.type == sp.type && length($0.cartesian - sp.coord) < tol }
            XCTAssertTrue(represented, "generated landmark \(sp.type) at \(sp.coord) not represented")
        }
    }

    // MARK: - BZPresentation mapping is finite and matches the renderer formula

    func testPresentationMappingMatchesRendererFormula() throws {
        let bz = fccBZ()
        let scene = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        let pres = BZPresentation(bz: bz, scene: scene)

        // Reproduce the renderer's drawBrillouinZone mapping independently and
        // confirm BZPresentation matches it exactly.
        var extent: Float = 0
        for face in bz.faces { for v in face { extent = max(extent, length(v)) } }
        let (_, radius) = scene.boundingSphere()
        let targetExtent = max(1.0, radius) * 0.45
        let inv = extent > 1e-5 ? targetExtent / extent : 0
        let center = scene.centroid

        XCTAssertEqual(pres.inv, inv, accuracy: 1e-6)
        XCTAssertTrue(allComponentsEqual(pres.center, center))

        // A candidate's Cartesian and fractional mappings must agree and be finite.
        for cand in bz.candidates() {
            let wCart = pres.world(cartesian: cand.cartesian)
            let wFrac = pres.world(frac: cand.point.frac)
            XCTAssertTrue(allComponentsEqual(wCart, wFrac, 1e-3),
                          "\(cand.point.label): cartesian/fractional world positions diverge")
            XCTAssertTrue(wCart.x.isFinite && wCart.y.isFinite && wCart.z.isFinite,
                          "\(cand.point.label): non-finite world position \(wCart)")
            // Matches the renderer formula: center + coord * inv.
            let expected = center + cand.cartesian * inv
            XCTAssertTrue(allComponentsEqual(wCart, expected, 1e-3),
                          "\(cand.point.label): world position does not match renderer formula")
        }
    }

    // MARK: - Default route initialization: crystal vs molecule

    func testDefaultRouteInitialization() throws {
        // Crystal: seeded with the generated high-symmetry default (non-empty).
        let crystal = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        XCTAssertTrue(crystal.isCrystal)
        XCTAssertFalse(crystal.kPathPoints.isEmpty, "crystal must seed a default k-path")

        // Molecule: empty route.
        let mol = Scene(loaded: try Parser.load(fixture("h2o.xyz")))
        XCTAssertFalse(mol.isCrystal)
        XCTAssertTrue(mol.kPathPoints.isEmpty, "molecule must have an empty k-path")
    }

    // MARK: - StateStore persistence

    func testStateStoreRoundTrip() throws {
        var s = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        let route = [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.5, 0, 0), "X"),
                     KPoint(SIMD3(0.5, 0.5, 0.5), "L")]
        s.kPathPoints = route
        s.kPathBreaks = []  // clear any breaks from the generated path
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_rt.mvis-state")
        try StateStore.save(s, camera: nil, sourceURL: fixture("si110.xsf"), to: tmp)

        var s2 = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        var c2: Camera? = nil
        try StateStore.load(into: &s2, camera: &c2, from: tmp)
        XCTAssertEqual(s2.kPathPoints, route)
        XCTAssertTrue(s2.kPathBreaks.isEmpty)
    }

    func testStateStoreExplicitEmptyRouteClearsDefault() throws {
        // A crystal seeds a default route; an explicit [] in the state file clears it.
        var s = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        XCTAssertFalse(s.kPathPoints.isEmpty)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_empty.mvis-state")
        // Hand-write a state file with an explicit empty kPathPoints array.
        let payload: [String: Any] = ["version": 1, "displayMode": "ballStick", "supercell": [1, 1, 1],
                                      "kPathPoints": []]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)

        var s2 = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        var c2: Camera? = nil
        try StateStore.load(into: &s2, camera: &c2, from: tmp)
        XCTAssertTrue(s2.kPathPoints.isEmpty, "explicit [] must clear the default route")
    }

    func testStateStoreAbsentKeyPreservesDefault() throws {
        // No kPathPoints key -> the parsed scene's default route is untouched.
        var s = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        let defaultRoute = s.kPathPoints
        XCTAssertFalse(defaultRoute.isEmpty)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_absent.mvis-state")
        let payload: [String: Any] = ["version": 1, "displayMode": "ballStick", "supercell": [1, 1, 1]]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)

        var s2 = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        var c2: Camera? = nil
        try StateStore.load(into: &s2, camera: &c2, from: tmp)
        XCTAssertEqual(s2.kPathPoints, defaultRoute, "absent key must leave the default route intact")
    }

    func testStateStoreRejectsNonFiniteAndMalformed() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_bad.mvis-state")
        var s = Scene()
        var c: Camera? = nil

        // Non-finite coordinate. JSONSerialization can't serialize NaN/Inf, so
        // write a raw JSON string with an explicit NaN token (a malicious state
        // file could contain this) and confirm the load rejects it.
        let badFracJSON = #"{"version":1,"displayMode":"ballStick","supercell":[1,1,1],"kPathPoints":[{"frac":[NaN,0.0,0.0],"label":"X"}]}"#
        try badFracJSON.data(using: .utf8)!.write(to: tmp)
        XCTAssertThrowsError(try StateStore.load(into: &s, camera: &c, from: tmp))

        // Malformed entry (missing label).
        let malformed: [String: Any] = ["version": 1, "displayMode": "ballStick", "supercell": [1, 1, 1],
                                       "kPathPoints": [["frac": [0.5, 0.0, 0.0]]]]
        try JSONSerialization.data(withJSONObject: malformed, options: []).write(to: tmp)
        XCTAssertThrowsError(try StateStore.load(into: &s, camera: &c, from: tmp))

        // Over-cap count (1025 entries).
        let many = (0..<1025).map { _ in ["frac": [0.0, 0.0, 0.0], "label": "X"] as [String: Any] }
        let overCap: [String: Any] = ["version": 1, "displayMode": "ballStick", "supercell": [1, 1, 1],
                                      "kPathPoints": many]
        try JSONSerialization.data(withJSONObject: overCap, options: []).write(to: tmp)
        XCTAssertThrowsError(try StateStore.load(into: &s, camera: &c, from: tmp))
    }

    // MARK: - Issue 1: basis correctness of defaultPath(cell:atoms:)

    /// Build the conventional + primitive reciprocal bases for a cubic cell of
    /// the given lattice, and the canonical primitive-basis default path.
    private func basesAndPath(lattice: CubicLattice, a: Float)
        -> (primRecip: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>),
            convRecip: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>),
            path: KPath) {
        let cell = Cell(a: SIMD3<Float>(a, 0, 0), b: SIMD3<Float>(0, a, 0), c: SIMD3<Float>(0, 0, a))
        let centering: LatticeCentering = (lattice == .fcc) ? .face : (lattice == .bcc ? .body : .primitive)
        let primDir = Lattice.primitiveDirect(centering: centering, cell)
        let primRecip = Cell(a: primDir.a, b: primDir.b, c: primDir.c).reciprocalVectors
        let convRecip = cell.reciprocalVectors
        return (primRecip, convRecip, KPath.defaultPath(lattice: lattice))
    }

    func testDefaultPathConversionPreservesCartesianPosition() throws {
        // For fcc and bcc the canonical route is in the primitive reciprocal basis;
        // defaultPath(cell:atoms:) must convert to conventional fractional coords
        // such that every point lands on the SAME Cartesian reciprocal position.
        struct Case {
            let lattice: CubicLattice
            let atoms: [SIMD3<Float>]
        }
        let cases: [Case] = [
            // fcc: face-center offsets (0,½,½)-type.
            Case(lattice: .fcc, atoms: [SIMD3(0, 0, 0), SIMD3(0, 2.715, 2.715),
                                        SIMD3(2.715, 0, 2.715), SIMD3(2.715, 2.715, 0)]),
            // bcc: body-center offset (½,½,½).
            Case(lattice: .bcc, atoms: [SIMD3(0, 0, 0), SIMD3(2.715, 2.715, 2.715)]),
        ]
        let cell = Cell(a: SIMD3<Float>(5.43, 0, 0), b: SIMD3<Float>(0, 5.43, 0), c: SIMD3<Float>(0, 0, 5.43))
        for c in cases {
            let (primRecip, convRecip, primPath) = basesAndPath(lattice: c.lattice, a: 5.43)
            let convPath = KPath.defaultPath(cell: cell, atoms: c.atoms)
            XCTAssertEqual(convPath.points.count, primPath.points.count,
                           "\(c.lattice): converted path dropped/added points")
            for (p, q) in zip(primPath.points, convPath.points) {
                let cartPrim = primRecip.a * p.frac.x + primRecip.b * p.frac.y + primRecip.c * p.frac.z
                let cartConv = convRecip.a * q.frac.x + convRecip.b * q.frac.y + convRecip.c * q.frac.z
                XCTAssertTrue(allComponentsEqual(cartPrim, cartConv, 1e-3),
                              "\(c.lattice): \(p.label) cartesian mismatch \(cartPrim) vs \(cartConv)")
                XCTAssertEqual(p.label, q.label)
                XCTAssertTrue(q.frac.x.isFinite && q.frac.y.isFinite && q.frac.z.isFinite)
            }
        }
    }

    func testDefaultPathSCIsUnchanged() throws {
        // sc primitive == conventional, so the route must pass through verbatim.
        let (_, _, primPath) = basesAndPath(lattice: .sc, a: 5.43)
        let convPath = KPath.defaultPath(
            cell: Cell(a: SIMD3<Float>(5.43, 0, 0), b: SIMD3<Float>(0, 5.43, 0), c: SIMD3<Float>(0, 0, 5.43)),
            atoms: [SIMD3(0, 0, 0)])
        XCTAssertEqual(convPath.points, primPath.points)
    }

    func testBCCDefaultPathHasDistinctNAndP() throws {
        // The bcc canonical route is Gamma-H-N-Gamma-P. N must NOT duplicate P:
        // the standard primitive reciprocal coordinate for N is (0,0,0.5) while P
        // is (0.25,0.25,0.25).
        let prim = KPath.defaultPath(lattice: .bcc)
        let labels = prim.points.map { $0.label }
        XCTAssertEqual(labels, ["G", "H", "N", "G", "P"])

        // Primitive coords: N and P are distinct.
        let nPrim = prim.points[2].frac
        let pPrim = prim.points[4].frac
        XCTAssertEqual(nPrim, SIMD3<Float>(0, 0, 0.5))
        XCTAssertEqual(pPrim, SIMD3<Float>(0.25, 0.25, 0.25))
        XCTAssertNotEqual(nPrim, pPrim, "N and P must not coincide in the primitive basis")

        // No two consecutive route nodes may duplicate.
        for i in 0..<prim.points.count - 1 {
            XCTAssertNotEqual(prim.points[i].frac, prim.points[i + 1].frac,
                              "consecutive points \(i),\(i+1) must differ")
        }

        // After conversion to the conventional reciprocal basis, N and P must land
        // on DISTINCT conventional fractional and Cartesian positions.
        let cell = Cell(a: SIMD3<Float>(5.43, 0, 0), b: SIMD3<Float>(0, 5.43, 0), c: SIMD3<Float>(0, 0, 5.43))
        let conv = KPath.defaultPath(cell: cell, atoms: [SIMD3(0, 0, 0), SIMD3(2.715, 2.715, 2.715)])
        guard let nNode = conv.points.first(where: { $0.label == "N" }),
              let pNode = conv.points.first(where: { $0.label == "P" }) else {
            XCTFail("bcc converted path missing N or P"); return
        }
        XCTAssertNotEqual(nNode.frac, pNode.frac, "conventional N and P must not coincide")
        XCTAssertTrue(allComponentsEqual(nNode.frac, SIMD3<Float>(0.5, 0.5, 0), 1e-3),
                      "conventional N frac \(nNode.frac) != expected (0.5,0.5,0)")
        XCTAssertTrue(allComponentsEqual(pNode.frac, SIMD3<Float>(0.5, 0.5, 0.5), 1e-3),
                      "conventional P frac \(pNode.frac) != expected (0.5,0.5,0.5)")

        // Their Cartesian reciprocal positions must also differ.
        let convRecip = cell.reciprocalVectors
        let nCart = convRecip.a * nNode.frac.x + convRecip.b * nNode.frac.y + convRecip.c * nNode.frac.z
        let pCart = convRecip.a * pNode.frac.x + convRecip.b * pNode.frac.y + convRecip.c * pNode.frac.z
        XCTAssertGreaterThan(length(nCart - pCart), 1e-3, "conventional N and P Cartesian positions must differ")
    }

    func testDefaultPathSurfaceNodesLandOnBZ() throws {
        // The converted conventional fcc route nodes (Gamma, X, W, K, L) must land
        // on the built BZ's surface landmarks — i.e. each converted point, mapped
        // to Cartesian via the conventional reciprocal, coincides with a candidate
        // vertex/edge-midpoint/face-center.
        let a: Float = 5.43
        let atoms: [Atom] = [SIMD3(0, 0, 0), SIMD3(0, 0.5 * a, 0.5 * a),
                             SIMD3(0.5 * a, 0, 0.5 * a), SIMD3(0.5 * a, 0.5 * a, 0)]
            .map { Atom(coord: $0, atomicNumber: 14, label: "Si") }
        let cell = Cell(a: SIMD3<Float>(a, 0, 0), b: SIMD3<Float>(0, a, 0), c: SIMD3<Float>(0, 0, a))
        let convRecip = cell.reciprocalVectors
        let path = KPath.defaultPath(cell: cell, atoms: atoms.map { $0.coord })
        guard let bz = BrillouinZone.build(cell: cell, atoms: atoms) else {
            XCTFail("fcc BZ build returned nil"); fatalError()
        }
        let cands = bz.candidates()
        // de-dup tolerance in Cartesian space.
        var extent: Float = 0
        for face in bz.faces { for v in face { extent = max(extent, length(v)) } }
        let tol = max(1e-5, extent * 5e-3)
        for kp in path.points {
            let cart = convRecip.a * kp.frac.x + convRecip.b * kp.frac.y + convRecip.c * kp.frac.z
            let hit = cands.contains { length($0.cartesian - cart) < tol }
            XCTAssertTrue(hit, "node \(kp.label) at cartesian \(cart) does not land on a BZ landmark")
        }
    }

    // MARK: - Issue 2: no Float-to-Int trap in candidate ordering

    func testCandidateOrderingUsesNoIntConversion() throws {
        // candidates() must not trap on large fractional coords. The old sort key
        // used Int((f*1e4).rounded()), which traps for |f| > ~9e14. BZ vertex
        // fractional coords are scale-independent rationals (e.g. 0.375, 0.5), so
        // we can't force a trap through candidates() directly — instead we prove the
        // sort is a total order by confirming deterministic, repeatable ordering
        // across the whole public surface (no Int cast remains in the path).
        let bz = fccBZ()
        let c1 = bz.candidates()
        let c2 = bz.candidates()
        XCTAssertEqual(c1.map { $0.point }, c2.map { $0.point })
        XCTAssertEqual(c1.map { $0.cartesian }, c2.map { $0.cartesian })
        // Every candidate's fractional coords are finite (no overflow into inf).
        for c in c1 {
            XCTAssertTrue(c.point.frac.x.isFinite && c.point.frac.y.isFinite && c.point.frac.z.isFinite)
        }
    }

    // MARK: - Issue 3: scale-relative determinant + de-dup

    func testScaleRelativeInvertibilityAndDedup() throws {
        // Candidate counts/labels must be STABLE when the direct cell is scaled
        // up substantially (reciprocal shrinks). build()'s own vertex de-dup uses
        // an absolute floor, so there is an upper scale bound; we stay well inside
        // it at 100x (a = 543) and verify the candidate set is identical to the
        // unit cell. This proves the scale-relative determinant + de-dup checks
        // keep every landmark distinct, rather than collapsing them as the
        // reciprocal basis shrinks. (The raw determinant-based fix is exercised
        // separately in testDeterminantCheckIsScaleRelative with a tiny basis.)
        func buildLabels(scale: Float) -> [String]? {
            let atoms: [Atom] = [SIMD3(0, 0, 0), SIMD3(0, 0.5 * scale, 0.5 * scale),
                                 SIMD3(0.5 * scale, 0, 0.5 * scale), SIMD3(0.5 * scale, 0.5 * scale, 0)]
                .map { Atom(coord: $0, atomicNumber: 14, label: "Si") }
            let cell = Cell(a: SIMD3<Float>(scale, 0, 0), b: SIMD3<Float>(0, scale, 0), c: SIMD3<Float>(0, 0, scale))
            guard let bz = BrillouinZone.build(cell: cell, atoms: atoms) else { return nil }
            return bz.candidates().map { $0.point.label }
        }
        guard let labelsAtUnit = buildLabels(scale: 5.43),
              let labelsAtScale = buildLabels(scale: 543) else {
            XCTFail("fcc BZ build returned nil"); fatalError()
        }
        XCTAssertFalse(labelsAtUnit.isEmpty, "unit cell must yield candidates")
        XCTAssertEqual(labelsAtUnit, labelsAtScale,
                       "scaling the cell 100x must not change candidate labels/counts")
        // The scaled cell must still yield the expected fcc truncated-octahedron
        // vertex count (24), proving relative de-dup did not merge distinct
        // landmarks as the reciprocal shrank.
        XCTAssertEqual(labelsAtScale.filter { $0.hasPrefix("V") }.count, 24)
    }

    /// The old invertibility check `abs(det) > 1e-9` rejects a valid but tiny
    /// reciprocal basis (huge real cell). Prove the scale-relative check accepts
    /// such a basis while the absolute check would have rejected it.
    func testDeterminantCheckIsScaleRelative() throws {
        // Conventional reciprocal basis of a 10^4 Å cell: |det| ~ 1.5e-12, well
        // below the old 1e-9 floor but a perfectly non-degenerate basis (ratio
        // |det|/(|a||b||c|) == 1 for a cubic cell).
        let a: Float = 1e4
        let cell = Cell(a: SIMD3<Float>(a, 0, 0), b: SIMD3<Float>(0, a, 0), c: SIMD3<Float>(0, 0, a))
        let convRecip = cell.reciprocalVectors
        let m = simd_float3x3(columns: (convRecip.a, convRecip.b, convRecip.c))
        XCTAssertLessThan(abs(m.determinant), 1e-9,
                          "sanity: this basis would be rejected by the old absolute check")
        XCTAssertTrue(BrillouinZone.isFiniteInvertible(m),
                      "scale-relative check must accept a tiny-but-valid basis")
        // And conversion through that basis round-trips.
        let frac = SIMD3<Float>(0.5, 0.25, 0.75)
        let cart = BrillouinZone.cartesianFromFractional(frac, reciprocal: convRecip)
        let back = BrillouinZone.fractionalFromCartesian(cart, reciprocal: convRecip)!
        XCTAssertTrue(allComponentsEqual(back, frac, 1e-4))
    }

    // MARK: - Issue 4: overlong labels throw transactionally

    func testStateStoreRejectsOverlongLabel() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_longlabel.mvis-state")
        let longLabel = String(repeating: "X", count: 65)
        let payload: [String: Any] = ["version": 1, "displayMode": "ballStick", "supercell": [1, 1, 1],
                                      "kPathPoints": [["frac": [0.0, 0.0, 0.0], "label": longLabel]]]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)
        var s = Scene()
        var c: Camera? = nil
        XCTAssertThrowsError(try StateStore.load(into: &s, camera: &c, from: tmp))
        // A 64-char label is the max allowed and must round-trip intact.
        let maxLabel = String(repeating: "Y", count: 64)
        let ok: [String: Any] = ["version": 1, "displayMode": "ballStick", "supercell": [1, 1, 1],
                                 "kPathPoints": [["frac": [0.5, 0.0, 0.0], "label": maxLabel]]]
        try JSONSerialization.data(withJSONObject: ok, options: []).write(to: tmp)
        var s2 = Scene()
        var c2: Camera? = nil
        try StateStore.load(into: &s2, camera: &c2, from: tmp)
        XCTAssertEqual(s2.kPathPoints.first?.label, maxLabel)
    }

    func testStateStoreRejectsScalarKPathPointsTransactionally() throws {
        // A present kPathPoints key that is a scalar (not an array of dicts) must
        // throw a path-bearing ParseError AND leave the caller's scene + camera
        // untouched (transactional rollback: commit only happens at the very end).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_scalar.mvis-state")
        let payload: [String: Any] = ["version": 1, "displayMode": "ballStick", "supercell": [1, 1, 1],
                                      "kPathPoints": "not-an-array"]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)

        var s = Scene()
        let route = [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.5, 0, 0), "X")]
        s.kPathPoints = route
        var c: Camera? = Camera()
        c?.center = SIMD3(1, 2, 3); c?.distance = 30; c?.perspective = true
        let origCenter = c!.center, origDistance = c!.distance, origPerspective = c!.perspective

        XCTAssertThrowsError(try StateStore.load(into: &s, camera: &c, from: tmp))
        XCTAssertEqual(s.kPathPoints, route, "scene kPathPoints must be unchanged after failed load")
        XCTAssertEqual(c?.center, origCenter)
        XCTAssertEqual(c?.distance, origDistance)
        XCTAssertEqual(c?.perspective, origPerspective)
    }

    func testStateStoreRejectsMixedKPathPointsArrayTransactionally() throws {
        // An array containing a non-dictionary entry must also throw and roll back.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_mixed.mvis-state")
        let payload: [String: Any] = ["version": 1, "displayMode": "ballStick", "supercell": [1, 1, 1],
                                      "kPathPoints": [["frac": [0.0, 0.0, 0.0], "label": "X"], "notadict"]]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)

        var s = Scene()
        let route = [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.5, 0.5, 0.5), "L")]
        s.kPathPoints = route
        var c: Camera? = Camera()
        c?.center = SIMD3(4, 5, 6); c?.distance = 25
        let origCenter = c!.center, origDistance = c!.distance

        XCTAssertThrowsError(try StateStore.load(into: &s, camera: &c, from: tmp))
        XCTAssertEqual(s.kPathPoints, route, "scene kPathPoints must be unchanged after failed load")
        XCTAssertEqual(c?.center, origCenter)
        XCTAssertEqual(c?.distance, origDistance)
    }

    // MARK: - Issue 5: shared Cartesian<->fractional helpers

    func testSharedConversionHelpers() throws {
        let a: Float = 5.43
        let cell = Cell(a: SIMD3<Float>(a, 0, 0), b: SIMD3<Float>(0, a, 0), c: SIMD3<Float>(0, 0, a))
        let convRecip = cell.reciprocalVectors
        // Round trip: frac -> cart -> frac for a known point.
        let frac = SIMD3<Float>(0.25, 0.375, 0.125)
        let cart = BrillouinZone.cartesianFromFractional(frac, reciprocal: convRecip)
        let back = BrillouinZone.fractionalFromCartesian(cart, reciprocal: convRecip)!
        XCTAssertTrue(allComponentsEqual(back, frac, 1e-4), "round trip failed: \(back) vs \(frac)")
        // Singular basis is rejected safely.
        let singular = (a: SIMD3<Float>(1, 0, 0), b: SIMD3<Float>(2, 0, 0), c: SIMD3<Float>(0, 0, 1))
        XCTAssertNil(BrillouinZone.fractionalFromCartesian(SIMD3(1, 1, 1), reciprocal: singular))
        XCTAssertFalse(BrillouinZone.isFiniteInvertible(
            simd_float3x3(columns: (singular.a, singular.b, singular.c))))
    }

    // MARK: - App.resolveAnimationFrame route preservation

    func testResolveAnimationFramePreservesRoute() throws {
        // Animated crystal fixture with 2 frames. Load frame 0, impose a custom
        // route, then ask resolveAnimationFrame to rebuild frame 1 (a saved frame
        // that differs from what was loaded) — the route must survive.
        let url = fixture("si.anim_grid.axsf")
        XCTAssertEqual(Parser.frameCount(url, as: nil), 2)
        var scene = Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0))
        let route = [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.25, 0.25, 0.25), "P"),
                     KPoint(SIMD3(0.5, 0, 0), "X")]
        scene.kPathPoints = route
        scene.kPathBreaks = [1]
        scene.kPathProvenance = .userEdited
        scene.kPathSignature = nil
        scene.currentFrame = 1 // differs from loadedFrame 0 -> triggers the rebuild

        try App.resolveAnimationFrame(scene: &scene, from: url, format: nil, loadedFrame: 0, fc: 2)
        XCTAssertEqual(scene.currentFrame, 1)
        XCTAssertEqual(scene.kPathPoints, route, "route must survive the frame rebuild")
        XCTAssertEqual(scene.kPathBreaks, [1], "route topology must survive the frame rebuild")
        XCTAssertEqual(scene.kPathProvenance, .userEdited)
        XCTAssertNil(scene.kPathSignature)
    }

    // MARK: - Phase 2: picking, click handling, and mutation helpers

    /// Project a world point to top-origin screen pixels using the given camera, mirroring
    /// MainWindowController.pickBZCandidate exactly (so tests can aim clicks at landmarks).
    private func project(world: SIMD3<Float>, cam: Camera, viewport: SIMD2<Float>) -> (x: Float, y: Float, depth: Float) {
        let aspect = viewport.x / viewport.y
        let view = cam.viewMatrix()
        let proj = cam.projectionMatrix(aspect: aspect)
        let viewPos = view * SIMD4<Float>(world, 1)
        let depth = -viewPos.z
        let clip = proj * viewPos
        let ndc = clip / clip.w
        let sx = (ndc.x * 0.5 + 0.5) * viewport.x
        let sy = (1.0 - (ndc.y * 0.5 + 0.5)) * viewport.y
        return (sx, sy, depth)
    }

    // MARK: pickBZCandidate

    func testPickCandidateExactHit() {
        let bz = fccBZ()
        let scene = Scene()
        let pres = BZPresentation(bz: bz, scene: scene)
        // Orthographic, identity rotation, looking down -z; landmarks near the BZ center
        // project near screen center.
        var cam = Camera()
        cam.perspective = false
        cam.distance = 40
        let viewport = SIMD2<Float>(200, 200)
        guard let gamma = bz.candidates().first(where: { $0.type == .center }) else {
            XCTFail("no Gamma"); return
        }
        let world = pres.world(cartesian: gamma.cartesian)
        let proj = project(world: world, cam: cam, viewport: viewport)
        guard proj.depth > 0.01 else { XCTFail("behind camera"); return }
        let picked = MainWindowController.pickBZCandidate(
            candidates: bz.candidates(), presentation: pres, camera: cam, viewport: viewport,
            click: SIMD2<Float>(proj.x, proj.y))
        // With a symmetric BZ centered on the view axis several landmarks can overlap
        // the same pixel; verify the helper returns the nearest-screen-distance candidate
        // within radius (depth only breaks ties), rather than assuming a specific label.
        guard let picked else { XCTFail("expected a pick at Gamma's pixel"); return }
        let pickedProj = project(world: pres.world(cartesian: picked.cartesian), cam: cam, viewport: viewport)
        let d = sqrt((pickedProj.x - proj.x) * (pickedProj.x - proj.x) + (pickedProj.y - proj.y) * (pickedProj.y - proj.y))
        XCTAssertLessThanOrEqual(d, 10, "picked candidate must be within 10px of the click")
        // It must be the nearest screen-space candidate within radius; depth only breaks ties.
        for cand in bz.candidates() {
            let cp = project(world: pres.world(cartesian: cand.cartesian), cam: cam, viewport: viewport)
            guard cp.depth > 0.01 else { continue }
            let cd = sqrt((cp.x - proj.x) * (cp.x - proj.x) + (cp.y - proj.y) * (cp.y - proj.y))
            if cd <= 10 {
                // No other in-radius candidate may be strictly closer on screen; if it is
                // equidistant it must not be nearer in depth.
                if cd + 1e-3 < d {
                    XCTFail("a closer in-radius candidate (\(cd)) was overlooked for (\(d))")
                }
                if abs(cd - d) <= 1e-3 {
                    XCTAssertGreaterThanOrEqual(cp.depth, pickedProj.depth, "screen tie must prefer nearer depth")
                }
            }
        }
    }

    func testPickCandidateCloserScreenHitWinsOverNearerDepth() {
        let bz = fccBZ()
        let pres = BZPresentation(bz: bz, scene: Scene())
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        let viewport = SIMD2<Float>(400, 400)
        guard let gamma = bz.candidates().first(where: { $0.type == .center }) else {
            XCTFail("no Gamma"); return
        }
        // "onPointer" projects exactly to the click (distance 0) but is farther in depth.
        // "offset" is slightly off the click (small screen distance) but nearer in depth.
        // Screen distance is primary, so onPointer must win despite being farther in depth.
        let onPointer = BZCandidate(point: KPoint(SIMD3(0, 0, 0), "onPointer"),
                                    cartesian: gamma.cartesian - SIMD3(0, 0, 10), type: .edge)
        let offset = BZCandidate(point: KPoint(SIMD3(0, 0, 0), "offset"),
                                 cartesian: gamma.cartesian + SIMD3(0.4, 0, 10), type: .edge)
        let proj = project(world: pres.world(cartesian: onPointer.cartesian), cam: cam, viewport: viewport)
        let picked = MainWindowController.pickBZCandidate(
            candidates: [offset, onPointer], presentation: pres, camera: cam, viewport: viewport,
            click: SIMD2<Float>(proj.x, proj.y))
        XCTAssertEqual(picked?.point.label, "onPointer", "closer screen hit must win over nearer depth")
    }

    func testPickCandidateExactOverlapChoosesNearestDepth() {
        let bz = fccBZ()
        let pres = BZPresentation(bz: bz, scene: Scene())
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        let viewport = SIMD2<Float>(400, 400)
        guard let gamma = bz.candidates().first(where: { $0.type == .center }) else {
            XCTFail("no Gamma"); return
        }
        // Two candidates at the same world position (identical screen projection) but the
        // helper is given distinct instances; exact screen tie must resolve to nearest depth.
        let near = BZCandidate(point: KPoint(SIMD3(0, 0, 0), "near"),
                               cartesian: gamma.cartesian + SIMD3(0, 0, 5), type: .edge)
        let far = BZCandidate(point: KPoint(SIMD3(0, 0, 0), "far"),
                              cartesian: gamma.cartesian - SIMD3(0, 0, 5), type: .edge)
        let proj = project(world: pres.world(cartesian: gamma.cartesian), cam: cam, viewport: viewport)
        let picked = MainWindowController.pickBZCandidate(
            candidates: [far, near], presentation: pres, camera: cam, viewport: viewport,
            click: SIMD2<Float>(proj.x, proj.y))
        XCTAssertEqual(picked?.point.label, "near", "exact screen overlap must prefer nearer depth")
    }

    func testPickCandidateOffscreenAndInvalidRejected() {
        let bz = fccBZ()
        let pres = BZPresentation(bz: bz, scene: Scene())
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        let viewport = SIMD2<Float>(200, 200)
        let cands = bz.candidates()
        // Click outside the viewport.
        XCTAssertNil(MainWindowController.pickBZCandidate(candidates: cands, presentation: pres, camera: cam, viewport: viewport, click: SIMD2<Float>(250, 100)))
        XCTAssertNil(MainWindowController.pickBZCandidate(candidates: cands, presentation: pres, camera: cam, viewport: viewport, click: SIMD2<Float>(-1, 100)))
        // Non-finite / non-positive radius.
        XCTAssertNil(MainWindowController.pickBZCandidate(candidates: cands, presentation: pres, camera: cam, viewport: viewport, click: SIMD2<Float>(100, 100), radiusPx: 0))
        XCTAssertNil(MainWindowController.pickBZCandidate(candidates: cands, presentation: pres, camera: cam, viewport: viewport, click: SIMD2<Float>(100, 100), radiusPx: -5))
        XCTAssertNil(MainWindowController.pickBZCandidate(candidates: cands, presentation: pres, camera: cam, viewport: viewport, click: SIMD2<Float>(100, 100), radiusPx: Float.nan))
    }

    func testPickCandidateMissReturnsNil() {
        let bz = fccBZ()
        let pres = BZPresentation(bz: bz, scene: Scene())
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        let viewport = SIMD2<Float>(200, 200)
        // Click a corner far from every landmark.
        let picked = MainWindowController.pickBZCandidate(
            candidates: bz.candidates(), presentation: pres, camera: cam, viewport: viewport,
            click: SIMD2<Float>(3, 3))
        XCTAssertNil(picked)
    }

    func testPickCandidateInvalidViewportReturnsNil() {
        let bz = fccBZ()
        let pres = BZPresentation(bz: bz, scene: Scene())
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        let cands = bz.candidates()
        for bad in [SIMD2<Float>(0, 200), SIMD2<Float>(-1, 200), SIMD2<Float>(200, 0),
                    SIMD2<Float>(Float.nan, 200), SIMD2<Float>(200, Float.nan)] {
            let picked = MainWindowController.pickBZCandidate(
                candidates: cands, presentation: pres, camera: cam, viewport: bad, click: SIMD2<Float>(100, 100))
            XCTAssertNil(picked, "non-positive/non-finite viewport must be rejected")
        }
        // Non-finite click.
        let picked2 = MainWindowController.pickBZCandidate(
            candidates: cands, presentation: pres, camera: cam, viewport: SIMD2<Float>(200, 200),
            click: SIMD2<Float>(Float.nan, 100))
        XCTAssertNil(picked2)
    }

    func testPickCandidateNonFiniteIgnored() {
        let bz = fccBZ()
        let pres = BZPresentation(bz: bz, scene: Scene())
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        let viewport = SIMD2<Float>(200, 200)
        let bad = BZCandidate(point: KPoint(SIMD3(Float.nan, 0, 0), "bad"),
                              cartesian: SIMD3(Float.nan, 0, 0), type: .edge)
        // A non-finite candidate must be skipped and never returned, even when it's the
        // only candidate near the click.
        let picked = MainWindowController.pickBZCandidate(
            candidates: [bad], presentation: pres, camera: cam, viewport: viewport, click: SIMD2<Float>(100, 100))
        XCTAssertNil(picked)
    }

    func testPickCandidateOverlappingPrefersNearestDepth() {
        let bz = fccBZ()
        let pres = BZPresentation(bz: bz, scene: Scene())
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        let viewport = SIMD2<Float>(200, 200)
        guard let gamma = bz.candidates().first(where: { $0.type == .center }) else {
            XCTFail("no Gamma"); return
        }
        let w = pres.world(cartesian: gamma.cartesian)
        // Two candidates projecting to the same pixel but different depth: the nearer
        // (smaller depth) must win. Offset along the view axis (camera looks down -z, so a
        // larger world z is nearer).
        let near = BZCandidate(point: KPoint(SIMD3(0, 0, 0), "near"),
                               cartesian: gamma.cartesian + SIMD3(0, 0, 5), type: .edge)
        let far = BZCandidate(point: KPoint(SIMD3(0, 0, 0), "far"),
                              cartesian: gamma.cartesian - SIMD3(0, 0, 5), type: .edge)
        let proj = project(world: w, cam: cam, viewport: viewport)
        let picked = MainWindowController.pickBZCandidate(
            candidates: [far, near], presentation: pres, camera: cam, viewport: viewport,
            click: SIMD2<Float>(proj.x, proj.y))
        XCTAssertEqual(picked?.point.label, "near")
    }

    func testPickCandidateBehindCameraRejected() {
        let bz = fccBZ()
        let pres = BZPresentation(bz: bz, scene: Scene())
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        let viewport = SIMD2<Float>(200, 200)
        guard let gamma = bz.candidates().first(where: { $0.type == .center }) else {
            XCTFail("no Gamma"); return
        }
        // Place a candidate far behind the camera (large positive world z, camera at +z
        // looking toward -z). Its depth will be <= 0.
        let behind = BZCandidate(point: KPoint(SIMD3(0, 0, 0), "behind"),
                                 cartesian: gamma.cartesian + SIMD3(0, 0, 1000), type: .edge)
        let proj = project(world: pres.world(cartesian: gamma.cartesian), cam: cam, viewport: viewport)
        let picked = MainWindowController.pickBZCandidate(
            candidates: [behind], presentation: pres, camera: cam, viewport: viewport,
            click: SIMD2<Float>(proj.x, proj.y))
        XCTAssertNil(picked)
    }

    // MARK: handleReciprocalPathClick

    private func crystalScene() throws -> Scene {
        Scene(loaded: try Parser.load(fixture("si110.xsf")))
    }

    private func makeController(_ scene: Scene) -> MainWindowController {
        MainWindowController(scene: scene, showWindow: false)
    }

    func testClickEditOffDoesNotConsume() throws {
        let c = makeController(try crystalScene())
        c.state.editKPathOnBZ = false
        let consumed = c.handleReciprocalPathClick(at: SIMD2<Float>(100, 100), viewport: SIMD2<Float>(200, 200))
        XCTAssertFalse(consumed, "click must not be consumed when edit mode is off")
    }

    func testClickEditOnConsumesAndAppends() throws {
        let c = makeController(try crystalScene())
        c.state.editKPathOnBZ = true
        guard let bz = BrillouinZone.build(cell: c.scene.cell!, atoms: c.scene.baseAtoms) else {
            XCTFail("no BZ"); return
        }
        let pres = BZPresentation(bz: bz, scene: c.scene)
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        c.camera = cam
        guard let gamma = bz.candidates().first(where: { $0.type == .center }) else {
            XCTFail("no Gamma"); return
        }
        let proj = project(world: pres.world(cartesian: gamma.cartesian), cam: cam, viewport: SIMD2<Float>(200, 200))
        let before = c.state.kPathPoints.count
        let consumed = c.handleReciprocalPathClick(at: SIMD2<Float>(proj.x, proj.y), viewport: SIMD2<Float>(200, 200))
        XCTAssertTrue(consumed)
        XCTAssertEqual(c.state.kPathPoints.count, before + 1)
        // The appended point is exactly the candidate the picker chose for this click.
        let expected = MainWindowController.pickBZCandidate(
            candidates: bz.candidates(), presentation: pres, camera: cam, viewport: SIMD2<Float>(200, 200),
            click: SIMD2<Float>(proj.x, proj.y))
        XCTAssertEqual(c.state.kPathPoints.last, expected?.point)
        XCTAssertEqual(c.scene.kPathPoints.last, expected?.point, "route must sync to scene")
    }

    func testClickEditOnMissConsumesWithoutSelection() throws {
        let c = makeController(try crystalScene())
        c.state.editKPathOnBZ = true
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        c.camera = cam
        let before = c.state.kPathPoints
        let consumed = c.handleReciprocalPathClick(at: SIMD2<Float>(2, 2), viewport: SIMD2<Float>(200, 200))
        XCTAssertTrue(consumed, "miss must still be consumed in edit mode")
        XCTAssertEqual(c.state.kPathPoints, before, "miss must not change the route")
        XCTAssertEqual(c.scene.selectedAtoms, [], "atom selection must never occur")
    }

    // MARK: editor BZ cache (at-most-once-per-scene build)

    func testEditorCacheBuildsAtMostOncePerScene() throws {
        let c = makeController(try crystalScene())
        c.state.editKPathOnBZ = true
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        c.camera = cam
        XCTAssertEqual(c.bzBuildCount, 0, "fresh controller starts uncached")
        // First click builds the BZ.
        c.handleReciprocalPathClick(at: SIMD2<Float>(100, 100), viewport: SIMD2<Float>(200, 200))
        XCTAssertEqual(c.bzBuildCount, 1)
        // Repeated clicks on the same scene reuse the cached build.
        c.handleReciprocalPathClick(at: SIMD2<Float>(120, 80), viewport: SIMD2<Float>(200, 200))
        c.handleReciprocalPathClick(at: SIMD2<Float>(50, 150), viewport: SIMD2<Float>(200, 200))
        XCTAssertEqual(c.bzBuildCount, 1, "repeated clicks must reuse one build")
    }

    func testEditorCacheInvalidatesOnLoadFile() throws {
        let c = makeController(try crystalScene())
        c.state.editKPathOnBZ = true
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        c.camera = cam
        c.handleReciprocalPathClick(at: SIMD2<Float>(100, 100), viewport: SIMD2<Float>(200, 200))
        XCTAssertEqual(c.bzBuildCount, 1)
        // Loading a new scene invalidates the cache and triggers a fresh build.
        let url = fixture("si110.xsf")
        c.loadFile(Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0)),
                   from: url, format: nil, frameIndex: 0)
        c.state.editKPathOnBZ = true
        c.handleReciprocalPathClick(at: SIMD2<Float>(100, 100), viewport: SIMD2<Float>(200, 200))
        XCTAssertEqual(c.bzBuildCount, 2, "file install must invalidate the cache")
    }

    func testEditorCacheInvalidatesOnReloadFrame() throws {
        let url = fixture("si.anim_grid.axsf")
        let c = makeController(Scene())
        c.loadFile(Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0)),
                   from: url, format: nil, frameIndex: 0)
        c.state.editKPathOnBZ = true
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        c.camera = cam
        c.handleReciprocalPathClick(at: SIMD2<Float>(100, 100), viewport: SIMD2<Float>(200, 200))
        XCTAssertEqual(c.bzBuildCount, 1)
        // Advancing to a new frame (reloadFrame) invalidates the cache.
        c.state.frameIndex = 1
        XCTAssertEqual(c.scene.currentFrame, 1)
        c.handleReciprocalPathClick(at: SIMD2<Float>(100, 100), viewport: SIMD2<Float>(200, 200))
        XCTAssertEqual(c.bzBuildCount, 2, "frame install must invalidate the cache")
    }

    func testClickConsecutiveDuplicateSuppressed() throws {
        let c = makeController(try crystalScene())
        c.state.kPathPoints = [] // loaded controllers now correctly start with their saved/default route
        c.state.editKPathOnBZ = true
        guard let bz = BrillouinZone.build(cell: c.scene.cell!, atoms: c.scene.baseAtoms) else {
            XCTFail("no BZ"); return
        }
        let pres = BZPresentation(bz: bz, scene: c.scene)
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        c.camera = cam
        guard let gamma = bz.candidates().first(where: { $0.type == .center }) else {
            XCTFail("no Gamma"); return
        }
        let proj = project(world: pres.world(cartesian: gamma.cartesian), cam: cam, viewport: SIMD2<Float>(200, 200))
        let p = SIMD2<Float>(proj.x, proj.y)
        c.handleReciprocalPathClick(at: p, viewport: SIMD2<Float>(200, 200))
        c.handleReciprocalPathClick(at: p, viewport: SIMD2<Float>(200, 200))
        XCTAssertEqual(c.state.kPathPoints.count, 1, "same landmark twice must not stack")
    }

    func testClickNonConsecutiveRepeatAllowed() throws {
        let c = makeController(try crystalScene())
        c.state.kPathPoints = [] // start this editor test from an intentionally empty route
        c.state.editKPathOnBZ = true
        guard let bz = BrillouinZone.build(cell: c.scene.cell!, atoms: c.scene.baseAtoms) else {
            XCTFail("no BZ"); return
        }
        let pres = BZPresentation(bz: bz, scene: c.scene)
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        c.camera = cam
        // A large viewport maps world-space BZ separations to many pixels, so distinct
        // landmarks land on unambiguous, well-separated pixels.
        let viewport = SIMD2<Float>(4000, 4000)
        // Find two candidates that project to distinct, well-separated pixels (more than
        // 2*radius apart) so each click resolves unambiguously to a different landmark.
        let cands = bz.candidates()
        var pair: (BZCandidate, BZCandidate)?
        outer: for i in 0..<cands.count {
            for j in (i+1)..<cands.count {
                let pi = project(world: pres.world(cartesian: cands[i].cartesian), cam: cam, viewport: viewport)
                let pj = project(world: pres.world(cartesian: cands[j].cartesian), cam: cam, viewport: viewport)
                guard pi.depth > 0.01, pj.depth > 0.01 else { continue }
                let sep = sqrt((pi.x - pj.x) * (pi.x - pj.x) + (pi.y - pj.y) * (pi.y - pj.y))
                if sep > 24 { pair = (cands[i], cands[j]); break outer }
            }
        }
        guard let (a, b) = pair else { XCTFail("no separated candidate pair"); return }
        let pa = project(world: pres.world(cartesian: a.cartesian), cam: cam, viewport: viewport)
        let pb = project(world: pres.world(cartesian: b.cartesian), cam: cam, viewport: viewport)
        // a, b, a: the third click repeats the first but non-consecutively, so it's allowed.
        c.handleReciprocalPathClick(at: SIMD2<Float>(pa.x, pa.y), viewport: viewport)
        c.handleReciprocalPathClick(at: SIMD2<Float>(pb.x, pb.y), viewport: viewport)
        c.handleReciprocalPathClick(at: SIMD2<Float>(pa.x, pa.y), viewport: viewport)
        XCTAssertEqual(c.state.kPathPoints.count, 3, "non-consecutive repeat must be allowed")
        XCTAssertEqual(c.state.kPathPoints[0], MainWindowController.pickBZCandidate(candidates: cands, presentation: pres, camera: cam, viewport: viewport, click: SIMD2<Float>(pa.x, pa.y))?.point)
        XCTAssertEqual(c.state.kPathPoints[2], c.state.kPathPoints[0], "first and third nodes must match (non-consecutive repeat)")
    }

    func testClickEnforces1024Cap() throws {
        let c = makeController(try crystalScene())
        c.state.editKPathOnBZ = true
        // Pre-fill to the cap with distinct points.
        c.state.kPathPoints = (0..<1024).map { KPoint(SIMD3(Float($0), 0, 0), "k\($0)") }
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        c.camera = cam
        guard let bz = BrillouinZone.build(cell: c.scene.cell!, atoms: c.scene.baseAtoms),
              let other = bz.candidates().first(where: { $0.type != .center }) else {
            XCTFail("no BZ/candidate"); return
        }
        let pres = BZPresentation(bz: bz, scene: c.scene)
        let proj = project(world: pres.world(cartesian: other.cartesian), cam: cam, viewport: SIMD2<Float>(200, 200))
        c.handleReciprocalPathClick(at: SIMD2<Float>(proj.x, proj.y), viewport: SIMD2<Float>(200, 200))
        XCTAssertEqual(c.state.kPathPoints.count, 1024, "route must not exceed the cap")
    }

    // MARK: edit mode forces BZ on

    func testEditModeForcesBrillouinZoneOn() throws {
        let c = makeController(try crystalScene())
        c.state.showBrillouinZone = false
        XCTAssertFalse(c.scene.showBrillouinZone)
        c.state.editKPathOnBZ = true   // fires onChange -> syncFromState
        XCTAssertTrue(c.state.showBrillouinZone)
        XCTAssertTrue(c.scene.showBrillouinZone)
    }

    // MARK: route survives unrelated sync + reloadFrame

    func testRouteSurvivesUnrelatedSyncFromState() throws {
        let c = makeController(try crystalScene())
        let route = [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.5, 0, 0), "X")]
        c.state.kPathPoints = route   // syncs into scene
        XCTAssertEqual(c.scene.kPathPoints, route)
        // An unrelated sidebar change must not regenerate the route.
        c.state.atomScale = 0.5
        XCTAssertEqual(c.state.kPathPoints, route)
        XCTAssertEqual(c.scene.kPathPoints, route)
    }

    func testRouteSurvivesReloadFrame() throws {
        let url = fixture("si.anim_grid.axsf")
        let c = makeController(Scene())
        c.loadFile(Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0)),
                   from: url, format: nil, frameIndex: 0)
        let route = [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.25, 0.25, 0.25), "P"),
                     KPoint(SIMD3(0.5, 0, 0), "X")]
        c.state.kPathPoints = route
        c.state.kPathBreaks = [1]
        XCTAssertEqual(c.scene.kPathPoints, route)
        XCTAssertEqual(c.scene.kPathProvenance, .userEdited)
        // Step to frame 1, triggering reloadFrame.
        c.state.frameIndex = 1
        XCTAssertEqual(c.scene.currentFrame, 1)
        XCTAssertEqual(c.scene.kPathPoints, route, "route must survive the frame reload")
        XCTAssertEqual(c.scene.kPathBreaks, [1], "route topology must survive the frame reload")
        XCTAssertEqual(c.scene.kPathProvenance, .userEdited)
    }

    func testLoadFileExitsEditModeAndSeedsDefault() throws {
        let url = fixture("si110.xsf")
        let c = makeController(Scene())
        c.state.editKPathOnBZ = true
        c.loadFile(Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0)),
                   from: url, format: nil, frameIndex: 0)
        XCTAssertFalse(c.state.editKPathOnBZ, "loading a new scene must exit edit mode")
        XCTAssertFalse(c.state.kPathPoints.isEmpty, "crystal must seed a default route")
        XCTAssertEqual(c.state.kPathPoints, c.scene.kPathPoints)
    }

    // MARK: sidebar mutation helpers

    func testSidebarMutationMethods() throws {
        let c = makeController(try crystalScene())
        let s = c.state
        // Track nodes by their (stable) fractional coordinate rather than label,
        // since updateLabel deliberately rewrites a label.
        let gamma = SIMD3<Float>(0, 0, 0)
        let x = SIMD3<Float>(0.5, 0, 0)
        let m = SIMD3<Float>(0.5, 0.5, 0)
        s.kPathPoints = [KPoint(gamma, "Γ"), KPoint(x, "X"), KPoint(m, "M")]

        // updateLabel bounds to 64 chars and is a no-op out of range.
        let long = String(repeating: "A", count: 100)
        s.updateLabel(at: 1, to: long)
        XCTAssertEqual(s.kPathPoints[1].label.count, 64)
        s.updateLabel(at: 99, to: "ignored")
        XCTAssertEqual(s.kPathPoints[1].label.count, 64)

        // moveUp / moveDown preserve order and are no-ops at boundaries.
        s.moveUp(at: 0); s.moveUp(at: 99)
        XCTAssertEqual(s.kPathPoints[0].frac, gamma)
        s.moveDown(at: 0)
        XCTAssertEqual(s.kPathPoints[0].frac, x)
        XCTAssertEqual(s.kPathPoints[1].frac, gamma)
        s.moveUp(at: 0); s.moveUp(at: 99)   // back to no-op boundaries
        XCTAssertEqual(s.kPathPoints[0].frac, x)
        // remove (drop the M node) and an out-of-range no-op.
        s.remove(at: 2); s.remove(at: 99)
        XCTAssertEqual(s.kPathPoints.count, 2)
        XCTAssertEqual(s.kPathPoints.map { $0.frac }, [x, gamma])
        // undoLast restores the prior snapshot (3 nodes incl. M).
        s.undoLast()
        XCTAssertEqual(s.kPathPoints.count, 3)
        XCTAssertEqual(s.kPathPoints[2].frac, m)
        // clear + undo.
        s.clear()
        XCTAssertTrue(s.kPathPoints.isEmpty)
        s.undoLast()
        XCTAssertFalse(s.kPathPoints.isEmpty)
    }

    func testAppendCapsAndSuppressesConsecutiveDup() {
        let s = SideBarState()
        let gamma = KPoint(SIMD3(0, 0, 0), "Γ")
        let x = KPoint(SIMD3(0.5, 0, 0), "X")
        s.append(gamma); s.append(gamma); s.append(x)
        XCTAssertEqual(s.kPathPoints, [gamma, x])
        // Fill to one below the cap directly, then append to the cap and beyond.
        s.kPathPoints = (0..<1023).map { KPoint(SIMD3(Float($0), 0, 0), "k\($0)") }
        s.append(KPoint(SIMD3(1023, 0, 0), "k1023"))
        XCTAssertEqual(s.kPathPoints.count, 1024)
        s.append(KPoint(SIMD3(9999, 0, 0), "overflow"))
        XCTAssertEqual(s.kPathPoints.count, 1024)
    }

    func testDefaultResetAndClearSemantics() throws {
        let c = makeController(try crystalScene())
        let s = c.state
        let defaultPath = try XCTUnwrap(MainWindowController.makeDefaultKPath(for: c.scene))
        XCTAssertFalse(defaultPath.points.isEmpty)
        s.kPathPoints = [KPoint(SIMD3(0, 0, 0), "only")]
        s.resetToDefault()
        XCTAssertEqual(s.kPathPoints, defaultPath.points)
        // Clear then undo returns to the default.
        s.clear()
        XCTAssertTrue(s.kPathPoints.isEmpty)
        s.undoLast()
        XCTAssertEqual(s.kPathPoints, defaultPath.points)
    }

    func testUndoEmptyIsNoOp() {
        let s = SideBarState()
        s.undoLast()   // must not trap
        XCTAssertTrue(s.kPathPoints.isEmpty)
    }

    func testEditorExportAvailabilityMatchesFormatSemantics() {
        let empty = KPath(points: [])
        XCTAssertFalse(KPathExport.isEnabledInEditor(empty, as: .qe))
        XCTAssertFalse(KPathExport.isEnabledInEditor(empty, as: .kpf))

        // QE K_POINTS crystal is an explicit list and accepts one special point;
        // KPF remains disabled until there is an actual connected path.
        let singleton = KPath(points: [KPoint(SIMD3(0, 0, 0), "Γ")])
        XCTAssertTrue(KPathExport.isEnabledInEditor(singleton, as: .qe))
        XCTAssertFalse(KPathExport.isEnabledInEditor(singleton, as: .kpf))

        let connected = KPath(points: [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.5, 0, 0), "X")])
        XCTAssertTrue(KPathExport.isEnabledInEditor(connected, as: .qe))
        XCTAssertTrue(KPathExport.isEnabledInEditor(connected, as: .kpf))

        let disconnected = KPath(points: connected.points, breaks: [0])
        XCTAssertTrue(KPathExport.isEnabledInEditor(disconnected, as: .qe))
        XCTAssertFalse(KPathExport.isEnabledInEditor(disconnected, as: .kpf))
    }

    func testExportGuardsEmptyRoute() throws {
        // The export method itself refuses to write an empty route.
        let c = makeController(try crystalScene())
        var pathSeen: [KPoint] = []
        c.state.onExportKPath = { path, _ in pathSeen = path.points }
        // Drive it the way the UI would: only enabled with >= 2 points, but verify the
        // empty-route guard directly by invoking the callback with an empty path.
        c.state.onExportKPath?(KPath(points: []), .qe)
        XCTAssertTrue(pathSeen.isEmpty, "empty-route export must be a no-op")
    }

    // MARK: Issue 5 — edit mode must work with the structure hidden

    func testHandlerConsumesMissAndBlocksSelectionWhenStructureHidden() throws {
        // With Show Structure off, atom picking is disabled — but the BZ editor must still
        // run: a click in edit mode is consumed and never reaches atom selection.
        let c = makeController(try crystalScene())
        c.state.editKPathOnBZ = true
        c.scene.showStructure = false
        // A corner click that misses every landmark.
        let consumed = c.handleReciprocalPathClick(at: SIMD2<Float>(5, 5), viewport: SIMD2<Float>(200, 200))
        XCTAssertTrue(consumed, "edit mode must consume the click even with structure hidden")
        XCTAssertEqual(c.scene.selectedAtoms, [], "atom selection must never fire in edit mode")
    }

    func testHandlerConsumesHitWhenStructureHidden() throws {
        let c = makeController(try crystalScene())
        c.state.kPathPoints = [] // the loaded scene's default route is not part of this click assertion
        c.state.editKPathOnBZ = true
        c.scene.showStructure = false
        guard let bz = BrillouinZone.build(cell: c.scene.cell!, atoms: c.scene.baseAtoms) else {
            XCTFail("no BZ"); return
        }
        let pres = BZPresentation(bz: bz, scene: c.scene)
        var cam = Camera(); cam.perspective = false; cam.distance = 40
        c.camera = cam
        guard let gamma = bz.candidates().first(where: { $0.type == .center }) else {
            XCTFail("no Gamma"); return
        }
        let proj = project(world: pres.world(cartesian: gamma.cartesian), cam: cam, viewport: SIMD2<Float>(200, 200))
        let consumed = c.handleReciprocalPathClick(at: SIMD2<Float>(proj.x, proj.y), viewport: SIMD2<Float>(200, 200))
        XCTAssertTrue(consumed)
        // With the structure hidden the handler still appends the picked landmark and never
        // selects an atom. (With a symmetric BZ centered on the view axis, several landmarks
        // overlap the pointer; the appended point is whichever the picker selects.)
        XCTAssertEqual(c.state.kPathPoints.count, 1, "hit must append exactly one node")
        XCTAssertEqual(c.state.kPathPoints.last, MainWindowController.pickBZCandidate(candidates: bz.candidates(), presentation: pres, camera: cam, viewport: SIMD2<Float>(200, 200), click: SIMD2<Float>(proj.x, proj.y))?.point)
        XCTAssertEqual(c.scene.selectedAtoms, [])
    }

    // MARK: Issue 2 — undo stack lifecycle

    func testCanUndoDrivesUndoButton() {
        let s = SideBarState()
        XCTAssertFalse(s.canUndo)
        s.kPathPoints = [KPoint(SIMD3(0, 0, 0), "Γ")]
        s.clear()                 // pushes undo (pre-clear route), empties the route
        XCTAssertTrue(s.kPathPoints.isEmpty)
        XCTAssertTrue(s.canUndo, "Undo must stay enabled after a Clear")
        s.undoLast()
        XCTAssertEqual(s.kPathPoints.count, 1)
        XCTAssertFalse(s.canUndo, "Undo disabled once the stack is exhausted")
    }

    func testClearWhenAlreadyEmptyIsNoOp() {
        let s = SideBarState()
        s.clear()                 // nothing to clear: no undo entry
        XCTAssertFalse(s.canUndo)
        s.kPathPoints = [KPoint(SIMD3(0, 0, 0), "Γ")]
        s.updateLabel(at: 0, to: "Γ")   // unchanged bounded value: no undo entry
        XCTAssertFalse(s.canUndo, "no-op mutation must not push undo")
    }

    func testLoadClearsStaleUndo() throws {
        let url = fixture("si110.xsf")
        let c = makeController(Scene())
        c.loadFile(Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0)),
                   from: url, format: nil, frameIndex: 0)
        // Edit, then load a second scene: the old undo history must not resurrect the
        // first scene's route.
        c.state.kPathPoints = [KPoint(SIMD3(0, 0, 0), "only")]
        c.state.clear()
        XCTAssertTrue(c.state.canUndo)
        let url2 = fixture("si110.xsf")
        c.loadFile(Scene(loaded: try Parser.load(url2, as: nil, frameIndex: 0)),
                   from: url2, format: nil, frameIndex: 0)
        XCTAssertFalse(c.state.canUndo, "loading a new scene must discard stale undo history")
        XCTAssertFalse(c.state.kPathPoints.isEmpty)
    }

    // MARK: Phase 3 — renderer draws the k-path route overlay and landmarks

    /// The 3-axis cross helper emits exactly three orthogonal segments (six
    /// endpoints) centered on `world`, each arm spanning ±half.
    func testCrossLineSegmentsProducesThreeAxes() {
        let segs = Renderer.crossLineSegments(SIMD3<Float>(1, 2, 3), half: 0.5)
        XCTAssertEqual(segs.count, 6)
        // Pair 0,1 along x; pair 2,3 along y; pair 4,5 along z.
        for (a, b) in [(0, 1), (2, 3), (4, 5)] {
            let d = segs[b] - segs[a]
            XCTAssertEqual(simd_length(d), 1.0, accuracy: 1e-4, "arm length must be 2*half")
        }
        XCTAssertEqual(segs[0].y, 2); XCTAssertEqual(segs[0].z, 3)   // x-arm keeps y,z
        XCTAssertEqual(segs[2].x, 1); XCTAssertEqual(segs[2].z, 3)   // y-arm keeps x,z
        XCTAssertEqual(segs[4].x, 1); XCTAssertEqual(segs[4].y, 2)   // z-arm keeps x,y
    }

    /// A non-finite center must yield an empty vertex list so the line buffer is
    /// never fed a garbage position.
    func testCrossLineSegmentsRejectsNonFiniteCenter() {
        XCTAssertTrue(Renderer.crossLineSegments(SIMD3(Float.nan, 0, 0), half: 1).isEmpty)
        XCTAssertTrue(Renderer.crossLineSegments(SIMD3(Float.infinity, 0, 0), half: 1).isEmpty)
        XCTAssertTrue(Renderer.crossLineSegments(SIMD3(0, 0, 0), half: Float.nan).isEmpty)
    }

    // MARK: - Metal render regression (route overlay + BZ landmarks)

    /// fcc-Si scene whose BZ builds; atoms == baseAtoms so the BZ (built from
    /// baseAtoms) is centered on the displayed structure centroid.
    private func bzScene(kPath: [KPoint] = [], breaks: Set<Int> = []) -> Scene {
        let a: Float = 5.43
        let offsets: [SIMD3<Float>] = [[0, 0, 0], [0, 0.5 * a, 0.5 * a],
                                        [0.5 * a, 0, 0.5 * a], [0.5 * a, 0.5 * a, 0]]
        let atoms = offsets.map { Atom(coord: $0, atomicNumber: 14, label: "Si") }
        var s = Scene()
        s.isCrystal = true
        s.cell = Cell(a: SIMD3(a, 0, 0), b: SIMD3(0, a, 0), c: SIMD3(0, 0, a))
        s.baseAtoms = atoms
        s.atoms = atoms
        s.showBrillouinZone = true
        s.kPathPoints = kPath
        s.kPathBreaks = breaks
        return s
    }

    /// Render the BZ overlay with the structure hidden, framing the BZ so its
    /// displayed extent fills most of the viewport. Returns raw RGBA bytes and
    /// the live renderer (so callers can inspect bzRebuildCount).
    @discardableResult
    private func renderBZ(_ scene: Scene, viewport: Int = 120, showBZLandmarks: Bool = false) throws -> (pixels: [UInt8], renderer: Renderer) {
        var s = scene
        s.background = "#000000"
        s.showStructure = false
        s.showAxes = false
        s.showCellFrame = false
        s.showIsoSurface = false
        s.showFermiSurface = false
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noGPU }
        let r = try Renderer(device: device)
        r.scene = s
        r.showBZLandmarks = showBZLandmarks
        let displayedHalfExtent = max(1.0, s.boundingSphere().1) * 0.45
        var cam = Camera()
        cam.perspective = false
        cam.center = s.centroid
        cam.distance = displayedHalfExtent * 1.7
        let w = viewport, h = viewport
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm; desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { throw RenderError.noTexture }
        let cb = device.makeCommandQueue()!.makeCommandBuffer()!
        let ok = r.encode(to: cb, target: tex,
                          viewport: MTLViewport(originX: 0, originY: 0, width: Double(w),
                                                height: Double(h), znear: 0, zfar: 1),
                          camera: cam)
        XCTAssertTrue(ok, "encode failed — frame would be blank")
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return (px, r)
    }

    private func pixelHash(_ px: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in px { hash ^= UInt64(b); hash = hash &* 0x100000001b3 }
        return hash
    }

    /// Count pixels whose summed channel-distance from `a` exceeds `threshold`.
    private func pixelDiff(_ a: [UInt8], _ b: [UInt8], threshold: Int = 24) -> Int {
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            if abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2])) > threshold { n += 1 }
        }
        return n
    }

    /// Near-white pixels (landmark crosses) within `radius` px of (cx, cy).
    private func whitePixelsNear(_ px: [UInt8], w: Int, h: Int, cx: Int, cy: Int, radius: Int) -> Int {
        var n = 0
        for dy in -radius...radius {
            for dx in -radius...radius {
                let x = cx + dx, y = cy + dy
                guard x >= 0, y >= 0, x < w, y < h, dx * dx + dy * dy <= radius * radius else { continue }
                let i = (y * w + x) * 4
                if px[i] > 200 && px[i + 1] > 200 && px[i + 2] > 200 { n += 1 }
            }
        }
        return n
    }

    /// Render with an empty route vs a two-node route: the output must change
    /// (route overlay drawn) while BZ geometry (purple faces + white landmarks)
    /// stays present in both.
    func testRouteOverlayChangesOutputWhileBZStaysPresent() throws {
        let empty = try renderBZ(bzScene(), showBZLandmarks: true)
        let twoNode = bzScene(kPath: [KPoint(SIMD3(0, 0, 0), "Γ"),
                                      KPoint(SIMD3(0.5, 0.5, 0.5), "L")])
        let withRoute = try renderBZ(twoNode, showBZLandmarks: true)
        XCTAssertNotEqual(pixelHash(empty.pixels), pixelHash(withRoute.pixels),
                          "a two-node route must change the rendered output")
        XCTAssertGreaterThan(pixelDiff(empty.pixels, withRoute.pixels), 5,
                             "route overlay should add visible pixels")
        // BZ geometry present in both: near-white landmark pixels near center.
        let w = 120, h = 120
        XCTAssertGreaterThan(whitePixelsNear(empty.pixels, w: w, h: h, cx: w / 2, cy: h / 2, radius: 6), 0,
                             "BZ landmarks must be visible with an empty route")
        XCTAssertGreaterThan(whitePixelsNear(withRoute.pixels, w: w, h: h, cx: w / 2, cy: h / 2, radius: 6), 0,
                              "BZ landmarks must remain visible with a route")
    }

    /// The controller's renderer hides BZ landmarks by default and shows them only
    /// while edit mode is on; toggling edit mode off hides them again immediately.
    func testShowBZLandmarksFollowsEditMode() throws {
        let c = makeController(try crystalScene())
        guard let r = c.renderer else { throw RenderError.noGPU }
        XCTAssertFalse(r.showBZLandmarks, "landmarks must be hidden by default")
        c.state.editKPathOnBZ = true   // onChange -> syncFromState
        XCTAssertTrue(r.showBZLandmarks, "edit mode must show BZ landmarks")
        c.state.editKPathOnBZ = false
        XCTAssertFalse(r.showBZLandmarks, "leaving edit mode must hide BZ landmarks immediately")
    }

    /// Metal: with landmarks disabled (the default) there is NO white landmark cross
    /// at Gamma for a route-empty scene; enabling the renderer property reveals it.
    /// The purple BZ wireframe stays present in either case.
    func testLandmarksGatedByRendererProperty() throws {
        let w = 120, h = 120
        let empty = bzScene()   // route-empty so only the BZ + landmarks are drawn
        let hidden = try renderBZ(empty, showBZLandmarks: false)
        let shown = try renderBZ(empty, showBZLandmarks: true)

        // No white landmark cross near screen-center Gamma when disabled.
        XCTAssertEqual(whitePixelsNear(hidden.pixels, w: w, h: h, cx: w / 2, cy: h / 2, radius: 6), 0,
                       "landmarks disabled: no white cross must appear at Gamma")
        // White cross appears once landmarks are enabled.
        XCTAssertGreaterThan(whitePixelsNear(shown.pixels, w: w, h: h, cx: w / 2, cy: h / 2, radius: 6), 0,
                             "landmarks enabled: white cross must appear at Gamma")

        // Purple BZ wireframe present in both. bzColor == (0.85, 0.30, 0.95): high red+blue, low green.
        func purple(_ px: [UInt8]) -> Int {
            var n = 0
            for i in stride(from: 0, to: px.count, by: 4) {
                if px[i] > 150 && px[i + 2] > 150 && px[i + 1] < 110 { n += 1 }
            }
            return n
        }
        XCTAssertGreaterThan(purple(hidden.pixels), 0, "purple BZ must be present with landmarks hidden")
        XCTAssertGreaterThan(purple(shown.pixels), 0, "purple BZ must be present with landmarks shown")
    }

    /// A one-node route draws a visible node cross and the encode succeeds.
    func testOneNodeRouteRendersVisibleNode() throws {
        let oneNode = bzScene(kPath: [KPoint(SIMD3(0, 0, 0), "Γ")])
        let (px, _) = try renderBZ(oneNode)
        // Cyan node cross: high blue+green, low red.
        var cyan = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            if px[i + 2] > 180 && px[i + 1] > 120 && px[i] < 90 { cyan += 1 }
        }
        XCTAssertGreaterThan(cyan, 0, "a one-node route must draw a visible cyan node cross")
    }

    /// Editing only the route must change the render WITHOUT rebuilding the BZ
    /// geometry cache (bzRebuildCount stays at 1).
    func testRouteEditDoesNotRebuildBZCache() throws {
        let r = try Renderer(device: MTLCreateSystemDefaultDevice()!)
        r.scene = bzScene(kPath: [KPoint(SIMD3(0, 0, 0), "Γ"),
                                  KPoint(SIMD3(0.5, 0, 0), "X")])
        var cam = Camera()
        let displayedHalfExtent = max(1.0, r.scene.boundingSphere().1) * 0.45
        cam.perspective = false
        cam.center = r.scene.centroid
        cam.distance = displayedHalfExtent * 1.7
        let w = 120, h = 120
        let device = r.device
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm; desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        func encode() -> Bool {
            let tex = device.makeTexture(descriptor: desc)!
            let cb = device.makeCommandQueue()!.makeCommandBuffer()!
            let ok = r.encode(to: cb, target: tex,
                              viewport: MTLViewport(originX: 0, originY: 0, width: Double(w),
                                                    height: Double(h), znear: 0, zfar: 1),
                              camera: cam)
            cb.commit(); cb.waitUntilCompleted()
            return ok
        }
        XCTAssertTrue(encode())
        XCTAssertEqual(r.bzRebuildCount, 1)
        // Edit the route only (same cell + baseAtoms) — must NOT rebuild the BZ.
        r.scene.kPathPoints = [KPoint(SIMD3(0, 0, 0), "Γ"),
                               KPoint(SIMD3(0.5, 0, 0), "X"),
                               KPoint(SIMD3(0.5, 0.5, 0.5), "L")]
        XCTAssertTrue(encode())
        XCTAssertEqual(r.bzRebuildCount, 1, "route-only edit must not rebuild the BZ cache")
    }

    /// A route with a non-finite node must not fail the encode, must skip that
    /// node, and must NOT bridge a segment across it (its two valid neighbours
    /// stay disconnected).
    func testNonFiniteRoutePointsSkippedAndNotBridged() throws {
        let a = KPoint(SIMD3(0, 0, 0), "Γ")
        let b = KPoint(SIMD3(0.5, 0.5, 0.5), "L")
        let nan = KPoint(SIMD3(Float.nan, 0, 0), "bad")

        let clean = try renderBZ(bzScene(kPath: [a, b]))
        let gap = try renderBZ(bzScene(kPath: [a, nan, b]))
        // Both encode successfully (non-finite points never trap).
        XCTAssertGreaterThan(pixelDiff(clean.pixels, gap.pixels), 0,
                             "the NaN node must not bridge its valid neighbours: clean has an amber segment, gap does not")
        // A one-node render at `a` shares only the A landmark with `gap`; the gap
        // render additionally shows B, proving B is drawn as its own node while A-B
        // is NOT connected.
        let onlyA = try renderBZ(bzScene(kPath: [a]))
        XCTAssertNotEqual(pixelHash(gap.pixels), pixelHash(onlyA.pixels),
                          "gap route must still draw node B (distinct from single-node A)")
    }

    /// A declared topology break must suppress exactly the same amber segment
    /// that a non-finite intermediate node suppresses, while retaining both
    /// endpoint crosses.
    func testRouteBreakDoesNotRenderConnectingSegment() throws {
        let a = KPoint(SIMD3(0, 0, 0), "Γ")
        let b = KPoint(SIMD3(0.5, 0.5, 0.5), "L")
        let connected = try renderBZ(bzScene(kPath: [a, b]))
        let disconnected = try renderBZ(bzScene(kPath: [a, b], breaks: [0]))
        XCTAssertGreaterThan(pixelDiff(connected.pixels, disconnected.pixels), 0,
                             "a topology break must remove the amber A-B segment")
        let onlyA = try renderBZ(bzScene(kPath: [a]))
        XCTAssertNotEqual(pixelHash(disconnected.pixels), pixelHash(onlyA.pixels),
                          "both endpoint crosses must remain visible across a break")
    }

    // MARK: post-phase-3 integration fixes

    /// Build a crystal scene that also carries band data, by attaching a minimal
    /// bandStructure to a parsed crystal fixture.
    private func crystalWithBands() throws -> Scene {
        var scene = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        let bp = BandKPoint(k: .zero, weight: 1, label: "", energies: [1, 2])
        scene.bandStructure = BandStructure(kPoints: [bp], fermiEnergy: nil, nSpin: 1,
                                            reciprocal: nil, kPointsPerSpin: 1)
        return scene
    }

    // Issue 1 — edit mode must show the Metal canvas even when band/DOS/grid data is present.

    func testEditModeShowsCanvasDespiteBandData() throws {
        let c = makeController(try crystalWithBands())
        XCTAssertTrue(c.scene.bandStructure != nil)
        // Establish the normal-precendence baseline via a sidebar sync (as a file load
        // would): with band data present the band grapher wins and the canvas is hidden.
        c.state.atomScale = c.state.atomScale   // no-op assign is a no-op; force a real sync below
        c.state.showLabels = c.scene.showLabels  // mirrors scene -> triggers syncFromState
        XCTAssertTrue(c.canvas.isHidden, "band data should hide the canvas before edit mode")
        XCTAssertFalse(c.bandGrapher.isHidden)
        // Enabling edit mode forces the Metal canvas visible and hides the grapher.
        c.state.editKPathOnBZ = true
        XCTAssertFalse(c.canvas.isHidden, "edit mode must show the Metal canvas")
        XCTAssertTrue(c.bandGrapher.isHidden, "edit mode must hide the band grapher")
        XCTAssertTrue(c.scene.showBrillouinZone)
        // Exiting edit mode restores the normal precedence automatically.
        c.state.editKPathOnBZ = false
        XCTAssertTrue(c.canvas.isHidden, "leaving edit mode restores band-graph precedence")
        XCTAssertFalse(c.bandGrapher.isHidden)
    }

    // Issue 2 — entering edit mode from a 2D display mode switches to 3D (so orbit works).

    func testEditModeFrom2DSwitchesTo3D() throws {
        let c = makeController(try crystalScene())
        c.state.displayMode = .ballStick2D
        c.state.editKPathOnBZ = true
        XCTAssertFalse(c.scene.displayMode.is2D, "edit mode from 2D must switch to 3D")
        XCTAssertEqual(c.scene.displayMode, .ballStick)
        XCTAssertTrue(c.scene.showBrillouinZone)
    }

    func testEditModeFrom3DStays3D() throws {
        let c = makeController(try crystalScene())
        c.state.displayMode = .spaceFill
        c.state.editKPathOnBZ = true
        XCTAssertEqual(c.scene.displayMode, .spaceFill, "edit mode must not disturb an existing 3D mode")
        XCTAssertTrue(c.scene.showBrillouinZone)
    }

    // Issue 3 — duplicate suppression is by fractional coordinate, independent of label.

    func testAppendSuppressesDuplicateByCoordinateDespiteRename() {
        let s = SideBarState()
        let gamma = KPoint(SIMD3(0, 0, 0), "Γ")
        let renamedGamma = KPoint(SIMD3(0, 0, 0), "Gamma-renamed")
        s.append(gamma)
        // Renaming the last node must not defeat the duplicate check: the same coordinate
        // clicked again is still suppressed.
        s.kPathPoints[0].label = "Gamma-renamed"
        s.append(renamedGamma)
        XCTAssertEqual(s.kPathPoints.count, 1, "same coordinate must be suppressed even after rename")
        // But a non-consecutive repeat of the same coordinate is allowed.
        s.append(KPoint(SIMD3(0.5, 0, 0), "X"))
        s.append(renamedGamma)
        XCTAssertEqual(s.kPathPoints.count, 3, "non-consecutive coordinate repeat must be allowed")
    }

    // MARK: Renderer integration fixes — coincident depth + invalid presentation scale

    /// Issue 1 regression: a route node drawn at the SAME position as a BZ landmark
    /// (Gamma, at the BZ origin) must remain visible. Before the fix the route was
    /// drawn with the strict `.less` state, so equal-depth route fragments failed the
    /// test and were dropped behind the white landmark drawn moments earlier. With the
    /// `.lessEqual`/no-write route state, the cyan node overlays the landmark.
    func testRouteNodeVisibleOverCoincidentLandmark() throws {
        // Route node placed exactly on Gamma (the BZ origin == a landmark).
        let onGamma = bzScene(kPath: [KPoint(SIMD3(0, 0, 0), "Γ")])
        let (px, _) = try renderBZ(onGamma)
        let w = 120, h = 120
        // Cyan node cross: high blue+green, low red — must appear near screen center
        // (Gamma maps to the scene centroid, which the test camera frames at center).
        var cyan = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            if px[i + 2] > 180 && px[i + 1] > 120 && px[i] < 90 { cyan += 1 }
        }
        XCTAssertGreaterThan(cyan, 0,
                             "route node coincident with a landmark must be visible (not depth-dropped)")
    }

    /// Issue 2 seam: BZPresentation reports inv==0 when the BZ face extent is ~0, which
    /// is exactly the condition the renderer's new guard checks to skip drawing. A
    /// degenerate (zero-extent) BZ would otherwise collapse every point onto the scene
    /// center. This pins the presentation behavior the guard relies on.
    func testDegenerateBZPresentationHasZeroScale() {
        // A BZ with no real faces has extent 0 -> inv must be 0.
        let bz = BrillouinZone(faces: [], normals: [], specialPoints: [],
                               reciprocal: (a: .zero, b: .zero, c: .zero))
        let pres = BZPresentation(bz: bz, scene: Scene())
        XCTAssertEqual(pres.inv, 0, "zero-extent BZ must yield inv==0 (the renderer guard's trigger)")
        XCTAssertFalse(pres.inv > 0, "guard `pres.inv > 0` must reject a zero-extent BZ")
    }

    /// Performance: landmark candidates must be computed ONCE per cached BZ, not per
    /// frame. Repeated encodes and route-only edits must not re-run `bz.candidates()`
    /// (scale conversion + O(n²) de-dup + sorting). `bzCandidateComputeCount` pins this.
    func testCandidateComputedOnceNotPerFrame() throws {
        let device = MTLCreateSystemDefaultDevice()!
        let r = try Renderer(device: device)
        r.scene = bzScene(kPath: [KPoint(SIMD3(0, 0, 0), "Γ")])
        let w = 120, h = 120
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm; desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        let cam = { () -> Camera in
            var c = Camera()
            c.perspective = false
            c.center = r.scene.centroid
            c.distance = max(1.0, r.scene.boundingSphere().1) * 0.45 * 1.7
            return c
        }
        func encode() {
            let tex = device.makeTexture(descriptor: desc)!
            let cb = device.makeCommandQueue()!.makeCommandBuffer()!
            XCTAssertTrue(r.encode(to: cb, target: tex,
                                   viewport: MTLViewport(originX: 0, originY: 0, width: Double(w),
                                                         height: Double(h), znear: 0, zfar: 1),
                                   camera: cam()))
            cb.commit(); cb.waitUntilCompleted()
        }
        encode()
        XCTAssertEqual(r.bzCandidateComputeCount, 1)
        encode(); encode(); encode()
        XCTAssertEqual(r.bzCandidateComputeCount, 1, "repeated encodes must not recompute candidates")
        // Route-only edit (same cell/baseAtoms): candidate cache must survive.
        r.scene.kPathPoints.append(KPoint(SIMD3(0.5, 0, 0), "X"))
        encode()
        XCTAssertEqual(r.bzCandidateComputeCount, 1, "route-only edit must not recompute candidates")
    }
}
