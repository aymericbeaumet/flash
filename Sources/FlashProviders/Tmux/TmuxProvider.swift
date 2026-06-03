import AppKit
import FlashCore
import Foundation

/// Hints individual words inside every visible tmux pane when the focused
/// app is a terminal hosting an attached tmux client.
///
/// Why a separate provider: alacritty/kitty/wezterm render text via
/// OpenGL and expose nothing through AX (an AX walk returns `raw=0`).
/// Terminal.app and iTerm2 do expose their cell text via
/// `AXTextArea`, but it's a single rect — Flash can hint the area but
/// not individual words. Tmux exposes both the visible content
/// (`tmux capture-pane`) and the cell-grid geometry (`#{client_width}/
/// height`, `#{pane_left}/top/width/height`), which is enough to
/// compute per-word pixel rectangles inside the host terminal's
/// window frame.
///
/// **Detection** (`supports`):
///   1. Focused bundle id is in `terminalBundles`.
///   2. `tmux` binary is on one of the well-known install paths
///      (Flash launches via launchd; user PATH isn't inherited).
///   3. `tmux list-clients` returns at least one client. `discover`
///      then filters to the one whose tty lives inside the focused
///      terminal's process subtree.
///
/// **Discovery** (`discover`):
///   1. Identify the tmux client hosted by the focused terminal by
///      cross-referencing tmux client ttys against the focused pid's
///      process descendants.
///   2. Enumerate every pane in the client's current window via
///      `tmux list-panes`. Capture each pane's visible content with
///      `tmux capture-pane -t <pane_id> -p`.
///   3. Cell pixel size is `window / client_cells` — direct
///      division, no font metrics, no padding compensation.
///      With `dynamic_padding = true` the cells absorb the leftover
///      pixels into the per-cell size (off by sub-pixel per cell);
///      with explicit user padding the cells get fractionally taller
///      and the math still spans the full window. Pixel drift
///      accumulates to at most a few pixels across the whole
///      terminal, which is acceptable for word hinting.
///   4. For each pane, tokenize each captured line into alphanumeric
///      runs (≥2 chars) and build a `JumpTarget` per word, offset by
///      `pane_left` / `pane_top` so that splits and a top-positioned
///      status bar shift the words to the right cells of the
///      terminal grid.
///   5. No custom `activate` — the commit falls through to the
///      synthesized mouse click at the chip centre. Alacritty / kitty
///      / wezterm receive the click as a normal mouse event; when
///      tmux mouse mode is on, that becomes a tmux mouse event that
///      selects the pane and positions the cursor.
///
/// **Volatility**: `resultsAreVolatile = true`. Tmux content changes
/// (terminal output, async tmux activity) don't propagate through
/// AX, so AppMonitor's cache would serve stale hints. Marking the
/// provider volatile makes activation skip the cache lookup + write
/// + pre-walk for any context this provider applies to.
public final class TmuxProvider: JumpProvider {
  public let identifier: String = "tmux"
  /// Priority 20 — above the generic AX walker (10), below browser
  /// DOM (30). When the AX walker also returns hints for the same
  /// terminal (Terminal.app's `AXTextArea` is the typical case), the
  /// spatial-dedup pass keeps the small per-word rects and drops the
  /// larger AX text-area rect.
  public let priority: Int = 20
  public var resultsAreVolatile: Bool { true }

  /// Known terminal app bundles. Only these get the tmux probe — any
  /// other app skips supports() at line 1 and falls through to AX.
  private static let terminalBundles: Set<String> = [
    "org.alacritty",
    "io.alacritty",
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "dev.warp.Warp-Stable",
    "co.zeit.hyperterm",
    "co.zeit.hyper",
  ]

  /// Resolve the tmux binary once at provider construction. Flash
  /// launches under launchd, so it doesn't inherit the user's PATH;
  /// hardcoded probe through the standard Homebrew + macOS locations.
  private static let tmuxPath: String? = {
    for p in [
      "/opt/homebrew/bin/tmux",
      "/usr/local/bin/tmux",
      "/opt/local/bin/tmux",
      "/usr/bin/tmux",
    ] {
      if FileManager.default.isExecutableFile(atPath: p) {
        return p
      }
    }
    return nil
  }()

