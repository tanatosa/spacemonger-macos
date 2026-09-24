import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Registers us as a regular (windowed) app so it gets a Dock icon and can focus.
app.setActivationPolicy(.regular)
app.run()