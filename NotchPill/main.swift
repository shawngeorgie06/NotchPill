import AppKit

// Unbuffered stdout so diagnostic/hover logging is visible immediately even
// when redirected to a file.
setvbuf(stdout, nil, _IONBF, 0)

// Agent-style app: no Dock icon, no main menu. All UI is the notch overlay window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