  public init() {}

  public func supports(_ context: AppContext) -> Bool {
    // Cheap check only — bundle id + tmux binary on disk. We deliberately
    // do NOT shell out to `tmux list-clients` here. `supports` is called
    // from two hot paths:
    //   1. AppMonitor.anyVolatileProviderApplies, on the MAIN thread,
    //      before each activation can dispatch to the AX queue.
    //   2. ProviderRegistry.chain, on the AX queue.
    // A blocking subprocess on the main path adds 3–10 ms of latency to
    // every alacritty/Terminal activation regardless of whether the user
    // actually has tmux running. `discover` runs the real
    // `clientHostedBy` check (which is already on the AX queue) and
    // returns [] when no client matches, so the AX walker still fills in
    // hints unaffected.
    guard Self.terminalBundles.contains(context.bundleIdentifier) else { return false }
    return Self.tmuxPath != nil
  }

  public func discover(in context: AppContext, deadline _: Date) throws -> [JumpTarget] {
    guard let tmux = Self.tmuxPath else { return [] }
    guard let client = clientHostedBy(pid: context.processID) else { return [] }

    // One subprocess invocation for all the per-client scalars: width,
    // height, status-lines, status-position. Each tmux fork+exec is
    // 3–8 ms on this machine, so collapsing four queries to one cuts
    // 9–24 ms off the volatile-walk hot path. Lines are separated by
    // explicit newlines inside the format; tmux preserves them in the
    // output exactly.
    guard
      let combined = runShell(
        tmux,
        [
          "display-message", "-c", client.tty, "-p",
          "#{client_width} #{client_height}\n#{status} #{status-position}",
        ])
    else { return [] }
    let combinedLines = combined.split(
      separator: "\n", omittingEmptySubsequences: false
    ).map(String.init)
    guard combinedLines.count >= 2,
      let (clientCols, clientRows) = parseTwoInts(combinedLines[0])
    else { return [] }
    let statusInfo = combinedLines[1]

    let windowFrame = context.frontWindowFrame
    guard !windowFrame.isNull, windowFrame.width > 0, windowFrame.height > 0,
      clientCols > 0, clientRows > 0
    else { return [] }

    // Cell geometry: prefer font-derived metrics when we can resolve
    // the host terminal's font (alacritty.toml today). Alacritty
    // uses tight cell sizing — `ascender − descender`, no leading —
    // and `dynamic_padding` distributes the leftover window pixels
    // as symmetric padding top/bottom. Without font metrics we fall
    // back to `window / cells`, which spreads the padding INTO each
    // cell and creates symmetric drift (top hints above the words,
    // bottom hints below). For non-alacritty terminals we don't
    // (yet) read their fonts, so the fallback applies — usually OK
    // since most have small or zero padding.
    let (cellW, cellH, padX, padY) = resolveGeometry(
      bundleID: context.bundleIdentifier,
      windowFrame: windowFrame,
      clientCols: clientCols,
      clientRows: clientRows
    )

    // Enumerate every pane in the client's current window. Splits +
    // status bar are all handled by walking the panes and offsetting
    // each by its `pane_left` / `pane_top`.
    guard
      let listOut = runShell(
        tmux,
        [
          "list-panes", "-t", client.tty, "-F",
          "#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}",
        ])
    else { return [] }
    let panes: [Pane] = listOut.split(separator: "\n").compactMap { line in
      let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        .filter { !$0.isEmpty }
      guard parts.count == 5,
        let pl = Int(parts[1]),
        let pt = Int(parts[2]),
        let pw = Int(parts[3]),
        let ph = Int(parts[4])
      else { return nil }
      return Pane(id: String(parts[0]), left: pl, top: pt, cols: pw, rows: ph)
    }
    if panes.isEmpty { return [] }

    // `pane_top` is relative to the tmux WINDOW (the content area
    // below the status bar), not the client (whole terminal grid).
    // Add the top-positioned status rows to lift pane content into
    // the right screen position. `#{status}` is the integer status
    // lines value (0–5; tmux normalises "on" to 1 in this variable).
    let statusParts =
      statusInfo
      .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
      .filter { !$0.isEmpty }
    let statusLines: Int = {
      guard let first = statusParts.first.map(String.init) else { return 0 }
      if let n = Int(first) { return n }
      return first == "on" ? 1 : 0
    }()
    let statusAtTop = statusParts.count >= 2 && statusParts[1] == "top"
    let topOffset = statusAtTop ? statusLines : 0

    // The tmux status bar is deliberately not hinted. Status content
    // (session name, hostname, clock) is rarely the thing the user
    // wants to act on, and hinting it clutters the overlay. We still
    // resolve status lines + position above because pane content
    // coordinates depend on `topOffset`.

    let pid = context.processID

    // Capture every pane's content in parallel. Each `tmux capture-pane`
    // is a separate fork+exec on Flash's side; tmux's server serialises
    // the requests but the fork+exec parallelises across panes, so a
    // 4-pane workspace gets ~3 fork+exec costs reclaimed (~9–15 ms).
    // Each worker writes only into its own `paneTargets[i]` slot, so
    // no locking is needed for the accumulation; the id-disambiguator
    // is the pane index so ids stay unique across the merge.
    var paneTargets: [[JumpTarget]] = Array(repeating: [], count: panes.count)
    paneTargets.withUnsafeMutableBufferPointer { buf in
      DispatchQueue.concurrentPerform(iterations: panes.count) { i in
        let pane = panes[i]
        guard let raw = self.runShell(tmux, ["capture-pane", "-t", pane.id, "-p"]) else {
          return
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        var local: [JumpTarget] = []
        local.reserveCapacity(64)
        var idCounter = 0
        for (rowIdx, line) in lines.enumerated() {
          if rowIdx >= pane.rows { break }
          self.extractWords(line: String(line), maxCols: pane.cols) { col, text in
            let screenCol = pane.left + col
            let screenRow = topOffset + pane.top + rowIdx
            let x = windowFrame.minX + padX + CGFloat(screenCol) * cellW
            // NSScreen Y grows up, so a cell's bottom-Y is
            // window-top minus the top padding minus (screenRow+1) cells.
            let y =
              windowFrame.minY + windowFrame.height - padY
              - CGFloat(screenRow + 1) * cellH
            let frame = CGRect(
              x: x, y: y, width: CGFloat(text.count) * cellW, height: cellH)
            idCounter += 1
            local.append(
              JumpTarget(
                id: "tmux-\(pid)-p\(i)-\(idCounter)",
                frame: frame,
                role: "tmux-word",
                accessibilityLabel: text,
                pid: pid,
                providerID: identifier
              ))
          }
        }
        buf[i] = local
      }
    }

    var targets: [JumpTarget] = []
    targets.reserveCapacity(paneTargets.reduce(0) { $0 + $1.count })
    for arr in paneTargets { targets.append(contentsOf: arr) }
    return targets
  }

  // MARK: Tokenization

  /// Iterate `[A-Za-z0-9]+` runs of length ≥2. 1-char tokens are
  /// noise (single digits, `a`, etc.); skipping them roughly halves
  /// the hint count without losing useful tokens. Punctuation always
  /// terminates a run — paths like `/foo/bar/baz` produce three
  /// separate words, which matches what was asked for.
  private func extractWords(
    line: String, maxCols: Int, emit: (_ col: Int, _ text: String) -> Void
  ) {
    var col = 0
    var wordStart: Int? = nil
    var wordChars: [Character] = []
    func flush() {
      if let start = wordStart, wordChars.count >= 2 {
        emit(start, String(wordChars))
      }
      wordStart = nil
      wordChars.removeAll(keepingCapacity: true)
    }
    for ch in line {
      if col >= maxCols { break }
      // Restricting to ASCII letters/digits keeps the per-character
      // grapheme-cluster → column mapping 1:1, which the pixel
      // coordinate math assumes. Wide-cell glyphs (CJK, emoji) are
      // skipped as word breaks; their cells advance the column
      // counter by 1 each, which is wrong for wide glyphs but
      // matches the simpler ASCII-cell model.
      if ch.isASCII, ch.isLetter || ch.isNumber {
        if wordStart == nil { wordStart = col }
        wordChars.append(ch)
      } else {
        flush()
      }
      col += 1
    }
    flush()
  }

  // MARK: Tmux client + pane discovery

  private struct TmuxClient {
    let tty: String
    let session: String
  }

  private struct Pane {
    let id: String
    let left: Int
    let top: Int
    let cols: Int
    let rows: Int
  }

  private func parseTwoInts(_ s: String) -> (Int, Int)? {
    let parts = s.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: { $0 == " " || $0 == "\t" })
      .filter { !$0.isEmpty }
    guard parts.count == 2,
      let a = Int(parts[0]),
      let b = Int(parts[1])
    else { return nil }
    return (a, b)
  }

