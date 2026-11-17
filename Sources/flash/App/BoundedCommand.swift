import Darwin
import FlashTerminal
import Foundation

/// A short command run to completion, bounded: the resident's one way to run
/// a tool and read its answer (`git`, `mise which`, `sandbox-exec`,
/// `activateSettings`, `sysadminctl`, `ditto`, `open`, `:!`).
///
/// - It spawns through `ProcessGroupSpawn`, so it leads its own process group.
/// - Output is drained as it arrives, up to `outputLimit` per stream; the
///   rest is read and dropped, so a chatty command never blocks on a full
///   pipe.
/// - Past `timeout`, its whole group gets SIGTERM, then SIGKILL after
///   `terminationGraceMs`: a timed-out `git fetch` takes its helpers with it.
/// - The run ends when the leader exits. What it wrote is read; a background
///   child it left holding the pipe is neither waited for nor killed.
///
/// It blocks the calling thread on a kqueue, never on the shared dispatch
/// pool, so a saturated pool cannot starve it into its timeout. Never call it
/// on main.
enum BoundedCommand {
  /// Which output streams are read; the others go to `/dev/null`.
  enum Capture: Equatable {
    case none
    case stdout
    case stderr
    /// stdout and stderr interleaved into `output`.
    case merged
    case separate
  }

  struct Result: Equatable {
    /// The exit status as a shell reports it (code, or 128 + signal); nil
    /// when the command did not start.
    var status: Int32?
    /// stdout, or both streams for `.merged`.
    var output = Data()
    /// stderr for `.stderr` and `.separate`.
    var errorOutput = Data()
    /// A stream passed `outputLimit` and was cut there.
    var truncated = false
    var timedOut = false
    /// Why it did not start.
    var launchFailure: String?

    var succeeded: Bool { status == 0 && !timedOut }
    var text: String { String(decoding: output, as: UTF8.self) }
    var errorText: String { String(decoding: errorOutput, as: UTF8.self) }
  }

  static let terminationGraceMs = 500
  static let defaultOutputLimit = 1 << 20

  static func run(
    _ argv: [String], environment: [String: String], directory: String? = nil,
    timeout: TimeInterval?, capture: Capture = .stdout, outputLimit: Int = defaultOutputLimit
  ) -> Result {
    var out: [Int32] = [-1, -1]
    var err: [Int32] = [-1, -1]
    let readsOut = capture == .stdout || capture == .merged || capture == .separate
    let readsErr = capture == .stderr || capture == .separate
    func closeAll() {
      for descriptor in out + err where descriptor >= 0 { close(descriptor) }
    }
    if readsOut, pipe(&out) != 0 {
      return Result(status: nil, launchFailure: "pipe: \(String(cString: strerror(errno)))")
    }
    if readsErr, pipe(&err) != 0 {
      closeAll()
      return Result(status: nil, launchFailure: "pipe: \(String(cString: strerror(errno)))")
    }
    let stdoutSink: ProcessGroupSpawn.Sink = readsOut ? .descriptor(out[1]) : .devNull
    let stderrSink: ProcessGroupSpawn.Sink =
      capture == .merged ? .descriptor(out[1]) : readsErr ? .descriptor(err[1]) : .devNull
    let pid: pid_t
    do {
      pid = try ProcessGroupSpawn.spawn(
        argv: argv, environment: environment, workingDirectory: directory,
        stdout: stdoutSink, stderr: stderrSink, closeInChild: (out + err).filter { $0 >= 0 })
    } catch {
      closeAll()
      return Result(
        status: nil, launchFailure: "\(argv.first ?? ""): \(error.localizedDescription)")
    }
    // The child holds the write ends now; the parent keeps only what it reads.
    for descriptor in [out[1], err[1]] where descriptor >= 0 { close(descriptor) }
    var streams: [Int32: Bool] = [:]  // read end → is stderr
    if readsOut { streams[out[0]] = false }
    if readsErr { streams[err[0]] = true }
    var result = Result(status: nil)
    supervise(pid: pid, streams: streams, timeout: timeout, outputLimit: outputLimit, into: &result)
    result.status = ProcessExit.reap(pid)
    return result
  }

