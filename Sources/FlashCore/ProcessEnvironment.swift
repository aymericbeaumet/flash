import Foundation

/// Canonical environment for every child process Flash spawns.
///
/// A GUI app launched from Finder/`launchd` inherits a minimal environment:
/// no `PATH` to Homebrew, `mise` shims, or anything the user's shell rc files
/// add. That breaks `script:`/`command:` status-bar tasks, command mappings,
/// and plugins, which expect the same tooling the user sees in their terminal.
///
/// The fix is the VS Code model: resolve the login-shell environment *once* at
/// launch (and again on config reload) by spawning `$SHELL -l -c 'export -p'`,
/// parse it, cache it, and apply it to every child process. The status bar
/// re-renders every second — paying a login-shell spawn on every render would
/// be absurd, so the cost is amortized to one spawn per launch/reload.
///
/// All binary execution in Flash routes its environment through
/// `FlashProcessEnvironment.shared` so the resolve-once cache is the single
/// source of truth.
public final class FlashProcessEnvironment: @unchecked Sendable {
  /// Shared cache used by every process-spawning site in the app.
  public static let shared = FlashProcessEnvironment()

  private let lock = NSLock()
  private var cached: [String: String]

  /// Seeds with the current process environment (plus a `PATH` fallback) so a
  /// command that runs before the first ``refresh()`` still has a usable
  /// `PATH`. `refresh()` replaces this with the real login-shell environment.
  public init(seed: [String: String] = ProcessInfo.processInfo.environment) {
    self.cached = Self.withFallbackPath(seed)
  }

  /// The cached environment to assign to `Process.environment`.
  public var environment: [String: String] {
    lock.lock()
    defer { lock.unlock() }
    return cached
  }

  /// Re-resolve the login-shell environment. Call once at launch and again on
  /// config reload. Spawns `$SHELL -l -c 'export -p'` a single time; on any
  /// failure (missing shell, timeout, empty output) the previous cache is kept
  /// untouched. Returns the environment now in effect.
  ///
  /// Blocking — run it off the main thread. The work is a single short-lived
  /// child process (login shell rc evaluation, typically tens of ms).
  @discardableResult
  public func refresh(
    shellPath: String? = nil,
    timeout: TimeInterval = 5
  ) -> [String: String] {
    let base = ProcessInfo.processInfo.environment
    let shell = shellPath ?? base["SHELL"]
    let merged: [String: String]
    if let resolved = Self.resolveLoginShellEnvironment(shellPath: shell, timeout: timeout) {
      // The login shell is spawned from this process, so `resolved` already
      // carries our env plus whatever the rc files added. Overlay it on the
      // current env anyway so a shell that prints a subset never drops a var.
      var env = base
      for (key, value) in resolved { env[key] = value }
      merged = Self.withFallbackPath(env)
    } else {
      merged = Self.withFallbackPath(base)
    }
    lock.lock()
    cached = merged
    lock.unlock()
    return merged
  }

  /// Apply the cached environment to `process`. `overrides` win over the
  /// shared base — used for per-process variables (plugin identity,
  /// `PYTHONDONTWRITEBYTECODE`, …) that should not pollute the global cache.
  public func apply(to process: Process, overrides: [String: String] = [:]) {
    process.environment = environment(withOverrides: overrides)
  }

  /// The cached environment with `overrides` layered on top. Use when a caller
  /// needs the dictionary directly rather than assigning it to a `Process`.
  public func environment(withOverrides overrides: [String: String]) -> [String: String] {
    guard !overrides.isEmpty else { return environment }
    var env = environment
    for (key, value) in overrides { env[key] = value }
    return env
  }

  // MARK: - Resolution

  /// Default `PATH` when neither the process nor the login shell supplies one.
  /// Mirrors a typical macOS interactive shell: Homebrew first, then the
  /// system directories.
  public static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  /// Returns `environment` with a `PATH` guaranteed to be non-empty.
  public static func withFallbackPath(_ environment: [String: String]) -> [String: String] {
    guard environment["PATH", default: ""].isEmpty else { return environment }
    var copy = environment
    copy["PATH"] = fallbackPath
    return copy
  }

  /// Spawn `shellPath -l -c 'export -p'` and parse the result. Returns `nil`
  /// when the shell can't be run, exits non-zero, times out, or yields nothing
  /// parseable, so callers fall back to the previous cache.
  public static func resolveLoginShellEnvironment(
    shellPath: String?,
    timeout: TimeInterval = 5
  ) -> [String: String]? {
    let shell = shellPath?.isEmpty == false ? shellPath! : "/bin/sh"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    // `export -p` is POSIX and emits a re-importable dump across sh/bash/zsh.
    // `-l` runs the login rc chain (`.zprofile`/`.profile`/…) where `PATH`
    // mutations like `eval "$(mise activate …)"` live.
    process.arguments = ["-l", "-c", "export -p"]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return nil
    }