  /// Find the tmux client whose pty lives in the focused terminal's
  /// process subtree. Returns nil if there isn't one — at which
  /// point `discover` returns [] and the AX walker takes over.
  ///
  /// Why the subtree check is necessary: `tmux list-clients` returns
  /// every attached client across every terminal window. Without the
  /// match, focusing alacritty while another terminal hosts a tmux
  /// session would have us capture from the WRONG pane.
  ///
  /// Algorithm: ask tmux for each attached client's `client_pid` (the
  /// process that ran `tmux attach`), then walk its parent chain via
  /// `proc_pidinfo` until we either hit `focusedPid` (match) or pid 1
  /// (no match). This replaces a prior `/bin/ps` shell-out that
  /// enumerated the whole process table; the new approach is one
  /// syscall per ancestor hop and avoids paying a fork+exec on every
  /// tmux walk (~3 ms saved).
  private func clientHostedBy(pid focusedPid: pid_t) -> TmuxClient? {
    guard let tmux = Self.tmuxPath else { return nil }
    guard
      let raw = runShell(
        tmux, ["list-clients", "-F", "#{client_tty}\t#{session_name}\t#{client_pid}"])
    else { return nil }
    for line in raw.split(separator: "\n") {
      let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
      guard parts.count == 3 else { continue }
      let tty = parts[0]
      let session = parts[1]
      guard let clientPid = pid_t(parts[2]) else { continue }
      if Self.isAncestor(focusedPid, of: clientPid) {
        return TmuxClient(tty: tty, session: session)
      }
    }
    return nil
  }

