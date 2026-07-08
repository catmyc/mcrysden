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

    static func printHelp() {
        print("""
        mcrysden — native macOS crystal/molecule viewer (Metal).
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
