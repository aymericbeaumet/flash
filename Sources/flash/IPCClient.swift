import AppKit
import Darwin
import Foundation

/// The CLI's end of the resident's socket (`IPCServer`): one blocking
/// connection, every wait bounded by a deadline except an event stream's.
final class IPCClient {
  enum Failure: Error, Equatable, CustomStringConvertible {
    /// The resident closed the connection before answering.
    case closed
    case timedOut(String)
    /// The resident sent something this CLI cannot read.
    case unreadable(String)
    /// The resident answered with an `error`.
    case refused(code: String, message: String)
    case io(String)

    var description: String {
      switch self {
      case .closed: return "the resident closed the connection"
      case .timedOut(let what): return "the resident did not answer \(what) in time"
      case .unreadable(let what): return "the resident sent \(what)"
      case .refused(_, let message): return message
      case .io(let what): return what
      }
    }
  }

  /// How long `hello` may take: the resident answers it on its own queue.
  static let handshakeTimeout: TimeInterval = 10
  /// How long a command may run: a confirmation, a plugin or the doctor's
  /// checks can take a while.
  static let replyTimeout: TimeInterval = 5 * 60

  private let fd: Int32
  private var reader = IPCFrameReader(maxFrameBytes: IPCProtocol.maxOutboundFrameBytes)
  private var pending: [Data] = []
  private var lastID = 0

  init(fd: Int32) {
    self.fd = fd
  }

  deinit {
    close(fd)
  }

  /// One attempt to reach the socket, refusing a server that does not run
  /// as this user.
  static func connect(_ endpoint: IPCEndpoint) -> ResidentConnector.Attempt<IPCClient> {
    let address: sockaddr_un
    do {
      address = try endpoint.address()
    } catch {
      return .failed("\(error)")
    }
    guard let fd = IPCSocket.make() else {
      return .failed("socket: \(String(cString: strerror(errno)))")
    }
    let status = IPCSocket.connect(fd, to: address)
    guard status == 0 else {
      close(fd)
      if status == ENOENT || status == ECONNREFUSED { return .absent }
      return .failed("\(endpoint.socketPath): \(String(cString: strerror(status)))")
    }
    guard IPCSocket.admits(peer: IPCSocket.peerUID(fd)) else {
      close(fd)
      return .failed("\(endpoint.socketPath) is served by another account")
    }
    return .connected(IPCClient(fd: fd))
  }

  /// Say `hello`; the resident's name once it answers `welcome`.
  func hello(client: String) throws -> String {
    try send(IPCProtocol.helloMessage(client: client))
    let deadline = ProcessInfo.processInfo.systemUptime + Self.handshakeTimeout
    while true {
      let frame = try nextFrame(until: deadline, what: "hello")
      switch IPCProtocol.decodeServerMessage(frame) {
      case .welcome(let version, let server):
        guard version == IPCProtocol.version else {
          throw Failure.unreadable("protocol \(version); this flash speaks \(IPCProtocol.version)")
        }
        return server
      case .error(let code, let message, _):
        throw Failure.refused(code: code, message: Self.explain(code: code, message: message))
      default:
        throw Failure.unreadable("something other than welcome")
      }
    }
  }

  /// Run `words` as `:<words>` and wait for how it ended.
  func request(words: [String], directory: String?) throws -> CommandInvocationResult {
    let id = nextID()
    try send(IPCProtocol.requestMessage(id: id, words: words, cwd: directory))
    let deadline = ProcessInfo.processInfo.systemUptime + Self.replyTimeout
    while true {
      let frame = try nextFrame(until: deadline, what: words.joined(separator: " "))
      switch IPCProtocol.decodeServerMessage(frame) {
      case .result(id, let result):
        return result
      case .error(let code, let message, let errorID) where errorID == nil || errorID == id:
        throw Failure.refused(code: code, message: Self.explain(code: code, message: message))
      case nil:
        throw Failure.unreadable("an unreadable line")
      default:
        continue
      }
    }
  }

