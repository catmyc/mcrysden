import Foundation
import simd
import AppKit

/// Sort keys for the neighbor table.
enum NeighborTableSortKey: CaseIterable {
    case distance
    case sourceIndex
    case targetIndex
    case imageX
    case imageY
    case imageZ

    var label: String {
        switch self {
        case .distance: return "Distance"
        case .sourceIndex: return "Source"
        case .targetIndex: return "Target"
        case .imageX: return "ix"
        case .imageY: return "iy"
        case .imageZ: return "iz"
        }
    }

    /// The key string used in NSSortDescriptor and table column identifiers.
    var descriptorKey: String {
        switch self {
        case .distance: return "dist"
        case .sourceIndex: return "srcIdx"
        case .targetIndex: return "tgtIdx"
        case .imageX: return "ix"
        case .imageY: return "iy"
        case .imageZ: return "iz"
        }
    }

    init?(descriptorKey: String) {
        switch descriptorKey {
        case "dist": self = .distance
        case "srcIdx": self = .sourceIndex
        case "tgtIdx": self = .targetIndex
        case "ix": self = .imageX
        case "iy": self = .imageY
        case "iz": self = .imageZ
        default: return nil
        }
    }
}

/// A flat index into the coordination analysis neighbor records.
struct NeighborTableEntry {
    let offset: Int
    let sourceIndex: Int
}

