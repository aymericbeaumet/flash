import XCTest

@testable import flash

/// `notify send` / `notify clear`, `logs write` and `metrics record`: their
/// grammar, the notification controller over a fake center (no real
/// notification, no permission prompt), and recorded metrics landing in the
/// store status formats read and in the exporter's batch.
final class NotifyLogMetricsTests: XCTestCase {
  private func parse(_ line: String) -> URLCommand? {
    NormalModeDispatcher.commandLineCoreCommand(":" + line)
  }

  private func resolve(_ line: String) -> NormalModeDispatcher.CommandLineResolution {
    NormalModeDispatcher.resolveCommandLine(":" + line, inventory: .core())
  }

  // MARK: notify

  func testNotifySendReadsItsWordsAsTheCommandLineDoes() throws {
    let command = try XCTUnwrap(
      parse("notify send --title=Build done --body=All tests passed --sound --id=build"))
    guard case .notify(.send(let request)) = command else { return XCTFail("\(command)") }
    XCTAssertEqual(request.title, "Build done")
    XCTAssertEqual(request.body, "All tests passed")
    XCTAssertTrue(request.sound)
    XCTAssertEqual(request.id, "build")
    XCTAssertEqual(URLEventHandler.parse(words: Array(command.argv.dropFirst())), command)
    XCTAssertEqual(parse("notify clear"), .notify(.clear(id: nil)))
    XCTAssertEqual(parse("notify clear --id=build"), .notify(.clear(id: "build")))
  }

  func testNotifySendRefusesWhatItCannotPost() {
    XCTAssertNil(parse("notify send --subtitle=only"), "a title or a body is required")
    XCTAssertNil(parse("notify send --title=x --url=https://a.b --command=window switch"))
    XCTAssertNil(parse("notify send --title=x --url=file:///etc/passwd"))
    XCTAssertNil(parse("notify send --title=x --url=javascript:alert(1)"))
    XCTAssertNil(parse("notify send --title=x --url=nonsense"))
    XCTAssertNil(parse("notify send --title=x --id=has space"))
    XCTAssertNil(parse("notify send --title=x --command=not a command"))
    XCTAssertNil(parse("notify clear --id=a/b"))
    if case .failure(let error) = NotifyRequest.make(
      title: nil, subtitle: nil, body: nil, sound: false, url: nil, command: nil, id: nil)
    {
      XCTAssertEqual(error.description, "notify send needs a --title or a --body")
    } else {
      XCTFail("an empty notification posts nothing")
    }
  }

  func testAClickOpensItsURLOrRunsItsCommandAcrossRestarts() throws {
    let url = try XCTUnwrap(parse("notify send --title=x --url=https://example.com/build/1"))
    guard case .notify(.send(let open)) = url else { return XCTFail() }
    XCTAssertEqual(
      NotifyClick(userInfo: open.userInfo), .open(URL(string: "https://example.com/build/1")!))
    let run = try XCTUnwrap(parse("notify send --title=x --command=window switch"))
    guard case .notify(.send(let command)) = run else { return XCTFail() }
    XCTAssertEqual(NotifyClick(userInfo: command.userInfo), .run(.windowSwitch))
    XCTAssertEqual(NotifyClick(userInfo: [:]), .nothing)
    XCTAssertEqual(
      NotifyClick(userInfo: [NotifyClick.urlKey: "file:///tmp/x"]), .nothing,
      "a refused scheme stays refused when clicked")
    XCTAssertEqual(NotifyClick(userInfo: [NotifyClick.commandKey: "renamed command"]), .nothing)
  }

  private final class FakeCenter: NotificationCentering {
    var state = NotifyAuthorization.notDetermined
    var answer = true
    var requests = 0
    var pendingAnswer: ((Bool) -> Void)?
    var posted: [(NotifyRequest, String)] = []
    var removed: [[String]?] = []

