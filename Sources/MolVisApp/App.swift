import AppKit

final class App: NSObject, NSApplicationDelegate {
    var mainWC: MainWindowController?

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            Self.printHelp(); NSApp.terminate(nil); return
        }
        // headless export path
        if let idx = args.firstIndex(of: "--export"), idx + 1 < args.count {
            let outURL = URL(fileURLWithPath: args[idx + 1])
            let inURL = URL(fileURLWithPath: args.first!)
            do {
                var scene = Scene(loaded: try Parser.load(inURL))
                var camera: Camera? = nil
                if let stIdx = args.firstIndex(where: { $0.hasSuffix(".mvis-state") }), stIdx != idx {
                    try StateStore.load(&scene, camera: &camera, from: URL(fileURLWithPath: args[stIdx]))
                }
                try PngExporter.export(scene: scene, camera: camera, to: outURL, size: CGSize(width: 800, height: 800))
            } catch {
                print("[mcrysden] export failed: \(error)")
            }
            NSApp.terminate(nil)
            return
        }
        // GUI path
        if let input = args.first {
            do {
                var scene = Scene(loaded: try Parser.load(URL(fileURLWithPath: input)))
                // If a companion .mvis-state was passed, load + apply it
                // (final-review Minor #3: the GUI path used to ignore it).
                var camera: Camera? = nil
                if let stIdx = args.firstIndex(where: { $0.hasSuffix(".mvis-state") }) {
                    try StateStore.load(&scene, camera: &camera, from: URL(fileURLWithPath: args[stIdx]))
                }
                mainWC = MainWindowController(scene: scene)
                if let camera {
                    mainWC?.camera = camera
                    mainWC?.setNeedsRender()
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
          mcrysden <file.xsf|xyz|pdb|axsf>          # open a structure
          mcrysden <file> <state.mvis-state>         # open with saved state
          mcrysden <file> <state> --export out.png  # headless render
          mcrysden --help
        """)
    }
}
