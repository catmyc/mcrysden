import XCTest

@testable import MolVisApp

final class AnimationControllerTests: XCTestCase {
    @MainActor
    func testReloadFrameIsNonReentrantAndMutatesOnce() throws {
        let relaxURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Assets/si_relax.out")
        let relaxInitial = Scene(loaded: try Parser.load(relaxURL, as: nil, frameIndex: 0))
        let relaxController = MainWindowController(scene: Scene(), showWindow: false)
        relaxController.loadFile(relaxInitial, from: relaxURL, format: nil, frameIndex: 0)

        // QE relaxation frames must scrub without re-entering reloadFrame.
        XCTAssertEqual(relaxController.state.frameCount, 2)
        relaxController.state.frameIndex = 1
        XCTAssertEqual(relaxController.scene.currentFrame, 1)
        XCTAssertEqual(relaxController.state.frameIndex, 1)
        relaxController.state.frameIndex = 0
        XCTAssertEqual(relaxController.scene.currentFrame, 0)
        XCTAssertEqual(relaxController.state.frameIndex, 0)

        // The held reload transaction must also perform only one scene mutation
        // for an AXSF field frame and return cleanly to the no-field frame.
        let gridURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.anim_grid.axsf")
        let gridController = MainWindowController(scene: Scene(), showWindow: false)
        gridController.loadFile(try Scene(loaded: Parser.load(gridURL, as: nil, frameIndex: 0)),
                                from: gridURL, format: nil, frameIndex: 0)
        XCTAssertEqual(gridController.state.frameCount, 2)
        gridController.state.frameIndex = 1
        XCTAssertEqual(gridController.scene.currentFrame, 1)
        XCTAssertEqual(gridController.state.frameIndex, 1)
        gridController.state.frameIndex = 0
        XCTAssertEqual(gridController.scene.currentFrame, 0)
        XCTAssertEqual(gridController.state.frameIndex, 0)

        // MARK: - Atom-coordinate editing regression coverage
        // Populate the atom table so commitAtomEdit can resolve filtered rows.
        // (Table window is not visible in tests, so refreshAtomTable is skipped.)
        relaxController.atomTable.update(atoms: relaxController.scene.atoms,
                                          cell: relaxController.scene.cell,
                                          selectedAtoms: relaxController.scene.selectedAtoms)

        // --- Cartesian edit: change x of atom 0 ---
        let cartOriginalX = relaxController.scene.atoms[0].coord.x
        let cartOriginalY = relaxController.scene.atoms[0].coord.y
        let cartOriginalZ = relaxController.scene.atoms[0].coord.z
        let cartOriginalLabel = relaxController.scene.atoms[0].label
        let cartOriginalForce = relaxController.scene.atoms[0].force
        let cartOriginalAN = relaxController.scene.atoms[0].atomicNumber
        let cartNewX = cartOriginalX + 1.5
        let cartResult = relaxController.commitAtomEdit(
            row: 0, columnIdentifier: AtomTableView.colX,
            value: String(format: "%.3f", cartNewX))
        XCTAssertEqual(cartResult, .accepted)
        XCTAssertEqual(relaxController.scene.atoms[0].coord.x, cartNewX, accuracy: 1e-4)
        // Unchanged components preserved.
        XCTAssertEqual(relaxController.scene.atoms[0].coord.y, cartOriginalY, accuracy: 1e-6)
        XCTAssertEqual(relaxController.scene.atoms[0].coord.z, cartOriginalZ, accuracy: 1e-6)
        // Identity / label / force preserved.
        XCTAssertEqual(relaxController.scene.atoms[0].atomicNumber, cartOriginalAN)
        XCTAssertEqual(relaxController.scene.atoms[0].label, cartOriginalLabel)
        XCTAssertEqual(relaxController.scene.atoms[0].force, cartOriginalForce)

        // --- Fractional edit: change fractional a of atom 1 ---
        guard relaxController.scene.cell != nil else {
            throw XCTSkip("si_relax.out has no cell; cannot test fractional edit")
        }
        let fracBefore = relaxController.scene.fractionalCoord(relaxController.scene.atoms[1].coord)!
        let fracNewA = fracBefore.x + 0.1
        let fracResult = relaxController.commitAtomEdit(
            row: 1, columnIdentifier: AtomTableView.colA,
            value: String(format: "%.3f", fracNewA))
        XCTAssertEqual(fracResult, .accepted)
        let fracAfter = relaxController.scene.fractionalCoord(relaxController.scene.atoms[1].coord)!
        XCTAssertEqual(fracAfter.x, fracNewA, accuracy: 1e-3)
        // Other fractional components preserved.
        XCTAssertEqual(fracAfter.y, fracBefore.y, accuracy: 1e-4)
        XCTAssertEqual(fracAfter.z, fracBefore.z, accuracy: 1e-4)

        // --- Measurement invalidation ---
        // Set a locked measurement, then edit — measurement must clear.
        relaxController.scene.selectedAtoms = [0, 1]
        relaxController.scene.measurementMode = .distance
        relaxController.scene.measurementResult = Scene.computeMeasurement(
            mode: .distance, atoms: relaxController.scene.atoms,
            selected: [0, 1], cell: relaxController.scene.cell,
            periodicDim: relaxController.scene.periodicDim)
        XCTAssertNotNil(relaxController.scene.measurementResult)
        let measEditResult = relaxController.commitAtomEdit(
            row: 0, columnIdentifier: AtomTableView.colY,
            value: String(format: "%.3f", cartOriginalY + 0.5))
        XCTAssertEqual(measEditResult, .accepted)
        XCTAssertNil(relaxController.scene.measurementResult,
                     "editing an atom must invalidate the locked measurement")

        // Edited source snapshots survive a supercell round trip.
        let editedBase = relaxController.scene
        let expanded = editedBase.widenSuperCell(SuperCell(n1: 2, n2: 1, n3: 1))
        let restoredBase = expanded.widenSuperCell(SuperCell())
        XCTAssertEqual(restoredBase.atoms, editedBase.atoms)
        XCTAssertEqual(restoredBase.bonds.map { [$0.i, $0.j] },
                       editedBase.bonds.map { [$0.i, $0.j] })

        // --- Real undo / redo through the document undo manager ---
        relaxController.undoCoordinateEdit()
        XCTAssertEqual(relaxController.scene.atoms[0].coord.y, cartOriginalY, accuracy: 1e-4)
        XCTAssertNotNil(relaxController.scene.measurementResult)
        relaxController.redoCoordinateEdit()
        XCTAssertEqual(relaxController.scene.atoms[0].coord.y, cartOriginalY + 0.5, accuracy: 1e-4)
        XCTAssertNil(relaxController.scene.measurementResult)

        // --- Coordination lifecycle: enabling coordination restarts analysis ---
        relaxController.state.coordinationEnabled = true
        XCTAssertEqual(relaxController.state.coordinationStatusText, "Calculating…")

        // --- Invalid / nonfinite rejection leaves scene unchanged ---
        let preRejectSnapshot = relaxController.scene
        let nanResult = relaxController.commitAtomEdit(
            row: 0, columnIdentifier: AtomTableView.colX, value: "nan")
        XCTAssertEqual(nanResult, .rejected(reason: "\"nan\" is not a finite number."))
        XCTAssertEqual(relaxController.scene.atoms[0].coord, preRejectSnapshot.atoms[0].coord)
        XCTAssertEqual(relaxController.scene.atoms[1].coord, preRejectSnapshot.atoms[1].coord)
        let infResult = relaxController.commitAtomEdit(
            row: 0, columnIdentifier: AtomTableView.colX, value: "inf")
        XCTAssertEqual(infResult, .rejected(reason: "\"inf\" is not a finite number."))
        XCTAssertEqual(relaxController.scene.atoms[0].coord, preRejectSnapshot.atoms[0].coord)
        let emptyResult = relaxController.commitAtomEdit(
            row: 0, columnIdentifier: AtomTableView.colX, value: "not_a_number")
        XCTAssertEqual(emptyResult, .rejected(reason: "\"not_a_number\" is not a finite number."))
        XCTAssertEqual(relaxController.scene.atoms[0].coord, preRejectSnapshot.atoms[0].coord)

        // --- Active supercell / slab edit rejection ---
        relaxController.state.n1 = 2
        relaxController.state.onChange?()
        XCTAssertGreaterThan(relaxController.scene.superCell.total, 1)
        relaxController.syncAtomTableEditingState()
        XCTAssertFalse(relaxController.atomTable.isEditingEnabled)
        let scReject = relaxController.commitAtomEdit(
            row: 0, columnIdentifier: AtomTableView.colX, value: "0.000")
        XCTAssertEqual(scReject, .rejected(reason: "Editing disabled: supercell active. Reset the supercell to 1×1×1 to edit atom coordinates."))
        // Reset supercell; enable slab.
        relaxController.state.n1 = 1
        relaxController.state.slabEnabled = true
        relaxController.state.onChange?()
        XCTAssertNotNil(relaxController.scene.slab)
        relaxController.syncAtomTableEditingState()
        XCTAssertFalse(relaxController.atomTable.isEditingEnabled)
        let slabReject = relaxController.commitAtomEdit(
            row: 0, columnIdentifier: AtomTableView.colX, value: "0.000")
        XCTAssertEqual(slabReject, .rejected(reason: "Editing disabled: slab active. Remove the slab to edit atom coordinates."))
        XCTAssertEqual(relaxController.scene.atoms[0].coord, preRejectSnapshot.atoms[0].coord,
                       "rejected edits must not change the scene")

        // --- Molecule bonds update after coordinate edit ---
        let molURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/h2o.xyz")
        let molScene = Scene(loaded: try Parser.load(molURL))
        let molController = MainWindowController(scene: Scene(), showWindow: false)
        molController.loadFile(molScene, from: molURL, format: nil, frameIndex: 0)
        XCTAssertNil(molController.scene.cell, "h2o.xyz is a molecule")
        molController.atomTable.update(atoms: molController.scene.atoms,
                                        cell: molController.scene.cell,
                                        selectedAtoms: molController.scene.selectedAtoms)
        let molBondsBefore = molController.scene.bonds
        XCTAssertFalse(molBondsBefore.isEmpty, "molecule must have bonds after loading")
        let molOrigX = molController.scene.atoms[0].coord.x
        let molResult = molController.commitAtomEdit(
            row: 0, columnIdentifier: AtomTableView.colX,
            value: String(format: "%.3f", molOrigX + 0.5))
        XCTAssertEqual(molResult, .accepted)
        XCTAssertFalse(molController.scene.bonds.isEmpty,
                       "molecule bonds must be recomputed after edit")
        XCTAssertEqual(molController.scene.atoms[0].coord.x, molOrigX + 0.5, accuracy: 1e-4)

        // --- Asymmetric-unit symmetry completeness preserved after edit ---
        let asuController = AnimationControllerTests.findAsymmetricUnitController()
        let asuCompletenessBefore = asuController.scene.crystalSymmetry?.inputCompleteness ?? .complete
        XCTAssertNotEqual(asuCompletenessBefore, .complete,
                          "fixture should be parsed as asymmetric-unit")
        asuController.atomTable.update(atoms: asuController.scene.atoms,
                                        cell: asuController.scene.cell,
                                        selectedAtoms: asuController.scene.selectedAtoms)
        let asuOrigX = asuController.scene.atoms[0].coord.x
        let asuResult = asuController.commitAtomEdit(
            row: 0, columnIdentifier: AtomTableView.colX,
            value: String(format: "%.3f", asuOrigX + 0.1))
        XCTAssertEqual(asuResult, .accepted)
        let asuCompletenessAfter = asuController.scene.crystalSymmetry?.inputCompleteness ?? .complete
        XCTAssertEqual(asuCompletenessAfter, asuCompletenessBefore,
                       "edit must preserve asymmetric-unit completeness")
        XCTAssertNil(asuController.scene.crystalSymmetry?.symmetry,
                     "incomplete input must not gain symmetry after edit")
        // --- Frame metadata sync (merged regression) ---
        do {

        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.anim_grid.axsf")
        // Fixture: scalar grid lives on frame 1 (range [0, 1.4]); frame 0 has none.
        XCTAssertNil(try Parser.load(url, as: nil, frameIndex: 0).scalarField)
        XCTAssertNotNil(try Parser.load(url, as: nil, frameIndex: 1).scalarField)

        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(try Scene(loaded: Parser.load(url, as: nil, frameIndex: 0)),
                            from: url, format: nil, frameIndex: 0)
        XCTAssertEqual(controller.state.frameCount, 2)
        XCTAssertEqual(controller.state.frameIndex, 0)
        // Simulate a stale gate from a prior grid frame; reload must refresh all
        // per-frame metadata when stepping onto and back off the field frame.
        controller.state.hasScalarField = true
        XCTAssertFalse((try Parser.load(url, as: nil, frameIndex: 0).scalarField != nil),
                       "baseline frame parses with no grid")

        controller.state.frameIndex = 1
        XCTAssertEqual(controller.scene.currentFrame, 1)
        XCTAssertNotNil(controller.scene.scalarField)
        XCTAssertTrue(controller.state.hasScalarField, "stepped onto grid -> gate ON")
        XCTAssertEqual(controller.state.isoRange.lowerBound, 0.0, accuracy: 1e-4)
        XCTAssertEqual(controller.state.isoRange.upperBound, 1.4, accuracy: 1e-4)
        XCTAssertEqual(controller.state.isoLevel, controller.scene.isoLevel, accuracy: 1e-4)

        controller.state.frameIndex = 0
        XCTAssertEqual(controller.scene.currentFrame, 0)
        XCTAssertNil(controller.scene.scalarField)
        XCTAssertFalse(controller.state.hasScalarField, "stepped off grid -> gate OFF")
        XCTAssertEqual(controller.state.isoRange.lowerBound, 0.0, accuracy: 1e-4)
        XCTAssertEqual(controller.state.isoRange.upperBound, 1.0, accuracy: 1e-4)

        // The same field-presence transaction must refresh the 2D color plane,
        // its labels/contours/spans, and sibling visibility.
        let planeURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.anim_grid2d.axsf")
        XCTAssertNil(try Parser.load(planeURL, as: nil, frameIndex: 0).grid2D)
        XCTAssertNotNil(try Parser.load(planeURL, as: nil, frameIndex: 1).grid2D)

        let planeController = MainWindowController(scene: Scene(), showWindow: false)
        planeController.loadFile(try Scene(loaded: Parser.load(planeURL, as: nil, frameIndex: 0)),
                                 from: planeURL, format: nil, frameIndex: 0)
        XCTAssertEqual(planeController.state.frameCount, 2)

        planeController.state.frameIndex = 1
        XCTAssertEqual(planeController.scene.currentFrame, 1)
        XCTAssertNotNil(planeController.scene.grid2D, "grid data must be present on a grid frame")
        XCTAssertEqual(planeController.scene.grid2D?.ident, "density")
        // The color plane now lives in the Metal scene; the canvas stays visible.
        XCTAssertFalse(planeController.canvas.isHidden, "canvas must stay visible (plane composites in 3D)")

        planeController.state.frameIndex = 0
        XCTAssertEqual(planeController.scene.currentFrame, 0)
        XCTAssertNil(planeController.scene.grid2D, "grid data must be cleared on a no-grid frame")
        XCTAssertFalse(planeController.canvas.isHidden, "canvas must stay visible when no grid")

        // The same reload transaction must also apply the preserved multi-orbital
        // selection and clamp the carried iso level against the selected field.
        try assertMultiOrbitalSelectionAppliedDuringReload()
        }   // end merged block

    }

