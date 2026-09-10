import AppKit
import CFlashTerminal
import Darwin
import Foundation

public struct TerminalConfiguration: Equatable, Sendable {
  public let command: [String]
  public let workingDirectory: String?
  public let environment: [String: String]
  public let columns: Int
  public let rows: Int
  public init(
    command: [String], workingDirectory: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    columns: Int = 80, rows: Int = 24
  ) {
    self.command = command
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.columns = max(1, min(1000, columns))
    self.rows = max(1, min(1000, rows))
  }
}

public enum TerminalSessionState: Equatable, Sendable {
  case idle
  case running(pid: Int32)
  case exited(code: Int32)
  case failed(String)
  case stopped
}

public enum TerminalSessionDiagnostic: Equatable, Sendable {
  case reapDeferred(pid: Int32)
  case reaped(pid: Int32)
}

enum TerminalChildReaping {
  private static let queue = DispatchQueue(label: "com.flash.terminal.reaper", qos: .utility)

  static func poll(_ pid: pid_t) -> Bool {
    var status: Int32 = 0
    let result = flash_pty_wait(pid, &status)
    return result > 0 || (result < 0 && errno == ECHILD)
  }

  static func wait(
    pid: pid_t, timeoutMilliseconds: UInt64, poll: (pid_t) -> Bool = Self.poll
  ) -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutMilliseconds * 1_000_000
    repeat {
      if poll(pid) { return true }
      if DispatchTime.now().uptimeNanoseconds >= deadline { return false }
      usleep(5_000)
    } while true
  }

  static func reapLater(
    pid: pid_t, poll: @escaping (pid_t) -> Bool = Self.poll,
    completion: @escaping () -> Void
  ) {
    queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
      if poll(pid) {
        completion()
      } else {
        reapLater(pid: pid, poll: poll, completion: completion)
      }
    }
  }
}

public final class TerminalSession {
  public let configuration: TerminalConfiguration
  public private(set) var state: TerminalSessionState = .idle
  public private(set) var frame: TerminalFrame?
  public var onFrame: ((TerminalFrame) -> Void)?
  /// Queue-confined; see `setWantsFrames`.
  private var wantsFrames = true
  public var onInputRejected: ((Int) -> Void)?
  public var onStateChange: ((TerminalSessionState) -> Void)?
  public var onDiagnostic: ((TerminalSessionDiagnostic) -> Void)?
  private let queue = DispatchQueue(label: "com.flash.terminal.pty", qos: .userInitiated)
  private let queueKey = DispatchSpecificKey<Bool>()
  private let buffer: TerminalBuffer
  private var descriptor: Int32 = -1
  private var child: pid_t = 0
  private var reader: (any DispatchSourceRead)?
  private var writer: (any DispatchSourceWrite)?
  private var process: (any DispatchSourceProcess)?
  private var pending = Data()
  private var columns: Int
  private var rows: Int
  private var cellWidth: UInt32 = 1
  private var cellHeight: UInt32 = 1
  private var started = false
  private var scheduledFrame = false

  public init(configuration: TerminalConfiguration) {
    self.configuration = configuration
    queue.setSpecific(key: queueKey, value: true)
    columns = configuration.columns
    rows = configuration.rows
    buffer = TerminalBuffer(columns: columns, rows: rows, scrollback: true)
    buffer.connectOutput()
    buffer.output = { [weak self] data in self?.enqueue(data) }
  }
  deinit { shutdown() }