  /// True if `ancestor` appears in the parent chain of `descendant`
  /// (or equals it). Walks up via `proc_pidinfo(_, PROC_PIDTBSDINFO,
  /// _)`; bounded to 64 hops as a pathological-safety cap (real
  /// chains rarely exceed a dozen).
  private static func isAncestor(_ ancestor: pid_t, of descendant: pid_t) -> Bool {
    var cur = descendant
    var hops = 0
    while cur > 1, hops < 64 {
      if cur == ancestor { return true }
      guard let p = parentPID(of: cur), p != cur else { return false }
      cur = p
      hops += 1
    }
    return false
  }

  private static func parentPID(of pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let got = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, Int32(size))
    }
    guard got == Int32(size) else { return nil }
    return pid_t(info.pbi_ppid)
  }

  // MARK: Geometry resolution

  /// Returns (cellW, cellH, padX, padY) in window-local pixels.
  ///
  /// **alacritty** (`org.alacritty` / `io.alacritty`): read font
  /// family + size from `alacritty.toml`, compute the cell box from
  /// NSFont (`ascender − descender` for height, glyph advance for
  /// width), then derive padding from the leftover between `window`
  /// and `cells × cellSize`. Handles `dynamic_padding = true`
  /// without needing to read its value — the leftover IS the
  /// dynamic padding alacritty applies.
  ///
  /// **Anything else** (Terminal.app / iTerm2 / kitty / wezterm /
  /// Warp / hyper): fall back to `window / cells`, exact for
  /// terminals without padding and acceptably close for those with
  /// small padding. Adding readers per-terminal is the natural
  /// extension when the fallback proves wrong on a specific app.
  private func resolveGeometry(
    bundleID: String,
    windowFrame: CGRect,
    clientCols: Int,
    clientRows: Int
  ) -> (cellW: CGFloat, cellH: CGFloat, padX: CGFloat, padY: CGFloat) {
    if bundleID == "org.alacritty" || bundleID == "io.alacritty",
      let font = alacrittyFont(),
      let metrics = cellMetrics(family: font.family, size: font.size)
    {
      let contentW = CGFloat(clientCols) * metrics.width
      let contentH = CGFloat(clientRows) * metrics.height
      let padX = max(0, (windowFrame.width - contentW) / 2)
      let padY = max(0, (windowFrame.height - contentH) / 2)
      return (metrics.width, metrics.height, padX, padY)
    }
    return (windowFrame.width / CGFloat(clientCols), windowFrame.height / CGFloat(clientRows), 0, 0)
  }

  private struct AlacrittyFont {
    let family: String
    let size: Double
  }

  /// Read alacritty's TOML config, return the resolved monospace
  /// font family + size. Returns nil when no config is present
  /// (alacritty uses its built-in defaults: Menlo at 11pt).
  /// Done at every walk rather than cached: walks happen only on
  /// activation (cheap), the file is small, and reading every time
  /// makes config edits take effect without a Flash restart.
  private func alacrittyFont() -> AlacrittyFont? {
    let candidates = [
      (NSString(string: "~/.config/alacritty/alacritty.toml")
        as NSString).expandingTildeInPath,
      (NSString(string: "~/.alacritty.toml") as NSString).expandingTildeInPath,
    ]
    var text: String?
    for path in candidates {
      if let c = try? String(contentsOfFile: path, encoding: .utf8) {
        text = c
        break
      }
    }
    guard let text else { return nil }
    let size = readTOMLNumber(in: text, section: "font", key: "size") ?? 11.0
    let family =
      readTOMLString(in: text, section: "font.normal", key: "family")
      ?? "Menlo"
    return AlacrittyFont(family: family, size: size)
  }

  /// Minimal TOML lookup — finds `key` inside `[section]`. Doesn't
  /// handle inline tables, nested sections beyond two levels, or
  /// trailing comments — enough for the alacritty.toml shape we read.
  private func readTOMLRaw(in text: String, section: String, key: String) -> String? {
    var inSection = false
    for rawLine in text.split(separator: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if line.hasPrefix("[") && line.hasSuffix("]") {
        let inner = String(line.dropFirst().dropLast()).trimmingCharacters(
          in: .whitespaces)
        inSection = (inner == section)
        continue
      }
      if !inSection { continue }
      guard let eq = line.firstIndex(of: "=") else { continue }
      let k = line[..<eq].trimmingCharacters(in: .whitespaces)
      if k == key {
        return String(line[line.index(after: eq)...]).trimmingCharacters(
          in: .whitespaces)
      }
    }
    return nil
  }

  private func readTOMLString(in text: String, section: String, key: String) -> String? {
    guard var v = readTOMLRaw(in: text, section: section, key: key) else { return nil }
    if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
      v = String(v.dropFirst().dropLast())
    }
    return v.isEmpty ? nil : v
  }

  private func readTOMLNumber(in text: String, section: String, key: String) -> Double? {
    guard let v = readTOMLRaw(in: text, section: section, key: key) else { return nil }
    return Double(v)
  }

  /// Resolve a monospace font's per-cell pixel box.
  /// **Width** is the glyph advance (identical across glyphs for
  /// monospace fonts).
  /// **Height** is `ascender − descender` — tight line metrics with
  /// no typographic leading, matching alacritty's cell sizing.
  /// `NSLayoutManager.defaultLineHeight(for:)` adds leading and
  /// overshoots by ~3pt for typical monospace fonts; using it would
  /// push our content height past the window and clamp padding to
  /// zero. Falls back to Menlo if the named family can't load.
  private func cellMetrics(family: String, size: Double) -> (width: CGFloat, height: CGFloat)? {
    let font =
      NSFont(name: family, size: CGFloat(size))
      ?? NSFont(name: "Menlo", size: CGFloat(size))
      ?? NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    let lineHeight = font.ascender - font.descender  // descender is negative
    let advance = font.maximumAdvancement.width
    guard advance > 0, lineHeight > 0 else { return nil }
    return (advance, lineHeight)
  }

  // MARK: Shell helper

  private func runShell(_ exec: String, _ args: [String]) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: exec)
    task.arguments = args
    let outPipe = Pipe()
    task.standardOutput = outPipe
    // Suppress stderr so a missing tmux server doesn't spam the
    // Flash log. The non-zero exit code is enough to know it failed.
    task.standardError = Pipe()
    do {
      try task.run()
    } catch {
      return nil
    }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }

}