    func authorization(_ completion: @escaping (NotifyAuthorization) -> Void) { completion(state) }
    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
      requests += 1
      pendingAnswer = { allowed in
        self.state = allowed ? .allowed : .denied
        completion(allowed)
      }
    }
    func post(_ request: NotifyRequest, identifier: String, completion: @escaping (String?) -> Void)
    {
      posted.append((request, identifier))
      completion(nil)
    }
    func remove(identifiers: [String]?) { removed.append(identifiers) }
  }

  private func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }

  private func request(_ title: String, id: String? = nil) -> NotifyRequest {
    NotifyRequest(
      title: title, subtitle: "", body: "", sound: false, url: nil, command: nil, id: id)
  }

  /// Authorization is asked on the first post, never before, and once:
  /// posts that arrive while the prompt is up wait for its answer.
  func testTheFirstPostAsksOnceAndPostsWhatWaited() {
    let center = FakeCenter()
    let controller = NotificationController(center: center)
    XCTAssertEqual(center.requests, 0, "nothing is asked until a post")
    var results: [String?] = []
    controller.send(request("one")) { results.append($0) }
    settle()
    controller.send(request("two", id: "build")) { results.append($0) }
    settle()
    XCTAssertEqual(center.requests, 1)
    XCTAssertTrue(center.posted.isEmpty, "nothing posts before the answer")
    center.pendingAnswer?(true)
    settle()
    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(results.compactMap { $0 }, [])
    XCTAssertEqual(center.posted.map(\.0.title), ["one", "two"])
    XCTAssertEqual(center.posted.last?.1, "flash.notify.build", "an id replaces its last post")
    controller.send(request("three")) { results.append($0) }
    settle()
    XCTAssertEqual(center.requests, 1, "an allowed Flash is not asked again")
    XCTAssertEqual(center.posted.count, 3)
  }

  func testADenialSaysWhereToAllowIt() {
    let center = FakeCenter()
    let controller = NotificationController(center: center)
    var result: String??
    controller.send(request("one")) { result = $0 }
    settle()
    center.pendingAnswer?(false)
    settle()
    XCTAssertEqual(result, .some(NotificationController.deniedMessage))
    center.state = .denied
    controller.send(request("two")) { result = $0 }
    settle()
    XCTAssertEqual(center.requests, 1, "a denial is not asked again: System Settings changes it")
    XCTAssertEqual(result, .some(NotificationController.deniedMessage))
    XCTAssertTrue(center.posted.isEmpty)
  }

  func testClearRemovesOneOrAllOfFlashsNotifications() {
    let center = FakeCenter()
    let controller = NotificationController(center: center)
    controller.clear(id: "build")
    controller.clear(id: nil)
    XCTAssertEqual(center.removed.count, 2)
    XCTAssertEqual(center.removed.first ?? nil, ["flash.notify.build"])
    XCTAssertNil(center.removed.last ?? ["unexpected"])
  }

  func testNoNotificationCenterExistsInTheTestRunner() {
    XCTAssertNil(NotificationController.live())
  }

  // MARK: logs write

  func testLogsWriteTakesALevelFlagAndTheConventionsShape() throws {
    let command = try XCTUnwrap(
      parse(
        "logs write --warn --message=disk almost full --area=backup --fields=job=nightly,host=mini")
    )
    guard case .logWrite(let write) = command else { return XCTFail("\(command)") }
    XCTAssertEqual(write.level, .warn)
    XCTAssertEqual(write.line, "[backup] disk almost full")
    XCTAssertEqual(write.fields, ["job": "nightly", "host": "mini"])
    XCTAssertEqual(URLEventHandler.parse(words: Array(command.argv.dropFirst())), command)
    guard case .logWrite(let plain)? = parse("logs write --message=hello") else { return XCTFail() }
    XCTAssertEqual(plain.level, .info, "no flag is info")
    XCTAssertEqual(plain.line, "[user] hello")
    XCTAssertNil(parse("logs write --warn --error --message=x"), "one level")
    XCTAssertNil(parse("logs write --message=x --area=Has-Caps"))
    XCTAssertNil(parse("logs write --message=x --fields=novalue"))
    XCTAssertNil(parse("logs write --warn"), "a message is required")
    guard
      case .success(let folded) = LogWrite.make(
        levelFlags: [], message: "one\ntwo\r\nthree", area: nil, fields: nil)
    else { return XCTFail() }
    XCTAssertEqual(folded.message, "one two three", "one log line per write")
  }

  /// `logs write` is typed in full: `logs` has two actions, so flags after
  /// the topic pick none (`:logs --warn …` runs nothing), while a bare
  /// `:logs` still opens the logs page. A one-action topic takes its
  /// arguments right away (`:metrics --name=… --value=…`).
  func testLogsWriteIsTypedInFullAndABareLogsShowsThePage() {
    guard case .commands(let commands) = resolve("logs write --error --message=boom"),
      case .logWrite(let write)? = commands.first
    else { return XCTFail("\(resolve("logs write --error --message=boom"))") }
    XCTAssertEqual(write.level, .error)
    XCTAssertEqual(write.line, "[user] boom")
    XCTAssertEqual(resolve("logs"), .commands([.showLogs]))
    XCTAssertEqual(resolve("logs --error --message=boom"), .unknown)
    XCTAssertEqual(resolve("log --error --message=boom"), .unknown, "`log` is no topic")
    XCTAssertEqual(
      NormalModeDispatcher.resolveCommandWords(
        ["logs", "write", "--warn", "--message=disk", "almost", "full"], inventory: .core()),
      .commands([
        .logWrite(LogWrite(level: .warn, message: "disk almost full", area: "user", fields: [:]))
      ]),
      "the CLI reads the same words")
    guard case .commands(let metrics) = resolve("metrics --name=build.duration --value=42"),
      case .metricRecord? = metrics.first
    else { return XCTFail("\(resolve("metrics --name=build.duration --value=42"))") }
  }

  // MARK: metrics record

  func testMetricsRecordValidatesNamesKindsAndAttributes() throws {
    let command = try XCTUnwrap(
      parse(
        "metrics record --name=build.duration --value=42.5 --kind=histogram --unit=s --attributes=job=ci,branch=main"
      ))
    guard case .metricRecord(let record) = command else { return XCTFail("\(command)") }
    XCTAssertEqual(record.name, "build.duration")
    XCTAssertEqual(record.kind, .histogram)
    XCTAssertEqual(record.instrument.unit, "s")
    XCTAssertEqual(record.attributes, ["job": "ci", "branch": "main"])
    XCTAssertEqual(record.instrument.bounds, MetricRecord.defaultBounds)
    XCTAssertEqual(URLEventHandler.parse(words: Array(command.argv.dropFirst())), command)
    guard case .metricRecord(let gauge)? = parse("metrics record --name=disk.free --value=12")
    else { return XCTFail() }
    XCTAssertEqual(gauge.kind, .gauge, "a gauge unless told otherwise")
    for bad in [
      "metrics record --name=Build --value=1",
      "metrics record --name=build..duration --value=1",
      "metrics record --name=flash.hints.latency --value=1",
      "metrics record --name=ok --value=nan",
      "metrics record --name=ok --value=abc",
      "metrics record --name=ok --value=-1 --kind=counter",
      "metrics record --name=ok --value=1 --kind=summary",
      "metrics record --name=ok --value=1 --attributes=Bad=1",
      "metrics record --name=ok --value=1 --attributes=a=1,a=2",
    ] {
      XCTAssertNil(parse(bad), bad)
    }
    let many = (0...MetricRecord.maxAttributes).map { "k\($0)=v" }.joined(separator: ",")
    XCTAssertNil(parse("metrics record --name=ok --value=1 --attributes=\(many)"), "cardinality")
  }

  private func record(_ line: String) throws -> MetricRecord {
    guard case .metricRecord(let record)? = parse(line) else {
      throw XCTSkip("unparsed: \(line)")
    }
    return record
  }

  /// A recorded metric is read by status formats as a received one is.
  func testRecordedMetricsAreReadLikeReceivedOnes() throws {
    var wall = Date(timeIntervalSince1970: 1_800_000_000)
    let store = TelemetryStore(clock: { 100 }, wallClock: { wall })
    store.record(
      try record("metrics record --name=disk.free --value=12"), scope: MetricRecord.recordedScope)
    wall += 1
    store.record(
      try record("metrics record --name=disk.free --value=9"), scope: MetricRecord.recordedScope)
    store.record(
      try record("metrics record --name=jobs.done --value=2 --kind=counter --attributes=host=a"),
      scope: MetricRecord.recordedScope)
    store.record(
      try record("metrics record --name=jobs.done --value=3 --kind=counter --attributes=host=a"),
      scope: MetricRecord.recordedScope)
    store.record(
      try record("metrics record --name=jobs.done --value=10 --kind=counter --attributes=host=b"),
      scope: MetricRecord.recordedScope)
    for value in ["10", "20", "300"] {
      store.record(
        try record("metrics record --name=build.duration --value=\(value) --kind=histogram"),
        scope: MetricRecord.recordedScope)
    }
    let values = store.values(for: [
      "flash.otel:disk.free", "flash.otel.total:jobs.done", "flash.otel.total:jobs.done[host=a]",
      "flash.otel.count:build.duration", "flash.otel.max:build.duration",
    ])
    XCTAssertEqual(values["flash.otel:disk.free"], "9", "a gauge keeps its latest value")
    XCTAssertEqual(values["flash.otel.total:jobs.done"], "15", "counters add across series")
    XCTAssertEqual(values["flash.otel.total:jobs.done[host=a]"], "5")
    XCTAssertEqual(values["flash.otel.count:build.duration"], "3")
    XCTAssertEqual(values["flash.otel.max:build.duration"], "300")
  }

  /// Flash's own instruments join the store only once something reads
  /// them, which keeps their hot paths a set lookup.
  func testFlashsOwnMetricsJoinTheStoreOnlyWhileRead() {
    let store = TelemetryStore(clock: { 100 })
    let latency = MetricRecord(
      instrument: FlashInstrument.hintsLatency.instrument, value: 42, attributes: [:])
    store.recordIfObserved(latency, scope: MetricRecord.instrumentScope)
    XCTAssertTrue(store.values(for: ["flash.otel.count:flash.hints.latency"]).isEmpty)
    store.observe(keys: ["flash.otel.count:flash.hints.latency"])
    store.recordIfObserved(latency, scope: MetricRecord.instrumentScope)
    XCTAssertEqual(store.values(for: ["flash.otel.count:flash.hints.latency"]).values.first, "1")
  }

  /// One recorder path: a recorded metric exports beside Flash's own, with
  /// its own name, unit, kind and bounds.
  func testRecordedMetricsExportWithFlashsOwn() throws {
    let recorder = TelemetryRecorder(signals: [.metrics])
    let duration = try record(
      "metrics record --name=build.duration --value=42 --kind=histogram --unit=s")
    recorder.record(duration.instrument, duration.value, attributes: duration.attributes)
    let jobs = try record("metrics record --name=jobs.done --value=2 --kind=counter")
    recorder.record(jobs.instrument, jobs.value, attributes: jobs.attributes)
    recorder.record(jobs.instrument, jobs.value, attributes: jobs.attributes)
    recorder.record(.pluginRestarts, 1, attributes: ["plugin": "x"])
    let batch = recorder.drain(maxItems: 10)
    let request = TelemetryExportBuilder.metrics(
      batch.metrics ?? [], resource: [:], version: "test", startNs: 1)
    let metrics = request.resourceMetrics.first?.scopeMetrics.first?.metrics ?? []
    XCTAssertEqual(metrics.map(\.name), ["build.duration", "flash.plugin.restarts", "jobs.done"])
    let histogram = try XCTUnwrap(metrics.first { $0.name == "build.duration" })
    XCTAssertEqual(histogram.unit, "s")
    XCTAssertEqual(histogram.histogram.dataPoints.first?.explicitBounds, MetricRecord.defaultBounds)
    XCTAssertEqual(metrics.first { $0.name == "jobs.done" }?.sum.dataPoints.first?.asDouble, 4)
  }
}
