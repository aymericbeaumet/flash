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
  let args = Array(CommandLine.arguments.dropFirst())
  // Local (no-resident) verbs run before the AppleEvent dispatch. The only
  // one is the underscore-prefixed sandbox-profile printer the conformance
  // runner and tests use; everything user-facing still goes to the resident.
  if args[0] == "_plugin-sandbox-profile" {
    exit(PluginSandboxProfileCLI.run(args: Array(args.dropFirst())))
  }
  exit(FlashCLI.run(args: args))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
