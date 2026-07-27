import XCTest
import Combine
import simd
@testable import MolVisApp

// Regressions for direct k-path editing review findings 3 and 4:
//   3. Undoing an edit to a generated route must restore points, breaks,
//      provenance, and the generated signature exactly — including across a
//      save/load round-trip.
//   4. Updating a point's coordinates + label must publish one final kPathPoints
//      value via Combine, never an intermediate (new-coordinate, old-label) state.
final class KPathUndoProvenanceTests: XCTestCase {

    func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    private func crystalScene() throws -> Scene {
        Scene(loaded: try Parser.load(fixture("si110.xsf")))
    }

    private func makeController(_ scene: Scene) -> MainWindowController {
        MainWindowController(scene: scene, showWindow: false)
    }

    // MARK: - Finding 3: undo restores generated provenance + signature

    func testUndoRestoresGeneratedProvenanceAndSignature() throws {
        let c = makeController(try crystalScene())
        let s = c.state
        // A freshly-loaded crystal seeds a generated route with a signature.
        XCTAssertEqual(c.scene.kPathProvenance, .generated)
        let originalSignature = c.scene.kPathSignature
        XCTAssertNotNil(originalSignature)
        let originalPoints = s.kPathPoints
        let originalBreaks = s.kPathBreaks
        XCTAssertFalse(originalPoints.isEmpty)

        // Edit a node: provenance flips to userEdited and signature is cleared.
        s.updateKPathPoint(at: 0, fractionalCoordinate: SIMD3(0.25, 0.25, 0.25), label: "Q")
        XCTAssertEqual(c.scene.kPathProvenance, .userEdited)
        XCTAssertNil(c.scene.kPathSignature)

        // Undo must restore the route's full identity — points, breaks, provenance,
        // and the generated signature — not just the geometry.
        s.undoLast()
        XCTAssertEqual(s.kPathPoints, originalPoints)
        XCTAssertEqual(s.kPathBreaks, originalBreaks)
        XCTAssertEqual(c.scene.kPathProvenance, .generated)
        XCTAssertEqual(c.scene.kPathSignature, originalSignature)
    }

    func testUndoAfterAppendRestoresGeneratedProvenance() throws {
        let c = makeController(try crystalScene())
        let s = c.state
        XCTAssertEqual(c.scene.kPathProvenance, .generated)
        let originalSig = c.scene.kPathSignature
        let originalCount = s.kPathPoints.count

        // Append a landmark: user edit flips provenance and clears the signature.
        s.append(KPoint(SIMD3(0.3, 0.3, 0.3), "K"))
        XCTAssertEqual(s.kPathPoints.count, originalCount + 1)
        XCTAssertEqual(c.scene.kPathProvenance, .userEdited)
        XCTAssertNil(c.scene.kPathSignature)

        // Undo restores the generated identity exactly.
        s.undoLast()
        XCTAssertEqual(s.kPathPoints.count, originalCount)
        XCTAssertEqual(c.scene.kPathProvenance, .generated)
        XCTAssertEqual(c.scene.kPathSignature, originalSig)
    }

    func testEditUndoSaveLoadRoundTripPreservesGeneratedIdentity() throws {
        let c = makeController(try crystalScene())
        let s = c.state
        let originalSig = c.scene.kPathSignature
        let originalPoints = s.kPathPoints

        // Edit then undo: back to the generated route.
        s.updateKPathPoint(at: 0, fractionalCoordinate: SIMD3(0.2, 0.2, 0.2), label: "Z")
        s.undoLast()
        XCTAssertEqual(c.scene.kPathProvenance, .generated)
        XCTAssertEqual(c.scene.kPathSignature, originalSig)
        XCTAssertEqual(s.kPathPoints, originalPoints)

        // Save the state, then load it fresh. A generated route with a matching
        // signature must round-trip as generated with its signature intact.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kpath_undo_rt-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try StateStore.save(c.scene, camera: nil, sourceURL: fixture("si110.xsf"), to: tmp)

        var reloaded = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        var camera: Camera? = nil
        try StateStore.load(into: &reloaded, camera: &camera, from: tmp)
        XCTAssertEqual(reloaded.kPathProvenance, .generated)
        XCTAssertEqual(reloaded.kPathSignature, originalSig)
        XCTAssertEqual(reloaded.kPathPoints, originalPoints)
    }

    func testUndoOfUserEditPreservesBreaks() throws {
        let s = SideBarState()
        s.kPathPoints = [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.5, 0, 0), "X"),
                         KPoint(SIMD3(0.5, 0.5, 0.5), "L")]
        s.kPathBreaks = [0]
        s.kPathProvenance = .generated
        s.kPathSignature = "sig"

        // Toggle a break (user edit): provenance flips.
        s.toggleBreak(at: 1)
        XCTAssertEqual(s.kPathBreaks, [0, 1])
        XCTAssertEqual(s.kPathProvenance, .userEdited)
        XCTAssertNil(s.kPathSignature)

        // Undo restores the original break set, provenance, and signature.
        s.undoLast()
        XCTAssertEqual(s.kPathBreaks, [0])
        XCTAssertEqual(s.kPathProvenance, .generated)
        XCTAssertEqual(s.kPathSignature, "sig")
    }

    func testClearThenUndoRestoresGeneratedIdentity() throws {
        let s = SideBarState()
        let pts = [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.5, 0, 0), "X")]
        s.kPathPoints = pts
        s.kPathBreaks = []
        s.kPathProvenance = .generated
        s.kPathSignature = "abc"

        s.clear()
        XCTAssertTrue(s.kPathPoints.isEmpty)
        XCTAssertEqual(s.kPathProvenance, .userEdited)
        XCTAssertNil(s.kPathSignature)

        s.undoLast()
        XCTAssertEqual(s.kPathPoints, pts)
        XCTAssertEqual(s.kPathBreaks, [])
        XCTAssertEqual(s.kPathProvenance, .generated)
        XCTAssertEqual(s.kPathSignature, "abc")
    }

    // MARK: - Finding 4: atomic Combine publication for coordinate + label edits

    func testUpdateKPathPointPublishesSingleAtomicValue() {
        let s = SideBarState()
        s.kPathPoints = [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.5, 0, 0), "X")]
        s.kPathBreaks = [0]

        // Observe kPathPoints directly through its Combine publisher. @Published
        // fires objectWillChange per *assignment* to the property, so an in-place
        // frac update followed by a separate label update would emit an
        // intermediate (new-coordinate, old-label) value. The fix assigns a whole
        // KPoint so only the final value is ever published.
        var emitted: [[KPoint]] = []
        let c = s.$kPathPoints.sink { emitted.append($0) }
        // Sink replays the current value on subscription.
        XCTAssertEqual(emitted.count, 1)

        s.updateKPathPoint(at: 1, fractionalCoordinate: SIMD3(0.25, 0.25, 0.25), label: "W")

        // Exactly one change notification (initial replay is the pre-edit value).
        XCTAssertEqual(emitted.count, 2, "editing a node must publish exactly one new kPathPoints value")
        let final = emitted.last!
        XCTAssertEqual(final[1].frac, SIMD3(0.25, 0.25, 0.25))
        XCTAssertEqual(final[1].label, "W")
        // No emission may carry the new coordinate with the stale old label.
        let intermediate = emitted.dropFirst().contains { arr in
            arr.indices.contains(1) && arr[1].frac == SIMD3(0.25, 0.25, 0.25) && arr[1].label == "X"
        }
        XCTAssertFalse(intermediate, "intermediate (new-coord, old-label) state must never be published")
        _ = c
    }
}
