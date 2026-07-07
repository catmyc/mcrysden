import AppKit

@main
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
            // find input file = first arg that isn't a flag and isn't the --export target
            let inURL = URL(fileURLWithPath: args.first!)
            do {
                var scene = Scene(loaded: try Parser.load(inURL))
                if let stIdx = args.firstIndex(where: { $0.hasSuffix(".mvis-state") }), stIdx != idx {
                    var camera = scene.camera
                    try StateStore.load(&scene, &camera, from: URL(fileURLWithPath: args[stIdx]))
                    scene.camera = camera
                }
                try PngExporter.export(scene: scene, camera: scene.camera, to: outURL, size: CGSize(width: 800, height: 800))
            } catch {
                print("[mcrysden] export failed: \(error)")
                NSApp.terminate(nil)
                return
            }
            NSApp.terminate(nil)
            return
        }
        // GUI path
        if let input = args.first {
            do {
                let scene = Scene(loaded: try Parser.load(URL(fileURLWithPath: input)))
                mainWC = MainWindowController(scene: scene)
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
