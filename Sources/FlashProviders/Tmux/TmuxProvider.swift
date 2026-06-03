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

    // (Diagnostic file write removed — see git history for the
    // alignment-debug version if you need to instrument again.)

    var targets: [JumpTarget] = []
    targets.reserveCapacity(512)
    var idCounter = 0
    let pid = context.processID

    // Status bar(s): query the rendered text per line via tmux's
    // `#{T:status-format[i]}` format expander. The status bar isn't
    // a pane so `capture-pane` doesn't reach it. The result keeps
    // `#[…]` directives as literal text, so we parse them to honor
    // `align=left/center/right` and place each segment at its known
    // base column (left at 0, right at `clientCols - len`, center
    // at `(clientCols - len) / 2`). Lines sit at the top of the
    // client grid when status-position=top, or the bottom otherwise.
    for i in 0..<statusLines {
      let formatArg = "#{T:status-format[\(i)]}"
      guard
        let raw = runShell(
          tmux, ["display-message", "-c", client.tty, "-p", formatArg])
      else { continue }
      let cleanedFormat =
        Self.stripAnsi(raw).trimmingCharacters(in: .newlines)
      var aligned = Self.parseStatusAlign(cleanedFormat)

      // Some users build a custom `status-format[i]` that doesn't
      // reference `#{status-left}` / `#{status-right}`, so the
      // dynamic content those options expand to never makes it into
      // the master template's output. Query them separately and
      // merge — but only when the raw (unexpanded) format doesn't
      // already reference them, so users whose template DOES
      // reference them don't get double-rendered content.
      let rawTemplate =
        runShell(tmux, ["show-options", "-gv", "status-format[\(i)]"]) ?? ""
      if !rawTemplate.contains("status-left") {
        if let leftRaw = runShell(
          tmux,
          ["display-message", "-c", client.tty, "-p", "#{T:status-left}"])
        {
          let cleanLeft = Self.stripAnsi(leftRaw).trimmingCharacters(in: .newlines)
          if !cleanLeft.isEmpty {
            // status-left in tmux's natural rendering is appended
            // at the LEFT of the line before any format-supplied
            // content, so it goes at the head of the left bucket.
            aligned.left = cleanLeft + aligned.left
          }
        }
      }
      if !rawTemplate.contains("status-right") {
        if let rightRaw = runShell(
          tmux,
          ["display-message", "-c", client.tty, "-p", "#{T:status-right}"])
        {
          let cleanRight = Self.stripAnsi(rightRaw).trimmingCharacters(in: .newlines)
          if !cleanRight.isEmpty {
            // status-right sits at the END of the right-aligned
            // region in tmux's rendering, after any format-supplied
            // right-aligned content.
            aligned.right = aligned.right + cleanRight
          }
        }
      }
      let statusScreenRow: Int
      if statusAtTop {
        statusScreenRow = i
      } else {
        statusScreenRow = clientRows - statusLines + i
      }
      let leftBase = 0
      let rightBase = max(0, clientCols - aligned.right.count)
      let centerBase = max(0, (clientCols - aligned.center.count) / 2)
      for (text, baseCol) in [
        (aligned.left, leftBase),
        (aligned.center, centerBase),
        (aligned.right, rightBase),
      ] where !text.isEmpty {
        extractWords(line: text, maxCols: clientCols - baseCol) { col, word in
          let actualCol = baseCol + col
          let x = windowFrame.minX + padX + CGFloat(actualCol) * cellW
          let y =
            windowFrame.minY + windowFrame.height - padY
            - CGFloat(statusScreenRow + 1) * cellH
          let frame = CGRect(
            x: x, y: y, width: CGFloat(word.count) * cellW, height: cellH)
          idCounter += 1
          targets.append(
            JumpTarget(
              id: "tmux-\(pid)-status\(i)-\(idCounter)",
              frame: frame,
              role: "tmux-status-word",
              accessibilityLabel: word,
              pid: pid,
              providerID: identifier
            ))
        }
      }
    }

    for pane in panes {
      guard
        let raw = runShell(tmux, ["capture-pane", "-t", pane.id, "-p"])
      else { continue }
      let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
      for (rowIdx, line) in lines.enumerated() {
        if rowIdx >= pane.rows { break }
        extractWords(line: String(line), maxCols: pane.cols) { col, text in
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
          targets.append(
            JumpTarget(
              id: "tmux-\(pid)-\(idCounter)",
              frame: frame,
              role: "tmux-word",
              accessibilityLabel: text,
              pid: pid,
              providerID: identifier
            ))
        }
      }
    }

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
  private func clientHostedBy(pid: pid_t) -> TmuxClient? {
    guard let tmux = Self.tmuxPath else { return nil }
    guard let raw = runShell(tmux, ["list-clients", "-F", "#{client_tty}\t#{session_name}"])
    else { return nil }
    let clients = raw.split(separator: "\n").compactMap { line -> TmuxClient? in
      let parts = line.split(separator: "\t", maxSplits: 1)
      guard parts.count == 2 else { return nil }
      return TmuxClient(tty: String(parts[0]), session: String(parts[1]))
    }
    if clients.isEmpty { return nil }
    let subtreeTtys = Set(ttysInSubtree(of: pid))
    return clients.first(where: { subtreeTtys.contains($0.tty) })
  }

  // MARK: Process subtree walk
  //
  // One `ps axo pid=,ppid=,tty=` call gives us the entire process
  // table in a single shell-out. We build pid→children + pid→tty in
  // memory and BFS from the focused pid to collect every tty owned
  // by a descendant. The match against `tmux list-clients` then
  // identifies the right client.

  private func ttysInSubtree(of root: pid_t) -> [String] {
    guard let raw = runShell("/bin/ps", ["axo", "pid=,ppid=,tty="]) else {
      return []
    }
    struct Info {
      let ppid: pid_t
      let tty: String
    }
    var byPid: [pid_t: Info] = [:]
    var children: [pid_t: [pid_t]] = [:]
    for line in raw.split(separator: "\n") {
      let parts =
        line
        .split(whereSeparator: { $0 == " " || $0 == "\t" })
        .filter { !$0.isEmpty }
      guard parts.count >= 3,
        let pid = pid_t(parts[0]),
        let ppid = pid_t(parts[1])
      else { continue }
      let tty = String(parts[2])
      byPid[pid] = Info(ppid: ppid, tty: tty)
      children[ppid, default: []].append(pid)
    }

    var ttys: [String] = []
    var queue: [pid_t] = [root]
    var visited = Set<pid_t>()
    while let p = queue.first {
      queue.removeFirst()
      if !visited.insert(p).inserted { continue }
      if visited.count > 1024 { break }  // pathological-safety cap
      if let info = byPid[p], info.tty != "?", info.tty != "??" {
        // `ps` prints tty without the `/dev/` prefix; tmux's
        // `client_tty` is the fully-qualified path. Normalise.
        ttys.append("/dev/" + info.tty)
      }
      for child in children[p] ?? [] {
        queue.append(child)
      }
    }
    return ttys
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

  /// Split a tmux status-format string into its left / center /
  /// right text buckets by interpreting `#[align=…]` directives.
  /// All `#[…]` segments are removed from the output (they aren't
  /// rendered cells); the remaining visible characters land in
  /// whichever bucket matches the most recent `align=` directive.
  /// Default alignment is left (tmux's default before any directive).
  ///
  /// We don't try to parse styling (`fg=…`, `bg=…`, `bold`) — those
  /// don't affect column positioning, so consuming the directive
  /// and discarding its non-align attributes is enough.
  private static func parseStatusAlign(_ format: String)
    -> (left: String, center: String, right: String)
  {
    enum Align { case left, center, right }
    var align: Align = .left
    var left = ""
    var center = ""
    var right = ""
    var i = format.startIndex
    while i < format.endIndex {
      // Detect `#[…]` directive.
      if format[i] == "#",
        format.index(after: i) < format.endIndex,
        format[format.index(after: i)] == "["
      {
        let dirStart = format.index(i, offsetBy: 2)
        if let dirEnd = format[dirStart...].firstIndex(of: "]") {
          let directive = String(format[dirStart..<dirEnd])
          if directive.contains("align=left") {
            align = .left
          } else if directive.contains("align=right") {
            align = .right
          } else if directive.contains("align=center")
            || directive.contains("align=centre")
          {
            align = .center
          }
          i = format.index(after: dirEnd)
          continue
        }
      }
      let ch = format[i]
      switch align {
      case .left: left.append(ch)
      case .center: center.append(ch)
      case .right: right.append(ch)
      }
      i = format.index(after: i)
    }
    return (left, center, right)
  }

  /// Strip CSI escape sequences (ESC `[` … letter) from a string.
  /// Tmux's `#{T:status-format}` evaluation can emit style escapes
  /// (e.g. `\x1b[1;34m`) when the status format contains `#[fg=…]`
  /// directives; they're invisible cells in the rendered terminal
  /// but they confuse our column-based tokenizer. Strip them so
  /// `col` increments line up with the visible character grid.
  private static func stripAnsi(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var iter = s.makeIterator()
    while let ch = iter.next() {
      if ch == "\u{1b}" {
        // Consume the rest of the CSI until a final byte (letter).
        // Tmux only emits CSI-m (SGR) sequences here; for safety
        // also accept any other terminator in the 0x40–0x7e range.
        while let c = iter.next() {
          if let scalar = c.unicodeScalars.first,
            (0x40...0x7e).contains(Int(scalar.value))
          {
            break
          }
        }
      } else {
        out.append(ch)
      }
    }
    return out
  }

}