  public func start() { queue.async { [self] in startOnQueue() } }
  public func restart() {
    queue.async { [self] in
      stopOnQueue()
      started = false
      flash_vt_reset(buffer.handle)
      startOnQueue()
    }
  }
  public func stop(completion: (() -> Void)? = nil) {
    queue.async { [self] in
      stopOnQueue()
      if let completion { DispatchQueue.main.async(execute: completion) }
    }
  }
  /// Reaping uses two 200 ms deadlines; delayed kernel exits are reaped asynchronously.
  public func shutdown() {
    if DispatchQueue.getSpecific(key: queueKey) == true {
      stopOnQueue()
    } else {
      queue.sync { stopOnQueue() }
    }
  }
  public func resize(columns: Int, rows: Int) {
    let columns = max(1, min(1000, columns))
    let rows = max(1, min(1000, rows))
    queue.async { [self] in
      guard self.columns != columns || self.rows != rows else { return }
      self.columns = columns
      self.rows = rows
      flash_vt_resize(buffer.handle, UInt16(columns), UInt16(rows))
      if descriptor >= 0 {
        _ = flash_pty_resize_pixels(
          descriptor, UInt16(columns), UInt16(rows), cellWidth, cellHeight)
      }
      publishFrame()
    }
  }
  public func setCellSize(width: Int, height: Int) {
    let width = UInt32(clamping: max(1, width))
    let height = UInt32(clamping: max(1, height))
    queue.async { [self] in
      guard cellWidth != width || cellHeight != height else { return }
      cellWidth = width
      cellHeight = height
      flash_vt_cell_size(buffer.handle, width, height)
      if descriptor >= 0 {
        _ = flash_pty_resize_pixels(descriptor, UInt16(columns), UInt16(rows), width, height)
      }
    }
  }
  public func setColors(foreground: NSColor, background: NSColor) {
    let fg = foreground.terminalRGB
    let bg = background.terminalRGB
    queue.async { [self] in
      flash_vt_colors(buffer.handle, fg, bg)
      publishFrame()
    }
  }
  public func send(_ data: Data) { queue.async { [self] in enqueue(data) } }
  public func paste(_ text: String) {
    queue.async { [self] in
      var bytes = Array(text.utf8CString)
      let count = bytes.count - 1
      bytes.withUnsafeMutableBufferPointer { flash_vt_paste(buffer.handle, $0.baseAddress, count) }
    }
  }
  public func setFocused(_ focused: Bool) {
    queue.async { [self] in flash_vt_focus(buffer.handle, focused) }
  }
  public func scroll(lines: Int) {
    queue.async { [self] in
      flash_vt_scroll(buffer.handle, Int32(clamping: lines))
      publishFrame()
    }
  }
  public func key(code: UInt16, modifiers: UInt16, action: Int32, text: String, unshifted: UInt32) {
    queue.async { [self] in
      text.withCString {
        flash_vt_key(buffer.handle, code, modifiers, action, $0, text.utf8.count, unshifted)
      }
    }
  }
  public func mousePosition(action: Int32, button: Int32, modifiers: UInt16, x: Double, y: Double) {
    queue.async { [self] in flash_vt_mouse(buffer.handle, action, button, modifiers, x, y) }
  }

