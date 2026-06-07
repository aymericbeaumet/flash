import AppKit
import Darwin

// Ignore SIGPIPE so writing to a closed pipe (a plugin subprocess that
// died, a debug-server client that hung up) returns EPIPE on the write
// instead of killing the resident process. `try? handle.write(...)`
// already swallows the resulting error, so the practical effect is
// "plugin crash is contained — Flash stays up."
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
