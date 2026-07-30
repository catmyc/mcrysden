import AppKit
import Darwin
import XCTest
import simd
@testable import MolVisApp

@MainActor
final class CoordinationIntegrationTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func increment() {
            lock.lock(); storage += 1; lock.unlock()
        }
    }

    private final class DebounceHarness {
        private var nextID = 0
        private var entries: [Int: (() -> Void, Bool)] = [:]

        var pendingCount: Int {
            entries.values.filter { !$0.1 }.count
        }

        func schedule(_ delay: TimeInterval, action: @escaping () -> Void) -> (() -> Void) {
            nextID += 1
            let id = nextID
            entries[id] = (action, false)
            return { [weak self] in
                guard let self, var entry = self.entries[id] else { return }
                entry.1 = true
                self.entries[id] = entry
            }
        }

        func fireNext() {
            guard let id = entries.keys.sorted().first(where: { entries[$0]?.1 == false }),
                  let entry = entries.removeValue(forKey: id) else { return }
            entry.0()
        }
    }

    private func makeScene(atomCount: Int = 2) -> Scene {
        var scene = Scene()
        scene.isCrystal = true
        scene.periodicDim = 3
        scene.cell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        scene.atoms = (0..<atomCount).map { index in
            Atom(coord: SIMD3(Float(index) * 0.5, 0, 0), atomicNumber: 1, label: "H")
        }
        return scene
    }

    private func installProvider(on controller: MainWindowController,
                                 calls: Counter) {
        controller.coordinationAnalyzerOverride = { atoms, cell, periodicDim, scale, isCancelled in
            calls.increment()
            return CoordinationAnalyzer.analyze(atoms: atoms, cell: cell,
                                                 periodicDim: periodicDim,
                                                 radiusScale: scale,
                                                 isCancelled: isCancelled)
        }
    }

    private func waitForReady(_ controller: MainWindowController) async {
        let expectation = expectation(description: "coordination analysis installed")
        var fulfilled = false
        controller.coordinationAnalysisDidUpdate = {
            if controller.state.coordinationAnalysisAvailable && !fulfilled {
                fulfilled = true
                expectation.fulfill()
            }
        }
        if controller.state.coordinationAnalysisAvailable && !fulfilled {
            fulfilled = true
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 3)
    }

    func testDisabledIsLazy() {
        let calls = Counter()
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        installProvider(on: controller, calls: calls)

        XCTAssertFalse(controller.state.coordinationEnabled)
        XCTAssertNil(controller.coordinationAnalysis)
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(controller.state.coordinationStatusText, "Off")
    }

    func testEnableInstallsAnalysisAndPublishesSummary() async {
        let calls = Counter()
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        installProvider(on: controller, calls: calls)

        controller.state.coordinationEnabled = true
        await waitForReady(controller)

        XCTAssertNotNil(controller.coordinationAnalysis)
        XCTAssertGreaterThan(calls.value, 0)
        XCTAssertTrue(controller.state.coordinationSummaryText.contains("Atoms: 2"))
        XCTAssertTrue(controller.state.coordinationSummaryText.contains("coordination range"))
    }

    func testStaleGenerationCannotInstallOverNewScene() async throws {
        let calls = Counter()
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        let firstStarted = expectation(description: "first analysis started")
        let firstCancelled = expectation(description: "first analysis cancelled")
        var isFirst = true
        controller.coordinationAnalyzerOverride = { atoms, cell, periodicDim, scale, isCancelled in
            calls.increment()
            if isFirst {
                isFirst = false
                firstStarted.fulfill()
                while !isCancelled() { usleep(1_000) }
                firstCancelled.fulfill()
                return nil
            }
            return CoordinationAnalyzer.analyze(atoms: atoms, cell: cell,
                                                 periodicDim: periodicDim,
                                                 radiusScale: scale,
                                                 isCancelled: isCancelled)
        }

        controller.state.coordinationEnabled = true
        await fulfillment(of: [firstStarted], timeout: 3)
        controller.loadFile(makeScene(atomCount: 3))
        await fulfillment(of: [firstCancelled], timeout: 3)
        await waitForReady(controller)

        XCTAssertEqual(controller.scene.atoms.count, 3)
        XCTAssertEqual(controller.coordinationAnalysis?.coordinationNumbers.count, 3)
        XCTAssertGreaterThanOrEqual(calls.value, 2)
    }

    func testScaleSceneSupercellAndSlabChangesRefreshOnlyWhenEnabled() async {
        let calls = Counter()
        let controller = MainWindowController(scene: makeScene(atomCount: 4), showWindow: false)
        let scheduler = DebounceHarness()
        controller.coordinationDebounceScheduler = scheduler.schedule
        installProvider(on: controller, calls: calls)

        controller.state.coordinationEnabled = true
        await waitForReady(controller)
        let afterEnable = calls.value

        controller.state.coordinationRadiusScale = 0.85
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.fireNext()
        await waitForReady(controller)
        XCTAssertGreaterThan(calls.value, afterEnable)
        let afterScale = calls.value

        controller.state.n1 = 2
        await waitForReady(controller)
        XCTAssertGreaterThan(calls.value, afterScale)
        let afterSupercell = calls.value

        controller.state.slabEnabled = true
        controller.state.slabA_h = 0
        controller.state.slabA_k = 1
        controller.state.slabA_l = 0
        controller.state.slabB_h = 0
        controller.state.slabB_k = -1
        controller.state.slabB_l = 0
        await waitForReady(controller)
        XCTAssertGreaterThan(calls.value, afterSupercell)
    }

    func testEffectiveCellScalesOnlyPeriodicDisplayedAxes() async {
        var scene = makeScene()
        scene.periodicDim = 2
        scene.superCell = SuperCell(n1: 2, n2: 3, n3: 4)
        let controller = MainWindowController(scene: scene, showWindow: false)

        let cell = controller.effectiveCoordinationCell(for: scene)
        XCTAssertEqual(cell?.a, SIMD3(20, 0, 0))
        XCTAssertEqual(cell?.b, SIMD3(0, 30, 0))
        XCTAssertEqual(cell?.c, SIMD3(0, 0, 10))

        let calls = Counter()
        installProvider(on: controller, calls: calls)
        controller.state.coordinationEnabled = true
        await waitForReady(controller)
        XCTAssertEqual(calls.value, 1)
    }

    func testDisableClearsAnalysisRendererAndVisibleTable() async {
        let calls = Counter()
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        installProvider(on: controller, calls: calls)
        controller.showAtomTable()
        controller.state.coordinationEnabled = true
        await waitForReady(controller)

        XCTAssertNotNil(controller.atomTable.value(atRow: 0, columnIdentifier: AtomTableView.colCoordination))
        controller.state.showCoordinationColors = true
        controller.state.coordinationEnabled = false

        XCTAssertNil(controller.coordinationAnalysis)
        XCTAssertFalse(controller.state.coordinationAnalysisAvailable)
        XCTAssertEqual(controller.state.coordinationStatusText, "Off")
        XCTAssertNil(controller.atomTable.value(atRow: 0, columnIdentifier: AtomTableView.colCoordination))
        XCTAssertFalse(controller.renderer?.showCoordinationColors ?? false)
        XCTAssertTrue(controller.renderer?.coordinationNumbers.isEmpty ?? true)
        XCTAssertFalse(controller.renderer2D?.showCoordinationColors ?? false)
        XCTAssertTrue(controller.renderer2D?.coordinationNumbers.isEmpty ?? true)
    }

    func testHiddenTableReopensWithCurrentCoordinationNumbers() async throws {
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        installProvider(on: controller, calls: Counter())
        controller.state.coordinationEnabled = true
        await waitForReady(controller)
        controller.showAtomTable()
        let window = try XCTUnwrap(controller.atomTableWindow)
        XCTAssertNotNil(controller.atomTable.value(atRow: 0, columnIdentifier: AtomTableView.colCoordination))

        window.orderOut(nil)
        controller.state.coordinationEnabled = false
        controller.state.coordinationEnabled = true
        await waitForReady(controller)
        controller.showAtomTable()
        XCTAssertEqual(controller.atomTableWindow, window)
        XCTAssertNotNil(controller.atomTable.value(atRow: 0, columnIdentifier: AtomTableView.colCoordination))
    }

    func testSelectedReadoutContainsCoordinationDetailsAndSelectionCap() async {
        let controller = MainWindowController(scene: makeScene(atomCount: 10), showWindow: false)
        installProvider(on: controller, calls: Counter())
        controller.state.coordinationEnabled = true
        await waitForReady(controller)

        controller.scene.selectedAtoms = Array(0..<10)
        let text = controller.buildInfoText()
        XCTAssertTrue(text.contains("Coordination:"))
        XCTAssertTrue(text.contains("CN"))
        XCTAssertTrue(text.contains("H #"))
        XCTAssertTrue(text.contains("Å"))
        XCTAssertTrue(text.contains("more selected atoms"))
    }

    func testSelectedReadoutShowsNonzeroPeriodicImageOffset() async {
        var scene = makeScene()
        scene.atoms = [
            Atom(coord: SIMD3(0.1, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(9.9, 0, 0), atomicNumber: 1, label: "H"),
        ]
        let controller = MainWindowController(scene: scene, showWindow: false)
        installProvider(on: controller, calls: Counter())
        controller.state.coordinationEnabled = true
        await waitForReady(controller)
        controller.scene.selectedAtoms = [0]

        XCTAssertTrue(controller.buildInfoText().contains("image=("))
    }

    func testScaleControlClampsToSidebarRange() {
        let state = SideBarState()
        state.coordinationRadiusScale = 3
        XCTAssertEqual(state.coordinationRadiusScale, 2.0, accuracy: 1e-6)
        state.coordinationRadiusScale = 0
        XCTAssertEqual(state.coordinationRadiusScale, 0.50, accuracy: 1e-6)
    }

    func testColorToggleDoesNotRecomputeAndWiresBothRenderers() async {
        let calls = Counter()
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        installProvider(on: controller, calls: calls)
        controller.state.coordinationEnabled = true
        await waitForReady(controller)
        let before = calls.value

        controller.state.showCoordinationColors = true

        XCTAssertEqual(calls.value, before)
        if let renderer = controller.renderer {
            XCTAssertTrue(renderer.showCoordinationColors)
            XCTAssertEqual(renderer.coordinationNumbers.count, controller.scene.atoms.count)
        }
        if let renderer2D = controller.renderer2D {
            XCTAssertTrue(renderer2D.showCoordinationColors)
            XCTAssertEqual(renderer2D.coordinationNumbers.count, controller.scene.atoms.count)
        }
    }

    func testRepeatedRendersDoNotPushOrDeriveCoordinationNumbers() async {
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        installProvider(on: controller, calls: Counter())
        controller.state.coordinationEnabled = true
        await waitForReady(controller)

        let before = controller.coordinationRendererUpdateCount
        controller.setNeedsRender()
        controller.setNeedsRender()
        controller.setNeedsRender()
        XCTAssertEqual(controller.coordinationRendererUpdateCount, before)
    }

    func testScaleChangesDebounceToOneAnalysisAndDoNotFullRefreshTable() async {
        let calls = Counter()
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        let scheduler = DebounceHarness()
        controller.coordinationDebounceScheduler = scheduler.schedule
        installProvider(on: controller, calls: calls)
        controller.showAtomTable()
        controller.state.coordinationEnabled = true
        await waitForReady(controller)

        let fullRefreshes = controller.coordinationFullTableRefreshCount
        let coordinationUpdates = controller.coordinationTableUpdateCount
        let analyses = calls.value
        controller.state.coordinationRadiusScale = 0.80
        controller.state.coordinationRadiusScale = 0.85
        controller.state.coordinationRadiusScale = 0.90

        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(calls.value, analyses)
        scheduler.fireNext()
        await waitForReady(controller)

        XCTAssertEqual(calls.value, analyses + 1)
        XCTAssertEqual(controller.coordinationFullTableRefreshCount, fullRefreshes)
        XCTAssertGreaterThan(controller.coordinationTableUpdateCount, coordinationUpdates)
    }

    func testEnableAndGeometryChangesLaunchWithoutDebounce() async {
        let calls = Counter()
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        let scheduler = DebounceHarness()
        controller.coordinationDebounceScheduler = scheduler.schedule
        installProvider(on: controller, calls: calls)

        controller.state.coordinationEnabled = true
        XCTAssertEqual(scheduler.pendingCount, 0)
        await waitForReady(controller)

        controller.loadFile(makeScene(atomCount: 3))
        XCTAssertEqual(scheduler.pendingCount, 0)
        await waitForReady(controller)
        XCTAssertGreaterThanOrEqual(calls.value, 2)
    }

    func testCancellationPredicateStopsSupersededWorkerWithoutUnavailableFlash() async {
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        let started = expectation(description: "analysis started")
        let stopped = expectation(description: "analysis stopped")
        let observedCancellation = Counter()
        controller.coordinationAnalyzerOverride = { _, _, _, _, isCancelled in
            started.fulfill()
            while !isCancelled() { usleep(1_000) }
            observedCancellation.increment()
            stopped.fulfill()
            return nil
        }

        controller.state.coordinationEnabled = true
        await fulfillment(of: [started], timeout: 3)
        controller.state.coordinationRadiusScale = 0.90
        XCTAssertEqual(controller.state.coordinationStatusText, "Calculating…")
        await fulfillment(of: [stopped], timeout: 3)

        XCTAssertEqual(observedCancellation.value, 1)
        XCTAssertFalse(controller.state.coordinationAnalysisAvailable)
        XCTAssertEqual(controller.state.coordinationStatusText, "Calculating…")
    }

    func testWindowCloseCancelsCoordinationWorkerAndPendingDebounce() async {
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        let started = expectation(description: "analysis started")
        let stopped = expectation(description: "analysis stopped")
        controller.coordinationAnalyzerOverride = { _, _, _, _, isCancelled in
            started.fulfill()
            while !isCancelled() { usleep(1_000) }
            stopped.fulfill()
            return nil
        }

        controller.state.coordinationEnabled = true
        await fulfillment(of: [started], timeout: 3)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification,
                                                 object: controller.window))
        await fulfillment(of: [stopped], timeout: 3)

        XCTAssertFalse(controller.state.coordinationAnalysisAvailable)
    }

    func testWindowCloseCancelsPendingScaleDebounce() async {
        let calls = Counter()
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        let scheduler = DebounceHarness()
        controller.coordinationDebounceScheduler = scheduler.schedule
        installProvider(on: controller, calls: calls)
        controller.state.coordinationEnabled = true
        await waitForReady(controller)

        controller.state.coordinationRadiusScale = 0.90
        XCTAssertEqual(scheduler.pendingCount, 1)
        let before = calls.value
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification,
                                                 object: controller.window))
        XCTAssertEqual(scheduler.pendingCount, 0)
        scheduler.fireNext()
        XCTAssertEqual(calls.value, before)
    }

    func testFailedNoncancelledAnalysisBecomesUnavailable() async {
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        let unavailable = expectation(description: "analysis unavailable")
        controller.coordinationAnalyzerOverride = { _, _, _, _, _ in
            unavailable.fulfill()
            return nil
        }

        controller.state.coordinationEnabled = true
        await fulfillment(of: [unavailable], timeout: 3)
        let status = expectation(description: "unavailable status installed")
        controller.coordinationAnalysisDidUpdate = {
            if controller.state.coordinationStatusText == "Unavailable" {
                status.fulfill()
            }
        }
        if controller.state.coordinationStatusText == "Unavailable" { status.fulfill() }
        await fulfillment(of: [status], timeout: 3)

        XCTAssertNil(controller.coordinationAnalysis)
        XCTAssertFalse(controller.state.coordinationAnalysisAvailable)
        XCTAssertEqual(controller.state.coordinationStatusText, "Unavailable")
    }

    func testGeometryAndAnalysisUpdatesDoNotRebuildFractionalTableData() async {
        let controller = MainWindowController(scene: makeScene(), showWindow: false)
        let scheduler = DebounceHarness()
        controller.coordinationDebounceScheduler = scheduler.schedule
        installProvider(on: controller, calls: Counter())
        controller.showAtomTable()
        controller.state.coordinationEnabled = true
        await waitForReady(controller)

        let fullRefreshes = controller.coordinationFullTableRefreshCount
        let coordinationUpdates = controller.coordinationTableUpdateCount
        controller.state.coordinationRadiusScale = 0.95
        XCTAssertEqual(controller.coordinationFullTableRefreshCount, fullRefreshes)
        scheduler.fireNext()
        await waitForReady(controller)
        XCTAssertEqual(controller.coordinationFullTableRefreshCount, fullRefreshes)
        XCTAssertGreaterThan(controller.coordinationTableUpdateCount, coordinationUpdates)
    }
}
