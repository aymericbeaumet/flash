import Darwin
import Foundation

/// The resident's IPC listener (hard constraint 4): one Unix domain socket
/// at `IPCEndpoint.standard`, speaking `IPCProtocol` to the user's own
/// processes. Every request runs through `runner`, the command line's one
/// runner; every subscription goes to `subscriptions` (`IPCEventHub`), which
/// hands matching host events back through `deliver`.
///
/// Event-driven throughout: a read source accepts, one read source per
/// connection reads, and a write source is resumed only while a connection
/// has bytes the socket did not take. No timer and no poll; the handshake
/// deadline is a one-shot bounding one operation. Connections, their
/// in-flight requests, line length and each subscriber's backlog are all
/// bounded (`IPCProtocol.Limits`).
///
/// Queue-confined to `queue` (`.userInitiated`: the CLI waits on it).
/// `runner` and `subscriptions` are called on `callbackQueue` (main in the
/// resident) and must call their completions exactly once, on any queue.
final class IPCServer {
  /// Run `invocation` (the request arrived at `arrivedAt`, systemUptime
  /// seconds) and complete once with its result.
  typealias Runner = (
    _ invocation: CommandInvocation, _ arrivedAt: TimeInterval,
    _ completion: @escaping (CommandInvocationResult) -> Void
  ) -> Void
  /// `connection` now subscribes to `events`; nil when it went away. `done`
  /// runs once the subscription is in effect.
  typealias SubscriptionSink = (
    _ connection: UInt64, _ events: [String]?, _ done: @escaping () -> Void
  ) -> Void

  enum StartError: Error, Equatable, CustomStringConvertible {
    case endpoint(IPCEndpoint.Problem)
    /// Another process already accepts on the path: never take it over.
    case inUse(String)
    case system(String, errno: Int32)

    var description: String {
      switch self {
      case .endpoint(let problem): return problem.description
      case .inUse(let path): return "another process already listens on \(path)"
      case .system(let call, let code): return "\(call): \(String(cString: strerror(code)))"
      }
    }
  }

  let endpoint: IPCEndpoint
  let limits: IPCProtocol.Limits
  private let welcome: Data
  private let runner: Runner
  private let subscriptions: SubscriptionSink
  private let callbackQueue: DispatchQueue
  private let queue = DispatchQueue(label: "flash.ipc", qos: .userInitiated)

  private var acceptSource: DispatchSourceRead?
  private var connections: [UInt64: Connection] = [:]
  private var lastConnectionID: UInt64 = 0
  /// The socket file this server created, so `stop` unlinks only its own.
  private var socketIdentity: (device: dev_t, inode: ino_t)?
  private var stopped = false

  private final class Connection {
    let id: UInt64
    let fd: Int32
    var session: IPCSession
    var reader: IPCFrameReader
    var outbox: IPCOutbox
    let readSource: DispatchSourceRead
    let writeSource: DispatchSourceWrite
    var writing = false
    /// The resident is closing it: nothing more is read or admitted, and
    /// it goes once what it is owed is written, or `closeGraceMs` passed.
    var closing = false
    var lingering = false
    /// It subscribed once: the hub must forget it when it goes.
    var subscribed = false
    /// Its subscription names events now.
    var streaming = false
    /// The peer sent EOF (`printf … | nc -U` does once its input ends):
    /// replies owed to requests in flight still go out, then it closes.
    var inputEnded = false

    init(id: UInt64, fd: Int32, welcome: Data, limits: IPCProtocol.Limits, queue: DispatchQueue) {
      self.id = id
      self.fd = fd
      session = IPCSession(welcome: welcome, maxInFlightRequests: limits.maxInFlightRequests)
      reader = IPCFrameReader(maxFrameBytes: limits.maxInboundFrameBytes)
      outbox = IPCOutbox(
        maxEvents: limits.maxQueuedEvents, maxEventBytes: limits.maxQueuedEventBytes)
      readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
    }
  }

