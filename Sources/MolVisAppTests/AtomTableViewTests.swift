import simd
import XCTest
@testable import MolVisApp

@MainActor
final class AtomTableViewTests: XCTestCase {

    private func makeView() -> AtomTableView {
        let view = AtomTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        return view
    }

    private func makeAtoms() -> [Atom] {
        [
            Atom(coord: SIMD3<Float>(0.0, 0.0, 0.0), atomicNumber: 14, label: "Si"),
            Atom(coord: SIMD3<Float>(1.3575, 1.3575, 0.0), atomicNumber: 14, label: "Si"),
            Atom(coord: SIMD3<Float>(2.0, 0.5, 0.5), atomicNumber: 8, label: "O"),
            Atom(coord: SIMD3<Float>(0.5, 2.0, 0.5), atomicNumber: 8, label: "O"),
            Atom(coord: SIMD3<Float>(0.1, 0.2, 0.3), atomicNumber: 26, label: "Fe"),
        ]
    }

    private func makeCell() -> Cell {
        Cell(a: SIMD3<Float>(5.43, 0, 0), b: SIMD3<Float>(0, 5.43, 0), c: SIMD3<Float>(0, 0, 5.43))
    }

    // MARK: - Row count and values

    func testRowCountMatchesAtomCount() {
        let view = makeView()
        let atoms = makeAtoms()
        view.update(atoms: atoms, cell: makeCell(), selectedAtoms: [])
        XCTAssertEqual(view.tableView.numberOfRows, 5)
    }

