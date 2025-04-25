import Cocoa

let delegate = AppDelegate()
let menu = AppMenu()

NSApplication.shared.delegate = delegate
NSApplication.shared.mainMenu = menu

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
