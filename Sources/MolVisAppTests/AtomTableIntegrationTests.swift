import simd
import XCTest
import AppKit
@testable import MolVisApp

final class AtomTableIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// A small molecule: 4 atoms, no cell. Good for row-count + selection tests.
    private func makeMolecule() -> Scene {
        var s = Scene()
        s.atoms = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 14, label: "Si"),
            Atom(coord: SIMD3(1.3575, 1.3575, 0), atomicNumber: 14, label: "Si"),
            Atom(coord: SIMD3(2.0, 0.5, 0.5), atomicNumber: 8, label: "O"),
            Atom(coord: SIMD3(0.5, 2.0, 0.5), atomicNumber: 8, label: "O"),
        ]
        return s
    }

    /// A crystal with a 10 Å cubic cell and two H atoms near opposite faces so
    /// the minimum-image distance (wrapping) differs from the direct distance.
    private func makePeriodicCrystal() -> Scene {
        var s = Scene()
        s.isCrystal = true
        s.cell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        s.periodicDim = 3
        s.atoms = [
            Atom(coord: SIMD3(0.5, 5, 5), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(9.5, 5, 5), atomicNumber: 1, label: "H"),
        ]
        return s
    }

    /// A slabbed crystal whose A-plane distance can remove the first atom while
    /// retaining the second, exercising the table's refreshed row mapping.
    private func makeSlabbedCrystal() -> Scene {
        var s = Scene()
        s.isCrystal = true
        s.cell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        s.periodicDim = 3
        s.atoms = [
            Atom(coord: SIMD3(1, 2, 1), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(2, 8, 2), atomicNumber: 2, label: "He"),
        ]
        let slab = Slab(planeA: Plane(h: 0, k: 1, l: 0, distance: 0),
                        planeB: Plane(h: 0, k: -1, l: 0, distance: 0))
        return s.applySlab(slab)
    }

    // MARK: - Window lifecycle

    @MainActor
    func testControllerConstructsWithoutAtomTableWindow() {
        let c = MainWindowController(scene: makeMolecule(), showWindow: false)
        XCTAssertNil(c.atomTableWindow, "atom table window must be absent until shown")
        XCTAssertEqual(c.atomTable.tableView.numberOfRows, 0,
                       "unopened table must not be populated during controller construction")
    }

    @MainActor
    func testUnopenedAtomTableRemainsUnpopulatedAfterLoad() {
        let c = MainWindowController(scene: Scene(), showWindow: false)
        c.loadFile(makeMolecule())

        XCTAssertNil(c.atomTableWindow)
        XCTAssertEqual(c.atomTable.tableView.numberOfRows, 0,
                       "loading a scene must not populate an unopened table")
        XCTAssertTrue(c.atomTable.filteredAtomIndices.isEmpty)
    }

    @MainActor
    func testShowAtomTableLazilyCreatesAndReusesOneWindow() {
        let c = MainWindowController(scene: makeMolecule(), showWindow: false)
        XCTAssertNil(c.atomTableWindow)

        c.state.onShowAtomTable?()
        let first = c.atomTableWindow
        XCTAssertNotNil(first, "first show must create the auxiliary window")
        XCTAssertEqual(c.atomTable.tableView.numberOfRows, 4,
                       "first show must populate the current scene")
        XCTAssertNil(first?.delegate, "the auxiliary window must not delegate to its viewer")

        // A second show must reuse the same window identity.
        c.state.onShowAtomTable?()
        XCTAssertTrue(c.atomTableWindow === first, "repeated shows must reuse the same window")
    }

    @MainActor
    func testOrderOutLeavesAtomTableModelUntouchedUntilReopened() throws {
        let c = MainWindowController(scene: makePeriodicCrystal(), showWindow: false)
        c.showAtomTable()
        let auxiliary = try XCTUnwrap(c.atomTableWindow)
        c.atomTable.searchField.stringValue = "H"
        c.atomTable.searchChanged(c.atomTable.searchField)
        c.toggleSelection(1)

        let originalSearch = c.atomTable.searchField.stringValue
        let originalRows = c.atomTable.tableView.numberOfRows
        let originalIndices = c.atomTable.filteredAtomIndices
        let originalX = c.atomTable.value(atRow: 0, columnIdentifier: AtomTableView.colX)
        let originalSelection = c.atomTable.tableView.selectedRowIndexes
        auxiliary.orderOut(nil)
        XCTAssertFalse(auxiliary.isVisible)

        c.loadFile(makeSlabbedCrystal())
        c.adjustSlabPlaneA(by: 0.5)
        c.toggleSelection(0)

        XCTAssertEqual(c.atomTable.searchField.stringValue, originalSearch)
        XCTAssertEqual(c.atomTable.tableView.numberOfRows, originalRows)
        XCTAssertEqual(c.atomTable.filteredAtomIndices, originalIndices)
        XCTAssertEqual(c.atomTable.value(atRow: 0, columnIdentifier: AtomTableView.colX), originalX)
        XCTAssertEqual(c.atomTable.tableView.selectedRowIndexes, originalSelection)

        c.showAtomTable()
        XCTAssertTrue(c.atomTableWindow === auxiliary)
        XCTAssertEqual(c.atomTable.tableView.numberOfRows, 1)
        XCTAssertEqual(c.atomTable.filteredAtomIndices, [0])
        XCTAssertEqual(c.atomTable.value(atRow: 0, columnIdentifier: AtomTableView.colElement), "He")
        XCTAssertEqual(c.atomTable.value(atRow: 0, columnIdentifier: AtomTableView.colA), "0.200")
        XCTAssertEqual(c.atomTable.tableView.selectedRowIndexes, IndexSet([0]))
    }

    @MainActor
    func testCloseLeavesAtomTableModelUntouchedUntilReopened() throws {
        let c = MainWindowController(scene: makePeriodicCrystal(), showWindow: false)
        c.showAtomTable()
        let auxiliary = try XCTUnwrap(c.atomTableWindow)
        c.atomTable.searchField.stringValue = "H"
        c.atomTable.searchChanged(c.atomTable.searchField)
        c.toggleSelection(1)

        let originalRows = c.atomTable.tableView.numberOfRows
        let originalIndices = c.atomTable.filteredAtomIndices
        let originalSelection = c.atomTable.tableView.selectedRowIndexes
        auxiliary.close()
        XCTAssertFalse(auxiliary.isVisible)

        c.loadFile(makeSlabbedCrystal())
        c.adjustSlabPlaneA(by: 0.5)
        c.toggleSelection(0)

        XCTAssertEqual(c.atomTable.tableView.numberOfRows, originalRows)
        XCTAssertEqual(c.atomTable.filteredAtomIndices, originalIndices)
        XCTAssertEqual(c.atomTable.tableView.selectedRowIndexes, originalSelection)

        c.showAtomTable()
        XCTAssertTrue(c.atomTableWindow === auxiliary)
        XCTAssertEqual(c.atomTable.tableView.numberOfRows, 1)
        XCTAssertEqual(c.atomTable.filteredAtomIndices, [0])
        XCTAssertEqual(c.atomTable.value(atRow: 0, columnIdentifier: AtomTableView.colElement), "He")
        XCTAssertEqual(c.atomTable.value(atRow: 0, columnIdentifier: AtomTableView.colC), "0.200")
        XCTAssertEqual(c.atomTable.tableView.selectedRowIndexes, IndexSet([0]))
    }

    @MainActor
    func testAuxiliaryCloseDoesNotUnregisterOrCloseMainViewer() throws {
        let app = App()
        let c = MainWindowController(scene: makeMolecule(), showWindow: false)
        app.testAddWindow(c)
        c.state.isPlaying = true
        c.showAtomTable()
        let auxiliary = try XCTUnwrap(c.atomTableWindow)

        // The production auxiliary panel has no controller delegate, so closing it
        // cannot enter either the controller or app main-window lifecycle.
        XCTAssertNil(auxiliary.delegate)
        c.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: auxiliary))
        XCTAssertTrue(c.state.isPlaying)

        // Also protect App.windowWillClose against any unrelated window that happens
        // to point at this controller as its delegate.
        auxiliary.delegate = c
        app.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: auxiliary))
        XCTAssertTrue(app.mainWC === c)

        c.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: c.window))
    }

    // MARK: - Initial rows

    @MainActor
    func testInitialRowCountAfterShow() {
        let c = MainWindowController(scene: makeMolecule(), showWindow: false)
        c.state.onShowAtomTable?()
        XCTAssertEqual(c.atomTable.tableView.numberOfRows, 4)
        XCTAssertEqual(c.atomTable.filteredAtomIndices, [0, 1, 2, 3])
    }

    // MARK: - Table → scene selection

    @MainActor
    func testTableToSceneSelectionClearsLockedResult() {
        var s = makeMolecule()
        s.measurementResult = MeasurementResult(mode: .distance, atomIndices: [0, 1],
                                                value: 1.234, summary: "locked")
        let c = MainWindowController(scene: s, showWindow: false)
        c.state.onShowAtomTable?()

        XCTAssertNotNil(c.scene.measurementResult)

        // Simulate the user selecting rows 0 and 2 in the table.
        c.atomTable.tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        c.atomTable.tableViewSelectionDidChange(Notification(name: .init("test")))

        XCTAssertNil(c.scene.measurementResult, "selection via table must clear locked result")
        XCTAssertEqual(c.scene.selectedAtoms, [0, 2])
    }

    @MainActor
    func testTableToSceneSelectionSortedUniqueAndValidated() {
        let c = MainWindowController(scene: makeMolecule(), showWindow: false)
        c.state.onShowAtomTable?()

        // Select in scrambled order; callback must sort + dedupe.
        c.atomTable.tableView.selectRowIndexes(IndexSet([3, 0, 2, 0]), byExtendingSelection: false)
        c.atomTable.tableViewSelectionDidChange(Notification(name: .init("test")))
        XCTAssertEqual(c.scene.selectedAtoms, [0, 2, 3])
    }

    @MainActor
    func testTableDistanceSelectionKeepsAllRowsWithoutMeasuring() {
        var s = makeMolecule()
        s.measurementMode = .distance
        let c = MainWindowController(scene: s, showWindow: false)
        c.state.onShowAtomTable?()

        c.atomTable.tableView.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
        c.atomTable.tableViewSelectionDidChange(Notification(name: .init("test")))

        XCTAssertEqual(c.scene.selectedAtoms, [0, 1, 2])
        XCTAssertEqual(c.atomTable.tableView.selectedRowIndexes, IndexSet([0, 1, 2]))
        XCTAssertNil(c.scene.measurementResult)
    }

    @MainActor
    func testTableAngleAndDihedralSelectionDoesNotAutoMeasure() {
        for mode in [MeasurementMode.angle, .dihedral] {
            var s = makeMolecule()
            s.measurementMode = mode
            let c = MainWindowController(scene: s, showWindow: false)
            c.state.onShowAtomTable?()

            let rows = IndexSet(integersIn: 0..<mode.selectionCap)
            c.atomTable.tableView.selectRowIndexes(rows, byExtendingSelection: false)
            c.atomTable.tableViewSelectionDidChange(Notification(name: .init("test")))

            XCTAssertEqual(c.scene.selectedAtoms, Array(0..<mode.selectionCap))
            XCTAssertEqual(c.atomTable.tableView.selectedRowIndexes, rows)
            XCTAssertNil(c.scene.measurementResult)
        }
    }

    // MARK: - Scene/viewport → table selection sync

    @MainActor
    func testViewportSelectionSyncsToTable() {
        let c = MainWindowController(scene: makeMolecule(), showWindow: false)
        c.state.onShowAtomTable?()

        // Viewport click path.
        c.toggleSelection(1)
        c.toggleSelection(3)

        XCTAssertEqual(c.atomTable.tableView.selectedRowIndexes, IndexSet([1, 3]))
    }

    @MainActor
    func testViewportDeselectionSyncsToTable() {
        let c = MainWindowController(scene: makeMolecule(), showWindow: false)
        c.state.onShowAtomTable?()

        c.toggleSelection(0)
        c.toggleSelection(2)
        XCTAssertEqual(c.atomTable.tableView.selectedRowIndexes, IndexSet([0, 2]))

        // Deselect atom 0 via the viewport toggle.
        c.toggleSelection(0)
        XCTAssertEqual(c.atomTable.tableView.selectedRowIndexes, IndexSet([2]))
    }

    // MARK: - loadFile refresh

    @MainActor
    func testLoadFileRefreshUpdatesTableRows() {
        let c = MainWindowController(scene: Scene(), showWindow: false)
        c.state.onShowAtomTable?()
        XCTAssertEqual(c.atomTable.tableView.numberOfRows, 0)

        c.loadFile(makeMolecule())
        XCTAssertEqual(c.atomTable.tableView.numberOfRows, 4)
        XCTAssertEqual(c.atomTable.filteredAtomIndices, [0, 1, 2, 3])
    }

    // MARK: - Interactive slab refresh

    @MainActor
    func testInteractiveSlabDistanceRefreshesOpenAtomTableMapping() {
        let c = MainWindowController(scene: makeSlabbedCrystal(), showWindow: false)
        c.showAtomTable()
        XCTAssertEqual(c.atomTable.filteredAtomIndices, [0, 1])

        c.adjustSlabPlaneA(by: 0.5)

        XCTAssertEqual(c.scene.slab?.planeA.distance, 0.5)
        XCTAssertEqual(c.scene.atoms.count, 1)
        XCTAssertEqual(c.atomTable.tableView.numberOfRows, 1)
        XCTAssertEqual(c.atomTable.filteredAtomIndices, [0])
        XCTAssertEqual(c.atomTable.value(atRow: 0, columnIdentifier: AtomTableView.colIndex), "1")
        XCTAssertEqual(c.atomTable.value(atRow: 0, columnIdentifier: AtomTableView.colElement), "He")
    }

    @MainActor
    func testInteractiveSlabDistanceKeepsUnopenedAtomTableLazy() {
        let c = MainWindowController(scene: makeSlabbedCrystal(), showWindow: false)

        c.adjustSlabPlaneA(by: 0.5)

        XCTAssertNil(c.atomTableWindow)
        XCTAssertEqual(c.atomTable.tableView.numberOfRows, 0)
        XCTAssertTrue(c.atomTable.filteredAtomIndices.isEmpty)
    }

    // MARK: - Stale selection

    @MainActor
    func testStaleSelectionIndicesIgnored() {
        let c = MainWindowController(scene: makeMolecule(), showWindow: false)
        c.state.onShowAtomTable?()

        // Select valid rows, then drive a scene selection containing an
        // out-of-range index (99). The table must ignore the stale index.
        c.toggleSelection(1)
        XCTAssertEqual(c.atomTable.tableView.selectedRowIndexes, IndexSet([1]))

        c.scene.selectedAtoms = [1, 99]
        c.setNeedsRender()
        XCTAssertEqual(c.atomTable.tableView.selectedRowIndexes, IndexSet([1]))
    }

    // MARK: - Measurement integration across a periodic boundary

    @MainActor
    func testPeriodicDistanceMeasurementUsesCell() {
        var s = makePeriodicCrystal()
        s.measurementMode = .distance
        let c = MainWindowController(scene: s, showWindow: false)
        // Route selection through the table (production callback path).
        c.state.onShowAtomTable?()
        c.atomTable.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        c.atomTable.tableViewSelectionDidChange(Notification(name: .init("test")))

        XCTAssertEqual(c.scene.selectedAtoms, [0, 1])
        // Direct distance is 9.0; minimum-image wrap across the 10 Å face is 1.0.
        XCTAssertNotNil(c.scene.measurementResult)
        XCTAssertEqual(c.scene.measurementResult!.value, 1.0, accuracy: 1e-4,
                       "periodic measurement must use the minimum-image distance via the cell")

        // Deselecting through the same table callback must clear the locked result.
        c.atomTable.tableView.selectRowIndexes(IndexSet([0]), byExtendingSelection: false)
        c.atomTable.tableViewSelectionDidChange(Notification(name: .init("test")))
        XCTAssertEqual(c.scene.selectedAtoms, [0])
        XCTAssertNil(c.scene.measurementResult)
    }

    @MainActor
    func testPerformMeasurementAcrossPeriodicBoundary() {
        var s = makePeriodicCrystal()
        s.measurementMode = .distance
        let c = MainWindowController(scene: s, showWindow: false)
        c.state.onShowAtomTable?()

        // Two-atom distance selection via the table.
        c.atomTable.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        c.atomTable.tableViewSelectionDidChange(Notification(name: .init("test")))

        c.performMeasurement()
        XCTAssertNotNil(c.scene.measurementResult)
        XCTAssertEqual(c.scene.measurementResult!.value, 1.0, accuracy: 1e-4)
    }
}
