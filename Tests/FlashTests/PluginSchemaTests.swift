import AppKit
import FlashCore
import XCTest

@testable import flash

/// `docs/schema/plugin/` pins every frame of the plugin wire protocol, and
/// `Plugins/_flash_plugin_rust/conformance/` is the corpus both ends read:
/// each line validates against its schema as the corpus says, the host's
/// decoders take or refuse each plugin frame as the corpus says, and the
/// host answers each host RPC with the reply the corpus names. The SDK reads
/// the same two files in `src/conformance.rs`.
final class PluginSchemaTests: XCTestCase {
  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  private static let directory = root.appendingPathComponent("docs/schema/plugin")
  private static let sdk = root.appendingPathComponent("Plugins/_flash_plugin_rust")

  private var validator: JSONSchemaValidator!
  private var pluginFrames: [CorpusLine] = []
  private var hostFrames: [CorpusLine] = []

  override func setUpWithError() throws {
    validator = try JSONSchemaValidator(directory: Self.directory)
    pluginFrames = try Self.corpus("plugin-frames.ndjson")
    hostFrames = try Self.corpus("host-frames.ndjson")
  }

  // MARK: - The corpus

  /// One corpus line: a frame, who must take it, and what answers it.
  private struct CorpusLine {
    var name: String
    /// The receiver takes the frame as the well-formed frame it claims to be.
    var accepted: Bool
    /// The request method a reply frame answers.
    var replyTo: String?
    /// The line of the other file the receiver answers with.
    var reply: String?
    /// The schema's verdict, where it differs from the receiver's.
    var schemaAccepts: Bool
    /// The frame's bytes exactly as the line carries them.
    var frame: Data
    var value: Any

    var object: [String: Any]? { value as? [String: Any] }
    var method: String? { object?["method"] as? String }
    var result: [String: Any]? { object?["result"] as? [String: Any] }
    var params: [String: Any] { object?["params"] as? [String: Any] ?? [:] }
  }

  private static let envelopeKeys: Set<String> = [
    "name", "expect", "reply_to", "reply", "schema", "frame",
  ]

  private static func corpus(_ file: String) throws -> [CorpusLine] {
    let text = try String(
      contentsOf: sdk.appendingPathComponent("conformance/\(file)"), encoding: .utf8)
    return try text.split(separator: "\n").map { raw in
      let line = String(raw)
      let entry = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
      XCTAssertTrue(Set(entry.keys).isSubset(of: envelopeKeys), line)
      let name = try XCTUnwrap(entry["name"] as? String, line)
      let expect = try XCTUnwrap(entry["expect"] as? String, name)
      XCTAssertTrue(["accept", "reject"].contains(expect), name)
      let schema = entry["schema"] as? String ?? expect
      XCTAssertTrue(["accept", "reject"].contains(schema), name)
      // `frame` is the last key, so the bytes between its colon and the
      // line's closing brace are the frame as it crosses the wire: a number
      // keeps its spelling, which a re-encoding would not.
      let marker = try XCTUnwrap(line.range(of: ", \"frame\": "), name)
      let frame = Data(line[marker.upperBound...].dropLast().utf8)
      return CorpusLine(
        name: name, accepted: expect == "accept", replyTo: entry["reply_to"] as? String,
        reply: entry["reply"] as? String, schemaAccepts: schema == "accept", frame: frame,
        value: try XCTUnwrap(entry["frame"], name))
    }
  }

