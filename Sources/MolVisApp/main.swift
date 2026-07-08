import AppKit

// SPM executables do not bundle a nib/Info.plist, so `@main` on an
// NSApplicationDelegate would synthesize NSApplicationMain() without ever
// assigning NSApp.delegate — the delegate methods would silently never fire
// and the run loop would spin forever (the headless hang). Wire the delegate
// explicitly and then start the shared application.
let app = NSApplication.shared

// A non-bundled executable defaults to `.prohibited` activation policy,
// which means no menu bar, no Dock icon, and the app inherits the
// terminal's menu bar. Promote to `.regular` so it behaves as a proper
// foreground application with its own menu toolbar (set in
// `App.applicationDidFinishLaunching`). The headless export path exits
// before the run loop begins, so this is harmless for command-line use.
app.setActivationPolicy(.regular)

let delegate = App()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