  init(
    endpoint: IPCEndpoint, serverName: String, limits: IPCProtocol.Limits = .standard,
    callbackQueue: DispatchQueue = .main, runner: @escaping Runner,
    subscriptions: @escaping SubscriptionSink
  ) {
    self.endpoint = endpoint
    self.limits = limits
    self.welcome = IPCProtocol.welcomeFrame(
      server: serverName, pid: ProcessInfo.processInfo.processIdentifier, limits: limits)
    self.callbackQueue = callbackQueue
    self.runner = runner
    self.subscriptions = subscriptions
  }

  /// Bind and listen. The socket is bound under a staging name, made
  /// `0600`, set listening and only then renamed over the path, replacing a
  /// stale socket a crashed resident left: a client that finds the path can
  /// connect at once.
  func start() throws {
    try queue.sync { try startOnQueue() }
  }

  private func startOnQueue() throws {
    do {
      try endpoint.prepareDirectory()
    } catch let problem as IPCEndpoint.Problem {
      throw StartError.endpoint(problem)
    }
    let address: sockaddr_un
    let staging: sockaddr_un
    do {
      address = try endpoint.address()
      staging = try endpoint.address(of: IPCEndpoint.stagingName)
    } catch let problem as IPCEndpoint.Problem {
      throw StartError.endpoint(problem)
    }
    if let probe = IPCSocket.make() {
      let status = IPCSocket.connect(probe, to: address)
      close(probe)
      if status == 0 { throw StartError.inUse(endpoint.socketPath) }
    }
    guard let fd = IPCSocket.make() else { throw StartError.system("socket", errno: errno) }
    let stagingPath = endpoint.directory.appendingPathComponent(IPCEndpoint.stagingName).path
    unlink(stagingPath)
    func fail(_ call: String) -> StartError {
      let code = errno
      close(fd)
      unlink(stagingPath)
      return .system(call, errno: code)
    }
    let bound = IPCSocket.bind(fd, to: staging)
    guard bound == 0 else {
      errno = bound
      throw fail("bind")
    }
    guard chmod(stagingPath, 0o600) == 0 else { throw fail("chmod") }
    guard listen(fd, Int32(limits.maxConnections)) == 0 else { throw fail("listen") }
    IPCSocket.setNonBlocking(fd)
    guard rename(stagingPath, endpoint.socketPath) == 0 else { throw fail("rename") }
    var info = stat()
    if lstat(endpoint.socketPath, &info) == 0 {
      socketIdentity = (info.st_dev, info.st_ino)
    }
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.acceptPending(fd) }
    source.setCancelHandler { close(fd) }
    source.resume()
    acceptSource = source
    FlashLog.info("[ipc] listening", fields: ["path": endpoint.socketPath])
  }

  /// Close every connection (each first sends what the socket takes now:
  /// the reply to `resident quit`, then `shutting_down`), stop accepting and
  /// remove the socket file if it is still this server's.
  func stop() {
    queue.sync {
      guard !stopped else { return }
      stopped = true
      acceptSource?.cancel()
      acceptSource = nil
      for connection in connections.values.sorted(by: { $0.id < $1.id }) {
        _ = connection.outbox.drain { IPCSocket.writeAvailable(connection.fd, $0) }
        connection.outbox.replaceWithFinal(
          IPCProtocol.errorFrame(.shuttingDown, "Flash is quitting"))
        _ = connection.outbox.drain { IPCSocket.writeAvailable(connection.fd, $0) }
        teardown(connection, reason: "stop")
      }
      var info = stat()
      if let identity = socketIdentity, lstat(endpoint.socketPath, &info) == 0,
        info.st_dev == identity.device, info.st_ino == identity.inode
      {
        unlink(endpoint.socketPath)
      }
      socketIdentity = nil
    }
  }

  /// Hand an encoded `event` to `connections`; called by the event hub.
  func deliver(_ frame: Data, coalescingKey: String?, to ids: [UInt64]) {
    queue.async { [self] in
      for id in ids {
        guard let connection = connections[id], connection.subscribed, !connection.closing
        else { continue }
        if connection.outbox.enqueueEvent(frame, coalescingKey: coalescingKey) == .overflow {
          FlashLog.info(
            "[ipc] subscriber_overflow",
            fields: ["connection": String(id), "queued": String(connection.outbox.count)])
          connection.outbox.replaceWithFinal(
            IPCProtocol.errorFrame(
              .overflow,
              "more than \(limits.maxQueuedEvents) events waited unread; reconnect"))
          connection.closing = true
        }
        flush(connection)
      }
    }
  }

  /// Open connections, for diagnostics and tests.
  func connectionCount(_ completion: @escaping (Int) -> Void) {
    queue.async { [self] in completion(connections.count) }
  }

  // MARK: - Connections

  private func acceptPending(_ listener: Int32) {
    while !stopped {
      let fd = accept(listener, nil, nil)
      if fd < 0 {
        if errno == EINTR { continue }
        return
      }
      admit(fd)
    }
  }

  private func admit(_ fd: Int32) {
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var on: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    IPCSocket.setNonBlocking(fd)
    let peer = IPCSocket.peerUID(fd)
    guard IPCSocket.admits(peer: peer) else {
      FlashLog.info(
        "[ipc] refused_peer", fields: ["uid": peer.map { String($0) } ?? "unknown"])
      close(fd)
      return
    }
    guard connections.count < limits.maxConnections else {
      FlashLog.info("[ipc] refused_connection", fields: ["open": String(connections.count)])
      IPCProtocol.errorFrame(
        .tooManyConnections, "\(limits.maxConnections) connections are already open"
      ).withUnsafeBytes { _ = IPCSocket.writeAvailable(fd, $0) }
      close(fd)
      return
    }
    lastConnectionID &+= 1
    let connection = Connection(
      id: lastConnectionID, fd: fd, welcome: welcome, limits: limits, queue: queue)
    connections[connection.id] = connection
    // Both sources watch the descriptor: it closes once both are cancelled.
    let closer = DescriptorCloser(fd: fd, sources: 2)
    let release: () -> Void = { closer.release() }
    connection.readSource.setEventHandler { [weak self, weak connection] in
      guard let self, let connection else { return }
      self.readAvailable(connection)
    }
    connection.readSource.setCancelHandler(handler: release)
    connection.writeSource.setEventHandler { [weak self, weak connection] in
      guard let self, let connection else { return }
      self.flush(connection)
    }
    connection.writeSource.setCancelHandler(handler: release)
    connection.readSource.resume()
    // A timeout bounding one operation: hello arrives, or the connection goes.
    let id = connection.id
    queue.asyncAfter(deadline: .now() + .milliseconds(limits.handshakeTimeoutMs)) {
      [weak self] in
      guard let self, let connection = self.connections[id] else { return }
      self.perform(connection.session.handshakeExpired(), on: connection, arrivedAt: 0)
    }
    FlashLog.debug("[ipc] connected", fields: ["connection": String(id)])
  }

  private func readAvailable(_ connection: Connection) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while connections[connection.id] != nil {
      let count = buffer.withUnsafeMutableBytes { read(connection.fd, $0.baseAddress, $0.count) }
      if count == 0 { return endInput(connection) }
      if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { return }
        return teardown(connection, reason: "read_failed")
      }
      // A closing connection's input is read and dropped.
      guard !connection.closing else { continue }
      let arrivedAt = ProcessInfo.processInfo.systemUptime
      for output in connection.reader.append(Data(buffer[0..<count])) {
        guard connections[connection.id] != nil, !connection.closing else { break }
        perform(connection.session.receive(output), on: connection, arrivedAt: arrivedAt)
      }
    }
  }

  /// EOF from the peer: it sends nothing more but may still read. A
  /// subscription ends with it; the results of requests in flight are
  /// written before the connection closes.
  private func endInput(_ connection: Connection) {
    connection.inputEnded = true
    connection.readSource.cancel()
    guard !connection.streaming, !connection.session.inFlight.isEmpty else {
      return teardown(connection, reason: "eof")
    }
  }

  private func perform(
    _ actions: [IPCSession.Action], on connection: Connection, arrivedAt: TimeInterval
  ) {
    guard !actions.isEmpty else { return }
    let connectionID = connection.id
    for action in actions {
      switch action {
      case .send(let frame):
        connection.outbox.enqueueReply(frame)
      case .close:
        connection.closing = true
      case .run(let requestID, let invocation):
        callbackQueue.async { [weak self, runner] in
          runner(invocation, arrivedAt) { result in
            self?.queue.async { self?.finish(connectionID, requestID, result) }
          }
        }
      case .subscribe(let requestID, let events):
        connection.subscribed = true
        connection.streaming = !events.isEmpty
        callbackQueue.async { [weak self, subscriptions] in
          subscriptions(connectionID, events) {
            self?.queue.async { self?.acknowledge(connectionID, requestID, events) }
          }
        }
      }
    }
    flush(connection)
  }

  private func finish(
    _ connectionID: UInt64, _ requestID: String, _ result: CommandInvocationResult
  ) {
    guard let connection = connections[connectionID], !connection.closing else { return }
    connection.session.finished(id: requestID)
    var frame = IPCProtocol.resultFrame(id: requestID, result: result)
    if frame.count - 1 > limits.maxOutboundFrameBytes {
      frame = IPCProtocol.errorFrame(
        .replyTooLarge, "the result is larger than \(limits.maxOutboundFrameBytes) bytes",
        id: requestID)
    }
    connection.outbox.enqueueReply(frame)
    if connection.inputEnded, connection.session.inFlight.isEmpty { connection.closing = true }
    flush(connection)
  }

  private func acknowledge(_ connectionID: UInt64, _ requestID: String, _ events: [String]) {
    guard let connection = connections[connectionID], !connection.closing else { return }
    connection.outbox.enqueueReply(IPCProtocol.subscribedFrame(id: requestID, events: events))
    flush(connection)
  }

  /// Write what the socket takes; the write source finishes the rest. A
  /// closing connection goes once it is written, or `closeGraceMs` later:
  /// a peer that stopped reading cannot hold its slot.
  private func flush(_ connection: Connection) {
    guard connections[connection.id] != nil else { return }
    let ok = connection.outbox.drain { IPCSocket.writeAvailable(connection.fd, $0) }
    if !ok { return teardown(connection, reason: "write_failed") }
    if connection.outbox.isEmpty {
      if connection.closing { return teardown(connection, reason: "closed") }
      if connection.writing {
        connection.writeSource.suspend()
        connection.writing = false
      }
      return
    }
    if !connection.writing {
      connection.writeSource.resume()
      connection.writing = true
    }
    if connection.closing, !connection.lingering {
      connection.lingering = true
      // A timeout bounding one operation: the last words are read, or the
      // connection goes without them.
      let id = connection.id
      queue.asyncAfter(deadline: .now() + .milliseconds(limits.closeGraceMs)) { [weak self] in
        guard let self, let connection = self.connections[id] else { return }
        self.teardown(connection, reason: "close_grace")
      }
    }
  }

  private func teardown(_ connection: Connection, reason: String) {
    guard connections.removeValue(forKey: connection.id) != nil else { return }
    connection.readSource.cancel()
    connection.writeSource.cancel()
    // A source is cancelled only once it runs: resume a suspended one.
    if !connection.writing {
      connection.writeSource.resume()
      connection.writing = true
    }
    if connection.subscribed {
      let id = connection.id
      callbackQueue.async { [subscriptions] in subscriptions(id, nil) {} }
    }
    FlashLog.debug(
      "[ipc] disconnected", fields: ["connection": String(connection.id), "reason": reason])
  }
}

/// Closes a descriptor once every dispatch source watching it has been
/// cancelled; closing it earlier would let a recycled descriptor reach a
/// source that still watches the old one.
private final class DescriptorCloser {
  private let fd: Int32
  private var pending: Int

  init(fd: Int32, sources: Int) {
    self.fd = fd
    self.pending = sources
  }

  /// Called from each source's cancel handler, all on one serial queue.
  func release() {
    pending -= 1
    if pending == 0 { close(fd) }
  }
}