  private static func protocolSpec() throws -> [String: Any] {
    let data = try Data(contentsOf: sdk.appendingPathComponent("protocol.json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// The methods of each direction, in `protocol.json`'s terms.
  private struct Methods {
    var hostToPlugin: [String]
    var notifications: [String]
    var hostRPCs: [String]

    /// Host requests that are answered; `event` is a notification.
    var requests: [String] { hostToPlugin.filter { $0 != "event" } }
  }

  private static func methods() throws -> Methods {
    let methods = try XCTUnwrap(try protocolSpec()["methods"] as? [String: Any])
    return Methods(
      hostToPlugin: try XCTUnwrap(methods["host_to_plugin"] as? [String: Any]).keys.sorted(),
      notifications: try XCTUnwrap(methods["plugin_to_host_notifications"] as? [String: Any])
        .keys.sorted(),
      hostRPCs: try XCTUnwrap(methods["plugin_to_host_rpcs"] as? [String: Any]).keys.sorted())
  }

  // MARK: - The documents

  func testEveryFrameHasASchemaAndTheUnionsListThemAll() throws {
    let methods = try Self.methods()
    let hostFrames =
      methods.hostToPlugin.map { "\($0).schema.json" }
      + methods.hostRPCs.map { "\($0).reply.schema.json" }
    let pluginFrames =
      methods.requests.map { "\($0).reply.schema.json" }
      + methods.notifications.map { "\($0).schema.json" }
      + methods.hostRPCs.map { "\($0).schema.json" }
    XCTAssertEqual(
      Set(validator.documents.keys),
      Set(
        hostFrames + pluginFrames + [
          "definitions.schema.json", "host-frame.schema.json", "plugin-frame.schema.json",
        ]))
    for (file, document) in validator.documents {
      XCTAssertEqual(
        document["$schema"] as? String, "http://json-schema.org/draft-07/schema#", file)
      XCTAssertEqual(
        document["$id"] as? String,
        "https://raw.githubusercontent.com/aymericbeaumet/flash/main/docs/schema/plugin/\(file)",
        file)
      XCTAssertNotNil(document["description"] as? String, file)
    }
    func union(_ file: String) -> Set<String> {
      Set(
        (validator.documents[file]?["anyOf"] as? [[String: String]] ?? []).compactMap {
          $0["$ref"]
        })
    }
    XCTAssertEqual(union("host-frame.schema.json"), Set(hostFrames))
    XCTAssertEqual(union("plugin-frame.schema.json"), Set(pluginFrames))
  }

  /// The numbers the schemas spell out are the contract's.
  func testTheSchemasCarryTheContractsBounds() throws {
    func node(_ file: String, _ path: Any...) -> [String: Any] {
      var node: Any = validator.documents[file] ?? [:]
      for step in path {
        if let key = step as? String {
          node = (node as? [String: Any])?[key] ?? [:]
        } else if let index = step as? Int, let array = node as? [Any], index < array.count {
          node = array[index]
        }
      }
      return node as? [String: Any] ?? [:]
    }
    let rows = node("publish.schema.json", "properties", "params", "properties", "rows")
    XCTAssertEqual(rows["maxItems"] as? Int, PluginProtocol.maxCatalogRows)
    let found = node(
      "search.reply.schema.json", "properties", "result", "anyOf", 0, "properties", "rows")
    XCTAssertEqual(found["maxItems"] as? Int, PluginProtocol.maxCatalogRows)
    let registrations = node(
      "poll.schema.json", "properties", "params", "properties", "registrations")
    XCTAssertEqual(registrations["maxProperties"] as? Int, PluginProtocol.pollMaxRegistrations)
    let definitions = "definitions.schema.json"
    let metadata = node(definitions, "definitions", "row", "properties", "metadata")
    XCTAssertEqual(metadata["maxProperties"] as? Int, PluginProtocol.maxMetadataEntries)
    let confirm = node(definitions, "definitions", "row", "properties", "confirm")
    XCTAssertEqual(confirm["maxLength"] as? Int, PluginProtocol.maxConfirmBytes)
    XCTAssertEqual(
      Set(node(definitions, "definitions", "priority")["enum"] as? [String] ?? []),
      Set(FlashPriority.allCases.map(\.rawValue)))
    let answers = node(
      "evaluate.reply.schema.json", "properties", "result", "anyOf", 0, "properties", "answers")
    XCTAssertEqual(answers["maxItems"] as? Int, PluginProtocol.maxAnswers)
    for dimension in ["columns", "rows"] {
      let bound = node(
        "text_grid.reply.schema.json", "properties", "result", "anyOf", 0, "properties",
        dimension)
      XCTAssertEqual(bound["maximum"] as? Int, PluginProtocol.maxTextGridDimension, dimension)
    }
    // A cap on bytes inside a marker is beyond a schema; its comment still
    // quotes the contract's number.
    let markup = node(
      "status.schema.json", "properties", "params", "properties", "segments",
      "additionalProperties", "anyOf", 0)
    let quotas = try XCTUnwrap(try Self.protocolSpec()["quotas"] as? [String: Any])
    let cap = try XCTUnwrap(quotas["inline_preview_bytes"] as? Int)
    XCTAssertTrue((markup["$comment"] as? String ?? "").contains("at most \(cap) "))
  }

  // MARK: - Every line against its schema

  /// The schema a line is held to: the reply schema of the request it
  /// answers, else the schema of the method it names, else the direction's
  /// union.
  private func schema(for line: CorpusLine, union: String) -> String {
    if let replyTo = line.replyTo { return "\(replyTo).reply.schema.json" }
    if let method = line.method, validator.documents["\(method).schema.json"] != nil {
      return "\(method).schema.json"
    }
    return union
  }

  func testEveryCorpusLineMeetsItsSchemaVerdict() {
    for (lines, union) in [
      (pluginFrames, "plugin-frame.schema.json"), (hostFrames, "host-frame.schema.json"),
    ] {
      for line in lines {
        let schema = schema(for: line, union: union)
        let problems = validator.problems(json: line.frame, against: schema)
        if line.schemaAccepts {
          XCTAssertEqual(problems, [], "\(line.name) against \(schema)")
          XCTAssertEqual(
            validator.problems(json: line.frame, against: union), [],
            "\(line.name) against \(union)")
        } else {
          XCTAssertFalse(problems.isEmpty, "\(line.name) passes \(schema)")
        }
      }
    }
  }

  /// The session `docs/plugin-protocol.md` opens with is made of frames the
  /// schemas take.
  func testTheQuickStartFramesMeetTheSchemas() throws {
    let page = try String(
      contentsOf: Self.root.appendingPathComponent("docs/plugin-protocol.md"), encoding: .utf8)
    let section = try XCTUnwrap(page.range(of: "## Quick start\n"))
    let block = try XCTUnwrap(
      page[section.upperBound...].components(separatedBy: "```").dropFirst().first)
    var frames = 0
    for line in block.split(separator: "\n") {
      let fromHost = line.hasPrefix("▶ ")
      guard fromHost || line.hasPrefix("◀ ") else { continue }
      frames += 1
      let union = fromHost ? "host-frame.schema.json" : "plugin-frame.schema.json"
      XCTAssertEqual(
        validator.problems(json: Data(line.dropFirst(2).utf8), against: union), [], String(line))
    }
    XCTAssertGreaterThan(frames, 8)
  }

  func testTheCorpusCoversEveryMethodBothWays() throws {
    let methods = try Self.methods()
    XCTAssertEqual(Set(pluginFrames.map(\.name)).count, pluginFrames.count)
    XCTAssertEqual(Set(hostFrames.map(\.name)).count, hostFrames.count)
    for (lines, others) in [(pluginFrames, hostFrames), (hostFrames, pluginFrames)] {
      let names = Set(others.map(\.name))
      for line in lines {
        if let reply = line.reply { XCTAssertTrue(names.contains(reply), line.name) }
      }
    }
    func verdicts(_ lines: [CorpusLine], _ matches: (CorpusLine) -> Bool) -> Set<Bool> {
      Set(lines.filter(matches).map(\.accepted))
    }
    for method in methods.hostToPlugin {
      XCTAssertEqual(
        verdicts(hostFrames) { $0.replyTo == nil && $0.method == method }, [true, false], method)
    }
    for method in methods.requests {
      XCTAssertEqual(verdicts(pluginFrames) { $0.replyTo == method }, [true, false], method)
    }
    for method in methods.notifications where method != "log" {
      XCTAssertEqual(verdicts(pluginFrames) { $0.method == method }, [true, false], method)
    }
    XCTAssertEqual(verdicts(pluginFrames) { $0.method == "log" }, [true])
    for method in methods.hostRPCs {
      XCTAssertTrue(verdicts(pluginFrames) { $0.method == method }.contains(true), method)
      XCTAssertTrue(verdicts(hostFrames) { $0.replyTo == method }.contains(true), method)
    }
  }

  // MARK: - What the host takes

  /// How the host settles one plugin frame.
  private enum Taken: Equatable {
    /// Decoded, and acted on as a success.
    case success
    /// Decoded as a well-formed refusal.
    case refusal
    /// Refused as malformed.
    case malformed
    /// Settled empty: for these replies the host does not tell a refusal
    /// from a malformed frame.
    case empty
  }

  private func taken(_ line: CorpusLine) -> Taken {
    guard let object = try? PluginWireCodec.decodeFrame(line.frame) else { return .malformed }
    let params = object["params"] as? [String: Any] ?? [:]
    switch (object["method"] as? String, line.replyTo) {
    case ("publish"?, _):
      let decoded = PluginWireCodec.publish(
        frame: line.frame, object: object, sourceID: "plugin:example",
        allowedSources: ["example.items", "example.tabs"])
      return decoded == nil ? .malformed : .success
    case ("status"?, _):
      guard
        let segments = PluginWireCodec.statusSegments(from: params, declared: ["summary", "feed"])
      else { return .malformed }
      return segments.contains { $0.segment == .malformed } ? .malformed : .success
    case ("changed"?, _):
      return PluginWireCodec.changedSource(from: params, liveSources: ["example.live"]) == nil
        ? .malformed : .success
    case ("poll"?, _):
      return PluginWireCodec.pollRegistrations(from: params) == nil ? .malformed : .success
    case (.some, _):
      // `log`: the envelope is all the host checks.
      return .success
    case (nil, "initialize"?):
      switch PluginWireCodec.initializeReply(object["result"] as? [String: Any] ?? [:]) {
      case .accepted: return .success
      case .refused: return .refusal
      case .versionMismatch, .malformed: return .malformed
      }
    case (nil, "perform"?):
      switch PluginWireCodec.validatedPerformResult(object["result"] as? [String: Any] ?? [:]) {
      case .performed?: return .success
      case .unhandled?, .failed?: return .refusal
      case nil: return .malformed
      }
    case (nil, "evaluate"?):
      let answers = PluginWireCodec.evaluateAnswers(object["result"] as? [String: Any]).flatMap {
        PluginWireCodec.queryAnswers(from: $0, sourceID: "plugin:example", source: "example")
      }
      return answers == nil ? .empty : .success
    case (nil, "hints"?):
      let targets = PluginWireCodec.okPayload(object["result"] as? [String: Any]).flatMap {
        PluginWireCodec.hintTargets(from: $0, sourceID: "plugin:example", contextPID: 512)
      }
      return targets == nil ? .empty : .success
    case (nil, "text_grid"?):
      let grid = PluginWireCodec.okPayload(object["result"] as? [String: Any]).flatMap(
        PluginWireCodec.textGrid(from:))
      return grid == nil ? .empty : .success
    case (nil, "search"?):
      let rows = PluginWireCodec.searchRows(
        from: object["result"] as? [String: Any], source: "example.live",
        sourceID: "plugin:example")
      return rows == nil ? .empty : .success
    case (nil, _):
      // `ping`, and a reply to a request the plugin does not know.
      return PluginWireCodec.okPayload(object["result"] as? [String: Any]) == nil
        ? .empty : .success
    }
  }

  func testTheHostTakesEachPluginFrameAsTheCorpusSays() {
    // The host RPC requests are answered, not decoded: the next test holds
    // each to the reply the corpus names.
    for line in pluginFrames where line.method?.hasPrefix("host.") != true {
      let taken = taken(line)
      if !line.accepted {
        XCTAssertTrue([.malformed, .empty].contains(taken), "\(line.name): \(taken)")
      } else if line.result.map({ PluginJSON.boolean($0["ok"]) == false }) == true {
        XCTAssertTrue([.refusal, .empty].contains(taken), "\(line.name): \(taken)")
      } else {
        XCTAssertEqual(taken, .success, line.name)
      }
    }
  }

  // MARK: - What the host answers

  private final class WiFi: WiFiInfoProviding {
    func fetchSSID(requestAuthorization: Bool, completion: @escaping (String?) -> Void) {
      completion("Atelier")
    }
  }

  /// A dispatcher whose side effects are the corpus's fixture: the focused
  /// app, the network name, the app that opens a link and a script's output.
  /// Nothing here opens, posts or runs anything.
  private func fixtureDispatcher() -> PluginHostRPC {
    let rpc = PluginHostRPC()
    rpc.onNormalModeTargetRequested = { (pid: 512, bundleID: "com.example.app", windowID: 4021) }
    rpc.onSyntheticKeysRequested = { _, _, _ in }
    rpc.wifiInfoProvider = wifi
    rpc.audioDevices = AudioDeviceStub()
    rpc.systemActions = SystemActionStub()
    rpc.processSignals = ProcessSignalStub()
    rpc.processTable = HostProcessTable(kernel: ProcessKernelStub.corpus())
    rpc.calendarEvents = HostCalendarEvents(
      provider: CalendarEventStub.corpus(), scheduler: PollScheduler(), changed: {})
    for kind in HostAppItemKind.allCases {
      rpc.appItems[kind] = AppItemStub.host(kind, AppItemStub.corpus(kind))
    }
    rpc.appleScriptRunner = { _, _ in
      AppleScriptOutput(status: 0, stdout: "Focus\nRest\n", stderr: "")
    }
    rpc.browserEngines = { .sample }
    return rpc
  }

  private let wifi = WiFi()

  private func hostReply(_ rpc: PluginHostRPC, _ line: CorpusLine) -> [String: Any] {
    let lock = NSLock()
    var reply: [String: Any] = [:]
    let replied = expectation(description: line.name)
    rpc.handleHostRequest(
      method: line.method ?? "", params: line.params, pluginID: "example",
      capabilities: Set(PluginCapability.allCases),
      fetchURLs: ["https://api.example.com/"],
      appleEventsTargets: [
        "com.apple.Safari", "com.apple.Music", "com.apple.shortcuts.events",
        "com.apple.systemevents",
      ],
      scope: PluginHostRequestScope(isCurrent: { true })
    ) { result in
      lock.lock()
      reply = result
      lock.unlock()
      replied.fulfill()
    }
    wait(for: [replied], timeout: 5)
    lock.lock()
    defer { lock.unlock() }
    return reply
  }

  func testTheHostAnswersEachHostRPCWithTheReplyTheCorpusNames() throws {
    let (opener, handler, appOpener) = (
      PluginHostRPC.urlOpener, PluginHostRPC.urlHandler, PluginHostRPC.appOpener
    )
    defer {
      (PluginHostRPC.urlOpener, PluginHostRPC.urlHandler, PluginHostRPC.appOpener) = (
        opener, handler, appOpener
      )
    }
    PluginHostRPC.urlOpener = { _ in true }
    // Only `https:` links have an application in the fixture.
    PluginHostRPC.urlHandler = { $0.scheme == "https" ? "com.apple.Safari" : nil }
    PluginHostRPC.appOpener = { _, done in done(nil) }
    let replies = Dictionary(uniqueKeysWithValues: hostFrames.map { ($0.name, $0) })
    var answered: Set<String> = []
    for line in pluginFrames where line.method?.hasPrefix("host.") == true {
      guard let name = line.reply else {
        XCTAssertTrue(line.accepted, "\(line.name): a refused request names its reply")
        continue
      }
      answered.insert(line.method ?? "")
      let expected = try XCTUnwrap(replies[name]?.result, name)
      // Each line meets the fixture as the corpus describes it, not as an
      // earlier line left it.
      let reply = hostReply(fixtureDispatcher(), line)
      XCTAssertTrue(
        JSONSchemaValidator.equal(reply, expected), "\(line.name): \(reply) is not \(name)")
      if !line.accepted {
        XCTAssertEqual(PluginJSON.boolean(reply["ok"]), false, line.name)
      }
    }
    // Every host RPC is answered here at least once, and so is a method the
    // host does not have.
    XCTAssertEqual(answered, Set(try Self.methods().hostRPCs + ["host.teleport"]))
  }

  // MARK: - What the host writes

  /// The request payloads the host builds are the corpus's.
  func testTheHostEncodesTheContextsAndRowsTheCorpusShows() throws {
    let lines = Dictionary(uniqueKeysWithValues: hostFrames.map { ($0.name, $0) })
    let frame = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let context = AppContext(
      bundleIdentifier: "com.example.app", processID: 512, runningApp: .current,
      frontWindowFrame: frame, allScreensFrame: frame,
      displays: [AppContext.Display(frame: frame, scale: 2)])
    XCTAssertTrue(
      JSONSchemaValidator.equal(
        PluginWireCodec.spatialContextJSON(context), try XCTUnwrap(lines["hints"]).params))
    XCTAssertTrue(
      JSONSchemaValidator.equal(
        PluginWireCodec.spatialContextJSON(context), try XCTUnwrap(lines["text_grid"]).params))
    let command = try XCTUnwrap(lines["perform.command.core"]).params
    XCTAssertTrue(
      JSONSchemaValidator.equal(
        PluginWireCodec.contextJSON(context), try XCTUnwrap(command["context"])))

    for (name, count) in [("perform.command.counted", 5), ("perform.command.uncounted", 1)] {
      var own = PluginManager.commandParams(
        command: "example", subcommand: "repeat", args: [], count: count)
      own["kind"] = "command"
      XCTAssertTrue(JSONSchemaValidator.equal(own, try XCTUnwrap(lines[name]).params), name)
    }

    // An own command's arguments go out in the one spelling its declaration
    // gives them, whatever order and spelling they were typed in.
    let declared = DeclaredArguments(parameters: [
      CommandParameter(name: "name", kind: .text("name"), required: true, positional: true),
      CommandParameter(name: "times", kind: .integer(min: 1, max: nil), required: false),
      CommandParameter(name: "mode", kind: .choice(["fast", "slow"]), required: false),
      CommandParameter(name: "dry_run", kind: .flag, required: false),
      CommandParameter(name: "loud", kind: .flag, required: false),
    ])
    var measure = PluginManager.commandParams(
      command: "example", subcommand: "measure",
      args: try XCTUnwrap(
        declared.canonical(["--dry_run=true", "--mode=fast", "--loud=0", "--times=+2", "Daft Punk"])
      ))
    measure["kind"] = "command"
    XCTAssertTrue(
      JSONSchemaValidator.equal(
        measure, try XCTUnwrap(lines["perform.command.declared"]).params))

    for (name, confirmed) in [
      ("perform.command.confirmed", true), ("perform.command.unconfirmed", false),
    ] {
      let own = PluginProcess.performParams(
        kind: "command",
        params: PluginManager.commandParams(command: "example", subcommand: "confirm", args: []),
        confirmed: confirmed)
      XCTAssertTrue(JSONSchemaValidator.equal(own, try XCTUnwrap(lines[name]).params), name)
    }
    // A row comes back in its resolve as the plugin wrote it, its question
    // included, and marked once the user answered it.
    let asking = Candidate(
      title: "Restart",
      metadata: [
        CandidateMetadataKey.source: "example.items",
        CandidateMetadataKey.sourceID: "plugin:example",
      ], confirm: "Restart this Mac?")
    XCTAssertTrue(
      JSONSchemaValidator.equal(
        PluginProcess.performParams(
          kind: "resolve", params: ["row": PluginWireCodec.candidateJSON(asking)],
          confirmed: true),
        try XCTUnwrap(lines["perform.resolve.confirmed"]).params))

    let row = Candidate(
      title: "Example row", url: URL(string: "https://example.com/a"),
      metadata: [
        CandidateMetadataKey.source: "example.items",
        CandidateMetadataKey.sourceID: "plugin:example",
        CandidateMetadataKey.subtitle: "First",
      ], effect: .copyText("Example row"))
    let resolve = try XCTUnwrap(lines["perform.resolve"]).params
    XCTAssertTrue(
      JSONSchemaValidator.equal(
        PluginWireCodec.candidateJSON(row), try XCTUnwrap(resolve["row"])))

    func event(_ event: PluginEvent) throws -> Any {
      try JSONSerialization.jsonObject(with: try XCTUnwrap(PluginProcess.encodedEventFrame(event)))
    }
    XCTAssertTrue(
      JSONSchemaValidator.equal(
        try event(
          .axChanged(pid: 512, notification: "AXValueChanged", bundleID: "com.example.app")),
        try XCTUnwrap(lines["event.ax-changed"]).value))
    XCTAssertTrue(
      JSONSchemaValidator.equal(
        try event(.axChanged(pid: 512, notification: "AXTitleChanged", bundleID: nil)),
        try XCTUnwrap(lines["event.ax-changed.without-bundle-id"]).value))
    XCTAssertTrue(
      JSONSchemaValidator.equal(
        try event(
          .appsChanged([
            ["bundle_id": "com.example.app", "pid": 512, "localized_name": "Example"],
            ["bundle_id": "com.example.other", "pid": 640, "localized_name": "Other"],
          ])), try XCTUnwrap(lines["event.apps-changed"]).value))
    XCTAssertTrue(
      JSONSchemaValidator.equal(
        try event(PluginEvent(.sessionOpened)),
        try XCTUnwrap(lines["event.session-opened"]).value))
  }
}
