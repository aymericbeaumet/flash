import Darwin
import XCTest

@testable import flash

/// The resident's socket end to end, on a private socket in a temporary
/// directory: permissions, the handshake, requests run through the runner,
/// the limits, and event fan-out to a subscriber that stops reading.
final class IPCServerTests: XCTestCase {
  private var directory: URL!
  private var endpoint: IPCEndpoint!
  private let callbacks = DispatchQueue(label: "flash.tests.ipc.callbacks")
  private var servers: [IPCServer] = []

  override func setUpWithError() throws {
    // Short: sun_path holds 104 bytes.
    let name = "fipc-" + UUID().uuidString.prefix(8)
    directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    endpoint = IPCEndpoint(directory: directory.appendingPathComponent("run"))
  }

  override func tearDown() {
    for server in servers { server.stop() }
    servers = []
    try? FileManager.default.removeItem(at: directory)
  }

  private func startServer(
    limits: IPCProtocol.Limits = .standard,
    runner: @escaping IPCServer.Runner = { invocation, _, completion in
      completion(.succeeded("ran \(invocation.line)"))
    },
    subscriptions: @escaping IPCServer.SubscriptionSink = { _, _, done in done() }
  ) throws -> IPCServer {
    let server = IPCServer(
      endpoint: endpoint, serverName: "Flash test", limits: limits, callbackQueue: callbacks,
      runner: runner, subscriptions: subscriptions)
    try server.start()
    servers.append(server)
    return server
  }

  // MARK: - A raw client

  /// A client speaking lines by hand, reading with a deadline.
  private final class RawClient {
    let fd: Int32
    private var reader = IPCFrameReader(maxFrameBytes: 16 << 20)
    private var pending: [Data] = []

    init?(_ endpoint: IPCEndpoint) {
      guard let fd = IPCSocket.make(), let address = try? endpoint.address(),
        IPCSocket.connect(fd, to: address) == 0
      else { return nil }
      self.fd = fd
    }

    deinit { close(fd) }

    func send(_ object: [String: Any]) {
      send(IPCProtocol.frame(object))
    }

    func send(_ bytes: Data) {
      bytes.withUnsafeBytes { raw in _ = write(fd, raw.baseAddress, raw.count) }
    }

    /// The next message, or nil at EOF or after `timeout` seconds.
    func next(timeout: TimeInterval = 5) -> [String: Any]? {
      let deadline = Date().addingTimeInterval(timeout)
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while pending.isEmpty {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
        guard poll(&descriptor, 1, remaining) > 0 else { return nil }
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count > 0 else { return nil }
        for case .frame(let frame) in reader.append(Data(buffer[0..<count])) {
          pending.append(frame)
        }
      }
      return (try? JSONSerialization.jsonObject(with: pending.removeFirst())) as? [String: Any]
    }

    /// Whether the resident closed the connection (EOF within `timeout`).
    func closed(timeout: TimeInterval = 5) -> Bool {
      while let message = next(timeout: timeout) {
        _ = message
      }
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      guard poll(&descriptor, 1, 0) > 0 else { return false }
      var byte: UInt8 = 0
      return read(fd, &byte, 1) == 0
    }

    /// Hang up without closing the descriptor (`deinit` does).
    func hangUp() {
      shutdown(fd, SHUT_RDWR)
    }

    /// Send EOF but keep reading, as `printf … | nc -U` does.
    func endInput() {
      shutdown(fd, SHUT_WR)
    }

    func hello() -> [String: Any]? {
      send(["type": "hello", "protocol": IPCProtocol.version, "client": "tests"])
      return next()
    }
  }

  // MARK: - The socket file

  func testTheSocketIsPrivateToTheUser() throws {
    // A looser directory left behind is tightened.
    try FileManager.default.createDirectory(
      at: endpoint.directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    _ = try startServer()
    var info = stat()
    XCTAssertEqual(lstat(endpoint.directory.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o700)
    XCTAssertEqual(info.st_uid, geteuid())
    XCTAssertEqual(lstat(endpoint.socketPath, &info), 0)
    XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
    XCTAssertEqual(info.st_mode & 0o777, 0o600)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: endpoint.directory.appendingPathComponent(IPCEndpoint.stagingName).path))
  }