    /// Find a CRYSCAL fixture that parses as asymmetric-unit (incomplete).
    /// The parser expands numeric space groups (1-230) to `.complete`; files
    /// with space group 0 or unrecognized symbols stay `.asymmetricUnit`.
    static func findAsymmetricUnitController() -> MainWindowController {
        let candidates = [
            "crystal_argonite.r1",
            "crystal_calcite.r1",
            "crystal_chabazite.r1",
            "crystal_cluster.r1",
            "crystal_corundum.r1",
            "crystal_cuprite.r1",
            "crystal_graphite.r1",
            "crystal_mgo.r1",
            "crystal_polymer.r1",
            "crystal_pyrite.r1",
            "crystal_rutile.r1",
            "crystal_zro2.r1",
        ]
        for name in candidates {
            let url = URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(name)")
            let scene = try! Scene(loaded: Parser.load(url))
            let completeness = scene.crystalSymmetry?.inputCompleteness ?? .complete
            if completeness != .complete {
                let controller = MainWindowController(scene: Scene(), showWindow: false)
                controller.loadFile(scene, from: url, format: nil, frameIndex: 0)
                return controller
            }
        }
        fatalError("no asymmetric-unit CRYSCAL fixture found")
    }

    // MARK: - Per-frame metadata gates + orbital/iso selection must track the
    // displayed frame. Before the reloadFrame fix only hasForceSet was refreshed;
    // scrubbing onto a frame that lost its scalarField (or gained one) left the
    // stale gate on the previous frame, and the orbitalCount/iso slider used
    // the prior frame's values.

