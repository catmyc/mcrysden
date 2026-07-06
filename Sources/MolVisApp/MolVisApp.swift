import AppKit

class App: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--help") || args.contains("-h") {
            Self.printHelp()
            NSApp.terminate(nil)
            return
        }
        print("[mcrysden] launched; args=\(Array(args))")
        NSApp.terminate(nil)
    }

    static func printHelp() {
        print("""
        mcrysden — native macOS crystal/molecule viewer (Metal).

        Usage:
          mcrysden                                  # empty viewer
          mcrysden <file.xsf|xyz|pdb|axsf>          # open a structure
          mcrysden <file> <state.mvis-state>         # open with saved state
          mcrysden <file> <state> --export out.png  # headless render
          mcrysden --help                           # this message
        """)
    }
}