    func testIndexColumnIsOneBased() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        for row in 0..<5 {
            let value = view.value(atRow: row, columnIdentifier: AtomTableView.colIndex)
            XCTAssertEqual(value, "\(row + 1)")
        }
    }

    func testElementColumnShowsSymbolOrLabel() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        XCTAssertEqual(view.value(atRow: 0, columnIdentifier: AtomTableView.colElement), "Si")
        XCTAssertEqual(view.value(atRow: 2, columnIdentifier: AtomTableView.colElement), "O")
        XCTAssertEqual(view.value(atRow: 4, columnIdentifier: AtomTableView.colElement), "Fe")
    }

    func testCartesianColumnsFormatValues() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        XCTAssertEqual(view.value(atRow: 0, columnIdentifier: AtomTableView.colX), "0.000")
        XCTAssertEqual(view.value(atRow: 0, columnIdentifier: AtomTableView.colY), "0.000")
        XCTAssertEqual(view.value(atRow: 0, columnIdentifier: AtomTableView.colZ), "0.000")
        XCTAssertEqual(view.value(atRow: 1, columnIdentifier: AtomTableView.colX), "1.357")
        XCTAssertEqual(view.value(atRow: 4, columnIdentifier: AtomTableView.colX), "0.100")
    }

    // MARK: - Fractional coordinates

    func testValidFractionalValues() {
        let view = makeView()
        let cell = makeCell()
        view.update(atoms: makeAtoms(), cell: cell, selectedAtoms: [])
        // Atom 0 at (0,0,0) -> fractional (0,0,0)
        XCTAssertEqual(view.value(atRow: 0, columnIdentifier: AtomTableView.colA), "0.000")
        XCTAssertEqual(view.value(atRow: 0, columnIdentifier: AtomTableView.colB), "0.000")
        XCTAssertEqual(view.value(atRow: 0, columnIdentifier: AtomTableView.colC), "0.000")
        // Atom 1 at (1.3575, 1.3575, 0) in a 5.43-cell -> ~0.25
        let a = view.value(atRow: 1, columnIdentifier: AtomTableView.colA)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, "0.250")
    }

    func testUniformlyTinyWellConditionedCellProducesFractionalValues() {
        let view = makeView()
        let scale: Float = 1e-20
        let atoms = [Atom(coord: SIMD3<Float>(2 * scale, 3 * scale, 4 * scale),
                          atomicNumber: 1, label: "H")]
        let cell = Cell(a: SIMD3<Float>(scale, 0, 0),
                        b: SIMD3<Float>(0, scale, 0),
                        c: SIMD3<Float>(0, 0, scale))
        view.update(atoms: atoms, cell: cell, selectedAtoms: [])
        XCTAssertEqual(view.value(atRow: 0, columnIdentifier: AtomTableView.colA), "2.000")
        XCTAssertEqual(view.value(atRow: 0, columnIdentifier: AtomTableView.colB), "3.000")
        XCTAssertEqual(view.value(atRow: 0, columnIdentifier: AtomTableView.colC), "4.000")
    }

    func testScaledNearSingularCellBlanksFractionalValues() {
        let view = makeView()
        let scale: Float = 1e-10
        let cell = Cell(a: SIMD3<Float>(scale, 0, 0),
                        b: SIMD3<Float>(scale, scale * 1e-14, 0),
                        c: SIMD3<Float>(0, 0, scale))
        view.update(atoms: makeAtoms(), cell: cell, selectedAtoms: [])
        XCTAssertNil(view.value(atRow: 0, columnIdentifier: AtomTableView.colA))
        XCTAssertNil(view.value(atRow: 0, columnIdentifier: AtomTableView.colB))
        XCTAssertNil(view.value(atRow: 0, columnIdentifier: AtomTableView.colC))
    }

    func testSingularCellBlanksFractional() {
        let view = makeView()
        // Two collinear vectors => det == 0
        let singular = Cell(a: SIMD3<Float>(1, 0, 0), b: SIMD3<Float>(2, 0, 0), c: SIMD3<Float>(0, 0, 1))
        view.update(atoms: makeAtoms(), cell: singular, selectedAtoms: [])
        for row in 0..<5 {
            XCTAssertNil(view.value(atRow: row, columnIdentifier: AtomTableView.colA))
            XCTAssertNil(view.value(atRow: row, columnIdentifier: AtomTableView.colB))
            XCTAssertNil(view.value(atRow: row, columnIdentifier: AtomTableView.colC))
        }
    }

    func testNoCellBlanksFractional() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: nil, selectedAtoms: [])
        for row in 0..<5 {
            XCTAssertNil(view.value(atRow: row, columnIdentifier: AtomTableView.colA))
            XCTAssertNil(view.value(atRow: row, columnIdentifier: AtomTableView.colB))
            XCTAssertNil(view.value(atRow: row, columnIdentifier: AtomTableView.colC))
        }
    }

    // MARK: - Filtering

    func testFilterBySymbol() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        view.searchField.stringValue = "O"
        view.searchChanged(view.searchField)
        XCTAssertEqual(view.tableView.numberOfRows, 2)
        XCTAssertEqual(view.filteredAtomIndices, [2, 3])
        XCTAssertEqual(view.value(atRow: 0, columnIdentifier: AtomTableView.colElement), "O")
        XCTAssertEqual(view.value(atRow: 1, columnIdentifier: AtomTableView.colElement), "O")
    }

    func testFilterByLabel() {
        let view = makeView()
        var atoms = makeAtoms()
        atoms[0] = Atom(coord: atoms[0].coord, atomicNumber: 14, label: "Si_surface")
        view.update(atoms: atoms, cell: makeCell(), selectedAtoms: [])
        view.searchField.stringValue = "surface"
        view.searchChanged(view.searchField)
        XCTAssertEqual(view.tableView.numberOfRows, 1)
        XCTAssertEqual(view.filteredAtomIndices, [0])
    }

    func testFilterCaseInsensitive() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        view.searchField.stringValue = "si"
        view.searchChanged(view.searchField)
        XCTAssertEqual(view.tableView.numberOfRows, 2)
        XCTAssertEqual(view.filteredAtomIndices, [0, 1])
    }

    func testEmptyFilterShowsAll() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        view.searchField.stringValue = ""
        view.searchChanged(view.searchField)
        XCTAssertEqual(view.tableView.numberOfRows, 5)
        XCTAssertEqual(view.filteredAtomIndices, [0, 1, 2, 3, 4])
    }

    func testFilterPreservesOriginalIndexMapping() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        view.searchField.stringValue = "Fe"
        view.searchChanged(view.searchField)
        XCTAssertEqual(view.filteredAtomIndices, [4])
        XCTAssertEqual(view.value(atRow: 0, columnIdentifier: AtomTableView.colIndex), "5")
    }

    func testFilteringPreservesSelectionByOriginalIndexWithoutCallback() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [1, 3])
        var callbackCount = 0
        view.onSelectionChange = { _ in callbackCount += 1 }

        view.searchField.stringValue = "O"
        view.searchChanged(view.searchField)
        XCTAssertEqual(view.filteredAtomIndices, [2, 3])
        XCTAssertEqual(view.tableView.selectedRowIndexes, IndexSet([1]))

        view.searchField.stringValue = "Si"
        view.searchChanged(view.searchField)
        XCTAssertEqual(view.filteredAtomIndices, [0, 1])
        XCTAssertEqual(view.tableView.selectedRowIndexes, IndexSet([1]))

        view.searchField.stringValue = ""
        view.searchChanged(view.searchField)
        XCTAssertEqual(view.tableView.selectedRowIndexes, IndexSet([1, 3]))
        XCTAssertEqual(callbackCount, 0)
    }

    // MARK: - User selection callback

    func testUserSelectionCallbackMapsToOriginalIndices() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        var calledWith: [Int]?
        view.onSelectionChange = { indices in calledWith = indices }
        // Simulate user selecting rows 0, 2, 4 (atoms 0, 2, 4)
        view.tableView.selectRowIndexes(IndexSet([0, 2, 4]), byExtendingSelection: false)
        view.tableViewSelectionDidChange(Notification(name: .init("test")))
        XCTAssertEqual(calledWith, [0, 2, 4])
    }

    func testUserSelectionCallbackSortedUnique() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        var calledWith: [Int]?
        view.onSelectionChange = { indices in calledWith = indices }
        // Select in non-sorted order
        view.tableView.selectRowIndexes(IndexSet([4, 1, 3]), byExtendingSelection: false)
        view.tableViewSelectionDidChange(Notification(name: .init("test")))
        XCTAssertEqual(calledWith, [1, 3, 4])
    }

    func testUserSelectionCallbackWithFilter() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        view.searchField.stringValue = "O"
        view.searchChanged(view.searchField)
        var calledWith: [Int]?
        view.onSelectionChange = { indices in calledWith = indices }
        // Select row 1 in filtered view -> original index 3
        view.tableView.selectRowIndexes(IndexSet([1]), byExtendingSelection: false)
        view.tableViewSelectionDidChange(Notification(name: .init("test")))
        XCTAssertEqual(calledWith, [3])
    }

    func testFilteredSelectionPreservesHiddenCanonicalIndices() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [0])
        view.searchField.stringValue = "O"
        view.searchChanged(view.searchField)
        var calledWith: [[Int]] = []
        view.onSelectionChange = { calledWith.append($0) }

        // Select visible atom 2 while hidden atom 0 remains selected.
        view.tableView.selectRowIndexes(IndexSet([0]), byExtendingSelection: false)
        view.tableViewSelectionDidChange(Notification(name: .init("test")))

        XCTAssertEqual(calledWith, [[0, 2]])
        view.searchField.stringValue = ""
        view.searchChanged(view.searchField)
        XCTAssertEqual(view.tableView.selectedRowIndexes, IndexSet([0, 2]))
    }

    func testFilteredDeselectionPreservesHiddenCanonicalIndices() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [0, 2, 3])
        view.searchField.stringValue = "O"
        view.searchChanged(view.searchField)
        var calledWith: [[Int]] = []
        view.onSelectionChange = { calledWith.append($0) }

        // Deselect visible atom 2; hidden atom 0 and visible atom 3 remain selected.
        view.tableView.selectRowIndexes(IndexSet([1]), byExtendingSelection: false)
        view.tableViewSelectionDidChange(Notification(name: .init("test")))

        XCTAssertEqual(calledWith, [[0, 3]])
        view.searchField.stringValue = ""
        view.searchChanged(view.searchField)
        XCTAssertEqual(view.tableView.selectedRowIndexes, IndexSet([0, 3]))
    }

    func testFilteredSelectionChangesDoNotCallbackWhenCanonicalSelectionIsUnchanged() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [0, 2])
        view.searchField.stringValue = "O"
        view.searchChanged(view.searchField)
        var callbackCount = 0
        view.onSelectionChange = { _ in callbackCount += 1 }

        // The table has the same visible selection it already had after filtering.
        view.tableViewSelectionDidChange(Notification(name: .init("test")))
        XCTAssertEqual(callbackCount, 0)

        view.searchField.stringValue = ""
        view.searchChanged(view.searchField)
        XCTAssertEqual(callbackCount, 0)
    }

    func testFilteredSelectionIgnoresStaleRowsAndIndices() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [0, 3, 99, -1])
        view.searchField.stringValue = "O"
        view.searchChanged(view.searchField)
        var calledWith: [Int]?
        view.onSelectionChange = { calledWith = $0 }

        // Row 99 is stale; hidden atom 0 and visible atom 3 remain valid.
        view.tableView.selectRowIndexes(IndexSet([1, 99]), byExtendingSelection: false)
        view.tableViewSelectionDidChange(Notification(name: .init("test")))

        XCTAssertEqual(calledWith, nil)
        view.searchField.stringValue = ""
        view.searchChanged(view.searchField)
        XCTAssertEqual(view.tableView.selectedRowIndexes, IndexSet([0, 3]))
    }

    func testSelectionCallbackIgnoresStaleSelectedRows() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        var calledWith: [Int]?
        view.onSelectionChange = { indices in calledWith = indices }
        view.tableView.selectRowIndexes(IndexSet([0]), byExtendingSelection: false)
        view.tableView.selectRowIndexes(IndexSet([99]), byExtendingSelection: true)
        view.tableViewSelectionDidChange(Notification(name: .init("test")))
        XCTAssertEqual(calledWith, [0])
    }

    // MARK: - Programmatic selection

    func testProgrammaticSelectionDoesNotRecurse() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        var callCount = 0
        view.onSelectionChange = { _ in callCount += 1 }
        view.setSelectedAtomIndices([1, 3])
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(view.tableView.selectedRowIndexes, IndexSet([1, 3]))
    }

    func testProgrammaticSelectionIgnoresStaleIndices() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        view.setSelectedAtomIndices([0, 99, 2, -1])
        XCTAssertEqual(view.tableView.selectedRowIndexes, IndexSet([0, 2]))
    }

    func testProgrammaticSelectionWithFilterIgnoresHidden() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        view.searchField.stringValue = "O"
        view.searchChanged(view.searchField)
        // Try to select atom 0 (Si, hidden) and atom 2 (O, visible)
        view.setSelectedAtomIndices([0, 2])
        // Only row 0 (atom 2) should be selected
        XCTAssertEqual(view.tableView.selectedRowIndexes, IndexSet([0]))
    }

    func testLargeTableSelectionUsesOriginalIndexMapping() {
        let view = makeView()
        let count = 500_000
        let atoms = (0..<count).map {
            Atom(coord: SIMD3<Float>(Float($0), 0, 0), atomicNumber: 1, label: "H")
        }
        view.update(atoms: atoms, cell: nil, selectedAtoms: [])
        view.setSelectedAtomIndices([count - 1, count / 2, 0, count - 1])
        XCTAssertEqual(view.tableView.selectedRowIndexes,
                       IndexSet([0, count / 2, count - 1]))
    }

    // MARK: - Empty table

    func testEmptyTable() {
        let view = makeView()
        view.update(atoms: [], cell: nil, selectedAtoms: [])
        XCTAssertEqual(view.tableView.numberOfRows, 0)
        XCTAssertEqual(view.filteredAtomIndices, [])
        XCTAssertNil(view.value(atRow: 0, columnIdentifier: AtomTableView.colIndex))
    }

    func testEmptyTableWithFilter() {
        let view = makeView()
        view.update(atoms: [], cell: nil, selectedAtoms: [])
        view.searchField.stringValue = "Si"
        view.searchChanged(view.searchField)
        XCTAssertEqual(view.tableView.numberOfRows, 0)
    }

    // MARK: - Non-finite values

    func testNonFiniteValuesBlanked() {
        let view = makeView()
        let atoms = [Atom(coord: SIMD3<Float>(Float.nan, Float.infinity, -Float.infinity), atomicNumber: 1, label: "H")]
        view.update(atoms: atoms, cell: makeCell(), selectedAtoms: [])
        XCTAssertNil(view.value(atRow: 0, columnIdentifier: AtomTableView.colX))
        XCTAssertNil(view.value(atRow: 0, columnIdentifier: AtomTableView.colY))
        XCTAssertNil(view.value(atRow: 0, columnIdentifier: AtomTableView.colZ))
    }

    // MARK: - Data source objectValueFor

    func testObjectValueForValue() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        let colX = view.tableView.tableColumns.first { $0.identifier == AtomTableView.colX }!
        let value = view.tableView(view.tableView, objectValueFor: colX, row: 4) as? String
        XCTAssertEqual(value, "0.100")
    }

    // MARK: - Update preserves search text

    func testUpdatePreservesSearchText() {
        let view = makeView()
        view.update(atoms: makeAtoms(), cell: makeCell(), selectedAtoms: [])
        view.searchField.stringValue = "O"
        view.searchChanged(view.searchField)
        XCTAssertEqual(view.tableView.numberOfRows, 2)
        // Update with new atoms but same filter should still apply
        let newAtoms = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 8, label: "O"),
            Atom(coord: SIMD3(1, 1, 1), atomicNumber: 14, label: "Si"),
        ]
        view.update(atoms: newAtoms, cell: makeCell(), selectedAtoms: [])
        XCTAssertEqual(view.searchField.stringValue, "O")
        XCTAssertEqual(view.tableView.numberOfRows, 1)
        XCTAssertEqual(view.filteredAtomIndices, [0])
    }
}