  func testAStaleSocketIsReplacedButALiveOneIsNeverTakenOver() throws {
    let first = try startServer()
    let second = IPCServer(
      endpoint: endpoint, serverName: "Flash two", callbackQueue: callbacks,
      runner: { _, _, completion in completion(.succeeded()) },
      subscriptions: { _, _, done in done() })
    XCTAssertThrowsError(try second.start()) { error in
      XCTAssertEqual(error as? IPCServer.StartError, .inUse(endpoint.socketPath))
    }
    // A resident that crashed leaves its socket; nothing accepts on it.
    first.stop()
    servers = []
    let stale = try XCTUnwrap(IPCSocket.make())
    unlink(endpoint.socketPath)
    XCTAssertEqual(IPCSocket.bind(stale, to: try endpoint.address()), 0)
    close(stale)
    XCTAssertTrue(FileManager.default.fileExists(atPath: endpoint.socketPath))
    _ = try startServer()
    XCTAssertNotNil(RawClient(endpoint)?.hello())
  }

  func testStopRemovesOnlyItsOwnSocket() throws {
    let server = try startServer()
    server.stop()
    servers = []
    XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.socketPath))
  }

  func testADirectoryThatIsNotOursIsRefused() throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    // A symbolic link where the directory should be is not trusted.
    try FileManager.default.createSymbolicLink(
      at: endpoint.directory, withDestinationURL: URL(fileURLWithPath: "/tmp"))
    XCTAssertThrowsError(try endpoint.prepareDirectory()) { error in
      XCTAssertEqual(error as? IPCEndpoint.Problem, .notADirectory(endpoint.directory.path))
    }
  }

  func testAPathLongerThanSunPathIsAProblemNotATruncation() {
    let long = IPCEndpoint(
      directory: URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 120)))
    XCTAssertThrowsError(try long.address()) { error in
      XCTAssertEqual(error as? IPCEndpoint.Problem, .pathTooLong(long.socketPath))
    }
    XCTAssertEqual(IPCEndpoint.maxPathBytes, 103)
    // The resident's own path fits for a home directory of up to 48 bytes.
    let typical = IPCEndpoint(
      directory: URL(fileURLWithPath: "/Users/" + String(repeating: "u", count: 41))
        .appendingPathComponent("Library/Application Support/Flash/run"))
    XCTAssertNoThrow(try typical.address(of: IPCEndpoint.stagingName))
  }

  // MARK: - Peers

  func testOnlyTheUsersOwnProcessesAreAdmitted() throws {
    XCTAssertTrue(IPCSocket.admits(peer: 501, own: 501))
    XCTAssertFalse(IPCSocket.admits(peer: 0, own: 501))
    XCTAssertFalse(IPCSocket.admits(peer: 502, own: 501))
    XCTAssertFalse(IPCSocket.admits(peer: nil, own: 501))
    _ = try startServer()
    let client = try XCTUnwrap(RawClient(endpoint))
    XCTAssertEqual(IPCSocket.peerUID(client.fd), geteuid())
  }

  /// A sandboxed plugin allowed the network still cannot reach the socket,
  /// which would run any command outside its sandbox; the same profile
  /// with the rule naming another directory connects.
  func testASandboxedProcessCannotConnect() throws {
    guard FileManager.default.isExecutableFile(atPath: PluginSandbox.sandboxExecPath),
      FileManager.default.isExecutableFile(atPath: "/usr/bin/nc")
    else { throw XCTSkip("sandbox-exec or nc unavailable") }
    var limits = IPCProtocol.Limits.standard
    limits.handshakeTimeoutMs = 200
    _ = try startServer(limits: limits)
    let manifest = PluginManifest(
      id: "test", name: "Test", version: "1", description: "", install: "true",
      exec: ["./flash-plugin-test"], sandbox: .spec(PluginSandboxSpec()),
      capabilities: [.network])
    func run(denying directories: [String]) throws -> (status: Int32, output: String) {
      let profile = PluginSandbox.denyDefaultSandboxProfile(
        for: manifest, spec: PluginSandboxSpec(), root: URL(fileURLWithPath: "/usr/bin"),
        dataDir: directory.appendingPathComponent("data"),
        residentSocketDirectories: directories)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: PluginSandbox.sandboxExecPath)
      process.arguments = ["-p", profile, "/usr/bin/nc", "-d", "-U", endpoint.socketPath]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      process.standardInput = FileHandle.nullDevice
      try process.run()
      let output = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
    XCTAssertTrue(
      endpoint.sandboxPaths.last?.hasPrefix("/private/") == true, "\(endpoint.sandboxPaths)")
    let allowed = try run(denying: ["/nonexistent/flash/run"])
    XCTAssertTrue(allowed.output.contains("handshake_timeout"), allowed.output)
    let denied = try run(denying: endpoint.sandboxPaths)
    XCTAssertFalse(denied.output.contains("handshake_timeout"), denied.output)
    XCTAssertNotEqual(denied.status, 0)
  }

  // MARK: - Handshake

  func testAWordBeforeHelloClosesTheConnection() throws {
    _ = try startServer()
    let client = try XCTUnwrap(RawClient(endpoint))
    client.send(["type": "request", "id": "1", "words": ["tab", "next"]])
    XCTAssertEqual(client.next()?["code"] as? String, "handshake_required")
    XCTAssertTrue(client.closed())
  }

  func testAnotherProtocolVersionIsRefused() throws {
    _ = try startServer()
    let client = try XCTUnwrap(RawClient(endpoint))
    client.send(["type": "hello", "protocol": IPCProtocol.version + 1])
    let error = try XCTUnwrap(client.next())
    XCTAssertEqual(error["code"] as? String, "protocol_mismatch")
    XCTAssertEqual(error["protocol"] as? Int, IPCProtocol.version)
    XCTAssertTrue(client.closed())
  }

  func testWelcomeAnnouncesTheVersionAndLimits() throws {
    _ = try startServer()
    let welcome = try XCTUnwrap(RawClient(endpoint)?.hello())
    XCTAssertEqual(welcome["type"] as? String, "welcome")
    XCTAssertEqual(welcome["protocol"] as? Int, IPCProtocol.version)
    XCTAssertEqual(welcome["pid"] as? Int, Int(getpid()))
    let limits = try XCTUnwrap(welcome["limits"] as? [String: Int])
    XCTAssertEqual(limits["max_frame_bytes"], IPCProtocol.maxInboundFrameBytes)
  }

  func testSilenceIsCutOffAtTheHandshakeDeadline() throws {
    var limits = IPCProtocol.Limits.standard
    limits.handshakeTimeoutMs = 100
    _ = try startServer(limits: limits)
    let client = try XCTUnwrap(RawClient(endpoint))
    XCTAssertEqual(client.next()?["code"] as? String, "handshake_timeout")
    XCTAssertTrue(client.closed())
  }

  // MARK: - Requests

  /// The words reach the runner as the command line would see them, with
  /// the shell's directory, and the reply is the result the CLI prints.
  func testARequestRunsItsWordsAndRepliesWithTheResult() throws {
    let lock = NSLock()
    var received: [CommandInvocation] = []
    _ = try startServer(runner: { invocation, arrivedAt, completion in
      lock.lock()
      received.append(invocation)
      lock.unlock()
      XCTAssertGreaterThan(arrivedAt, 0)
      completion(.failed("the focused app has no tab next", output: "o"))
    })
    guard case .connected(let client) = IPCClient.connect(endpoint) else {
      return XCTFail("no connection")
    }
    XCTAssertEqual(try client.hello(client: "tests"), "Flash test")
    let result = try client.request(words: ["#tab", "next"], directory: "/tmp")
    XCTAssertEqual(result, .failed("the focused app has no tab next", output: "o"))
    lock.lock()
    defer { lock.unlock() }
    XCTAssertEqual(
      received, [CommandInvocation(words: ["#tab", "next"], workingDirectory: "/tmp")])
    XCTAssertTrue(received.first?.capturesOutput == true)
  }

  /// A client that sent everything and closed its side still reads the
  /// results it is owed, then the resident closes.
  func testAHalfClosedClientStillGetsItsResult() throws {
    _ = try startServer(runner: { invocation, _, completion in
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
        completion(.succeeded("ran \(invocation.line)"))
      }
    })
    let client = try XCTUnwrap(RawClient(endpoint))
    client.send(["type": "hello", "protocol": 1])
    client.send(["type": "request", "id": "1", "words": ["resident", "status"]])
    client.endInput()
    XCTAssertEqual(client.next()?["type"] as? String, "welcome")
    let result = try XCTUnwrap(client.next())
    XCTAssertEqual(
      (result["result"] as? [String: Any])?["output"] as? String, "ran resident status")
    XCTAssertTrue(client.closed())
  }

  func testTheCLIClientSeesAMissingSocketAsAbsent() {
    guard case .absent = IPCClient.connect(endpoint) else { return XCTFail("not absent") }
  }

  func testInFlightRequestsAreBounded() throws {
    var limits = IPCProtocol.Limits.standard
    limits.maxInFlightRequests = 1
    let release = DispatchSemaphore(value: 0)
    _ = try startServer(
      limits: limits,
      runner: { _, _, completion in
        DispatchQueue.global().async {
          release.wait()
          completion(.succeeded("done"))
        }
      })
    let client = try XCTUnwrap(RawClient(endpoint))
    _ = client.hello()
    client.send(["type": "request", "id": "1", "words": ["tab", "next"]])
    client.send(["type": "request", "id": "2", "words": ["tab", "next"]])
    let refused = try XCTUnwrap(client.next())
    XCTAssertEqual(refused["code"] as? String, "too_many_requests")
    XCTAssertEqual(refused["id"] as? String, "2")
    release.signal()
    let result = try XCTUnwrap(client.next())
    XCTAssertEqual(result["type"] as? String, "result")
    XCTAssertEqual(result["id"] as? String, "1")
  }

  func testAnOverlongLineClosesTheConnection() throws {
    var limits = IPCProtocol.Limits.standard
    limits.maxInboundFrameBytes = 64
    _ = try startServer(limits: limits)
    let client = try XCTUnwrap(RawClient(endpoint))
    _ = client.hello()
    client.send(Data((String(repeating: "x", count: 100) + "\n").utf8))
    XCTAssertEqual(client.next()?["code"] as? String, "frame_too_large")
    XCTAssertTrue(client.closed())
  }

  func testConnectionsAreBounded() throws {
    var limits = IPCProtocol.Limits.standard
    limits.maxConnections = 2
    let server = try startServer(limits: limits)
    let first = try XCTUnwrap(RawClient(endpoint))
    let second = try XCTUnwrap(RawClient(endpoint))
    XCTAssertNotNil(first.hello())
    XCTAssertNotNil(second.hello())
    let third = try XCTUnwrap(RawClient(endpoint))
    XCTAssertEqual(third.next()?["code"] as? String, "too_many_connections")
    XCTAssertTrue(third.closed())
    let counted = expectation(description: "count")
    server.connectionCount { count in
      XCTAssertEqual(count, 2)
      counted.fulfill()
    }
    wait(for: [counted], timeout: 5)
  }

  // MARK: - Events

  /// One emission reaches every subscriber in order; a subscriber that
  /// stops reading is cut off once its bounded queue overflows, told why if
  /// it reads again in time, and the others never notice.
  func testEventsFanOutAndASlowSubscriberIsDisconnected() throws {
    var limits = IPCProtocol.Limits.standard
    limits.maxQueuedEvents = 16
    limits.closeGraceMs = 10_000
    let hub = IPCEventHub(clock: { 0 })
    let hubQueue = callbacks
    let server = try startServer(
      limits: limits,
      subscriptions: { connection, events, done in
        hub.setSubscription(connection, events: events)
        done()
      })
    hub.deliver = { [weak server] frame, key, ids in
      server?.deliver(frame, coalescingKey: key, to: ids)
    }
    let fast = try XCTUnwrap(RawClient(endpoint))
    let slow = try XCTUnwrap(RawClient(endpoint))
    for client in [fast, slow] {
      _ = client.hello()
      client.send(["type": "subscribe", "id": "s", "events": ["core:apps.launched"]])
      XCTAssertEqual(
        client.next()?["events"] as? [String], ["core:apps.launched"])
    }
    // Big enough that the kernel's socket buffers fill after a few events.
    let name = String(repeating: "n", count: 2_000)
    var received: [UInt64] = []
    for batch in 0..<20 {
      hubQueue.sync {
        for index in 0..<10 {
          hub.publish(
            PluginEvent(
              .appsLaunched,
              payload: ["localized_name": name, "pid": batch * 10 + index, "bundle_id": "b"]))
        }
      }
      for _ in 0..<10 {
        let event = try XCTUnwrap(fast.next(), "fast subscriber missed an event")
        XCTAssertEqual(event["type"] as? String, "event")
        XCTAssertEqual(event["name"] as? String, "core:apps.launched")
        received.append((event["seq"] as? NSNumber)?.uint64Value ?? 0)
      }
    }
    XCTAssertEqual(received, Array(1...200))
    var slowEvents = 0
    var last: [String: Any]?
    while let message = slow.next(timeout: 5) {
      if message["type"] as? String == "event" { slowEvents += 1 }
      last = message
    }
    XCTAssertLessThan(slowEvents, 200)
    XCTAssertEqual(last?["code"] as? String, "overflow")
    let counted = expectation(description: "count")
    server.connectionCount { count in
      XCTAssertEqual(count, 1)
      counted.fulfill()
    }
    wait(for: [counted], timeout: 5)
    hubQueue.sync { XCTAssertTrue(hub.hasSubscriber(for: "core:apps.launched")) }
  }

  /// No subscriber, no work: nothing is encoded and no OS source has to run.
  func testWithoutSubscribersTheHubDoesNothing() {
    let hub = IPCEventHub()
    var delivered = 0
    var changes = 0
    hub.deliver = { _, _, _ in delivered += 1 }
    hub.subscribersDidChange = { changes += 1 }
    for event in HostEvent.allCases {
      XCTAssertFalse(hub.hasSubscriber(for: event.rawValue))
      hub.publish(PluginEvent(event))
    }
    XCTAssertEqual(delivered, 0)
    XCTAssertEqual(hub.sequence, 0)
    hub.setSubscription(1, events: ["core:mode.changed"])
    hub.setSubscription(1, events: ["core:mode.changed"])
    hub.setSubscription(2, events: ["core:mode.changed", "core:hints.shown"])
    XCTAssertEqual(changes, 2)
    hub.publish(PluginEvent(.modeChanged, payload: ["mode": "normal", "previous": "insert"]))
    hub.publish(PluginEvent(.focusChanged))
    XCTAssertEqual(delivered, 1)
    hub.setSubscription(1, events: nil)
    hub.setSubscription(2, events: [])
    XCTAssertTrue(hub.isEmpty)
    XCTAssertFalse(hub.hasSubscriber(for: "core:mode.changed"))
  }

  func testUnsubscribedConnectionsAndTheSubscribedAckOrder() throws {
    let hub = IPCEventHub(clock: { 42 })
    var forgotten: XCTestExpectation?
    hub.subscribersDidChange = {
      if hub.isEmpty { forgotten?.fulfill() }
    }
    let server = try startServer(subscriptions: { connection, events, done in
      hub.setSubscription(connection, events: events)
      done()
    })
    hub.deliver = { [weak server] frame, key, ids in
      server?.deliver(frame, coalescingKey: key, to: ids)
    }
    let client = try XCTUnwrap(RawClient(endpoint))
    _ = client.hello()
    client.send(["type": "subscribe", "id": "s", "events": ["core:mode.changed"]])
    XCTAssertEqual(client.next()?["type"] as? String, "subscribed")
    callbacks.sync {
      hub.publish(PluginEvent(.modeChanged, payload: ["mode": "normal", "previous": "insert"]))
    }
    let event = try XCTUnwrap(client.next())
    XCTAssertEqual(event["time_ms"] as? Int, 42)
    XCTAssertEqual(event["payload"] as? [String: String], ["mode": "normal", "previous": "insert"])
    client.send(["type": "subscribe", "id": "u", "events": []])
    XCTAssertEqual(client.next()?["events"] as? [String], [])
    callbacks.sync { XCTAssertTrue(hub.isEmpty) }
    // Closing forgets a subscription too.
    client.send(["type": "subscribe", "id": "v", "events": ["core:*"]])
    XCTAssertEqual(client.next()?["type"] as? String, "subscribed")
    let gone = expectation(description: "forgotten")
    callbacks.sync { forgotten = gone }
    client.hangUp()
    wait(for: [gone], timeout: 5)
  }
}