    // Drain stdout on a background queue so a chatty rc file (a few KB) can't
    // deadlock by filling the pipe buffer while we wait on exit.
    let collected = DispatchSemaphore(value: 0)
    var data = Data()
    DispatchQueue.global(qos: .userInitiated).async {
      data = out.fileHandleForReading.readDataToEndOfFile()
      collected.signal()
    }

    let deadline = DispatchTime.now() + timeout
    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      process.waitUntilExit()
      exited.signal()
    }
    if exited.wait(timeout: deadline) == .timedOut {
      process.terminate()
      _ = exited.wait(timeout: .now() + 0.5)
      _ = collected.wait(timeout: .now() + 0.5)
      // Best-effort: stderr is drained on terminate to avoid a lingering fd.
      _ = try? err.fileHandleForReading.readToEnd()
      return nil
    }
    _ = collected.wait(timeout: .now() + 1)
    _ = try? err.fileHandleForReading.readToEnd()

    guard process.terminationStatus == 0 else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    let parsed = parse(exportOutput: text)
    return parsed.isEmpty ? nil : parsed
  }

  // MARK: - Parsing

  /// Parse the output of `export -p` (POSIX `sh`/`zsh`) or `declare -x`
  /// (`bash`) into key/value pairs.
  ///
  /// Handles the three quoting styles the common shells emit:
  ///   - `export KEY=value`            (unquoted, zsh simple values)
  ///   - `export KEY='value'`          (single-quoted, sh/zsh)
  ///   - `declare -x KEY="value"`      (double-quoted with `\` escapes, bash)
  ///   - `export KEY=$'va\tlue'`       (ANSI-C quoting for control chars)
  ///
  /// A value containing a raw newline would span multiple output lines; such a
  /// value is truncated at the newline rather than corrupting the vars that
  /// follow, because a continuation line never looks like a fresh assignment.
  public static func parse(exportOutput: String) -> [String: String] {
    var result: [String: String] = [:]
    for rawLine in exportOutput.split(separator: "\n", omittingEmptySubsequences: false) {
      var line = Substring(rawLine)
      for prefix in ["export ", "declare -x ", "typeset -x "] where line.hasPrefix(prefix) {
        line = line.dropFirst(prefix.count)
        break
      }
      guard let eq = line.firstIndex(of: "=") else { continue }
      let key = String(line[line.startIndex..<eq])
      guard isValidEnvironmentName(key) else { continue }
      let rawValue = String(line[line.index(after: eq)...])
      result[key] = unquote(rawValue)
    }
    return result
  }

  /// `true` when `name` is a POSIX environment variable name. Filters out
  /// continuation lines of multi-line values, which never form a valid name.
  static func isValidEnvironmentName(_ name: String) -> Bool {
    guard let first = name.first, first == "_" || first.isLetter else { return false }
    return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
  }

  /// Strip shell quoting from a single assignment's value.
  static func unquote(_ raw: String) -> String {
    guard let first = raw.first else { return raw }

    // ANSI-C quoting: $'...'
    if raw.hasPrefix("$'"), raw.hasSuffix("'"), raw.count >= 3 {
      let inner = raw.dropFirst(2).dropLast()
      return unescapeANSIC(String(inner))
    }

    // Single quotes: literal, except the `'\''` close-escape-reopen sequence.
    if first == "'", raw.hasSuffix("'"), raw.count >= 2 {
      let inner = raw.dropFirst().dropLast()
      return inner.replacingOccurrences(of: "'\\''", with: "'")
    }

    // Double quotes: bash escapes `"`, `\`, `$`, and backtick with a backslash.
    if first == "\"", raw.hasSuffix("\""), raw.count >= 2 {
      let inner = raw.dropFirst().dropLast()
      return unescapeDoubleQuoted(String(inner))
    }

    return raw
  }

  private static func unescapeDoubleQuoted(_ value: String) -> String {
    var out = ""
    out.reserveCapacity(value.count)
    var iterator = value.makeIterator()
    while let ch = iterator.next() {
      guard ch == "\\" else {
        out.append(ch)
        continue
      }
      guard let next = iterator.next() else {
        out.append("\\")
        break
      }
      switch next {
      case "\"", "\\", "$", "`":
        out.append(next)
      default:
        // Bash only escapes the four metacharacters inside double quotes;
        // anything else keeps the literal backslash.
        out.append("\\")
        out.append(next)
      }
    }
    return out
  }

  private static func unescapeANSIC(_ value: String) -> String {
    var out = ""
    out.reserveCapacity(value.count)
    var iterator = value.makeIterator()
    while let ch = iterator.next() {
      guard ch == "\\" else {
        out.append(ch)
        continue
      }
      guard let next = iterator.next() else {
        out.append("\\")
        break
      }
      switch next {
      case "n": out.append("\n")
      case "t": out.append("\t")
      case "r": out.append("\r")
      case "\\": out.append("\\")
      case "'": out.append("'")
      case "\"": out.append("\"")
      default:
        out.append("\\")
        out.append(next)
      }
    }
    return out
  }
}
