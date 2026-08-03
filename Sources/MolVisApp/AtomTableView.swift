import Foundation
import simd
import AppKit
import AudioToolbox

/// Result of attempting to commit an atom-coordinate edit from the table.
/// The controller returns this to the table so the table can update its
/// display or reject the edit without retaining a copy of the scene.
enum EditCommitResult: Equatable {
    /// The edit was valid and applied. The controller has already updated the
    /// scene and run the invalidation lifecycle; the table should refresh the
    /// affected row from its (now current) `atoms` snapshot.
    case accepted
    /// The edit was rejected: the value was non-finite, the cell was singular
    /// for a fractional edit, or the geometry was not editable (supercell/slab
    /// active). The table beeps and keeps the previous value.
    case rejected(reason: String)
}

/// A standalone virtualized atom table: an NSSearchField above a scrolling
/// NSTableView showing one row per (filtered) atom. Data-source backed —
/// never builds one view per atom, so it scales to 500k+ rows.
///
/// Columns (stable identifiers): index, element, coordination, x, y, z, a, b, c.
/// The a/b/c columns show fractional coordinates when a valid finite
/// nonsingular cell is supplied, else blank.
final class AtomTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    let searchField: NSSearchField
    let tableView: NSTableView
    var onSelectionChange: (([Int]) -> Void)?
    /// Invoked when the user commits an edit to a coordinate cell. The row is
    /// the currently-filtered row, the column identifies x/y/z or a/b/c, and
    /// `value` is the raw text from the field editor. The controller validates
    /// and applies the edit transactionally; the result tells the table whether
    /// to accept (refresh) or reject (beep + keep old value).
    var onCommitEdit: ((Int, NSUserInterfaceItemIdentifier, String) -> EditCommitResult)?
    /// When false, coordinate cells are shown but editing is disabled. Set by
    /// the controller when the displayed geometry is not pristine (supercell
    /// or slab active) so edits cannot corrupt base/preslab invariants.
    var isEditingEnabled: Bool = true
    /// Human-readable reason why editing is disabled, shown as a tooltip on
    /// the coordinate columns. nil when editing is enabled.
    var editingDisabledReason: String?
    /// The reason the most recent commit was rejected. Surfaced as the
    /// table's accessibility description so invalid input is communicated
    /// beyond a beep. Cleared on the next successful edit or table update.
    var lastRejectionReason: String?
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
    /// Coordination values are available only when analysis produced one
    /// value for every atom.
    private var coordinationNumbers: [Int]?

    // Internal counters keep coordination-only updates testable without timing.
    internal private(set) var fractionalConversionCount = 0
    internal private(set) var filterRebuildCount = 0

    /// Guards programmatic selection so it never recurses through onSelectionChange.
    private var isProgrammaticSelection = false

    // MARK: - Column identifiers

    static let colIndex = NSUserInterfaceItemIdentifier("index")
    static let colElement = NSUserInterfaceItemIdentifier("element")
    static let colCoordination = NSUserInterfaceItemIdentifier("coordination")
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
        searchField.placeholderString = "Element/label terms; cn:N, cn:>=N, cn:<=N"

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
            (Self.colCoordination, "CN", CGFloat(48)),
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
            // Coordinate columns (x/y/z, a/b/c) are editable; the rest are not.
            switch id {
            case Self.colX, Self.colY, Self.colZ, Self.colA, Self.colB, Self.colC:
                col.isEditable = true
            default:
                col.isEditable = false
            }
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
    func update(atoms: [Atom], cell: Cell?, selectedAtoms: [Int],
                coordinationNumbers: [Int]? = nil) {
        self.atoms = atoms
        self.cell = cell
        self.fractionalCoords = atoms.map { cartesianToFractional($0.coord) }
        selectedOriginalAtomIndices = normalizedOriginalIndices(selectedAtoms)
        lastRejectionReason = nil
        updateCoordinationNumbers(coordinationNumbers, rebuildFilterWhenNoCoordinationTerm: true)
    }

    /// Updates only coordination data. Atom-derived values and mappings are
    /// retained unless the current query depends on coordination numbers.
    func updateCoordinationNumbers(_ numbers: [Int]?) {
        updateCoordinationNumbers(numbers, rebuildFilterWhenNoCoordinationTerm: false)
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
        case Self.colCoordination:
            guard let coordinationNumbers, orig < coordinationNumbers.count else { return nil }
            return String(coordinationNumbers[orig])
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

    private struct FilterQuery {
        let textTerms: [String]
        let coordinationFilters: [CoordinationFilter]
        let hasInvalidCoordinationTerm: Bool

        var containsCoordinationTerm: Bool {
            hasInvalidCoordinationTerm || !coordinationFilters.isEmpty
        }
    }

    private func currentFilterQuery() -> FilterQuery {
        let terms = searchField.stringValue.split(whereSeparator: { $0.isWhitespace })
        var textTerms: [String] = []
        var coordinationFilters: [CoordinationFilter] = []
        var hasInvalidCoordinationTerm = false
        for rawTerm in terms {
            let term = String(rawTerm)
            if term.lowercased().hasPrefix("cn:") {
                guard let filter = parseCoordinationFilter(String(term.dropFirst(3))) else {
                    hasInvalidCoordinationTerm = true
                    continue
                }
                coordinationFilters.append(filter)
            } else {
                textTerms.append(term.lowercased())
            }
        }

        return FilterQuery(textTerms: textTerms,
                           coordinationFilters: coordinationFilters,
                           hasInvalidCoordinationTerm: hasInvalidCoordinationTerm)
    }

    private func applyFilter(_ query: FilterQuery) {
        filterRebuildCount += 1

        var indices: [Int] = []
        var rowsByOriginalIndex: [Int: Int] = [:]
        if query.textTerms.isEmpty && query.coordinationFilters.isEmpty
            && !query.hasInvalidCoordinationTerm {
            indices.reserveCapacity(atoms.count)
            rowsByOriginalIndex.reserveCapacity(atoms.count)
        }

        for (originalIndex, atom) in atoms.enumerated() {
            let symbol = ElementTable.symbol(atom.atomicNumber).lowercased()
            let label = atom.label.lowercased()
            let matches = !query.hasInvalidCoordinationTerm &&
                query.textTerms.allSatisfy { symbol.contains($0) || label.contains($0) } &&
                query.coordinationFilters.allSatisfy { filter in
                    guard let coordinationNumbers,
                          originalIndex < coordinationNumbers.count else { return false }
                    return filter.matches(coordinationNumbers[originalIndex])
                }
            if matches {
                rowsByOriginalIndex[originalIndex] = indices.count
                indices.append(originalIndex)
            }
        }
        filteredAtomIndices = indices
        filteredRowByOriginalIndex = rowsByOriginalIndex
    }

    private func updateCoordinationNumbers(_ numbers: [Int]?,
                                           rebuildFilterWhenNoCoordinationTerm: Bool) {
        coordinationNumbers = numbers?.count == atoms.count ? numbers : nil
        let query = currentFilterQuery()
        if rebuildFilterWhenNoCoordinationTerm || query.containsCoordinationTerm {
            rebuildFilterPreservingSelection(using: query)
        } else {
            reloadCoordinationColumn()
        }
    }

    private enum CoordinationFilter {
        case equal(Int)
        case atLeast(Int)
        case atMost(Int)

        func matches(_ value: Int) -> Bool {
            switch self {
            case .equal(let expected): value == expected
            case .atLeast(let minimum): value >= minimum
            case .atMost(let maximum): value <= maximum
            }
        }
    }

    private func parseCoordinationFilter(_ expression: String) -> CoordinationFilter? {
        let operation: (Int) -> CoordinationFilter
        let numberText: String
        if expression.hasPrefix(">=") {
            operation = CoordinationFilter.atLeast
            numberText = String(expression.dropFirst(2))
        } else if expression.hasPrefix("<=") {
            operation = CoordinationFilter.atMost
            numberText = String(expression.dropFirst(2))
        } else {
            operation = CoordinationFilter.equal
            numberText = expression
        }

        guard !numberText.isEmpty,
              numberText.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let number = Int(numberText) else { return nil }
        return operation(number)
    }

    private func rebuildFilterPreservingSelection() {
        rebuildFilterPreservingSelection(using: currentFilterQuery())
    }

    private func rebuildFilterPreservingSelection(using query: FilterQuery) {
        isProgrammaticSelection = true
        applyFilter(query)
        tableView.reloadData()
        tableView.selectRowIndexes(filteredRows(for: selectedOriginalAtomIndices),
                                   byExtendingSelection: false)
        isProgrammaticSelection = false
        revealSelectedRows()
    }

    private func reloadCoordinationColumn() {
        guard let column = tableView.tableColumns.firstIndex(where: {
            $0.identifier == Self.colCoordination
        }) else { return }

        let wasProgrammaticSelection = isProgrammaticSelection
        isProgrammaticSelection = true
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<filteredAtomIndices.count),
                             columnIndexes: IndexSet(integer: column))
        isProgrammaticSelection = wasProgrammaticSelection
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

    /// Commit an edited coordinate value. Routes the edit through the
    /// controller's `onCommitEdit` callback for transactional validation and
    /// application; never mutates the table's private `atoms` snapshot.
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?,
                   for tableColumn: NSTableColumn?, row: Int) {
        // Only coordinate columns are editable; ignore anything else defensively.
        guard let id = tableColumn?.identifier, isCoordinateColumn(id) else { return }
        guard row >= 0, row < filteredAtomIndices.count else { return }

        let text = (object as? String) ?? ""
        let result = onCommitEdit?(row, id, text) ?? .rejected(reason: "")
        switch result {
        case .accepted:
            // The controller has updated the scene and will refresh the table
            // through the normal `update(atoms:...)` path. No local mutation.
            lastRejectionReason = nil
            tableView.setAccessibilityHelp(nil)
            tableView.toolTip = editingDisabledReason
        case .rejected(let reason):
            // Beep, reload the rejected cell so the canonical value is redrawn
            // (the field editor's text is stale), and expose the reason for
            // accessibility/tooltip.
            AudioServicesPlaySystemSound(1104)
            if let col = tableView.tableColumns.firstIndex(where: { $0.identifier == id }) {
                tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                                     columnIndexes: IndexSet(integer: col))
            }
            // Surface the rejection reason for accessibility and pointer users.
            lastRejectionReason = reason
            tableView.setAccessibilityHelp(reason)
            tableView.toolTip = reason
        }
    }

    /// Gate editing on a per-column basis: only coordinate cells are editable,
    /// and only while `isEditingEnabled` is true (pristine geometry). When
    /// editing is disabled, the delegate returns false so the field editor
    /// never appears and the cell stays read-only.
    func tableView(_ tableView: NSTableView,
                   shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        guard let id = tableColumn?.identifier else { return false }
        guard isCoordinateColumn(id) else { return false }
        return isEditingEnabled
    }

    // MARK: - Math helpers

    /// Cramer's rule on the [a b c] system. Returns nil for a missing/singular
    /// cell or a non-finite result.
    private func cartesianToFractional(_ p: SIMD3<Float>) -> SIMD3<Float>? {
        fractionalConversionCount += 1
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

    /// True for the six coordinate columns (Cartesian x/y/z and fractional
    /// a/b/c). These are the only cells the user can edit.
    private func isCoordinateColumn(_ id: NSUserInterfaceItemIdentifier) -> Bool {
        switch id {
        case Self.colX, Self.colY, Self.colZ, Self.colA, Self.colB, Self.colC:
            return true
        default:
            return false
        }
    }
}