  /// Subscribe to `events` (globs) and hand each `event` line, as sent, to
  /// `emit` until it returns false, `count` events went out, or the stream
  /// ends. Returns the CLI's exit status.
  func watch(events: [String], count: Int?, emit: (Data) -> Bool) throws -> Int32 {
    let id = nextID()
    try send(IPCProtocol.subscribeMessage(id: id, events: events))
    let deadline = ProcessInfo.processInfo.systemUptime + Self.handshakeTimeout
    subscribing: while true {
      let frame = try nextFrame(until: deadline, what: "subscribe")
      switch IPCProtocol.decodeServerMessage(frame) {
      case .subscribed(id, _):
        break subscribing
      case .error(let code, let message, _):
        throw Failure.refused(code: code, message: Self.explain(code: code, message: message))
      default:
        continue
      }
    }
    var emitted = 0
    if let count, count <= 0 { return 0 }
    while true {
      let frame = try nextFrame(until: nil, what: "events")
      switch IPCProtocol.decodeServerMessage(frame) {
      case .event:
        guard emit(frame) else { return 0 }
        emitted += 1
        if let count, emitted >= count { return 0 }
      case .error(let code, let message, nil):
        throw Failure.refused(code: code, message: Self.explain(code: code, message: message))
      default:
        continue
      }
    }
  }

  private func nextID() -> String {
    lastID += 1
    return String(lastID)
  }

  private func send(_ object: [String: Any]) throws {
    let frame = IPCProtocol.frame(object)
    var offset = 0
    while offset < frame.count {
      let written = frame.withUnsafeBytes { raw in
        Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
      }
      if written < 0 {
        if errno == EINTR { continue }
        throw errno == EPIPE ? Failure.closed : Failure.io(String(cString: strerror(errno)))
      }
      offset += written
    }
  }

  /// The next line, waiting until `deadline` (systemUptime seconds; nil
  /// waits for as long as the resident keeps the connection).
  private func nextFrame(until deadline: TimeInterval?, what: String) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while pending.isEmpty {
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let timeout: Int32
      if let deadline {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw Failure.timedOut(what) }
        timeout = Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up))
      } else {
        timeout = -1
      }
      let ready = poll(&descriptor, 1, timeout)
      if ready < 0 {
        if errno == EINTR { continue }
        throw Failure.io(String(cString: strerror(errno)))
      }
      if ready == 0 { continue }
      let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count == 0 { throw Failure.closed }
      if count < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        throw Failure.io(String(cString: strerror(errno)))
      }
      for output in reader.append(Data(buffer[0..<count])) {
        switch output {
        case .frame(let frame): pending.append(frame)
        case .tooLarge: throw Failure.unreadable("a line longer than it may be")
        }
      }
    }
    return pending.removeFirst()
  }

  /// What an error code means to someone at a terminal.
  static func explain(code: String, message: String) -> String {
    switch IPCProtocol.ErrorCode(rawValue: code) {
    case .protocolMismatch:
      return "\(message); this flash speaks protocol \(IPCProtocol.version): run the flash of the "
        + "running Flash, or quit and reopen Flash"
    case .overflow:
      return "the event stream fell behind and was closed: \(message)"
    case .shuttingDown:
      return "Flash quit"
    default:
      return message
    }
  }
}

/// Reaching the resident from the CLI: its socket if it answers; otherwise,
/// when the CLI may start it and no resident runs, the app bundle the CLI
/// lives in, opened through Launch Services, then a wait for the socket
/// bounded by `startDeadline`. The wait is a kqueue on the socket's
/// directory, never a poll: the resident renames its socket into place
/// once it accepts, so each directory change is the moment to try again.
enum ResidentConnector {
  /// How long a resident may take to start answering.
  static let startDeadline: TimeInterval = 15

  enum Attempt<Connection> {
    case connected(Connection)
    /// Nothing listens there (no socket, or a stale one).
    case absent
    case failed(String)
  }

  enum Outcome<Connection> {
    case connected(Connection)
    /// No resident runs and the CLI did not start one.
    case notRunning
    case launchFailed(String)
    /// A resident was started and did not answer within `seconds`.
    case didNotStart(seconds: TimeInterval)
    /// A resident runs but its socket did not answer within `seconds`.
    case notAnswering(seconds: TimeInterval)
    case failed(String)
  }

