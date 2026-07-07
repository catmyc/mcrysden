import AppKit

// SPM executables do not bundle a nib/Info.plist, so `@main` on an
// NSApplicationDelegate would synthesize NSApplicationMain() without ever
// assigning NSApp.delegate — the delegate methods would silently never fire
// and the run loop would spin forever (the headless hang). Wire the delegate
// explicitly and then start the shared application.
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
