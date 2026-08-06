import XCTest
import simd

@testable import MolVisApp

final class StructureToolsControllerTests: XCTestCase {

    /// 2-atom diamond Si in a 5.43 Å cubic cell (fcc lattice + 2-atom basis).
    private func makeSiFccScene() throws -> (Scene, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("st-si-\(UUID().uuidString).in")
        try """
        lattice_vector 5.43 0.0 0.0
        lattice_vector 0.0 5.43 0.0
        lattice_vector 0.0 0.0 5.43
        atom_frac 0.0 0.0 0.0 Si
        atom_frac 0.25 0.25 0.25 Si
        """.write(to: url, atomically: true, encoding: .utf8)
        return (Scene(loaded: try Parser.load(url, as: .fhi)), url)
    }

    @MainActor
    func testBasisTransformSurfaceBuildAndVacuumViaController() throws {
        let (scene, url) = try makeSiFccScene()
        XCTAssertEqual(scene.isCrystal, true)
        XCTAssertEqual(scene.atoms.count, 2)

        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(scene, from: url, format: .fhi, frameIndex: 0)
        XCTAssertEqual(controller.scene.atoms.count, 2)

        // Primitive transform of the diamond basis keeps 2 atoms.
        controller.applyBasisTransform(.primitive)
        XCTAssertEqual(controller.scene.atoms.count, 2)

        // Build a (0 0 1) slab with 2 layers.
        controller.state.surfaceH = 0
        controller.state.surfaceK = 0
        controller.state.surfaceL = 1
        controller.state.surfaceLayers = 2
        controller.buildSurfaceCell()
        XCTAssertEqual(controller.scene.periodicDim, 2)
        XCTAssertGreaterThanOrEqual(controller.state.surfaceTerminationOptions, 1)

        // Live vacuum adjust via the direct callback: c length must grow beyond
        // the requested vacuum.
        controller.state.surfaceVacuum = 25
        controller.surfaceVacuumDidChange()
        let cLen = controller.scene.cell?.cLength ?? 0
        XCTAssertGreaterThan(cLen, 25)
        XCTAssertTrue(cLen.isFinite)

        // Live vacuum adjust via the state-assignment mirror (didSet -> onChange
        // -> syncFromState). Must apply and must not recurse infinitely.
        let originalLen = controller.scene.cell?.cLength ?? 0
        controller.state.surfaceVacuum = 30
        let mirroredLen = controller.scene.cell?.cLength ?? 0
        XCTAssertGreaterThan(mirroredLen, 30)
        XCTAssertTrue(mirroredLen.isFinite)
        XCTAssertNotEqual(mirroredLen, originalLen)
    }

    @MainActor
    func testDeformationAndClusterCutViaController() throws {
        let (scene, url) = try makeSiFccScene()
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(scene, from: url, format: .fhi, frameIndex: 0)

        let originalAX = controller.scene.cell?.a.x ?? 0
        controller.state.deformationMatrix = [1.1, 0, 0, 0, 1, 0, 0, 0, 1]
        controller.applyDeformation()
        XCTAssertEqual(controller.scene.cell?.a.x ?? 0, originalAX * 1.1, accuracy: 1e-4)

        // Cut a cluster around the first atom.
        controller.state.clusterCenter = controller.scene.atoms[0].coord
        controller.state.clusterRadius = 3
        controller.cutCluster()
        XCTAssertEqual(controller.scene.isCrystal, false)
        XCTAssertNil(controller.scene.cell)
        XCTAssertFalse(controller.scene.atoms.isEmpty)
    }
}