/// A virtualized neighbor table: an NSSearchField above a scrolling NSTableView
/// showing one row per directed neighbor record. Data-source backed — never
/// builds one view per row.
///
/// The table holds a flat index array into the CoordinationAnalysis rather than
/// duplicating records. A practical display cap keeps the index array bounded;
/// the total and omitted counts are reported via `rawTotalCount` and
/// `omittedCount`. A compact status field shows displayed/total and omitted.
final class NeighborTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    /// Maximum number of entries retained from the analysis.
    static let displayCap = 100_000

    let searchField: NSSearchField
    let tableView: NSTableView
    let statusField: NSTextField
    private let scrollView: NSScrollView

    private var atoms: [Atom] = []
    private var entries: [NeighborTableEntry] = []
    private var displayIndices: [Int] = []
    /// Raw total number of directed neighbor records in the analysis.
    private var rawTotalCount = 0

    private var sortKey: NeighborTableSortKey = .distance
    private var sortAscending = true
    private var filterSourceIndex: Int?
    private var filterTargetElement: String?
    private var filterMinDistance: Float?
    private var filterMaxDistance: Float?

    private var resolvedAnalysis: CoordinationAnalysis?

    internal private(set) var filterRebuildCount = 0

    private var isProgrammaticSelection = false

    // MARK: - Column identifiers

    static let colSourceIndex = NSUserInterfaceItemIdentifier("srcIdx")
    static let colSourceElement = NSUserInterfaceItemIdentifier("srcElem")
    static let colTargetIndex = NSUserInterfaceItemIdentifier("tgtIdx")
    static let colTargetElement = NSUserInterfaceItemIdentifier("tgtElem")
    static let colImageX = NSUserInterfaceItemIdentifier("ix")
    static let colImageY = NSUserInterfaceItemIdentifier("iy")
    static let colImageZ = NSUserInterfaceItemIdentifier("iz")
    static let colDX = NSUserInterfaceItemIdentifier("dx")
    static let colDY = NSUserInterfaceItemIdentifier("dy")
    static let colDZ = NSUserInterfaceItemIdentifier("dz")
    static let colDistance = NSUserInterfaceItemIdentifier("dist")

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        searchField = NSSearchField()
        scrollView = NSScrollView()
        tableView = NSTableView()
        statusField = NSTextField(labelWithString: "")
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        searchField = NSSearchField()
        scrollView = NSScrollView()
        tableView = NSTableView()
        statusField = NSTextField(labelWithString: "")
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = NSFont.systemFont(ofSize: 11)
        statusField.textColor = NSColor.secondaryLabelColor
        searchField.placeholderString = "src:N, elem:X, d>0.5, d<3.0"

        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        addSubview(searchField)
        addSubview(statusField)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusField.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 2),
            statusField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            statusField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: statusField.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        for (id, title, sortKey, width) in [
            (Self.colSourceIndex, "Src#", NeighborTableSortKey.sourceIndex, CGFloat(44)),
            (Self.colSourceElement, "Src", nil, CGFloat(48)),
            (Self.colTargetIndex, "Tgt#", NeighborTableSortKey.targetIndex, CGFloat(44)),
            (Self.colTargetElement, "Tgt", nil, CGFloat(48)),
            (Self.colImageX, "ix", NeighborTableSortKey.imageX, CGFloat(36)),
            (Self.colImageY, "iy", NeighborTableSortKey.imageY, CGFloat(36)),
            (Self.colImageZ, "iz", NeighborTableSortKey.imageZ, CGFloat(36)),
            (Self.colDX, "dx", nil, CGFloat(64)),
            (Self.colDY, "dy", nil, CGFloat(64)),
            (Self.colDZ, "dz", nil, CGFloat(64)),
            (Self.colDistance, "d (Å)", NeighborTableSortKey.distance, CGFloat(72)),
        ] {
            let col = NSTableColumn(identifier: id)
            col.title = title
            col.width = width
            col.minWidth = 36
            if let sk = sortKey {
                col.sortDescriptorPrototype = NSSortDescriptor(key: sk.descriptorKey, ascending: true)
            }
            tableView.addTableColumn(col)
        }

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView

        // Start sorted by distance ascending.
        tableView.sortDescriptors = [NSSortDescriptor(key: NeighborTableSortKey.distance.descriptorKey, ascending: true)]

        updateStatus()
    }

    // MARK: - Public API

    /// Raw total number of directed neighbor records in the analysis.
    var recordCount: Int { rawTotalCount }

    /// Number of records omitted by the display cap.
    var omittedCount: Int { max(0, rawTotalCount - entries.count) }

    /// Whether the display was truncated by the cap.
    var isTruncated: Bool { rawTotalCount > entries.count }

    /// Rebuild the table from a coordination analysis. Caps entries at
    /// displayCap during construction to bound memory. Self-contained: sets
    /// the analysis reference and rebuilds the filter/sort/status.
    func update(analysis: CoordinationAnalysis, atoms: [Atom]) {
        self.atoms = atoms
        self.resolvedAnalysis = analysis
        self.entries = Self.buildEntries(from: analysis, atoms: atoms, cap: Self.displayCap)
        self.rawTotalCount = analysis.neighbors.count
        rebuildFilterAndSort()
    }

    /// Update the filter from the search field text.
    @objc func searchChanged(_ sender: NSSearchField) {
        parseFilter(from: searchField.stringValue)
        rebuildFilterAndSort()
    }

    // MARK: - Entry construction

    /// Build flat entries from the analysis, resolving source indices from the
    /// offsets array. Validates every index against the atom array bounds.
    /// Stops after `cap` valid entries to bound memory.
    static func buildEntries(from analysis: CoordinationAnalysis, atoms: [Atom], cap: Int = Int.max) -> [NeighborTableEntry] {
        var result: [NeighborTableEntry] = []
        result.reserveCapacity(min(analysis.neighbors.count, cap))

        outer: for sourceIndex in analysis.offsets.dropLast().indices {
            let start = analysis.offsets[sourceIndex]
            let end = analysis.offsets[sourceIndex + 1]
            for i in start..<end {
                if result.count >= cap { break outer }
                let neighbor = analysis.neighbors[i]
                guard neighbor.atomIndex >= 0, neighbor.atomIndex < atoms.count,
                      neighbor.distance.isFinite, neighbor.distance > 0,
                      neighbor.displacement.isFinite else { continue }
                result.append(NeighborTableEntry(offset: i, sourceIndex: sourceIndex))
            }
        }
        return result
    }

    // MARK: - Filtering and sorting

    private func parseFilter(from text: String) {
        let terms = text.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        filterSourceIndex = nil
        filterTargetElement = nil
        filterMinDistance = nil
        filterMaxDistance = nil

        for term in terms {
            let lower = term.lowercased()
            if lower.hasPrefix("src:") {
                filterSourceIndex = Int(lower.dropFirst(4))
            } else if lower.hasPrefix("elem:") {
                filterTargetElement = String(lower.dropFirst(5))
            } else if lower.hasPrefix("d>") {
                filterMinDistance = Float(lower.dropFirst(2))
            } else if lower.hasPrefix("d<") {
                filterMaxDistance = Float(lower.dropFirst(2))
            }
        }
    }

    private func rebuildFilterAndSort() {
        filterRebuildCount += 1

        var filtered: [Int] = []
        filtered.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            if let src = filterSourceIndex, entry.sourceIndex != src { continue }
            guard let neighbor = safeNeighbor(for: entry) else { continue }
            if let elem = filterTargetElement {
                guard neighbor.atomIndex >= 0, neighbor.atomIndex < atoms.count else { continue }
                let symbol = ElementTable.symbol(atoms[neighbor.atomIndex].atomicNumber).lowercased()
                guard symbol.contains(elem) else { continue }
            }
            if let minD = filterMinDistance, !(neighbor.distance > minD) { continue }
            if let maxD = filterMaxDistance, !(neighbor.distance < maxD) { continue }
            filtered.append(index)
        }

        filtered.sort { lhs, rhs in
            guard let a = safeNeighbor(for: entries[lhs]),
                  let b = safeNeighbor(for: entries[rhs]) else { return false }
            let aSrc = entries[lhs].sourceIndex
            let bSrc = entries[rhs].sourceIndex
            let aTgt = a.atomIndex
            let bTgt = b.atomIndex
            let aOff = a.imageOffset
            let bOff = b.imageOffset
            let aDist = a.distance
            let bDist = b.distance

            switch sortKey {
            case .distance:
                if aDist != bDist { return aDist < bDist }
                if aSrc != bSrc { return aSrc < bSrc }
                if aTgt != bTgt { return aTgt < bTgt }
                if aOff.x != bOff.x { return aOff.x < bOff.x }
                if aOff.y != bOff.y { return aOff.y < bOff.y }
                return aOff.z < bOff.z
            case .sourceIndex:
                if aSrc != bSrc { return aSrc < bSrc }
                if aDist != bDist { return aDist < bDist }
                if aTgt != bTgt { return aTgt < bTgt }
                if aOff.x != bOff.x { return aOff.x < bOff.x }
                if aOff.y != bOff.y { return aOff.y < bOff.y }
                return aOff.z < bOff.z
            case .targetIndex:
                if aTgt != bTgt { return aTgt < bTgt }
                if aDist != bDist { return aDist < bDist }
                if aSrc != bSrc { return aSrc < bSrc }
                if aOff.x != bOff.x { return aOff.x < bOff.x }
                if aOff.y != bOff.y { return aOff.y < bOff.y }
                return aOff.z < bOff.z
            case .imageX:
                if aOff.x != bOff.x { return aOff.x < bOff.x }
                if aDist != bDist { return aDist < bDist }
                if aSrc != bSrc { return aSrc < bSrc }
                if aTgt != bTgt { return aTgt < bTgt }
                if aOff.y != bOff.y { return aOff.y < bOff.y }
                return aOff.z < bOff.z
            case .imageY:
                if aOff.y != bOff.y { return aOff.y < bOff.y }
                if aDist != bDist { return aDist < bDist }
                if aSrc != bSrc { return aSrc < bSrc }
                if aTgt != bTgt { return aTgt < bTgt }
                if aOff.x != bOff.x { return aOff.x < bOff.x }
                return aOff.z < bOff.z
            case .imageZ:
                if aOff.z != bOff.z { return aOff.z < bOff.z }
                if aDist != bDist { return aDist < bDist }
                if aSrc != bSrc { return aSrc < bSrc }
                if aTgt != bTgt { return aTgt < bTgt }
                if aOff.x != bOff.x { return aOff.x < bOff.x }
                return aOff.y < bOff.y
            }
        }

        if !sortAscending {
            filtered.reverse()
        }

        displayIndices = filtered

        isProgrammaticSelection = true
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(), byExtendingSelection: false)
        isProgrammaticSelection = false

        updateStatus()
    }

    /// Click a column header to sort by that column. Uses the descriptor's
    /// ascending flag directly so the table and the model agree.
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = NeighborTableSortKey(descriptorKey: descriptor.key ?? "") else { return }
        sortKey = key
        sortAscending = descriptor.ascending
        rebuildFilterAndSort()
    }

    /// Safe neighbor access — returns nil if the analysis is missing rather
    /// than force-unwrapping.
    private func safeNeighbor(for entry: NeighborTableEntry) -> CoordinationNeighbor? {
        guard let analysis = resolvedAnalysis,
              entry.offset >= 0, entry.offset < analysis.neighbors.count else { return nil }
        return analysis.neighbors[entry.offset]
    }

    /// Update the compact status field showing displayed/total and omitted.
    private func updateStatus() {
        let displayed = displayIndices.count
        if rawTotalCount == 0 {
            statusField.stringValue = "No neighbor records."
        } else if omittedCount > 0 {
            statusField.stringValue = "Showing \(displayed) of \(rawTotalCount) neighbors (\(omittedCount) omitted)"
        } else {
            statusField.stringValue = "Showing \(displayed) of \(rawTotalCount) neighbors"
        }
    }

    /// Returns the formatted string for the given filtered row and column.
    func value(atRow row: Int, columnIdentifier: NSUserInterfaceItemIdentifier) -> String? {
        guard row >= 0, row < displayIndices.count else { return nil }
        let entryIndex = displayIndices[row]
        guard entryIndex >= 0, entryIndex < entries.count else { return nil }
        let entry = entries[entryIndex]
        guard let neighbor = safeNeighbor(for: entry) else { return nil }

        switch columnIdentifier {
        case Self.colSourceIndex:
            return "\(entry.sourceIndex + 1)"
        case Self.colSourceElement:
            guard entry.sourceIndex >= 0, entry.sourceIndex < atoms.count else { return nil }
            let atom = atoms[entry.sourceIndex]
            return atom.label.isEmpty ? ElementTable.symbol(atom.atomicNumber) : atom.label
        case Self.colTargetIndex:
            return "\(neighbor.atomIndex + 1)"
        case Self.colTargetElement:
            guard neighbor.atomIndex >= 0, neighbor.atomIndex < atoms.count else { return nil }
            let atom = atoms[neighbor.atomIndex]
            return atom.label.isEmpty ? ElementTable.symbol(atom.atomicNumber) : atom.label
        case Self.colImageX:
            return "\(neighbor.imageOffset.x)"
        case Self.colImageY:
            return "\(neighbor.imageOffset.y)"
        case Self.colImageZ:
            return "\(neighbor.imageOffset.z)"
        case Self.colDX:
            return formatFloat(neighbor.displacement.x)
        case Self.colDY:
            return formatFloat(neighbor.displacement.y)
        case Self.colDZ:
            return formatFloat(neighbor.displacement.z)
        case Self.colDistance:
            return formatFloat(neighbor.distance)
        default:
            return nil
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayIndices.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let id = tableColumn?.identifier else { return nil }
        return value(atRow: row, columnIdentifier: id)
    }

    // MARK: - Helpers

    private func formatFloat(_ v: Float) -> String? {
        guard v.isFinite else { return nil }
        return String(format: "%.3f", v)
    }
}
