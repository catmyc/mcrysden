import Foundation
import simd
import AppKit

/// A standalone virtualized atom table: an NSSearchField above a scrolling
/// NSTableView showing one row per (filtered) atom. Data-source backed —
/// never builds one view per atom, so it scales to 500k+ rows.
///
/// Columns (stable identifiers): index, element, x, y, z, a, b, c.
/// The a/b/c columns show fractional coordinates when a valid finite
/// nonsingular cell is supplied, else blank.
final class AtomTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    let searchField: NSSearchField
    let tableView: NSTableView
    var onSelectionChange: (([Int]) -> Void)?
    private(set) var filteredAtomIndices: [Int] = []

    private let scrollView: NSScrollView

    private var atoms: [Atom] = []
    private var cell: Cell?
    /// Selection is stored in the source atom index space, not the current
    /// filtered row space. Hidden selected atoms therefore survive filtering.
    private var selectedOriginalAtomIndices: [Int] = []
    private var filteredRowByOriginalIndex: [Int: Int] = [:]
    /// Parallel to `atoms`: fractional coordinate per atom, or nil when the
    /// cell is missing/singular or the conversion is non-finite.
    private var fractionalCoords: [SIMD3<Float>?] = []

    /// Guards programmatic selection so it never recurses through onSelectionChange.
    private var isProgrammaticSelection = false

    // MARK: - Column identifiers

    static let colIndex = NSUserInterfaceItemIdentifier("index")
    static let colElement = NSUserInterfaceItemIdentifier("element")
    static let colX = NSUserInterfaceItemIdentifier("x")
    static let colY = NSUserInterfaceItemIdentifier("y")
    static let colZ = NSUserInterfaceItemIdentifier("z")
    static let colA = NSUserInterfaceItemIdentifier("a")
    static let colB = NSUserInterfaceItemIdentifier("b")
    static let colC = NSUserInterfaceItemIdentifier("c")

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        searchField = NSSearchField()
        scrollView = NSScrollView()
        tableView = NSTableView()
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        searchField = NSSearchField()
        scrollView = NSScrollView()
        tableView = NSTableView()
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        addSubview(searchField)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        for (id, title, width) in [
            (Self.colIndex, "#", CGFloat(44)),
            (Self.colElement, "Element", CGFloat(64)),
            (Self.colX, "x", CGFloat(84)),
            (Self.colY, "y", CGFloat(84)),
            (Self.colZ, "z", CGFloat(84)),
            (Self.colA, "a", CGFloat(84)),
            (Self.colB, "b", CGFloat(84)),
            (Self.colC, "c", CGFloat(84)),
        ] {
            let col = NSTableColumn(identifier: id)
            col.title = title
            col.width = width
            col.minWidth = 40
            tableView.addTableColumn(col)
        }

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
    }

    // MARK: - Public API

    /// Refreshes atoms/cell/filter mapping and selection safely. Preserves the
    /// current search text. Handles empty and 500k-scale inputs.
    func update(atoms: [Atom], cell: Cell?, selectedAtoms: [Int]) {
        self.atoms = atoms
        self.cell = cell
        self.fractionalCoords = atoms.map { cartesianToFractional($0.coord) }
        selectedOriginalAtomIndices = normalizedOriginalIndices(selectedAtoms)
        rebuildFilterPreservingSelection()
    }

    /// Selects rows by original atom index. Never invokes onSelectionChange.
    /// Invalid original indices and currently hidden rows are ignored for the
    /// table selection. Hidden but valid indices remain selected canonically.
    func setSelectedAtomIndices(_ indices: [Int]) {
        selectedOriginalAtomIndices = normalizedOriginalIndices(indices)
        applySelectedRows()
    }

    /// Returns the formatted string for the given filtered row and column, or
    /// nil for out-of-range rows or non-finite values.
    func value(atRow row: Int, columnIdentifier: NSUserInterfaceItemIdentifier) -> String? {
        guard row >= 0, row < filteredAtomIndices.count else { return nil }
        let orig = filteredAtomIndices[row]
        guard orig >= 0, orig < atoms.count else { return nil }
        let atom = atoms[orig]
        switch columnIdentifier {
        case Self.colIndex:
            return "\(orig + 1)"
        case Self.colElement:
            return atom.label.isEmpty ? ElementTable.symbol(atom.atomicNumber) : atom.label
        case Self.colX:
            return formatFloat(atom.coord.x)
        case Self.colY:
            return formatFloat(atom.coord.y)
        case Self.colZ:
            return formatFloat(atom.coord.z)
        case Self.colA:
            return orig < fractionalCoords.count ? fractionalCoords[orig].flatMap { formatFloat($0.x) } : nil
        case Self.colB:
            return orig < fractionalCoords.count ? fractionalCoords[orig].flatMap { formatFloat($0.y) } : nil
        case Self.colC:
            return orig < fractionalCoords.count ? fractionalCoords[orig].flatMap { formatFloat($0.z) } : nil
        default:
            return nil
        }
    }

    // MARK: - Filtering

    @objc func searchChanged(_ sender: NSSearchField) {
        rebuildFilterPreservingSelection()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let lower = query.lowercased()
        var indices: [Int] = []
        var rowsByOriginalIndex: [Int: Int] = [:]
        if query.isEmpty {
            indices.reserveCapacity(atoms.count)
            rowsByOriginalIndex.reserveCapacity(atoms.count)
        }

        for (originalIndex, atom) in atoms.enumerated() {
            let matches = query.isEmpty ||
                ElementTable.symbol(atom.atomicNumber).lowercased().contains(lower) ||
                atom.label.lowercased().contains(lower)
            if matches {
                rowsByOriginalIndex[originalIndex] = indices.count
                indices.append(originalIndex)
            }
        }
        filteredAtomIndices = indices
        filteredRowByOriginalIndex = rowsByOriginalIndex
    }

    private func rebuildFilterPreservingSelection() {
        isProgrammaticSelection = true
        applyFilter()
        tableView.reloadData()
        tableView.selectRowIndexes(filteredRows(for: selectedOriginalAtomIndices),
                                   byExtendingSelection: false)
        isProgrammaticSelection = false
        revealSelectedRows()
    }

    private func normalizedOriginalIndices(_ indices: [Int]) -> [Int] {
        Set(indices.filter { $0 >= 0 && $0 < atoms.count }).sorted()
    }

    private func filteredRows(for originalIndices: [Int]) -> IndexSet {
        var rows = IndexSet()
        for originalIndex in originalIndices {
            if let row = filteredRowByOriginalIndex[originalIndex] {
                rows.insert(row)
            }
        }
        return rows
    }

    private func applySelectedRows() {
        isProgrammaticSelection = true
        tableView.selectRowIndexes(filteredRows(for: selectedOriginalAtomIndices),
                                   byExtendingSelection: false)
        isProgrammaticSelection = false
        revealSelectedRows()
    }

    // MARK: - Selection plumbing

    private func revealSelectedRows() {
        let rows = tableView.selectedRowIndexes
        if let first = rows.min() {
            tableView.scrollRowToVisible(first)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        let visibleSelectedIndices = tableView.selectedRowIndexes.compactMap { row -> Int? in
            guard row >= 0, row < filteredAtomIndices.count else { return nil }
            return filteredAtomIndices[row]
        }
        let hiddenSelectedIndices = selectedOriginalAtomIndices.filter {
            filteredRowByOriginalIndex[$0] == nil
        }
        let indices = normalizedOriginalIndices(hiddenSelectedIndices + visibleSelectedIndices)
        guard indices != selectedOriginalAtomIndices else { return }
        selectedOriginalAtomIndices = indices
        onSelectionChange?(selectedOriginalAtomIndices)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredAtomIndices.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let id = tableColumn?.identifier else { return nil }
        return value(atRow: row, columnIdentifier: id)
    }

    // MARK: - Math helpers

    /// Cramer's rule on the [a b c] system. Returns nil for a missing/singular
    /// cell or a non-finite result.
    private func cartesianToFractional(_ p: SIMD3<Float>) -> SIMD3<Float>? {
        guard let cell else { return nil }
        let a = SIMD3<Double>(Double(cell.a.x), Double(cell.a.y), Double(cell.a.z))
        let b = SIMD3<Double>(Double(cell.b.x), Double(cell.b.y), Double(cell.b.z))
        let c = SIMD3<Double>(Double(cell.c.x), Double(cell.c.y), Double(cell.c.z))
        let point = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
        guard a.x.isFinite, a.y.isFinite, a.z.isFinite,
              b.x.isFinite, b.y.isFinite, b.z.isFinite,
              c.x.isFinite, c.y.isFinite, c.z.isFinite,
              point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }

        func length(_ v: SIMD3<Double>) -> Double {
            sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        }

        let scale = length(a) * length(b) * length(c)
        guard scale.isFinite, scale > 0 else { return nil }

        func determinant(_ first: SIMD3<Double>, _ second: SIMD3<Double>,
                         _ third: SIMD3<Double>) -> Double {
            first.x * (second.y * third.z - third.y * second.z)
                - second.x * (first.y * third.z - third.y * first.z)
                + third.x * (first.y * second.z - second.y * first.z)
        }

        let det = determinant(a, b, c)
        let relativeDeterminant = abs(det) / scale
        guard det.isFinite, relativeDeterminant.isFinite,
              relativeDeterminant > 1e-12 else { return nil }

        func det1(_ col: SIMD3<Double>) -> Double {
            determinant(col, b, c)
        }
        func det2(_ col: SIMD3<Double>) -> Double {
            determinant(a, col, c)
        }
        func det3(_ col: SIMD3<Double>) -> Double {
            determinant(a, b, col)
        }

        let fractional = SIMD3<Double>(det1(point) / det,
                                       det2(point) / det,
                                       det3(point) / det)
        guard fractional.x.isFinite, fractional.y.isFinite, fractional.z.isFinite else {
            return nil
        }
        let result = SIMD3<Float>(Float(fractional.x), Float(fractional.y), Float(fractional.z))
        guard result.x.isFinite, result.y.isFinite, result.z.isFinite else { return nil }
        return result
    }

    /// Stable, readable numeric string. Returns nil for non-finite values so
    /// the cell blanks rather than showing nan/inf.
    private func formatFloat(_ v: Float) -> String? {
        guard v.isFinite else { return nil }
        return String(format: "%.3f", v)
    }
}
