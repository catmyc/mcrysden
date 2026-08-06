import Foundation

protocol AnalysisPlugin {
    var name: String { get }
    var summary: String { get }
    func run(scene: Scene) -> String?
}

/// Analysis-plugin registry. Plugins are stored in registration order; the first
/// registration of a given name wins and later duplicates are ignored.
enum PluginRegistry {
    private static let lock = NSLock()
    private static var storage: [any AnalysisPlugin] = []
    private static var builtinsRegistered = false

    private static func ensureBuiltins() {
        guard !builtinsRegistered else { return }
        builtinsRegistered = true
        storage.append(BandGapPlugin())
        storage.append(DOSGapPlugin())
    }

    static func register(_ plugin: AnalysisPlugin) {
        lock.lock()
        defer { lock.unlock() }
        ensureBuiltins()
        if storage.contains(where: { $0.name == plugin.name }) { return }
        storage.append(plugin)
    }

    static func plugins() -> [AnalysisPlugin] {
        lock.lock()
        defer { lock.unlock() }
        ensureBuiltins()
        return storage
    }

    static func plugin(named name: String) -> AnalysisPlugin? {
        lock.lock()
        defer { lock.unlock() }
        ensureBuiltins()
        return storage.first { $0.name == name }
    }

    static func runAll(scene: Scene) -> [(name: String, output: String?)] {
        lock.lock()
        defer { lock.unlock() }
        ensureBuiltins()
        return storage.map { ($0.name, $0.run(scene: scene)) }
    }

    static func listText() -> String {
        plugins()
            .map { "\($0.name) — \($0.summary)" }
            .sorted()
            .joined(separator: "\n")
    }
}

private struct BandGapPlugin: AnalysisPlugin {
    let name = "band-gap"
    let summary = "Band gap (eV) from the parsed band structure"
    func run(scene: Scene) -> String? {
        guard let bs = scene.bandStructure else { return nil }
        guard let r = BandAnalysis.bandGap(bs) else { return nil }
        if r.isMetallic { return "Eg = \(fmt(r.gap)) eV (metallic)" }
        return "Eg = \(fmt(r.gap)) eV (\(r.isDirect ? "direct" : "indirect"))"
    }
}

private struct DOSGapPlugin: AnalysisPlugin {
    let name = "dos-gap"
    let summary = "DOS gap (eV) with VBM/CBM estimates"
    func run(scene: Scene) -> String? {
        guard let dos = scene.densityOfStates else { return nil }
        guard let r = DOSAnalysis.dosGap(dos) else { return nil }
        return "DOS gap ≈ \(fmt(r.gapWidth)) eV (VBM \(fmt(r.vbmEstimate)), CBM \(fmt(r.cbmEstimate)))"
    }
}

private func fmt(_ value: Float) -> String { String(format: "%.3f", value) }
