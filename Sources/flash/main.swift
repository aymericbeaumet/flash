import AppKit
import Darwin

// Ignore SIGPIPE so writing to a closed pipe (a plugin subprocess that
// died, a debug-server client that hung up) returns EPIPE on the write
// instead of killing the resident process. `try? handle.write(...)`
// already swallows the resulting error, so the practical effect is
// "plugin crash is contained — Flash stays up."
signal(SIGPIPE, SIG_IGN)

// `flash` is a fat binary: launched with no extra argv (Launch Services
// opening `/Applications/Flash.app`) it becomes the resident process;
// launched with argv (`/usr/local/bin/flash mouse_target`) it runs as a
// one-shot CLI that AppleEvents the verb to the running resident, then
// exits. This is why `flashctl` no longer exists — the CLI half lives in
// the same Mach-O as the app.
if CommandLine.arguments.count > 1 {
  exit(FlashCLI.run(args: Array(CommandLine.arguments.dropFirst())))
}

// Held for the process lifetime; see `ResidentLock`.
let residentLock: ResidentLock?
switch ResidentLock.acquire() {
case .acquired(let lock):
  residentLock = lock
case .heldByAnother(let pid):
  let holder = pid.map(String.init) ?? "unknown"
  FileHandle.standardError.write(
    Data("flash: another Flash resident is already running (pid \(holder)); exiting\n".utf8))
  FlashLog.warn("[resident] duplicate_exit holder_pid=\(holder)")
  FlashLog.flush()
  exit(0)
case .unavailable(let code):
  residentLock = nil
  FlashLog.warn("[resident] lock_unavailable errno=\(code)")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
