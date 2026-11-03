import AppKit
import Darwin

// Ignore SIGPIPE so writing to a closed pipe (a plugin subprocess that
// died, a debug-server client that hung up) returns EPIPE on the write
// instead of killing the resident process. `try? handle.write(...)`
// already swallows the resulting error, so the practical effect is
// "plugin crash is contained — Flash stays up."
signal(SIGPIPE, SIG_IGN)

// `flash` is one binary: launched with no extra argv (Launch Services
// opening `/Applications/Flash.app`) it becomes the resident process;
// launched with argv (`~/.local/bin/flash mouse target`) it runs as a
// one-shot CLI that sends the words to the resident over its socket
// (`IPCServer`), then exits. The CLI half lives in the same Mach-O as the
// app; there is no separate client executable.
if CommandLine.arguments.count > 1 {
  exit(FlashCLI.run(args: Array(CommandLine.arguments.dropFirst())))
}

// Started by the updater (`UpdateRelaunch`): the old resident is quitting,
// so wait for its lock instead of exiting as a duplicate. The variable is
// cleared so plugins and popups never inherit it.
let relaunchedByUpdate = getenv(UpdateRelaunch.waitVariable) != nil
unsetenv(UpdateRelaunch.waitVariable)

// Held for the process lifetime; see `ResidentLock`.
let residentLock: ResidentLock?
switch ResidentLock.acquire(waitingUpTo: relaunchedByUpdate ? 60 : 0) {
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
  FlashLog.error("[resident] lock_unavailable errno=\(code)")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
