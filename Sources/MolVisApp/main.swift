import AppKit

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