  private func startOnQueue() {
    guard !started else { return }
    started = true
    guard let command = configuration.command.first, !command.isEmpty,
      !configuration.command.contains(where: { $0.contains("\0") }),
      !configuration.environment.contains(where: {
        $0.key.contains("=") || $0.key.contains("\0") || $0.value.contains("\0")
      })
    else {
      publishState(.failed("Invalid terminal command or environment"))
      return
    }
    var environment = configuration.environment
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    let executable: String
    if command.contains("/") {
      executable = command
    } else {
      executable =
        (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        .split(separator: ":", omittingEmptySubsequences: false)
        .map { String($0) + "/" + command }
        .first { access($0, X_OK) == 0 } ?? command
    }
    let argv = configuration.command.map { strdup($0) } + [nil]
    let env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for pointer in argv { free(pointer) }
      for pointer in env { free(pointer) }
    }
    descriptor = argv.withUnsafeBufferPointer { args in
      env.withUnsafeBufferPointer { values in
        executable.withCString { path in
          if let directory = configuration.workingDirectory {
            return directory.withCString {
              flash_pty_spawn(
                path, args.baseAddress, values.baseAddress, $0,
                UInt16(columns), UInt16(rows), &child)
            }
          }
          return flash_pty_spawn(
            path, args.baseAddress, values.baseAddress, nil,
            UInt16(columns), UInt16(rows), &child)
        }
      }
    }
    guard descriptor >= 0 else {
      publishState(.failed(String(cString: strerror(errno))))
      return
    }
    let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    reader.setEventHandler { [weak self] in self?.readAvailable() }
    self.reader = reader
    let process = DispatchSource.makeProcessSource(
      identifier: child, eventMask: .exit, queue: queue)
    let pid = child
    process.setEventHandler { [weak self] in self?.childExited(expectedPID: pid) }
    self.process = process
    reader.resume()
    process.resume()
    publishState(.running(pid: child))
    publishFrame()
  }
  private func readAvailable() {
    guard descriptor >= 0 else { return }
    var bytes = [UInt8](repeating: 0, count: 32 * 1024)
    var consumed = 0
    while consumed < 256 * 1024 {
      let count = read(descriptor, &bytes, bytes.count)
      if count > 0 {
        buffer.write(Data(bytes.prefix(count)))
        consumed += count
      } else if count < 0 && errno == EINTR {
        continue
      } else {
        if count == 0 || (count < 0 && errno != EAGAIN) {
          reader?.cancel()
          reader = nil
        }
        break
      }
    }
    if consumed > 0 { scheduleFrame() }
  }
  private func enqueue(_ data: Data) {
    guard descriptor >= 0 else { return }
    // Bound input queued behind a child that stops reading its PTY.
    guard pending.count + data.count <= 4 * 1024 * 1024 else {
      DispatchQueue.main.async { [weak self] in self?.onInputRejected?(data.count) }
      return
    }
    pending.append(data)
    flushWrites()
  }
  private func flushWrites() {
    guard descriptor >= 0 else { return }
    while !pending.isEmpty {
      let count = pending.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
      if count > 0 {
        pending.removeFirst(count)
      } else if count < 0 && errno == EINTR {
        continue
      } else {
        break
      }
    }
    if pending.isEmpty {
      writer?.cancel()
      writer = nil
    } else if writer == nil {
      let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
      source.setEventHandler { [weak self] in self?.flushWrites() }
      writer = source
      source.resume()
    }
  }
  private func childExited(expectedPID: pid_t) {
    guard child == expectedPID, child > 0 else { return }
    readAvailable()
    var status: Int32 = 0
    let result = flash_pty_wait(child, &status)
    if result < 0 && errno != EINTR {
      child = 0
      closeSources()
      publishFrame()
      publishState(.failed("Terminal child exit status is unavailable"))
      return
    }
    guard result > 0 else {
      queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
        self?.childExited(expectedPID: expectedPID)
      }
      return
    }
    flash_pty_signal(descriptor, child, SIGKILL, false)
    child = 0
    closeSources()
    publishFrame()
    publishState(.exited(code: status))
  }
  private func closeSources() {
    reader?.cancel()
    reader = nil
    writer?.cancel()
    writer = nil
    process?.cancel()
    process = nil
    if descriptor >= 0 {
      close(descriptor)
      descriptor = -1
    }
    pending.removeAll(keepingCapacity: false)
  }
  private func stopOnQueue() {
    let pid = child
    if pid > 0 {
      flash_pty_signal(descriptor, pid, SIGHUP, true)
      flash_pty_signal(descriptor, pid, SIGTERM, true)
      let reaped = TerminalChildReaping.wait(pid: pid, timeoutMilliseconds: 200)
      // Group members can outlive their leader. Never signal its PID after reaping it.
      flash_pty_signal(descriptor, pid, SIGKILL, !reaped)
      child = 0
      // Closing the master and cancelling the process source must precede final reaping.
      closeSources()
      if !reaped && !TerminalChildReaping.wait(pid: pid, timeoutMilliseconds: 200) {
        let diagnostic = onDiagnostic
        DispatchQueue.main.async { diagnostic?(.reapDeferred(pid: pid)) }
        TerminalChildReaping.reapLater(pid: pid) {
          DispatchQueue.main.async { diagnostic?(.reaped(pid: pid)) }
        }
      }
    } else {
      closeSources()
    }
    publishState(.stopped)
  }
  private func publishState(_ state: TerminalSessionState) {
    DispatchQueue.main.async { [weak self] in
      self?.state = state
      self?.onStateChange?(state)
    }
  }
  /// Whether anything consumes frames. A hidden persistent popup keeps
  /// parsing output but skips the per-frame grid snapshot (one `String` per
  /// cell) and the main-thread hop; re-enabling publishes one frame at once.
  public func setWantsFrames(_ wants: Bool) {
    queue.async { [weak self] in
      guard let self, self.wantsFrames != wants else { return }
      self.wantsFrames = wants
      if wants { self.publishFrame() }
    }
  }

  private func scheduleFrame() {
    guard wantsFrames, !scheduledFrame else { return }
    scheduledFrame = true
    queue.asyncAfter(deadline: .now() + .milliseconds(33)) { [weak self] in
      guard let self else { return }
      self.scheduledFrame = false
      self.publishFrame()
    }
  }
  private func publishFrame() {
    guard wantsFrames, let snapshot = buffer.snapshot() else { return }
    DispatchQueue.main.async { [weak self] in
      self?.frame = snapshot
      self?.onFrame?(snapshot)
    }
  }
}
