import AppKit

// Unbuffered stdout so diagnostic/hover logging is visible immediately even
// when redirected to a file.
setvbuf(stdout, nil, _IONBF, 0)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