  /// Read `streams` until `pid` exits, signalling its group past `timeout`,
  /// and close every stream. Sets `timedOut`, and `launchFailure` when the
  /// run could not be watched at all (no kqueue: the group is killed).
  private static func supervise(
    pid: pid_t, streams: [Int32: Bool], timeout: TimeInterval?, outputLimit: Int,
    into result: inout Result
  ) {
    var open = Set(streams.keys)
    defer { for descriptor in open { close(descriptor) } }
    let queue = kqueue()
    guard queue >= 0 else {
      // Only descriptor exhaustion gets here: nothing can bound the wait, so
      // the run ends now.
      result.launchFailure = "kqueue: \(String(cString: strerror(errno)))"
      kill(-pid, SIGKILL)
      return
    }
    defer { close(queue) }
    for descriptor in open {
      _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
      var change = kevent(
        ident: UInt(descriptor), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0,
        data: 0, udata: nil)
      _ = kevent(queue, &change, 1, nil, 0, nil)
    }
    var exited = false
    var exitWatch = kevent(
      ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD),
      fflags: NOTE_EXIT, data: 0, udata: nil)
    if kevent(queue, &exitWatch, 1, nil, 0, nil) < 0 { exited = true }  // already gone
    let start = DispatchTime.now().uptimeNanoseconds
    let deadline = timeout.map { start + UInt64(max(0, $0) * 1_000_000_000) }
    var killAt: UInt64?
    var events = Array(
      repeating: kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil), count: 8)
    while !exited {
      let now = DispatchTime.now().uptimeNanoseconds
      if let deadline, !result.timedOut, now >= deadline {
        result.timedOut = true
        kill(-pid, SIGTERM)
        killAt = now + UInt64(terminationGraceMs) * 1_000_000
      }
      if let at = killAt, now >= at {
        kill(-pid, SIGKILL)
        killAt = nil
      }
      let wake = result.timedOut ? killAt : deadline
      var interval = timespec()
      if let wake {
        let remaining = wake > now ? wake - now : 0
        interval = timespec(
          tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
      }
      let count = withUnsafeMutablePointer(to: &interval) { pointer in
        kevent(queue, nil, 0, &events, Int32(events.count), wake == nil ? nil : pointer)
      }
      if count < 0 {
        if errno == EINTR { continue }
        break
      }
      for event in events.prefix(Int(count)) {
        if event.filter == Int16(EVFILT_PROC) {
          exited = true
          continue
        }
        let descriptor = Int32(event.ident)
        guard open.contains(descriptor) else { continue }
        if !read(
          descriptor, isError: streams[descriptor] ?? false, limit: outputLimit, into: &result)
        {
          open.remove(descriptor)
          close(descriptor)
        }
      }
    }
    // The leader is gone: take what it wrote, without waiting on a child that
    // may still hold the pipe.
    for descriptor in open {
      _ = read(descriptor, isError: streams[descriptor] ?? false, limit: outputLimit, into: &result)
    }
  }

  /// Read what `descriptor` holds now. False once it reached end of file.
  private static func read(
    _ descriptor: Int32, isError: Bool, limit: Int, into result: inout Result
  ) -> Bool {
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count > 0 {
        let kept = isError ? result.errorOutput.count : result.output.count
        let room = max(0, limit - kept)
        if count > room { result.truncated = true }
        if room > 0 {
          if isError {
            result.errorOutput.append(contentsOf: buffer.prefix(min(count, room)))
          } else {
            result.output.append(contentsOf: buffer.prefix(min(count, room)))
          }
        }
      } else if count == 0 {
        return false
      } else if errno == EINTR {
        continue
      } else {
        return errno == EAGAIN || errno == EWOULDBLOCK
      }
    }
  }
}
