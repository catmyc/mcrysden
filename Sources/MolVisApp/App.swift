import AppKit
import Darwin

final class App: NSObject, NSApplicationDelegate {
    var mainWC: MainWindowController?

    /// Quit automatically when the user closes the last window (issue 1).
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// Force-format flags (take no value).
    private static let formatFlags: Set<String> = ["--xsf", "--xyz", "--pdb", "--axsf", "--pwi"]

    /// Resolve a forced parser format from the CLI args, if any.
    private static func forcedFormat(from args: [String]) -> ParseFormat? {
        if args.contains("--xsf") { return .xsf }
        if args.contains("--xyz") { return .xyz }
        if args.contains("--pdb") { return .pdb }
        if args.contains("--axsf") { return .axsf }
        if args.contains("--pwi") { return .pwi }
        return nil
    }

    /// Find the input structure file: the first arg that is not a known flag and
    /// is not consumed by `--export <path>`. Allows the force-format flags to be
    /// placed anywhere, e.g. `mcrysden --pwi file.in`.
    private static func inputFile(from args: [String]) -> String? {
        var skipNext = false
        for a in args {
            if skipNext { skipNext = false; continue }
            if a == "--export" { skipNext = true; continue }
            if a == "--help" || a == "-h" { continue }
            if Self.formatFlags.contains(a) { continue }
            return a
        }
        return nil
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.mainMenu = buildMenu()
        NSApp.activate(ignoringOtherApps: true)         // bring to front so menu bar changes
        updateAnalysisCheckmarks()
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            Self.printHelp(); NSApp.terminate(nil); return
        }
        let format = Self.forcedFormat(from: args)
        // headless export path
        var exportHasHappened = false
        if let idx = args.firstIndex(of: "--export"), idx + 1 < args.count,
           let input = Self.inputFile(from: args) {
            let outURL = URL(fileURLWithPath: args[idx + 1])
            let inURL = URL(fileURLWithPath: input)
            do {
                var scene = Scene(loaded: try Parser.load(inURL, as: format))
                var camera: Camera? = nil
                if let stIdx = args.firstIndex(where: { $0.hasSuffix(".mvis-state") }), stIdx != idx {
                    try StateStore.load(&scene, camera: &camera, from: URL(fileURLWithPath: args[stIdx]))
                }
                try PngExporter.export(scene: scene, camera: camera, to: outURL, size: CGSize(width: 800, height: 800))
                exportHasHappened = true
            } catch {
                print("[mcrysden] export failed: \(error)")
                exit(EXIT_FAILURE)
            }
        }
        if exportHasHappened { NSApp.terminate(nil); return }
        // GUI path
        if let input = Self.inputFile(from: args) {
            do {
                var scene = Scene(loaded: try Parser.load(URL(fileURLWithPath: input), as: format))
                // If a companion .mvis-state was passed, load + apply it
                // (final-review Minor #3: the GUI path used to ignore it).
                var camera: Camera? = nil
                if let stIdx = args.firstIndex(where: { $0.hasSuffix(".mvis-state") }) {
                    try StateStore.load(&scene, camera: &camera, from: URL(fileURLWithPath: args[stIdx]))
                }
                let wc = MainWindowController(scene: Scene())
                mainWC = wc
                wc.loadFile(scene)
                if let camera {
                    wc.camera = camera
                    wc.setNeedsRender()
                }
            } catch {
                print("[mcrysden] failed to open \(input): \(error)")
            }
        } else {
            mainWC = MainWindowController(scene: Scene())
        }
    }

    // MARK: - Menu bar

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        // File
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        fileItem.submenu = file
        let openItem = file.addItem(withTitle: "Open\u{2026}", action: #selector(openDocument), keyEquivalent: "o")
        openItem.target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Quit", action: #selector(NSApp.terminate), keyEquivalent: "q")
        // View
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        viewItem.submenu = view
        let lbl = view.addItem(withTitle: "Toggle Element Labels", action: #selector(toggleLabelsFromMenu), keyEquivalent: "l")
        lbl.target = self
        // Analysis
        let analysisItem = NSMenuItem(); main.addItem(analysisItem)
        let analysis = NSMenu(title: "Analysis")
        analysisItem.submenu = analysis
        // Build the menu with a stable tag per item (1..4) so we can update
        // the checkmark without matching titles.
        let modeList: [(String, Int)] = [
            ("Selection", 1),
            ("Distance", 2),
            ("Angle", 3),
            ("Dihedral", 4),
        ]
        for (title, tag) in modeList {
            let it = analysis.addItem(withTitle: title, action: #selector(selectAnalysisMode(_:)), keyEquivalent: "")
            it.target = self
            it.tag = tag
        }
        return main
    }

    /// File > Open...
    @objc private func openDocument(_ sender: Any?) {
        guard let wc = mainWC else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "xsf")!,
                                      .init(filenameExtension: "xyz")!,
                                      .init(filenameExtension: "pdb")!,
                                      .init(filenameExtension: "axsf")!,
                                      .init(filenameExtension: "pwi")!,
                                      .init(filenameExtension: "in")!,
                                      .init(filenameExtension: "inp")!].compactMap { $0 }
        panel.beginSheetModal(for: wc.window) { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let scene = Scene(loaded: try Parser.load(url))
                wc.loadFile(scene)
            } catch {
                print("[mcrysden] open failed: \(error)")
            }
        }
    }

    /// View > Toggle Element Labels
    @objc private func toggleLabelsFromMenu(_ sender: Any?) {
        mainWC?.state.showLabels.toggle()      // propagates via onChange -> syncFromState
    }

    /// Mapping from menu tag to measurement mode.
    private static func modeFor(tag: Int) -> MeasurementMode {
        switch tag {
        case 2: return .distance
        case 3: return .angle
        case 4: return .dihedral
        default: return .none
        }
    }

    /// Analysis > Selection / Distance / Angle / Dihedral (sender carries tag).
    /// Toggling a measurement mode clears any previous selection and starts a
    /// fresh pick; once the required number of atoms is reached the result is
    /// computed automatically and shown in the bottom panel.
    @objc private func selectAnalysisMode(_ sender: NSMenuItem) {
        let mode = Self.modeFor(tag: sender.tag)
        guard let wc = mainWC else { return }
        if mode == .none {
            wc.clearMeasurement()            // back to free selection
        } else {
            wc.scene.measurementMode = mode
            wc.scene.measurementResult = nil
            wc.scene.selectedAtoms = []      // always start fresh
            wc.setNeedsRender()
        }
        updateAnalysisCheckmarks()
    }

    /// Reflect the active measurement mode with a checkmark in the Analysis menu.
    private func updateAnalysisCheckmarks() {
        guard let analysis = NSApp.mainMenu?.item(withTitle: "Analysis")?.submenu,
              let mode = mainWC?.scene.measurementMode else { return }
        let activeTag: Int = { switch mode {
            case .none: return 1; case .distance: return 2; case .angle: return 3; case .dihedral: return 4
        } }()
        for item in analysis.items { item.state = (item.tag == activeTag) ? .on : .off }
    }

    /// Current app version, surfaced in --help output.
    static let appVersion = "1.1.0"

    static func printHelp() {
        print("""
        mcrysden v\(appVersion) — native macOS crystal/molecule viewer (Metal).
        Usage:
          mcrysden                                  # empty viewer
          mcrysden <file.xsf|xyz|pdb|axsf|pwi>      # open a structure
          mcrysden <file> <state.mvis-state>         # open with saved state
          mcrysden <file> <state> --export out.png  # headless render
          mcrysden --help
        Input formats are chosen by extension (.xsf .xyz .pdb .axsf .pwi .in .inp).
        Override with a flag:  --xsf  --xyz  --pdb  --axsf  --pwi
        """)
    }
}