    // Multi-orbital selection and iso clamp must agree on the selected orbital
    // BEFORE the frame is installed, so the renderer shows the orbital whose iso
    // range the sidebar reports. AXSF animations never parse to multi-orbital
    // frames, so the helper is exercised via a focused synthetic Scene test.
    private func assertMultiOrbitalSelectionAppliedDuringReload() throws {
        // Two fictional orbitals with distinguishable ranges/values; selection "2"
        // clamps onto the second (index 1). Prior to the rework, next's default first-
        // orbital selection survived and the renderer drew orbital 0 while the picker
        // still showed the prior choice.
        let field0 = ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                                 vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                                 values: Array(repeating: 0.5, count: 8),
                                 minValue: 0.0, maxValue: 1.0)
        let field1 = ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                                 vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                                 values: Array(repeating: 5.0, count: 8),
                                 minValue: 2.0, maxValue: 6.0)

        let controller = MainWindowController(scene: Scene(), showWindow: false)

        // Clamp carries the slider's preserved level (out of range for field1) and the
        // prior selection (2) into the new frame.
        var next = Scene()
        next.multiOrbitalFields = [field0, field1]
        next.currentOrbital = 0          // parsed default — still orbital 0 on install
        next.isoLevel = 10.0             // out-of-range for BOTH fields
        controller.applySelectedOrbitalAndClampIso(scene: &next, currentOrbital: 2)
        // The preserved selection clips to index 1; scene now selects field1.
        XCTAssertEqual(next.currentOrbital, 1)
        XCTAssertEqual(next.scalarField?.minValue ?? .nan, 2.0, accuracy: 1e-4)
        XCTAssertEqual(next.scalarField?.maxValue ?? .nan, 6.0, accuracy: 1e-4)
        XCTAssertEqual(next.scalarField?.value(0, 0, 0) ?? .nan, 5.0, accuracy: 1e-4)
        XCTAssertEqual(next.isoLevel, 6.0, accuracy: 1e-4,
                       "clamped iso into the selected field's range")

        // A lower preserved selection is honored when it still fits.
        var next2 = Scene()
        next2.multiOrbitalFields = [field0, field1]
        next2.isoLevel = 0.5
        controller.applySelectedOrbitalAndClampIso(scene: &next2, currentOrbital: 0)
        XCTAssertEqual(next2.currentOrbital, 0)
        XCTAssertEqual(next2.scalarField?.minValue ?? .nan, 0.0, accuracy: 1e-4)
        XCTAssertEqual(next2.scalarField?.maxValue ?? .nan, 1.0, accuracy: 1e-4)
        XCTAssertEqual(next2.scalarField?.value(0, 0, 0) ?? .nan, 0.5, accuracy: 1e-4)
        XCTAssertEqual(next2.isoLevel, 0.5, accuracy: 1e-4,
                       "iso in-range is preserved unchanged")

        // Negative injected currentOrbital (not yet sanitized by syncFromState); the
        // helper's lower bound must clamp it to 0 so the sidebar never shows a
        // negative selection. This is the case the reloadFrame metadata transaction
        // now mirrors verbatim (state.currentOrbital = next.currentOrbital).
        var nextNeg = Scene()
        nextNeg.multiOrbitalFields = [field0, field1]
        nextNeg.isoLevel = 0.25
        controller.applySelectedOrbitalAndClampIso(scene: &nextNeg, currentOrbital: -3)
        XCTAssertEqual(nextNeg.currentOrbital, 0, "negative injected selection clamps to 0")
        XCTAssertEqual(nextNeg.scalarField?.minValue ?? .nan, 0.0, accuracy: 1e-4)
        XCTAssertEqual(nextNeg.scalarField?.maxValue ?? .nan, 1.0, accuracy: 1e-4)
        XCTAssertEqual(nextNeg.isoLevel, 0.25, accuracy: 1e-4)

        // No multi-orbital fields leaves selection untouched and the level clamped
        // against the (optional) single-field range.
        var next3 = Scene()
        next3.scalarField = field0
        next3.isoLevel = -5.0
        controller.applySelectedOrbitalAndClampIso(scene: &next3, currentOrbital: 7)
        XCTAssertEqual(next3.currentOrbital, 0, "single-field reload leaves selection at default")
        XCTAssertEqual(next3.isoLevel, 0.0, accuracy: 1e-4,
                       "single-field clamp bounds the iso level")
    }

    // MARK: - Export destination overwrite guard

    /// Writing an exported structure back onto the loaded source URL must be
    /// blocked by the destination-validation guard, not silently allowed to
    /// destroy the source. The guard lives in `App.validateGUIWriteDestination`
    /// and is invoked before any bytes are written.
    @MainActor
    func testExportStructureRefusesToOverwriteSource() throws {
        // A real multi-frame source the parser accepts.
        let src = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Assets/si_relax.out")
        let initial = Scene(loaded: try Parser.load(src, as: nil, frameIndex: 0))
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(initial, from: src, format: nil, frameIndex: 0)

        // Snapshot the source content, then attempt to export onto it.
        let original = try String(contentsOf: src, encoding: .utf8)
        controller.exportStructure(.xyz, to: src)

        // The guard must block the write: the file is unchanged. (If the guard
        // were missing, the .xyz text — a different format — would overwrite it.)
        let after = try String(contentsOf: src, encoding: .utf8)
        XCTAssertEqual(after, original, "export must not overwrite the loaded source")
    }

    // MARK: - Frame-reload appearance parity

    /// reloadFrame now adopts every appearance field from the previous frame
    /// via `Scene.adoptAppearance(from:)`. Before the fix, fields added to
    /// Scene after the original carry block (anaglyphMode, opacity, lineWidth,
    /// aoQuality, …) silently reset on every scrub. This test sets a
    /// distinctive value on each of those previously-missed fields, scrubs to
    /// the next frame, and asserts every one survives the reload.
    @MainActor
    func testReloadFrameAdoptsAllAppearanceFields() throws {
        let src = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Assets/si_relax.out")
        let initial = Scene(loaded: try Parser.load(src, as: nil, frameIndex: 0))
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(initial, from: src, format: nil, frameIndex: 0)
        XCTAssertEqual(controller.state.frameCount, 2)

        // Stamp the live scene with distinctive values for every field
        // adoptAppearance copies (including the ones the old manual block
        // missed). Use values far from Scene's defaults.
        var staged = controller.scene
        staged.anaglyphMode = .redCyan
        staged.opacity = 0.42
        staged.lineWidth = 3.7
        staged.depthCueingStrength = 0.31
        staged.aoStrength = 0.58
        staged.shadowStrength = 0.69
        staged.aoQuality = 5
        staged.shadowQuality = 4
        staged.msaaSampleCount = 8
        staged.clipPlane = ClipPlane(enabled: true, h: 1, k: 2, l: 3, distance: 1.5)
        staged.isoSurfaces = [IsoSurfaceSpec(level: 0.25, colorHex: "#AABBCC", sign: -1, enabled: true)]
        staged.colorPlaneColormap = .turbo
        staged.colorPlaneContourEnabled = true
        staged.colorPlaneContourCount = 12
        staged.volumeSlices = [VolumeSlice(), VolumeSlice()]
        staged.atomColorScheme = .coordination
        staged.cellRodsEnabled = true
        staged.cellRodFactor = 0.33
        staged.unicolorBonds = !staged.unicolorBonds
        controller.scene = staged

        // Scrub to frame 1 → reloadFrame builds the next scene from the parsed
        // frame and adopts appearance from the previous (staged) scene.
        controller.state.frameIndex = 1
        let next = controller.scene

        // Selection + measurement are per-frame and must NOT carry.
        XCTAssertTrue(next.selectedAtoms.isEmpty)
        XCTAssertNil(next.measurementResult)

        // Every adopted field must match the staged scene.
        XCTAssertEqual(next.anaglyphMode, .redCyan)
        XCTAssertEqual(next.opacity, 0.42, accuracy: 1e-6)
        XCTAssertEqual(next.lineWidth, 3.7, accuracy: 1e-6)
        XCTAssertEqual(next.depthCueingStrength, 0.31, accuracy: 1e-6)
        XCTAssertEqual(next.aoStrength, 0.58, accuracy: 1e-6)
        XCTAssertEqual(next.shadowStrength, 0.69, accuracy: 1e-6)
        XCTAssertEqual(next.aoQuality, 5)
        XCTAssertEqual(next.shadowQuality, 4)
        XCTAssertEqual(next.msaaSampleCount, 8)
        XCTAssertNotNil(next.clipPlane)
        XCTAssertEqual(next.clipPlane?.enabled, true)
        XCTAssertEqual(next.clipPlane?.h, 1)
        XCTAssertEqual(next.clipPlane?.distance ?? -1, Float(1.5), accuracy: 1e-4)
        XCTAssertEqual(next.isoSurfaces.count, 1)
        XCTAssertEqual(next.isoSurfaces.first?.level ?? -1, Float(0.25), accuracy: 1e-4)
        XCTAssertEqual(next.colorPlaneColormap, .turbo)
        XCTAssertEqual(next.colorPlaneContourEnabled, true)
        XCTAssertEqual(next.colorPlaneContourCount, 12)
        XCTAssertEqual(next.volumeSlices.count, 2)
        XCTAssertEqual(next.atomColorScheme, .coordination)
        XCTAssertEqual(next.cellRodsEnabled, true)
        XCTAssertEqual(next.cellRodFactor, 0.33, accuracy: 1e-6)
        XCTAssertEqual(next.unicolorBonds, staged.unicolorBonds)

        // Geometry must come from the freshly parsed frame, NOT the staged scene.
        XCTAssertEqual(next.currentFrame, 1)
    }

}