  /// The effects `connect` uses, injected by tests.
  struct Seams<Connection> {
    var attempt: () -> Attempt<Connection>
    var residentRunning: () -> Bool
    /// The app bundle to open, or nil when the CLI runs outside one.
    var bundle: () -> URL?
    /// Open the bundle; nil on success, else why it failed.
    var launch: (URL) -> String?
    /// Start noticing changes to the socket's directory; nil on success.
    var watch: () -> String?
    /// Block until the directory changes or `seconds` pass.
    var wait: (_ seconds: TimeInterval) -> Void
    var now: () -> TimeInterval
  }

  static func connect<Connection>(
    launching: Bool, deadline: TimeInterval = startDeadline, seams: Seams<Connection>
  ) -> Outcome<Connection> {
    switch seams.attempt() {
    case .connected(let connection): return .connected(connection)
    case .failed(let reason): return .failed(reason)
    case .absent: break
    }
    let running = seams.residentRunning()
    var bundle: URL?
    if !running {
      guard launching, let found = seams.bundle() else { return .notRunning }
      bundle = found
    }
    // Watch before launching or trying again, so the socket's arrival
    // cannot fall between a failed attempt and the wait.
    if let problem = seams.watch() { return .failed(problem) }
    if let bundle, let problem = seams.launch(bundle) { return .launchFailed(problem) }
    let start = seams.now()
    while true {
      switch seams.attempt() {
      case .connected(let connection): return .connected(connection)
      case .failed(let reason): return .failed(reason)
      case .absent: break
      }
      let remaining = deadline - (seams.now() - start)
      guard remaining > 0 else {
        return running ? .notAnswering(seconds: deadline) : .didNotStart(seconds: deadline)
      }
      seams.wait(remaining)
    }
  }

  /// The real effects: the socket at `endpoint`, Launch Services, a
  /// kqueue on the socket's directory.
  static func live(_ endpoint: IPCEndpoint, bundle: @escaping () -> URL?) -> Seams<IPCClient> {
    let watcher = DirectoryWatch()
    return Seams(
      attempt: { IPCClient.connect(endpoint) },
      residentRunning: {
        !NSRunningApplication.runningApplications(withBundleIdentifier: residentBundleID).isEmpty
      },
      bundle: bundle,
      launch: launch,
      watch: {
        do {
          try endpoint.prepareDirectory()
        } catch {
          return "\(error)"
        }
        return watcher.start(endpoint.directory.path)
      },
      wait: { watcher.wait($0) },
      now: { ProcessInfo.processInfo.systemUptime })
  }

  static let residentBundleID = "com.flash.app"

  /// Open the resident's bundle in the background: no activation, no
  /// recent-items entry, no arguments (with arguments the binary is a CLI).
  private static func launch(_ bundle: URL) -> String? {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.createsNewApplicationInstance = false
    let done = DispatchSemaphore(value: 0)
    var failure: String?
    NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
      failure = error?.localizedDescription
      done.signal()
    }
    guard done.wait(timeout: .now() + startDeadline) == .success else {
      return "Launch Services did not open \(bundle.path)"
    }
    return failure
  }
}

/// A kqueue on one directory: `wait` returns when an entry is added,
/// removed or renamed, or when the time is up.
private final class DirectoryWatch {
  private var queue: Int32 = -1
  private var directory: Int32 = -1

  func start(_ path: String) -> String? {
    guard queue < 0 else { return nil }
    directory = open(path, O_EVTONLY | O_CLOEXEC)
    guard directory >= 0 else { return "\(path): \(String(cString: strerror(errno)))" }
    queue = kqueue()
    guard queue >= 0 else { return "kqueue: \(String(cString: strerror(errno)))" }
    var change = kevent(
      ident: UInt(directory), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
      fflags: UInt32(NOTE_WRITE), data: 0, udata: nil)
    guard kevent(queue, &change, 1, nil, 0, nil) >= 0 else {
      return "kevent: \(String(cString: strerror(errno)))"
    }
    return nil
  }

  func wait(_ seconds: TimeInterval) {
    guard queue >= 0 else { return }
    let clamped = max(0, seconds)
    var timeout = timespec(
      tv_sec: Int(clamped), tv_nsec: Int((clamped - clamped.rounded(.down)) * 1_000_000_000))
    var event = kevent()
    _ = kevent(queue, nil, 0, &event, 1, &timeout)
  }

  deinit {
    if queue >= 0 { close(queue) }
    if directory >= 0 { close(directory) }
  }
}
