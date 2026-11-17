import FlashCore
import Foundation
import XCTest

@testable import flash

final class PluginSystemTests: XCTestCase {
  /// Single-row conveniences over the atomic plural decoders — the wire only
  /// ever carries arrays, so production has no singular path.
  private func decodeRow(
    from raw: [String: Any], sourceID: String, allowed: Set<String>
  ) -> Candidate? {
    PluginWireCodec.publishedRows([raw], sourceID: sourceID, allowedSources: allowed)?
      .rows.first
  }

  private func decodeQueryAnswer(
    from raw: [String: Any], sourceID: String, source: String
  ) -> Candidate? {
    PluginWireCodec.queryAnswers(from: [raw], sourceID: sourceID, source: source)?.first
  }

  // MARK: - Wire codec

  func testNullOptionalFieldsDecodeAsAbsent() throws {
    // `{"url": null}` is the natural serialization of an absent optional in
    // most languages; it must decode like a missing key, not atomically
    // reject the catalog.
    let candidate = try XCTUnwrap(
      decodeRow(
        from: [
          "source": "safe.items",
          "title": "Row",
          "url": NSNull(),
          "effect": NSNull(),
          "metadata": NSNull(),
        ],
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))
    XCTAssertNil(candidate.url)
    XCTAssertNil(candidate.effect)

    let answer = try XCTUnwrap(
      decodeQueryAnswer(
        from: [
          "title": "2",
          "subtitle": NSNull(),
          "effect": ["type": "copy_text", "text": "2"],
        ],
        sourceID: "plugin:answers",
        source: "answers"))
    XCTAssertEqual(answer.title, "2")

    // Required fields stay required: null means absent, and an absent query
    // effect is still a rejection.
    XCTAssertNil(
      decodeQueryAnswer(
        from: ["title": "x", "effect": NSNull()],
        sourceID: "plugin:answers",
        source: "answers"))
  }

  func testPluginRowCannotSpoofRoutingOwner() throws {
    // `source` is a first-class row field and must name a declared manifest
    // source; routing source_id is always host-stamped, even when the
    // metadata tries to smuggle one in.
    let candidate = try XCTUnwrap(
      decodeRow(
        from: [
          "source": "safe.items",
          "title": "Owned result",
          "metadata": [
            "source": "spoofed.items",
            "source_id": "plugin:attacker",
          ],
        ],
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))

    XCTAssertEqual(candidate.source, "safe.items")
    XCTAssertEqual(candidate.sourceID, "plugin:safe")

    XCTAssertNil(
      decodeRow(
        from: [
          "source": "other.items",
          "title": "Impostor",
        ],
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))
    // A row without a first-class source is malformed — the magic
    // metadata.source key no longer routes.
    XCTAssertNil(
      decodeRow(
        from: [
          "title": "No source",
          "metadata": ["source": "safe.items"],
        ],
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))
  }

  func testPluginCatalogPayloadIsStrictBoundedAndAtomic() throws {
    let valid: [String: Any] = [
      "source": "safe.items",
      "title": "Safe result",
      "url": "https://example.com/item",
      "metadata": ["kind": "document"],
    ]
    XCTAssertEqual(
      PluginWireCodec.publishedRows(
        [valid],
        sourceID: "plugin:safe",
        allowedSources: ["safe.items"])?.rows.count,
      1)

    var unknownKey = valid
    unknownKey["command"] = "spoof"
    XCTAssertNil(
      PluginWireCodec.publishedRows(
        [valid, unknownKey],
        sourceID: "plugin:safe",
        allowedSources: ["safe.items"]),
      "one malformed row rejects the complete catalog")

    var nonStringMetadata = valid
    nonStringMetadata["metadata"] = ["pid": 123]
    XCTAssertNil(
      decodeRow(
        from: nonStringMetadata,
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))

    var relativeURL = valid
    relativeURL["url"] = "relative/path"
    XCTAssertNil(
      decodeRow(
        from: relativeURL,
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))

    var oversizedTitle = valid
    oversizedTitle["title"] = String(
      repeating: "x",
      count: PluginProtocol.maxTitleBytes + 1)
    XCTAssertNil(
      decodeRow(
        from: oversizedTitle,
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))

    XCTAssertNil(
      PluginWireCodec.publishedRows(
        Array(
          repeating: valid,
          count: PluginProtocol.maxCatalogRows + 1),
        sourceID: "plugin:safe",
        allowedSources: ["safe.items"]))
  }

  func testPluginHintTargetCannotSpoofProviderOwnership() throws {
    let target = PluginWireCodec.target(
      from: [
        "id": "hint",
        "frame": [
          "x": 10,
          "y": 20,
          "width": 30,
          "height": 40,
        ],
        "source_id": "plugin:attacker",
      ],
      sourceID: "plugin:safe")

    XCTAssertNil(target, "routing ownership never crosses the wire")
  }

  func testQueryAnswerHasANarrowShapeAndGetsHostOwnedSemantics() throws {
    let candidate = try XCTUnwrap(
      decodeQueryAnswer(
        from: [
          "title": "2",
          "subtitle": "1+1",
          "effect": ["type": "copy_text", "text": "2"],
        ],
        sourceID: "plugin:answers",
        source: "answers"))
    guard case .copyText(let text) = candidate.effect else {
      return XCTFail("expected copy_text effect")
    }
    XCTAssertEqual(text, "2")
    XCTAssertEqual(candidate.source, "answers")
    XCTAssertEqual(candidate.sourceID, "plugin:answers")
    XCTAssertEqual(candidate.kind, .plugin("query_answer"))
    XCTAssertEqual(candidate.priority, .urgent)
    XCTAssertTrue(candidate.finishesCommand)
    XCTAssertNil(candidate.url)

    XCTAssertNil(
      decodeQueryAnswer(
        from: [
          "title": "unsafe",
          "effect": ["type": "unknown", "text": "unsafe"],
        ],
        sourceID: "plugin:answers",
        source: "answers"))
    XCTAssertNil(
      decodeQueryAnswer(
        from: [
          "title": "empty",
          "effect": ["type": "copy_text", "text": ""],
        ],
        sourceID: "plugin:answers",
        source: "answers"))
    XCTAssertNil(
      decodeQueryAnswer(
        from: [
          "title": "spoof",
          "url": "https://example.com",
          "effect": ["type": "copy_text", "text": "spoof"],
        ],
        sourceID: "plugin:answers",
        source: "answers"))
    XCTAssertNil(
      decodeQueryAnswer(
        from: [
          "title": "extra effect field",
          "effect": [
            "type": "copy_text",
            "text": "unsafe",
            "url": "https://example.com",
          ],
        ],
        sourceID: "plugin:answers",
        source: "answers"))
  }

  func testQueryEvaluatorAnswerPayloadsAreRejectedAtomicallyAboveTheCap() {
    let answer: [String: Any] = [
      "title": "2",
      "effect": ["type": "copy_text", "text": "2"],
    ]
    XCTAssertEqual(PluginProtocol.maxAnswers, 16)
    XCTAssertEqual(
      PluginWireCodec.queryAnswers(
        from: Array(repeating: answer, count: 16),
        sourceID: "plugin:answers",
        source: "answers")?.count,
      16)
    XCTAssertNil(
      PluginWireCodec.queryAnswers(
        from: Array(repeating: answer, count: 17),
        sourceID: "plugin:answers",
        source: "answers"))
  }

  func testQueryAnswerFieldAndAggregateLimitsAreStrict() {
    let oversizedField = String(
      repeating: "x",
      count: PluginProtocol.maxAnswerFieldBytes + 1)
    XCTAssertNil(
      decodeQueryAnswer(
        from: [
          "title": oversizedField,
          "effect": ["type": "copy_text", "text": "x"],
        ],
        sourceID: "plugin:answers",
        source: "answers"))

    let largeAnswer: [String: Any] = [
      "title": String(repeating: "t", count: PluginProtocol.maxAnswerFieldBytes),
      "subtitle": String(repeating: "s", count: PluginProtocol.maxAnswerFieldBytes),
      "effect": [
        "type": "copy_text",
        "text": String(repeating: "e", count: PluginProtocol.maxAnswerFieldBytes),
      ],
    ]
    XCTAssertNil(
      PluginWireCodec.queryAnswers(
        from: Array(
          repeating: largeAnswer,
          count: PluginProtocol.maxAnswers),
        sourceID: "plugin:answers",
        source: "answers"),
      "individually valid answers must still fit the aggregate response budget")
  }

  func testEffectVariantsDecodeAndOpenIsGatedToCatalogRows() throws {
    // insert_text decodes in both shapes.
    let insertAnswer = try XCTUnwrap(
      decodeQueryAnswer(
        from: [
          "title": "shrug",
          "effect": ["type": "insert_text", "text": "¯\\_(ツ)_/¯"],
        ],
        sourceID: "plugin:snippets",
        source: "snippets"))
    guard case .insertText(let inserted) = insertAnswer.effect else {
      return XCTFail("expected insert_text effect")
    }
    XCTAssertEqual(inserted, "¯\\_(ツ)_/¯")

    // Catalog rows accept open effects — url or bundle_id, exactly one.
    let openURLRow = try XCTUnwrap(
      decodeRow(
        from: [
          "source": "safe.items",
          "title": "Docs",
          "effect": ["type": "open", "url": "https://example.com/docs"],
        ],
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))
    XCTAssertEqual(openURLRow.effect, .openURL("https://example.com/docs"))
    let openAppRow = try XCTUnwrap(
      decodeRow(
        from: [
          "source": "safe.items",
          "title": "Calculator",
          "effect": ["type": "open", "bundle_id": "com.apple.calculator"],
        ],
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))
    XCTAssertEqual(openAppRow.effect, .openApplication("com.apple.calculator"))

    // A local file is never a row's effect: a sandboxed plugin could point
    // a row at a `.command` it wrote, and opening it would run outside the
    // sandbox.
    for url in ["file:///tmp/x.command", "FILE:///Applications/Terminal.app"] {
      XCTAssertNil(
        decodeRow(
          from: [
            "source": "safe.items", "title": "Settings", "effect": ["type": "open", "url": url],
          ],
          sourceID: "plugin:safe", allowed: ["safe.items"]),
        url)
    }

    // Schemeless URLs, both-keys, and neither-key forms are rejected.
    XCTAssertNil(
      decodeRow(
        from: [
          "source": "safe.items",
          "title": "bad",
          "effect": ["type": "open", "url": "not a url"],
        ],
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))
    XCTAssertNil(
      decodeRow(
        from: [
          "source": "safe.items",
          "title": "bad",
          "effect": [
            "type": "open",
            "url": "https://example.com",
            "bundle_id": "com.example",
          ],
        ],
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))

    // Query answers reject open — evaluators cannot manufacture navigation.
    XCTAssertNil(
      decodeQueryAnswer(
        from: [
          "title": "nav",
          "effect": ["type": "open", "url": "https://example.com"],
        ],
        sourceID: "plugin:answers",
        source: "answers"))
  }

  func testPluginProtocolVersionRequiresExactV1() {
    XCTAssertEqual(PluginProtocol.version, 1)
    XCTAssertTrue(
      PluginWireCodec.acceptsProtocolVersion([
        "ok": true,
        "protocol_version": 1,
      ]))
    XCTAssertFalse(PluginWireCodec.acceptsProtocolVersion(["protocol_version": 3]))
    XCTAssertFalse(PluginWireCodec.acceptsProtocolVersion(["ok": true]))
    XCTAssertFalse(PluginWireCodec.acceptsProtocolVersion(nil))
  }

  func testJSONScalarTypesAndPerformVariantsAreStrict() throws {
    func object(_ json: String) throws -> [String: Any] {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
    for json in [#"{"protocol_version":true}"#, #"{"protocol_version":1.5}"#] {
      XCTAssertFalse(PluginWireCodec.acceptsProtocolVersion(try object(json)), json)
    }
    XCTAssertNil(PluginWireCodec.okPayload(try object(#"{"ok":1}"#)))
    for json in [
      #"{"ok":true,"error":"contradiction"}"#,
      #"{"ok":false,"unhandled":true,"error":"effect failed"}"#,
      #"{"ok":true,"target_pid":"123"}"#,
      #"{"ok":true,"navigation_url":"relative/path"}"#,
    ] {
      guard case .failed = PluginWireCodec.performOutcome(from: try object(json)) else {
        XCTFail("malformed perform result must fail: \(json)")
        continue
      }
    }
  }

  func testCatalogQuotaCountsEncodedJSONAndHintsRequireNestedFrames() throws {
    let rows = Array(
      repeating: ["source": "safe", "title": String(repeating: "\n", count: 3_000)], count: 1_000)
    XCTAssertGreaterThan(
      try JSONSerialization.data(withJSONObject: rows).count, PluginProtocol.maxCatalogBytes)
    XCTAssertNil(
      PluginWireCodec.publishedRows(rows, sourceID: "plugin:safe", allowedSources: ["safe"]))
    XCTAssertNil(
      PluginWireCodec.target(
        from: ["id": "flat", "x": 0, "y": 0, "width": 1, "height": 1], sourceID: "plugin:safe"))
  }

  // MARK: - The perform trichotomy

  func testPerformOutcomeDecodeFollowsTheTrichotomy() {
    // ok:true carries optional pid/navigation/message.
    XCTAssertEqual(
      PluginWireCodec.performOutcome(from: [
        "ok": true,
        "target_pid": 123,
        "navigation_url": "tmux://window/main",
        "message": "switched",
      ]),
      .performed(
        pid: 123,
        navigationURL: URL(string: "tmux://window/main"),
        message: "switched"))
    XCTAssertEqual(
      PluginWireCodec.performOutcome(from: ["ok": true]),
      .performed(pid: nil, navigationURL: nil, message: nil))
    // {ok:false, unhandled:true} is the one blessed error-free NAK: the host
    // MAY fall back.
    XCTAssertEqual(
      PluginWireCodec.performOutcome(from: ["ok": false, "unhandled": true]),
      .unhandled)
    // {ok:false, error} means mine-but-broke: never falls back.
    XCTAssertEqual(
      PluginWireCodec.performOutcome(from: ["ok": false, "error": "boom"]),
      .failed("boom"))
    // Dispatched-but-no-reply (timeout, crash) coerces to failed — the
    // action may still land late and a fallback would double-fire.
    guard case .failed = PluginWireCodec.performOutcome(from: nil) else {
      return XCTFail("no reply must coerce to failed")
    }
    // The response law: a reply without boolean `ok` is failed too.
    guard case .failed = PluginWireCodec.performOutcome(from: ["result": "yes"]) else {
      return XCTFail("missing ok must coerce to failed")
    }
  }

  func testPerformNeverDispatchesToAnUnspawnablePlugin() throws {
    // Manifest-only: no process could ever serve this — settle unhandled
    // immediately, without burning the perform deadline.
    let manifest = try decodedManifest(
      """
      {
        "id": "manifest-only",
        "name": "Manifest only",
        "version": "1.0.0",
        "description": "fixture",
        "bindings": { "app save": { "": "cmd+s" } }
      }
      """)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-noexec-\(UUID().uuidString)")
    let process = PluginProcess(
      root: root, manifest: manifest, origin: .official, baseDataDir: root, watchFiles: false)
    let settled = expectation(description: "unhandled immediately")
    let started = CFAbsoluteTimeGetCurrent()
    process.perform(kind: "command", params: [:]) { outcome in
      XCTAssertEqual(outcome, .unhandled)
      XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 0.5)
      settled.fulfill()
    }
    wait(for: [settled], timeout: 1)
  }

  /// A warm catalog the user reaches by name (`@history`, `!fh`)
  /// stays reachable while none of the plugin's apps runs; a location pool
  /// alone stays gated on them.
  func testAScopedPluginWithANamedCatalogIsAlwaysActive() throws {
    func adapter(sources: String) throws -> PluginFlashSource {
      let manifest = try decodedManifest(
        """
        {
          "id": "scoped",
          "name": "Scoped",
          "version": "1.0.0",
          "description": "fixture",
          "exec": ["./p"],
          "only_bundle_ids": ["org.mozilla.firefox"],
          "sources": [\(sources)]
        }
        """)
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("flash-plugin-scoped-\(UUID().uuidString)")
      let process = PluginProcess(
        root: root, manifest: manifest, origin: .official, baseDataDir: root, watchFiles: false)
      return PluginFlashSource(plugin: process, store: PluginCatalogStore())
    }
    let tabs =
      #"{ "name": "firefox.tabs", "type": "tabs", "kind": "locations", "priority": "high" }"#
    let history =
      #"{ "name": "firefox.history", "type": "history", "kind": "default", "priority": "normal" }"#
    XCTAssertEqual(
      try adapter(sources: tabs).activationPolicy, .bundleIDs(["org.mozilla.firefox"]))
    XCTAssertEqual(try adapter(sources: "\(tabs), \(history)").activationPolicy, .always)
    XCTAssertEqual(try adapter(sources: history).activationPolicy, .always)
  }

  func testDeferredPerformSettlesUnhandledWhenSpawnNeverCompletes() throws {
    // An on-demand plugin whose binary cannot launch: the perform is never
    // dispatched, so at its deadline it settles `.unhandled` (fallback is
    // safe — nothing could have started).
    let manifest = try decodedManifest(
      """
      {
        "id": "ghost",
        "name": "Ghost",
        "version": "1.0.0",
        "description": "fixture",
        "exec": ["./does-not-exist"],
        "commands": [
          { "command": "ghost", "subcommand": "run", "description": "x" }
        ]
      }
      """)
    XCTAssertEqual(manifest.activation, .onDemand)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-ghost-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let process = PluginProcess(
      root: root, manifest: manifest, origin: .official, baseDataDir: root, watchFiles: false)
    let settled = expectation(description: "deferred perform settles unhandled")
    process.perform(kind: "command", params: [:], timeoutMs: 200) { outcome in
      XCTAssertEqual(outcome, .unhandled)
      settled.fulfill()
    }
    wait(for: [settled], timeout: 2)
    process.stopAndWait(reason: "test")
  }

  // MARK: - Catalog store

  func testCatalogStoreKeepsLastGoodOnRejectedPublish() {
    let store = PluginCatalogStore()
    let good: [[String: Any]] = [["source": "safe.items", "title": "Good"]]
    let decoded = PluginWireCodec.publishedRows(
      good, sourceID: "plugin:safe", allowedSources: ["safe.items"])!
    store.publish(pluginID: "safe", decoded)
    XCTAssertEqual(store.rows(for: "safe").map(\.title), ["Good"])

    // An over-quota publish decodes to nil and never touches the store —
    // the previous catalog is retained by construction.
    let overQuota = Array(
      repeating: ["source": "safe.items", "title": "Row"] as [String: Any],
      count: PluginProtocol.maxCatalogRows + 1)
    XCTAssertNil(
      PluginWireCodec.publishedRows(
        overQuota, sourceID: "plugin:safe", allowedSources: ["safe.items"]))
    XCTAssertEqual(store.rows(for: "safe").map(\.title), ["Good"])

    // Empty rows are an authoritative empty, not a rejection.
    store.publish(pluginID: "safe", .rows([]))
    XCTAssertTrue(store.rows(for: "safe").isEmpty)
    XCTAssertEqual(store.publishedPluginIDs(), ["safe"])

    store.drop(pluginID: "safe")
    XCTAssertTrue(store.rows(for: "safe").isEmpty)
    XCTAssertTrue(store.publishedPluginIDs().isEmpty)
  }

  func testCatalogStoreCoalescesChangeTicksLosslessly() {
    let store = PluginCatalogStore()
    store.notifyInterval = 0.05
    var ticks = 0
    let first = expectation(description: "burst tick")
    let second = expectation(description: "post-interval tick")
    store.onCatalogsChanged = { [weak store] in
      ticks += 1
      if ticks == 1 {
        // Lossless: by the time the coalesced tick lands, the store already
        // carries the whole burst's final rows.
        XCTAssertEqual(store?.rows(for: "p").map(\.title), ["9"])
        first.fulfill()
      }
      if ticks == 2 { second.fulfill() }
    }
    for index in 0..<10 {
      store.publish(pluginID: "p", .rows([Candidate(title: "\(index)")]))
    }
    wait(for: [first], timeout: 2)
    XCTAssertEqual(ticks, 1, "a publish burst collapses to one tick")
    // A later publish schedules a fresh (interval-spaced) tick.
    store.publish(pluginID: "p", .rows([Candidate(title: "later")]))
    wait(for: [second], timeout: 2)
    XCTAssertEqual(store.rows(for: "p").map(\.title), ["later"])
  }

  func testCatalogStoreIgnoresSemanticNoOpPublish() throws {
    let store = PluginCatalogStore()
    let first = Candidate(
      title: "Same",
      url: URL(string: "https://example.com"),
      metadata: ["source": "same.items"],
      effect: .copyText("Same"))
    store.publish(pluginID: "same", .rows([first], bytesPerRow: 20))
    let generation = try XCTUnwrap(store.entry(for: "same")?.generation)
    let publishedAt = try XCTUnwrap(store.entry(for: "same")?.publishedAt)

    var derivedCopy = first
    derivedCopy.displayTitle = "derived"
    derivedCopy.normalizedSearchText = "same"
    XCTAssertEqual(
      store.publish(pluginID: "same", .rows([derivedCopy], bytesPerRow: 999)), .unchanged)

    let entry = try XCTUnwrap(store.entry(for: "same"))
    XCTAssertEqual(entry.generation, generation)
    XCTAssertEqual(entry.publishedAt, publishedAt)
    // One row of 20 bytes, its separator and the brackets.
    XCTAssertEqual(entry.encodedBytes, 22)
  }

  // MARK: - Status segments

  /// A `status` that restates every segment unchanged schedules no status
  /// callback: the bar re-evaluates and host sources reconcile only for a
  /// value that moved.
  func testUnchangedStatusSegmentsScheduleNoNotification() throws {
    let manifest = try decodedManifest(
      """
      {
        "id": "seg",
        "name": "Seg",
        "version": "1.0.0",
        "description": "fixture",
        "exec": ["/usr/bin/true"],
        "status": ["session", "window"]
      }
      """)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-seg-\(UUID().uuidString)")
    let process = PluginProcess(
      root: root, manifest: manifest, origin: .official, baseDataDir: root, watchFiles: false)
    var notifications = 0
    process.onStatusChanged = { notifications += 1 }
    func settle() {
      let turn = expectation(description: "main turn")
      DispatchQueue.main.async { turn.fulfill() }
      wait(for: [turn], timeout: 1)
    }
    process.applyStatusSegments(["segments": ["session": "main", "window": "2"]])
    settle()
    XCTAssertEqual(notifications, 1)
    process.applyStatusSegments(["segments": ["session": "main", "window": "2"]])
    process.applyStatusSegments(["segments": ["window": "2"]])
    settle()
    XCTAssertEqual(notifications, 1, "a restatement wakes nobody")
    process.applyStatusSegments(["segments": ["window": "3"]])
    settle()
    XCTAssertEqual(notifications, 2)
    process.applyStatusSegments(["segments": ["session": ""]])
    settle()
    XCTAssertEqual(notifications, 3, "clearing a segment is a change")
    process.applyStatusSegments(["segments": ["session": ""]])
    settle()
    XCTAssertEqual(notifications, 3, "clearing an absent segment is not")
  }

  func testStatusSegmentUpdatesMergeWithoutLostUpdates() throws {
    let manifest = try decodedManifest(
      """
      {
        "id": "seg",
        "name": "Seg",
        "version": "1.0.0",
        "description": "fixture",
        "exec": ["/usr/bin/true"],
        "status": ["session", "window"]
      }
      """)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-seg-\(UUID().uuidString)")
    let process = PluginProcess(
      root: root, manifest: manifest, origin: .official, baseDataDir: root, watchFiles: false)
    // Two independent segment updates merge; neither clobbers the other.
    process.applyStatusSegments(["segments": ["session": "main"]])
    process.applyStatusSegments(["segments": ["window": "2"]])
    XCTAssertEqual(
      process.statusBarInfo().statusSegments,
      ["session": .text("main"), "window": .text("2")])
    // "" clears one segment; undeclared names are ignored.
    process.applyStatusSegments(["segments": ["session": "", "undeclared": "x"]])
    XCTAssertEqual(process.statusBarInfo().statusSegments, ["window": .text("2")])
    // A carousel object is a typed segment the host rotates; malformed
    // objects are rejected whole and no lines clears.
    process.applyStatusSegments([
      "segments": [
        "session": [
          "prefix": "NEWS ", "lines": ["one", " ", "two"], "cycle_seconds": 30,
        ]
      ]
    ])
    XCTAssertEqual(
      process.statusBarInfo().statusSegments["session"],
      .carousel(prefix: "NEWS ", lines: ["one", "two"], cycleSeconds: 30))
    process.applyStatusSegments(["segments": ["session": ["lines": ["x"], "cycle_seconds": 0]]])
    process.applyStatusSegments(["segments": ["session": ["lines": [1], "cycle_seconds": 5]]])
    process.applyStatusSegments(["segments": ["session": ["cycle_seconds": 5]]])
    XCTAssertEqual(
      process.statusBarInfo().statusSegments["session"],
      .carousel(prefix: "NEWS ", lines: ["one", "two"], cycleSeconds: 30))
    process.applyStatusSegments(["segments": ["session": ["lines": [" "], "cycle_seconds": 5]]])
    XCTAssertNil(process.statusBarInfo().statusSegments["session"])
  }

  // MARK: - Activation derivation

  func testActivationDerivesFromManifestSurfaces() throws {
    func activation(_ extra: String) throws -> PluginActivation {
      try decodedManifest(
        """
        {
          "id": "act",
          "name": "Act",
          "version": "1.0.0",
          "description": "fixture"\(extra)
        }
        """
      ).activation
    }
    // Resident: sources | query | hints | status | listen.
    XCTAssertEqual(
      try activation(#", "exec": ["/usr/bin/true"], "sources": [{"name": "a.b", "type": "b"}]"#),
      .resident)
    XCTAssertEqual(try activation(#", "exec": ["/usr/bin/true"], "query": {}"#), .resident)
    XCTAssertEqual(try activation(#", "exec": ["/usr/bin/true"], "hints": {}"#), .resident)
    XCTAssertEqual(
      try activation(#", "exec": ["/usr/bin/true"], "status": ["state"]"#), .resident)
    XCTAssertEqual(
      try activation(#", "exec": ["/usr/bin/true"], "listen": ["core:apps.*"]"#), .resident)
    // On-demand: only perform-driven surfaces.
    XCTAssertEqual(
      try activation(
        #", "exec": ["/usr/bin/true"], "commands": [{"command": "x", "subcommand": "go", "description": "x"}]"#
      ),
      .onDemand)
    XCTAssertEqual(
      try activation(
        #", "exec": ["/usr/bin/true"], "bangs": [{"token": "x"}]"#),
      .onDemand)
    XCTAssertEqual(
      try activation(#", "exec": ["/usr/bin/true"], "navigation": ["act"]"#), .onDemand)
    // Manifest-only: no exec at all.
    XCTAssertEqual(
      try activation(#", "bindings": {"app save": {"": "cmd+s"}}"#),
      .manifestOnly)
  }

  func testStatusBoundPluginIsResidentOnlyWhileObserved() throws {
    func manifest(_ extra: String) throws -> PluginManifest {
      try decodedManifest(
        """
        {
          "id": "bound",
          "name": "Bound",
          "version": "1.0.0",
          "description": "fixture"\(extra)
        }
        """
      )
    }
    // Status, the listen subscriptions feeding it, and perform surfaces.
    let bound = try manifest(
      #", "exec": ["/usr/bin/true"], "status": ["state"], "listen": ["core:power.changed"], "#
        + #""commands": [{"command": "x", "subcommand": "go", "description": "x"}]"#)
    XCTAssertTrue(bound.isStatusBound)
    XCTAssertEqual(bound.activation(statusObserved: true), .resident)
    XCTAssertEqual(bound.activation(statusObserved: false), .onDemand)
    // Any other resident surface keeps the plugin resident regardless.
    for extra in [
      #", "sources": [{"name": "a.b", "type": "b"}]"#, #", "query": {}"#, #", "hints": {}"#,
    ] {
      let other = try manifest(#", "exec": ["/usr/bin/true"], "status": ["state"]"# + extra)
      XCTAssertFalse(other.isStatusBound, extra)
      XCTAssertEqual(other.activation(statusObserved: false), .resident, extra)
    }
    let listening = try manifest(#", "exec": ["/usr/bin/true"], "listen": ["core:apps.*"]"#)
    XCTAssertEqual(listening.activation(statusObserved: false), .resident)
  }

  /// `lifecycle: publish_then_exit` declares a catalog-only plugin: `exec`
  /// and `sources`, nothing that needs a live child. `watch_settings` names
  /// the settings whose file the host watches to run it again, and belongs
  /// to that lifecycle alone. Any other spelling or combination is rejected
  /// at load, naming what to fix.
  func testPublishThenExitLifecycleDeclaresACatalogOnlyPlugin() throws {
    func manifest(_ extra: String) throws -> PluginManifest {
      try decodedManifest(
        """
        {
          "id": "catalog",
          "name": "Catalog",
          "version": "1.0.0",
          "description": "fixture"\(extra)
        }
        """
      )
    }
    func failure(_ extra: String) -> String {
      do {
        _ = try manifest(extra)
        return ""
      } catch {
        return String(describing: error)
      }
    }
    let sources = #", "exec": ["/usr/bin/true"], "sources": [{"name": "a.b", "type": "b"}]"#
    let catalog = try manifest(sources + #", "lifecycle": "publish_then_exit""#)
    XCTAssertEqual(catalog.lifecycle, .publishThenExit)
    XCTAssertEqual(catalog.activation, .publishThenExit)
    XCTAssertEqual(catalog.activation(statusObserved: false), .publishThenExit)
    XCTAssertFalse(catalog.isStatusBound)
    XCTAssertEqual(catalog.watchSettings, [])
    let watched = try manifest(
      sources + #", "lifecycle": "publish_then_exit", "watch_settings": [" file ", "file", ""]"#)
    XCTAssertEqual(watched.watchSettings, ["file"], "names are trimmed, unique and nonempty")
    XCTAssertNil(try manifest(sources).lifecycle, "absent: the surfaces decide")
    XCTAssertEqual(try manifest(sources).activation, .resident)

    XCTAssertTrue(
      failure(sources + #", "lifecycle": "resident""#).contains(
        "manifest.json lifecycle must be \"publish_then_exit\""),
      "the default has no spelling")
    XCTAssertTrue(
      failure(sources + #", "lifecycle": true"#).contains(
        "manifest.json lifecycle must be \"publish_then_exit\""))
    XCTAssertTrue(
      failure(#", "sources": [{"name": "a.b", "type": "b"}], "lifecycle": "publish_then_exit""#)
        .contains("manifest.json lifecycle publish_then_exit needs exec"))
    XCTAssertTrue(
      failure(#", "exec": ["/usr/bin/true"], "lifecycle": "publish_then_exit""#).contains(
        "manifest.json lifecycle publish_then_exit needs sources"))
    for (surface, message) in [
      (#""hints": {}"#, "hints"),
      (#""query": {}"#, "query"),
      (#""status": ["state"]"#, "status"),
      (#""listen": ["core:config.changed"]"#, "listen"),
      (#""commands": [{"command": "x", "subcommand": "go", "description": "x"}]"#, "commands"),
      (#""bangs": [{"token": "x"}]"#, "bangs"),
      (#""navigation": ["act"]"#, "navigation"),
    ] {
      let error = failure(sources + #", "lifecycle": "publish_then_exit", "# + surface)
      XCTAssertTrue(
        error.contains("manifest.json lifecycle publish_then_exit allows sources alone")
          && error.contains(message), "\(surface): \(error)")
    }
    XCTAssertTrue(
      failure(sources + #", "watch_settings": ["file"]"#).contains(
        "manifest.json watch_settings needs lifecycle publish_then_exit"))
    // Host-served surfaces stay allowed beside the catalog.
    XCTAssertNoThrow(
      try manifest(
        sources + #", "lifecycle": "publish_then_exit", "#
          + #""bindings": {"app save": {"": "cmd+s"}}, "help": {"topics": []}"#))
  }

  // MARK: - Manifest schema

  func testManifestLoadsRequiredFields() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "spotify",
          "name": "Spotify",
          "version": "0.1.0",
          "description": "Spotify controls",
          "install": "npm install",
          "exec": ["npm", "start"],
          "listen": [
            "core:apps.*",
            "core:config.*"
          ],
          "only_bundle_ids": ["com.spotify.client"],
          "commands": [
            { "command": "spotify", "subcommand": "pause", "description": "Pause playback" }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.id, "spotify")
    XCTAssertEqual(manifest.install, "npm install")
    XCTAssertEqual(manifest.exec, ["npm", "start"])
    XCTAssertEqual(manifest.listen, ["core:apps.*", "core:config.*"])
    XCTAssertEqual(manifest.onlyBundleIDs, ["com.spotify.client"])
    XCTAssertEqual(manifest.commands.first?.command, "spotify")
    XCTAssertEqual(manifest.commands.first?.subcommand, "pause")
    XCTAssertTrue(manifest.mappings.isEmpty, "absent mappings key defaults to []")
    XCTAssertEqual(manifest.activation, .resident)
  }

  func testManifestRejectsLegacyTopLevelKeys() throws {
    // The v1-redefinition retired these outright (no compat shims): every
    // one must fail as an unknown key, never decode as dead weight.
    let legacy: [(String, String)] = [
      ("shebangs", #"{"command": "x", "items": []}"#),
      ("queries", #"{"exclusive_prefixes": ["="]}"#),
      ("source_actions", #"["tab_new"]"#),
      ("volatile", "true"),
      ("request_timeout_ms", "8000"),
      ("only_urls", #"["https://example.com/*"]"#),
      ("manifest_version", "2"),
    ]
    for (key, value) in legacy {
      let root = try temporaryPluginRoot(
        manifest:
          """
          {
            "id": "legacy",
            "name": "Legacy",
            "version": "0.1.0",
            "description": "Legacy key",
            "install": "true",
            "exec": ["/usr/bin/true"],
            "\(key)": \(value)
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }

      XCTAssertThrowsError(try PluginManifest.load(from: root), key) { error in
        XCTAssertTrue(String(describing: error).contains("manifest.json unknown field \(key)"))
      }
    }
  }

  /// Surfaces no bundled plugin used left the manifest outright (no compat
  /// shims): a manifest still declaring one fails to load with the strict
  /// unknown-field error, like any typo.
  func testRemovedManifestSurfacesFailAsUnknownFields() throws {
    let fixtures: [(String, String)] = [
      (#""verbs": [{ "name": "app_save" }]"#, "manifest.json unknown field verbs"),
      (
        #""commands": [{ "command": "removed", "subcommand": "go", "timeout_ms": 300000 }]"#,
        "manifest.json commands[0] unknown field timeout_ms"
      ),
      (
        #""help": { "topics": [{ "name": "removed", "aliases": ["gone"] }] }"#,
        "manifest.json help.topics[0] unknown field aliases"
      ),
      (
        #""sandbox": { "exec": ["/usr/bin/pmset"] }"#,
        "manifest.json sandbox unknown field exec"
      ),
      (
        #""bangs": [{ "token": "r", "command": "removed" }]"#,
        "manifest.json bangs[0] unknown field command"
      ),
    ]
    for (fragment, expected) in fixtures {
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "removed",
            "name": "Removed",
            "version": "1.0.0",
            "description": "Removed surface fixture",
            "exec": ["/usr/bin/true"],
            \(fragment)
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      XCTAssertThrowsError(try PluginManifest.load(from: root), fragment) { error in
        XCTAssertTrue(String(describing: error).contains(expected), String(describing: error))
      }
    }
  }

  /// `bangs` is the list of entries itself: the old `{command, items}`
  /// wrapper is malformed, not read.
  func testBangsAreAPlainListOfEntries() throws {
    func load(_ bangs: String) throws -> PluginManifest {
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "banger",
            "name": "Banger",
            "version": "1.0.0",
            "description": "fixture",
            "exec": ["/usr/bin/true"],
            "bangs": \(bangs)
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      return try PluginManifest.load(from: root)
    }
    let manifest = try load(#"[{ "token": "b", "description": "Bang" }, { "token": "*" }]"#)
    XCTAssertEqual(manifest.bangs.map(\.token), ["b", "*"])
    XCTAssertEqual(manifest.bangs.first?.description, "Bang")
    XCTAssertThrowsError(try load(#"{ "command": "banger", "items": [{ "token": "b" }] }"#))
  }

  func testManifestOnlyPluginRejectsProcessBoundSurfaces() throws {
    let root = try temporaryPluginRoot(
      manifest: """
        {
          "id": "no-process",
          "name": "No process",
          "version": "1.0.0",
          "description": "fixture",
          "install": "true",
          "commands": [
            { "command": "no-process", "subcommand": "ping", "description": "x" }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue(
        String(describing: error).contains("without exec cannot declare commands"))
    }
  }

  /// `network` only composes `network-outbound` into the deny-default
  /// profile; an unsandboxed process has nothing for it to grant.
  func testNetworkCapabilityRequiresTheSandbox() throws {
    func load(_ fields: String) throws -> PluginManifest {
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "networked",
            "name": "Networked",
            "version": "1.0.0",
            "description": "fixture",
            "exec": ["/usr/bin/true"],
            "status": ["state"],
            \(fields)
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      return try PluginManifest.load(from: root)
    }
    XCTAssertEqual(try load(#""capabilities": ["network"]"#).capabilities, [.network])
    XCTAssertEqual(
      try load(#""sandbox": {}, "capabilities": ["network"]"#).capabilities, [.network])
    XCTAssertThrowsError(try load(#""sandbox": false, "capabilities": ["network"]"#)) { error in
      XCTAssertTrue(
        String(describing: error).contains(
          "network capability only composes the sandbox profile; an unsandboxed plugin cannot "
            + "declare it"),
        String(describing: error))
    }
    XCTAssertEqual(try load(#""sandbox": false, "capabilities": ["open"]"#).capabilities, [.open])
  }

  func testManifestRejectsUnknownNestedFieldsUniformly() throws {
    let fixtures: [(String, String)] = [
      (
        #""commands": [{ "command": "demo", "description": "Demo", "descrption": "typo" }]"#,
        "manifest.json commands[0] unknown field descrption"
      ),
      (
        #""sources": [{ "name": "demo.items", "type": "items", "priority": "normal", "priorty": 2 }]"#,
        "manifest.json sources[0] unknown field priorty"
      ),
      (
        #""sources": [{ "name": "demo.items", "type": "items", "mode": "live" }]"#,
        "manifest.json sources[0] unknown field mode"
      ),
      (
        #""sources": [{ "name": "demo.items", "type": "items", "live": true }]"#,
        "manifest.json sources[0] unknown field live"
      ),
      (
        #""help": { "topics": [{ "name": "demo", "title": "Demo", "summray": "typo" }] }"#,
        "manifest.json help.topics[0] unknown field summray"
      ),
      (
        #""query": { "regex": "^.+$" }"#,
        "manifest.json query unknown field regex"
      ),
      (
        #""bangs": [{ "token": "x", "candidate_source": "y" }]"#,
        "manifest.json bangs[0] unknown field candidate_source"
      ),
      (
        #""sandbox": { "read": ["~/Library"] }"#,
        "manifest.json sandbox unknown field read"
      ),
      (
        #""sandbox": { "signal": true }"#,
        "manifest.json sandbox unknown field signal"
      ),
      // A sandboxed sender cannot script apps: macOS refuses its Apple Events.
      (
        #""sandbox": { "appleevents": true }"#,
        "manifest.json sandbox unknown field appleevents"
      ),
      (
        #""mappings": [{ "key": "R", "command": ["true"], "only_urls": ["x://*"] }]"#,
        "manifest.json mappings[0] unknown field only_urls"
      ),
    ]

    for (fragment, expected) in fixtures {
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "nested",
            "name": "Nested",
            "version": "1.0.0",
            "description": "Nested schema fixture",
            "install": "true",
            "exec": ["/usr/bin/true"],
            \(fragment)
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }

      XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
        XCTAssertTrue(String(describing: error).contains(expected), String(describing: error))
      }
    }
  }

  func testManifestOnlyTerminalsScopesToHostTerminalList() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "tmuxish",
          "name": "tmuxish",
          "version": "0.1.0",
          "description": "Terminal-scoped hints",
          "exec": ["/usr/bin/true"],
          "only_terminals": true,
          "hints": { "fallback_on_empty": true }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertTrue(manifest.selector.onlyTerminals)
    XCTAssertTrue(manifest.onlyBundleIDs.isEmpty)
    let selector = CompiledPluginSelector(manifest.selector)
    XCTAssertFalse(selector.isEmpty)
    TerminalEmulatorFixture.declareOfficial()
    XCTAssertTrue(TerminalEmulators.contains("com.mitchellh.ghostty"))
    XCTAssertTrue(selector.matches(PluginSelectorContext(bundleID: "com.mitchellh.ghostty")))
    XCTAssertTrue(selector.matches(PluginSelectorContext(bundleID: "org.alacritty")))
    XCTAssertFalse(selector.matches(PluginSelectorContext(bundleID: "org.mozilla.firefox")))
    XCTAssertFalse(selector.matches(PluginSelectorContext(bundleID: nil)))
    XCTAssertEqual(selector.specificity(in: PluginSelectorContext(bundleID: "org.alacritty")), 1)
    XCTAssertNil(selector.specificity(in: PluginSelectorContext(bundleID: "org.mozilla.firefox")))

    let compound = CompiledPluginSelector(
      PluginSelector(onlyBundleIDs: ["org.alacritty"], onlyTerminals: true))
    XCTAssertTrue(compound.matches(PluginSelectorContext(bundleID: "org.alacritty")))
    XCTAssertFalse(compound.matches(PluginSelectorContext(bundleID: "com.mitchellh.ghostty")))
  }

  /// The terminals plugin declares the emulators and is scoped to them: its
  /// tmux hints, sources and actions exist only in a declared terminal.
  func testBundledTerminalsManifestIsTerminalScoped() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Plugins/terminals")
    let manifest = try PluginManifest.load(from: root)
    XCTAssertTrue(manifest.selector.onlyTerminals)
    XCTAssertEqual(manifest.hints?.fallbackOnEmpty, true)
    XCTAssertEqual(manifest.activation, .resident)
    XCTAssertNil(manifest.sandboxSpec, "tmux and ssh run outside the profile")
    XCTAssertFalse(manifest.terminalEmulators.isEmpty)
  }

  /// `own_text_editing` is app knowledge the host serves alone, like
  /// `terminal_emulators`: trimmed, deduplicated, open to a manifest-only
  /// plugin, and rejected when it is not a list of strings.
  func testManifestDeclaresOwnTextEditingLikeTerminalEmulators() throws {
    let manifest = try decodedManifest(
      """
      {
        "id": "editors",
        "name": "Editors",
        "version": "1.0.0",
        "description": "fixture",
        "own_text_editing": [" com.example.editor ", "com.example.editor", "dev.example.ide", ""]
      }
      """)
    XCTAssertEqual(manifest.ownTextEditing, ["com.example.editor", "dev.example.ide"])
    XCTAssertEqual(manifest.activation, .manifestOnly, "an app declaration needs no process")
    for malformed in [
      #""own_text_editing": "com.example.editor""#,
      #""own_text_editing": [1]"#,
      #""own_text_editing": {"com.example.editor": true}"#,
    ] {
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "editors",
            "name": "Editors",
            "version": "1.0.0",
            "description": "fixture",
            \(malformed)
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      XCTAssertThrowsError(try PluginManifest.load(from: root), malformed)
    }
  }

  func testManifestDecodesSurfacesAcrossKinds() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "multi",
          "name": "Multi",
          "version": "0.1.0",
          "description": "Every surface, flattened",
          "install": "true",
          "exec": ["/usr/bin/true"],
          "only_bundle_ids": ["com.example.app"],
          "sources": [
            { "name": "multi.items", "type": "items" }
          ],
          "navigation": ["multi"],
          "status": ["battery"],
          "hints": { "fallback_on_empty": true },
          "query": { "prefixes": ["="] },
          "commands": [
            { "command": "multi", "subcommand": "go", "description": "Go" },
            { "command": "resource", "subcommand": "archive" },
            { "command": "resource", "subcommand": "next" }
          ],
          "bangs": [
            { "token": "m", "description": "Multi", "source": "multi.items" }
          ],
          "mappings": [
            { "key": "q", "command": ["flash", "hints", "dismiss"] }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertTrue(manifest.providesHints)
    XCTAssertTrue(try XCTUnwrap(manifest.hints).fallbackOnEmpty)
    XCTAssertTrue(manifest.providesCandidates)
    XCTAssertTrue(manifest.providesQueryEvaluation)
    XCTAssertEqual(manifest.query?.prefixes, ["="])
    XCTAssertEqual(manifest.candidateSources, ["multi.items"])
    XCTAssertEqual(manifest.navigationSchemes, ["multi"])
    XCTAssertEqual(
      manifest.sourceCommands,
      [CommandName("resource", "archive"), CommandName("resource", "next")])
    XCTAssertEqual(manifest.statusSegments, ["battery"])
    XCTAssertEqual(manifest.commands.count, 3)
    XCTAssertEqual(manifest.pluginCommands.map(\.subcommand), ["go"])
    XCTAssertEqual(manifest.bangs.map(\.token), ["m"])
    XCTAssertEqual(manifest.bangs.first?.source, "multi.items")
    XCTAssertEqual(manifest.mappings.map(\.key), ["q"])
    XCTAssertEqual(manifest.activation, .resident)
  }

  func testManifestDecodesMappingsWithDefaults() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "spotify",
          "name": "Spotify",
          "version": "0.1.0",
          "description": "Spotify",
          "install": "true",
          "exec": ["/usr/bin/true"],
          "mappings": [
            { "key": "q", "command": ["flash", "spotify", "run"] },
            {
              "key": "ctrl+k",
              "mode": "insert",
              "command": ["flash", "hints", "dismiss"],
              "only_bundle_ids": ["com.spotify.client"],
              "priority": 40,
              "repeat": true
            },
            {
              "key": "cmd+r",
              "mode": "terminal",
              "command": ["flash", "mode", "normal"]
            }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.mappings.count, 3)

    let first = try XCTUnwrap(manifest.mappings.first)
    XCTAssertEqual(first.key, "q")
    XCTAssertEqual(first.mode, "normal", "mode defaults to normal")
    XCTAssertEqual(first.scope, .normal)
    XCTAssertTrue(first.selector.onlyBundleIDs.isEmpty, "only_bundle_ids defaults to []")
    XCTAssertNil(first.priority, "priority is optional")
    XCTAssertFalse(first.repeatsOnFinalKey, "repeat defaults to false")

    let second = manifest.mappings[1]
    XCTAssertEqual(second.mode, "insert")
    XCTAssertEqual(second.scope, .insert)
    XCTAssertEqual(second.selector.onlyBundleIDs, ["com.spotify.client"])
    XCTAssertEqual(second.priority, 40)
    XCTAssertTrue(second.repeatsOnFinalKey)
    XCTAssertEqual(manifest.mappings[2].scope, .terminal)
  }

  func testManifestDecodesBindingsAndRejectsUnknownCommandsOrChords() throws {
    let valid = try temporaryPluginRoot(
      manifest: """
        {
          "id": "chords",
          "name": "Chords",
          "version": "1.0.0",
          "description": "Bindings",
          "only_bundle_ids": ["com.example.browser", "com.example.other"],
          "bindings": {
            "tab next": { "": "cmd+shift+]" },
            "app reload --force": { "": "cmd+shift+r", "com.example.other": "cmd+option+r" },
            "history back": { "com.example.other": false }
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: valid) }
    let manifest = try PluginManifest.load(from: valid)
    XCTAssertEqual(manifest.activation, .manifestOnly, "bindings need no process")
    XCTAssertEqual(manifest.bindings[key("tab next")], ["": .chords(["cmd+shift+]"])])
    XCTAssertEqual(
      manifest.bindings[key("app reload --force")]?["com.example.other"],
      .chords(["cmd+option+r"]))
    XCTAssertEqual(
      manifest.bindings[key("history back")], ["com.example.other": CommandBindingSpec.unbound],
      "false declares that the app has no such command")

    for (fragment, message) in [
      (
        #""tab sideways": { "": "cmd+k" }"#,
        "tab sideways is not a command Flash asks of the focused app"
      ),
      (#""tab_next": { "": "cmd+k" }"#, "tab_next is not a command Flash asks of the focused app"),
      (#""tab next": { "": "cmd+shift+nope" }"#, "not a chord"),
      (#""tab next": { "": "" }"#, "use false for none"),
    ] {
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "badchords",
            "name": "Bad chords",
            "version": "1.0.0",
            "description": "Invalid bindings",
            "bindings": { \(fragment) }
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
        XCTAssertTrue(String(describing: error).contains(message), "\(error)")
      }
    }
  }

  /// A `commands[]` entry under one of Flash's topics is a core command the
  /// plugin performs where its selector matches; every other entry is the
  /// plugin's own command. Only the latter register for dispatch.
  func testManifestSplitsOwnAndCoreCommands() throws {
    let root = try temporaryPluginRoot(
      manifest: """
        {
          "id": "split",
          "name": "Split",
          "version": "1.0.0",
          "description": "Own and core commands",
          "exec": ["/usr/bin/true"],
          "only_bundle_ids": ["com.example.app"],
          "commands": [
            { "command": "example", "subcommand": "run", "description": "Run" },
            { "command": "tab", "subcommand": "close" }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.pluginCommands.map(\.command), ["example"])
    XCTAssertEqual(manifest.sourceCommands, [CommandName("tab", "close")])
    XCTAssertEqual(manifest.confirmations, [:])
    XCTAssertEqual(manifest.activation, .onDemand, "an own command keeps on-demand activation")
    let tabClose = CommandName("tab", "close")
    XCTAssertTrue(
      manifest.performs(tabClose, in: PluginSelectorContext(bundleID: "com.example.app")))
    XCTAssertFalse(
      manifest.performs(tabClose, in: PluginSelectorContext(bundleID: "com.example.other")),
      "the selector gates the claim")
    XCTAssertFalse(
      manifest.performs(
        CommandName("tab", "new"), in: PluginSelectorContext(bundleID: "com.example.app")))
    // A core entry alone is still a process-bound surface.
    let coreOnly = try temporaryPluginRoot(
      manifest: """
        {
          "id": "core", "name": "Core", "version": "1.0.0", "description": "fixture",
          "exec": ["/usr/bin/true"],
          "commands": [{ "command": "tab", "subcommand": "close" }]
        }
        """)
    defer { try? FileManager.default.removeItem(at: coreOnly) }
    let core = try PluginManifest.load(from: coreOnly)
    XCTAssertEqual(core.pluginCommands, [])
    XCTAssertEqual(core.activation, .onDemand)
  }

  /// A core-topic entry must name a command Flash asks of the focused app:
  /// the wildcard, an unknown action and a command Flash performs itself
  /// all fail the load.
  func testManifestRejectsACoreTopicThatIsNotASourceCommand() throws {
    for (command, subcommand) in [
      ("tab", "*"), ("tab", "sideways"), ("mode", "insert"), ("resident", "quit"),
      ("app", "quit"), ("scroll", "down"),
    ] {
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "core", "name": "Core", "version": "1.0.0", "description": "fixture",
            "exec": ["/usr/bin/true"],
            "commands": [{ "command": "\(command)", "subcommand": "\(subcommand)" }]
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      XCTAssertThrowsError(try PluginManifest.load(from: root), "\(command) \(subcommand)") {
        error in
        XCTAssertTrue(
          "\(error)".contains("is not a command Flash asks of the focused app"), "\(error)")
      }
    }
    // The same pair declared twice is still a duplicate.
    let twice = try temporaryPluginRoot(
      manifest: """
        {
          "id": "core", "name": "Core", "version": "1.0.0", "description": "fixture",
          "exec": ["/usr/bin/true"],
          "commands": [
            { "command": "tab", "subcommand": "close" },
            { "command": "tab", "subcommand": "close" }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: twice) }
    XCTAssertThrowsError(try PluginManifest.load(from: twice)) { error in
      XCTAssertTrue("\(error)".contains("declared more than once"), "\(error)")
    }
  }

  /// App knowledge is plugin data: the browsers plugin owns the browser
  /// chords (Safari's own hard reload included), `defaults` the shared
  /// conventions and the apps that differ, `terminals` the emulators' split
  /// traversal.
  func testOfficialManifestsOwnEveryAppSpecificBinding() throws {
    func manifest(_ id: String) throws -> PluginManifest {
      try PluginManifest.load(
        from: try XCTUnwrap(officialPluginRoots().first { $0.lastPathComponent == id }))
    }
    let browsers = try manifest("browsers")
    XCTAssertEqual(browsers.bindings[key("tab next")]?[""], .chords(["cmd+shift+]"]))
    XCTAssertEqual(browsers.bindings[key("scroll bottom")]?[""], .chords(["cmd+down"]))
    XCTAssertEqual(
      browsers.bindings[key("app reload --force")]?["com.apple.Safari"], .chords(["cmd+option+r"]))
    XCTAssertTrue(browsers.onlyBundleIDs.contains("org.mozilla.nightly"))
    XCTAssertEqual(browsers.bindings[key("tab move_next")]?[""], .chords(["ctrl+shift+pagedown"]))
    let defaults = try manifest("defaults")
    XCTAssertEqual(
      defaults.bindings[key("tab next")]?["com.apple.MobileSMS"], .chords(["ctrl+tab"]))
    let cursor = "com.todesktop.230313mzl4w4u92"
    XCTAssertEqual(defaults.bindings[key("history back")]?[cursor], .chords(["ctrl+-"]))
    XCTAssertEqual(defaults.bindings[key("history forward")]?[cursor], .chords(["ctrl+shift+-"]))
    XCTAssertEqual(
      defaults.bindings[key("history back")]?["com.apple.dt.Xcode"], .chords(["ctrl+cmd+left"]))
    XCTAssertEqual(
      defaults.bindings[key("history back")]?["com.apple.Notes"], CommandBindingSpec.unbound)
    XCTAssertEqual(defaults.bindings[key("history back")]?[""], .chords(["cmd+["]))
    XCTAssertEqual(defaults.bindings[key("tab new")]?[cursor], .chords(["cmd+n"]))
    XCTAssertEqual(defaults.bindings[key("tab reopen")]?[cursor], .chords(["cmd+shift+t"]))
    XCTAssertEqual(
      defaults.bindings[key("tab new")]?["com.apple.Notes"], CommandBindingSpec.unbound,
      "Cmd-T opens the Fonts panel, not a tab")
    XCTAssertEqual(defaults.bindings[key("tab new")]?[""], .chords(["cmd+t"]))
    XCTAssertEqual(defaults.bindings[key("tab close")]?[""], .chords(["cmd+w"]))
    for bundle in [
      "com.apple.MobileSMS", "com.apple.Notes", "com.apple.TextEdit", "com.apple.iWork.Pages",
      "com.apple.mail",
    ] {
      XCTAssertEqual(
        defaults.bindings[key("tab close")]?[bundle], CommandBindingSpec.unbound,
        "\(bundle) has no tab to close: `:q` closes its window, or quits it with the last")
    }
    XCTAssertEqual(defaults.bindings[key("tab select")]?[""], .chords(["cmd+{index}"]))
    let vscode = "com.microsoft.VSCode"
    XCTAssertEqual(defaults.bindings[key("tab new")]?[vscode], .chords(["cmd+n"]))
    XCTAssertEqual(defaults.bindings[key("tab reopen")]?[vscode], .chords(["cmd+shift+t"]))
    XCTAssertEqual(defaults.bindings[key("history back")]?[vscode], .chords(["ctrl+-"]))
    XCTAssertEqual(defaults.bindings[key("history forward")]?[vscode], .chords(["ctrl+shift+-"]))
    XCTAssertEqual(defaults.onDemandHints, ["com.apple.Notes"])
    XCTAssertTrue(
      Set(defaults.ownTextEditing).isSuperset(of: [
        vscode, "com.microsoft.VSCodeInsiders", "com.vscodium", cursor,
        "com.exafunction.windsurf", "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce", "com.jetbrains.WebStorm",
        "com.jetbrains.goland", "com.jetbrains.rider", "com.jetbrains.CLion",
        "com.jetbrains.rubymine", "com.jetbrains.PhpStorm", "com.jetbrains.datagrip",
        "dev.zed.Zed", "dev.zed.Zed-Preview", "com.sublimetext.4",
      ]), "editors with their own modal editing or partial Accessibility text")
    XCTAssertEqual(defaults.mappings, [], "Messages' tab chord is binding data, not a mapping")
    let terminals = try manifest("terminals")
    XCTAssertEqual(terminals.activation, .resident)
    XCTAssertEqual(terminals.sourceCommands.count, 17)
    XCTAssertTrue(terminals.sourceCommands.contains(CommandName("pane", "split_vertical")))
    XCTAssertEqual(terminals.pluginCommands.map(\.subcommand), ["session", "window"])
    XCTAssertEqual(browsers.sourceCommands.count, 7, "tab select, the four steps and the two moves")
    XCTAssertEqual(browsers.pluginCommands, [])
    XCTAssertTrue(
      Set(terminals.terminalEmulators).isSuperset(of: ["org.alacritty", "com.mitchellh.ghostty"]))
    XCTAssertEqual(
      terminals.bindings[key("pane next")]?["com.mitchellh.ghostty"], .chords(["cmd+]"]))
    for emulator in terminals.terminalEmulators {
      XCTAssertEqual(
        terminals.bindings[key("history back")]?[emulator], CommandBindingSpec.unbound,
        "\(emulator)'s Cmd-[ is a split chord, not back")
      XCTAssertEqual(
        terminals.bindings[key("history forward")]?[emulator], CommandBindingSpec.unbound)
    }
  }

  func testManifestRejectsInvalidMappingMode() throws {
    let root = try temporaryPluginRoot(
      manifest: """
        {
          "id": "bad-mode",
          "name": "Bad mode",
          "version": "1.0.0",
          "description": "Invalid mapping scope",
          "install": "true",
          "exec": ["/usr/bin/true"],
          "mappings": [
            { "key": "x", "mode": "bogus", "command": ["true"] }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue(
        String(describing: error).contains(
          "plugin mapping mode bogus must be all, normal, insert, terminal, command, hyper, hold, text or visual"
        ))
    }
  }

  /// A plugin maps keys in any mode a config can, under the same key rules:
  /// a command-mode key is one modified chord.
  func testManifestAcceptsEveryMappingModeAndRequiresAChordInCommand() throws {
    let root = try temporaryPluginRoot(
      manifest: """
        {
          "id": "every-mode",
          "name": "Every mode",
          "version": "1.0.0",
          "description": "Mappings in every scope",
          "install": "true",
          "exec": ["/usr/bin/true"],
          "mappings": [
            { "key": "x", "mode": "all", "command": ["true"] },
            { "key": "x", "mode": "normal", "command": ["true"] },
            { "key": "x", "mode": "insert", "command": ["true"] },
            { "key": "cmd+x", "mode": "terminal", "command": ["true"] },
            { "key": "cmd+x", "mode": "command", "command": ["true"] },
            { "key": "x", "mode": "hyper", "command": ["true"] },
            { "key": "x", "mode": "hold", "command": ["true"] }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(
      manifest.mappings.map(\.scope),
      [.all, .normal, .insert, .terminal, .command, .hyper, .hold])

    let bare = try temporaryPluginRoot(
      manifest: """
        {
          "id": "bare-command",
          "name": "Bare command",
          "version": "1.0.0",
          "description": "Unmodified command key",
          "install": "true",
          "exec": ["/usr/bin/true"],
          "mappings": [{ "key": "x", "mode": "command", "command": ["true"] }]
        }
        """)
    defer { try? FileManager.default.removeItem(at: bare) }
    XCTAssertThrowsError(try PluginManifest.load(from: bare)) { error in
      XCTAssertTrue(
        String(describing: error).contains(
          "plugin mapping x in command mode must be a single modified key"))
    }
  }

  func testManifestRejectsMalformedCommandAndBangFields() throws {
    let fixtures = [
      #""commands": [{ "command": "demo", "description": 42 }]"#,
      #""bangs": [{ "token": 42 }]"#,
    ]

    for fragment in fixtures {
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "malformed",
            "name": "Malformed",
            "version": "1.0.0",
            "description": "Malformed field fixture",
            "install": "true",
            "exec": ["/usr/bin/true"],
            \(fragment)
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      XCTAssertThrowsError(try PluginManifest.load(from: root))
    }
  }

  func testBangSourceMustNameADeclaredSource() throws {
    let root = try temporaryPluginRoot(
      manifest: """
        {
          "id": "banger",
          "name": "Banger",
          "version": "1.0.0",
          "description": "fixture",
          "exec": ["/usr/bin/true"],
          "sources": [{ "name": "banger.items", "type": "items" }],
          "bangs": [{ "token": "b", "source": "typo.items" }]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue(
        String(describing: error).contains("must name a declared sources[] entry"),
        String(describing: error))
    }
  }

  func testPluginCannotClaimACoreBang() throws {
    let root = try temporaryPluginRoot(
      manifest: """
        {
          "id": "banger",
          "name": "Banger",
          "version": "1.0.0",
          "description": "fixture",
          "exec": ["/usr/bin/true"],
          "bangs": [{ "token": "F" }]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue(
        String(describing: error).contains("plugin bang F is one of Flash's own bangs"),
        String(describing: error))
    }
  }

  func testQueryRegistrationDefaultsAndPrefixValidation() throws {
    let manifest = try decodedManifest(
      """
      {
        "id": "answers",
        "name": "Answers",
        "version": "1.0.0",
        "description": "Pure query answers",
        "exec": ["./flash-plugin-answers"],
        "query": {}
      }
      """)
    XCTAssertTrue(manifest.providesQueryEvaluation)
    XCTAssertEqual(manifest.query?.prefixes, [])

    let root = try temporaryPluginRoot(
      manifest: """
        {
          "id": "badprefix",
          "name": "Bad prefix",
          "version": "1.0.0",
          "description": "fixture",
          "exec": ["/usr/bin/true"],
          "query": { "prefixes": ["a b"] }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue(
        String(describing: error).contains("query prefix must be a non-whitespace literal"))
    }
  }

  /// `sandbox` is an allowance spec for the deny-default profile (absent:
  /// the empty spec) or an explicit `false`; nothing else, and the retired
  /// `subprocess`, `clipboard` and `notify` capabilities are unknown.
  func testManifestSandboxIsAnAllowanceSpecOrAnExplicitOptOut() throws {
    func load(_ fields: String) throws -> PluginManifest {
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "sandboxed",
            "name": "Sandboxed",
            "version": "1.0.0",
            "description": "fixture",
            \(fields)
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      return try PluginManifest.load(from: root)
    }
    let process = #""exec": ["./run"], "status": ["state"]"#

    let absent = try load(process)
    XCTAssertNil(absent.sandbox)
    XCTAssertEqual(absent.sandboxSpec, PluginSandboxSpec())
    let spec = try load(
      process + #", "sandbox": { "mach": ["com.apple.PowerManagement.control"] }"#)
    XCTAssertEqual(
      spec.sandboxSpec, PluginSandboxSpec(mach: ["com.apple.PowerManagement.control"]))
    let disabled = try load(process + #", "sandbox": false"#)
    XCTAssertEqual(disabled.sandbox, .disabled)
    XCTAssertNil(disabled.sandboxSpec)

    let rejected: [(String, String)] = [
      (process + #", "sandbox": true"#, "manifest.json sandbox must be an object or false"),
      (#""help": { "topics": [] }, "sandbox": false"#, "without exec cannot declare sandbox"),
      (
        #""apple_events_targets": ["com.apple.Safari"]"#,
        "without exec cannot declare apple_events_targets"
      ),
    ]
    for (fields, expected) in rejected {
      XCTAssertThrowsError(try load(fields), fields) { error in
        XCTAssertTrue(String(describing: error).contains(expected), String(describing: error))
      }
    }
    for capability in ["subprocess", "clipboard", "notify"] {
      XCTAssertThrowsError(
        try load(process + #", "capabilities": [""# + capability + #""]"#), capability)
    }
  }

  /// Every bundled bang trigger has one owner: core bangs, then each token a
  /// manifest declares (`aiproviders` chat bangs, `browsers`' history bangs),
  /// then the single catch-all, `searchproviders`. That plugin's Rust tests
  /// pin its reserved list to these tokens, so its DuckDuckGo and Kagi data
  /// never lists or serves one of them.
  func testEveryBundledBangTriggerHasOneOwner() throws {
    var owners = Dictionary(uniqueKeysWithValues: CoreBangs.all.map { ($0.token, "core") })
    var catchAll: [String] = []
    for root in try officialPluginRoots() {
      let manifest = try PluginManifest.load(from: root)
      for registration in manifest.bangs {
        let token = registration.token.lowercased()
        if token == "*" {
          catchAll.append(manifest.id)
          continue
        }
        XCTAssertNil(owners[token], "!\(token): \(manifest.id) and \(owners[token] ?? "")")
        owners[token] = manifest.id
      }
    }
    XCTAssertEqual(catchAll, ["searchproviders"])
    XCTAssertEqual(owners["f"], "core")
    XCTAssertEqual(owners["fb"], "browsers")
    for token in ["ai", "chat", "chatgpt", "claude", "perplexity", "lechat"] {
      XCTAssertEqual(owners[token], "aiproviders", "!\(token)")
    }
  }

  /// AGENTS.md rule 8: the generic Accessibility walk and the terminals
  /// plugin (tmux panes) are the hint providers; no other bundled plugin
  /// declares `hints`.
  func testTerminalsIsTheOnlyBundledHintProvider() throws {
    let providers = try officialPluginRoots()
      .map { try PluginManifest.load(from: $0) }
      .filter { $0.hints != nil }
      .map(\.id)
    XCTAssertEqual(providers, ["terminals"])
  }

  /// powerd's power-source service is the one mach allowance in the bundled
  /// tree: inside the sandbox IOPowerSources silently lists no battery
  /// without it, and no other bundled plugin reads a mach service.
  func testSysinfoIsTheOnlyBundledPluginWithAMachAllowance() throws {
    var allowances: [String: [String]] = [:]
    for root in try officialPluginRoots() {
      let manifest = try PluginManifest.load(from: root)
      if let mach = manifest.sandboxSpec?.mach, !mach.isEmpty {
        allowances[manifest.id] = mach
      }
    }
    XCTAssertEqual(allowances, ["sysinfo": ["com.apple.PowerManagement.control"]])
  }

  /// docs/privacy.md lists the bundled plugins that run unsandboxed; every
  /// other bundled plugin that runs a process gets the deny-default profile.
  func testOnlyTheDocumentedBundledPluginsRunUnsandboxed() throws {
    var unsandboxed: [String] = []
    for root in try officialPluginRoots() {
      let manifest = try PluginManifest.load(from: root)
      if manifest.exec != nil, manifest.sandboxSpec == nil {
        unsandboxed.append(manifest.id)
      }
    }
    XCTAssertEqual(unsandboxed, ["aiproviders", "screenshot", "terminals"])
  }

  /// The CLI queries' topics are Flash's: no plugin command can take them,
  /// and a query is nothing a plugin performs either.
  func testQueryTopicsAreReservedAgainstPluginCommands() throws {
    for name in ["resident", "config"] {
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "reserved",
            "name": "Reserved",
            "version": "1.0.0",
            "description": "fixture",
            "exec": ["/usr/bin/true"],
            "commands": [{ "command": "\(name)", "subcommand": "show", "description": "x" }]
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      XCTAssertThrowsError(try PluginManifest.load(from: root), name) { error in
        XCTAssertTrue(
          String(describing: error).contains(
            "\(name) show is not a command Flash asks of the focused app"),
          String(describing: error))
      }
      XCTAssertNil(parseMappingCommand(argv: ["flash", name, "show", "x"]))
    }
  }

  func testFetchURLsAndNetworkFetchCapabilityMustPair() throws {
    for manifest in [
      // fetch_urls without the capability.
      """
      {
        "id": "fetchy", "name": "Fetchy", "version": "1.0.0",
        "description": "fixture", "install": "true",
        "exec": ["/usr/bin/true"],
        "fetch_urls": ["https://example.com/"]
      }
      """,
      // Capability without fetch_urls.
      """
      {
        "id": "fetchy", "name": "Fetchy", "version": "1.0.0",
        "description": "fixture", "install": "true",
        "exec": ["/usr/bin/true"],
        "capabilities": ["network_fetch"]
      }
      """,
    ] {
      let root = try temporaryPluginRoot(manifest: manifest)
      defer { try? FileManager.default.removeItem(at: root) }
      XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
        XCTAssertTrue(
          String(describing: error).contains("must be declared together"),
          String(describing: error))
      }
    }
  }

  /// `apple_events` names the apps a plugin's scripts may address, so the
  /// capability and its targets come together, and a target is a bundle id.
  func testAppleEventsTargetsAndCapabilityMustPair() throws {
    for manifest in [
      """
      {
        "id": "scripty", "name": "Scripty", "version": "1.0.0",
        "description": "fixture", "install": "true",
        "exec": ["/usr/bin/true"],
        "apple_events_targets": ["com.apple.Safari"]
      }
      """,
      """
      {
        "id": "scripty", "name": "Scripty", "version": "1.0.0",
        "description": "fixture", "install": "true",
        "exec": ["/usr/bin/true"],
        "capabilities": ["apple_events"]
      }
      """,
    ] {
      let root = try temporaryPluginRoot(manifest: manifest)
      defer { try? FileManager.default.removeItem(at: root) }
      XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
        XCTAssertTrue(
          String(describing: error).contains(
            "apple_events capability and apple_events_targets must be declared together"),
          String(describing: error))
      }
    }
    for target in ["Safari", "com.apple.Safari/", "com.apple Safari", "", "com.apple.\"x\""] {
      let encodedTargets = String(
        decoding: try JSONSerialization.data(withJSONObject: ["com.apple.Safari", target]),
        as: UTF8.self)
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "scripty", "name": "Scripty", "version": "1.0.0",
            "description": "fixture", "install": "true",
            "exec": ["/usr/bin/true"],
            "capabilities": ["apple_events"],
            "apple_events_targets": \(encodedTargets)
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      XCTAssertThrowsError(try PluginManifest.load(from: root), target) { error in
        XCTAssertTrue(
          String(describing: error).contains("apple_events_targets entries must be bundle ids")
            || String(describing: error).contains("must be declared together"),
          "\(target): \(error)")
      }
    }
    let root = try temporaryPluginRoot(
      manifest: """
        {
          "id": "scripty", "name": "Scripty", "version": "1.0.0",
          "description": "fixture", "install": "true",
          "exec": ["/usr/bin/true"],
          "capabilities": ["apple_events"],
          "apple_events_targets": [" com.apple.Safari", "com.apple.Safari", "org.chromium.Chromium"]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.capabilities, [.appleEvents])
    XCTAssertEqual(manifest.appleEventsTargets, ["com.apple.Safari", "org.chromium.Chromium"])
  }

  func testFetchURLsMustBeHTTPSPrefixes() throws {
    let root = try temporaryPluginRoot(
      manifest: """
        {
          "id": "fetchy", "name": "Fetchy", "version": "1.0.0",
          "description": "fixture", "install": "true",
          "exec": ["/usr/bin/true"],
          "capabilities": ["network_fetch"],
          "fetch_urls": ["http://example.com/"]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue(String(describing: error).contains("https://"), String(describing: error))
    }
  }

  func testManifestRejectsInvalidID() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "Spotify",
          "name": "Spotify",
          "version": "0.1.0",
          "description": "Spotify controls",
          "install": "true",
          "exec": ["/usr/bin/true"]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try PluginManifest.load(from: root))
  }

  func testProvidesFlagsFalseWithoutMatchingSurface() throws {
    let manifest = try decodedManifest(
      """
      {
        "id": "cmdsonly",
        "name": "Commands Only",
        "version": "0.1.0",
        "description": "No hints, no candidates",
        "install": "true",
        "exec": ["/usr/bin/true"],
        "commands": [
          { "command": "x", "subcommand": "go", "description": "X" }
        ]
      }
      """)
    XCTAssertFalse(manifest.providesHints)
    XCTAssertFalse(manifest.providesCandidates)
    XCTAssertFalse(manifest.providesQueryEvaluation)
    XCTAssertEqual(manifest.activation, .onDemand)
  }

  func testSelectorPatternMatchingAndScopedBeatsUnscoped() throws {
    XCTAssertTrue(PluginPattern("core:apps.*").matches("core:apps.launched"))
    XCTAssertFalse(PluginPattern("core:apps.*").matches("core:config.changed"))
    XCTAssertTrue(PluginPattern("*").matches("core:session.opened"))

    let scoped = CompiledPluginSelector(PluginSelector(onlyBundleIDs: ["com.example.app"]))
    let unscoped = CompiledPluginSelector(PluginSelector())
    let context = PluginSelectorContext(bundleID: "com.example.app")
    XCTAssertTrue(scoped.matches(context))
    XCTAssertFalse(scoped.matches(PluginSelectorContext(bundleID: "com.other.app")))
    XCTAssertNil(scoped.specificity(in: PluginSelectorContext(bundleID: nil)))
    // The whole specificity model: scoped beats unscoped, nothing finer.
    XCTAssertGreaterThan(
      try XCTUnwrap(scoped.specificity(in: context)),
      try XCTUnwrap(unscoped.specificity(in: context)))
  }

  // MARK: - Process plumbing

  func testStoppingPluginSettlesGenericRequestsButCancelsLifecycleCallback() {
    var calls: [String] = []
    var pending: [Int: PluginProcess.PendingRequest] = [
      2: .init(
        completion: { response in
          XCTAssertNil(response)
          calls.append("generic")
        },
        settleOnStop: true),
      1: .init(
        completion: { _ in
          XCTFail("intentional stop must cancel the pending initialize callback")
        },
        settleOnStop: false),
    ]

    let callbacks = PluginProcess.takePendingCallbacks(&pending)
    XCTAssertTrue(pending.isEmpty)
    for callback in callbacks {
      callback(nil)
    }
    XCTAssertEqual(calls, ["generic"])
  }

  func testStoppedPluginWarmReadIsAnImmediateStoreRead() throws {
    let manifest = try decodedManifest(
      """
      {
        "id": "cold-source",
        "name": "Cold source",
        "version": "1.0.0",
        "description": "fixture",
        "install": "true",
        "exec": ["/usr/bin/true"],
        "sources": [
          { "name": "cold.items", "type": "items", "kind": "locations", "priority": "normal" }
        ]
      }
      """)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-cold-\(UUID().uuidString)")
    let process = PluginProcess(
      root: root,
      manifest: manifest,
      origin: .official,
      baseDataDir: root,
      watchFiles: false)
    let store = PluginCatalogStore()
    let source = PluginFlashSource(plugin: process, store: store)
    let env = FlashSourceEnvironment(runningApplications: [])

    // Nothing published: authoritative empty, no wire wait.
    XCTAssertTrue(source.candidates(in: env, scope: .all).isEmpty)

    // A published catalog serves without the process running at all.
    let decoded = PluginWireCodec.publishedRows(
      [["source": "cold.items", "title": "Warm row"]],
      sourceID: "plugin:cold-source",
      allowedSources: ["cold.items"])!
    store.publish(pluginID: "cold-source", decoded)
    XCTAssertEqual(source.candidates(in: env, scope: .all).map(\.title), ["Warm row"])
  }

  func testPluginRuntimeEnvironmentDropsUnrelatedSecrets() {
    let environment = PluginProcess.sanitizedPluginEnvironment(
      base: [
        "HOME": "/Users/demo",
        "PATH": "/opt/homebrew/bin:/usr/bin",
        "SHELL": "/bin/zsh",
        "AWS_SECRET_ACCESS_KEY": "secret",
        "SLACK_API_TOKEN": "secret",
        "SSH_AUTH_SOCK": "/tmp/agent.sock",
      ],
      overrides: [
        "FLASH_PLUGIN_ID": "answers",
        "FLASH_PLUGIN_CONFIG": "{}",
      ])

    XCTAssertEqual(environment["HOME"], "/Users/demo")
    XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/bin")
    XCTAssertEqual(environment["FLASH_PLUGIN_ID"], "answers")
    XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
    XCTAssertNil(environment["SLACK_API_TOKEN"])
    XCTAssertNil(environment["SSH_AUTH_SOCK"])
  }

  func testFetchURLAllowlistMatchesAtComponentBoundaries() {
    XCTAssertTrue(
      PluginHostRPC.urlIsAllowed(
        "https://api.example.com/v1/rates", byPrefix: "https://api.example.com/"))
    XCTAssertTrue(
      PluginHostRPC.urlIsAllowed("https://api.example.com", byPrefix: "https://api.example.com"))
    XCTAssertTrue(
      PluginHostRPC.urlIsAllowed(
        "https://api.example.com?q=1", byPrefix: "https://api.example.com"))
    // A prefix without a trailing slash must not admit a longer host.
    XCTAssertFalse(
      PluginHostRPC.urlIsAllowed(
        "https://api.example.com.attacker.tld/x", byPrefix: "https://api.example.com"))
    XCTAssertFalse(PluginHostRPC.urlIsAllowed("https://api.example.com/x", byPrefix: ""))
  }

  func testFlashLogIncludesSource() {
    var records: [FlashLog.Record] = []
    let sink = FlashLog.addSink { records.append($0) }
    defer { FlashLog.removeSink(sink) }

    FlashLog.debug("test message", source: "core:test")
    FlashLog.plugin(.info, pluginID: "spotify", message: "plugin message")

    XCTAssertEqual(records.first?.source, "core:test")
    XCTAssertEqual(records.last?.source, "plugin:spotify")
    XCTAssertTrue(
      String(decoding: FlashLog.jsonLineData(records[0]), as: UTF8.self)
        .contains("\"source\":\"core:test\""))
  }

  // MARK: - Clipboard dashboard decode

  func testDecodeClipboardHistoryPageRoundTripsPluginJSON() throws {
    // The shape the core clipboard history returns for `:clipboard`.
    let json = """
      {"entries":[{"id":"0123456789abcdef0123456789abcdef","kind":"text","preview":"hello","value":"hello"},{"id":"fedcba9876543210fedcba9876543210","kind":"html","preview":"two…","value":"two lines\\nof text","html":"<p>two</p>"}],"total":3,"next_offset":2}
      """
    let page = try XCTUnwrap(AppDelegate.decodeClipboardHistoryPage(json))
    let entries = page.entries
    XCTAssertEqual(page.total, 3)
    XCTAssertEqual(page.nextOffset, 2)
    XCTAssertEqual(entries.map(\.preview), ["hello", "two…"])
    XCTAssertEqual(entries.map(\.value), ["hello", "two lines\nof text"])
    XCTAssertEqual(entries[1].html, "<p>two</p>")
    XCTAssertEqual(entries[0].files, [])
    XCTAssertNil(entries[0].mime)
  }

  func testTheLastClipboardHistoryPageEncodesANullNextOffset() throws {
    // The help page rejects a page without `next_offset`; the last one must
    // say `null`, not leave the key out.
    let last = ClipboardHistoryPage(entries: [], total: 158, nextOffset: nil)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(last)) as? [String: Any])
    XCTAssertTrue(object.keys.contains("next_offset"))
    XCTAssertTrue(object["next_offset"] is NSNull)
    let next = ClipboardHistoryPage(entries: [], total: 158, nextOffset: 100)
    XCTAssertEqual(
      try JSONDecoder().decode(ClipboardHistoryPage.self, from: JSONEncoder().encode(next)), next)
  }

  func testDecodeClipboardHistoryPageAcceptsEmptyHistory() throws {
    let page = try XCTUnwrap(
      AppDelegate.decodeClipboardHistoryPage("{\"entries\":[],\"total\":0,\"next_offset\":null}"))
    XCTAssertTrue(page.entries.isEmpty)
    XCTAssertNil(page.nextOffset)
  }

  func testDecodeClipboardHistoryPageRejectsMalformedJSON() {
    XCTAssertNil(AppDelegate.decodeClipboardHistoryPage("not json"))
    XCTAssertNil(
      AppDelegate.decodeClipboardHistoryPage(
        "{\"entries\":[{\"preview\":\"x\"}],\"total\":1,\"next_offset\":null}"),
      "an entry missing the required `value` field decodes to nil")
    XCTAssertNil(
      AppDelegate.decodeClipboardHistoryPage(
        "{\"entries\":[{\"preview\":\"x\",\"value\":\"x\",\"kind\":\"text\"}],\"total\":1,\"next_offset\":null}"
      ),
      "an entry missing `id` decodes to nil")
  }

  func testClipboardStateOmitsImageBytes() {
    let id = "0123456789abcdef0123456789abcdef"
    let entry = ClipboardModalEntry(
      id: id, kind: "files", preview: "shot.png", value: "/tmp/shot.png", mime: "image/png",
      files: ["/tmp/shot.png"])
    let object = AppDelegate.clipboardStateObject(entry)
    XCTAssertEqual(object["id"] as? String, id)
    XCTAssertEqual(object["kind"] as? String, "files")
    XCTAssertEqual(object["mime"] as? String, "image/png")
    XCTAssertEqual(object["files"] as? [String], ["/tmp/shot.png"])
    XCTAssertNil(object["sha256"])
    XCTAssertNil(object["image"])
  }

  func testClipboardImageCacheKeepsTheNewestLoadedImagesWithinItsLimit() {
    func image(_ byte: String) -> ClipboardModalEntry {
      ClipboardModalEntry(
        id: String(repeating: byte, count: 32), kind: "image", preview: "Image", value: "",
        mime: "image/png")
    }
    let first = image("a")
    let second = image("b")
    let third = image("c")
    let newest = image("d")
    var cache = ClipboardImageCache(limit: 3)
    cache.remember([first, second, third], offset: 0)
    cache.remember([newest], offset: 0)
    XCTAssertNil(cache.mime(for: third.id), "the oldest loaded image is evicted")
    XCTAssertEqual(cache.mime(for: first.id), "image/png")
    XCTAssertEqual(cache.mime(for: newest.id), "image/png")
    cache.remove(first.id)
    XCTAssertNil(cache.mime(for: first.id))
  }

  // MARK: - Official plugins

  /// Manifests are being migrated to the v2 schema plugin-by-plugin (each
  /// plugin agent owns its own). Sweep assertions run over the manifests
  /// that already parse; `defaults` (host-owned) must always parse.
  private func loadableOfficialManifests() throws -> [(root: URL, manifest: PluginManifest)] {
    try officialPluginRoots().compactMap { root in
      guard let manifest = try? PluginManifest.load(from: root) else { return nil }
      return (root, manifest)
    }
  }

  func testOfficialPluginManifestsFollowBundledConventions() throws {
    let loaded = try loadableOfficialManifests()
    XCTAssertTrue(
      loaded.contains { $0.manifest.id == "defaults" },
      "the host-owned defaults manifest must always parse")
    for (root, manifest) in loaded {
      XCTAssertEqual(
        manifest.id, root.lastPathComponent,
        "manifest id must match its plugin directory name")
      // Bundled plugins have no install step (`install` is third-party-only).
      XCTAssertNil(manifest.install, "\(manifest.id): official plugins declare no install step")
      XCTAssertFalse(manifest.description.isEmpty)
      // A bundled source omits the default kind rather than spelling it out.
      let raw = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: Data(contentsOf: root.appendingPathComponent("manifest.json")))
          as? [String: Any])
      for source in raw["sources"] as? [[String: Any]] ?? [] {
        XCTAssertNotEqual(
          source["kind"] as? String, "default",
          "\(manifest.id) \(source["name"] ?? ""): omit the default kind")
      }
      if let exec = manifest.exec {
        XCTAssertFalse(exec.isEmpty)
        let compiled = ["Cargo.toml", "go.mod", "main.zig", "main.swift"].contains {
          FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        if compiled {
          XCTAssertEqual(exec, ["./flash-plugin-\(manifest.id)"])
        } else {
          XCTAssertFalse(
            exec[0].contains("/"),
            "\(manifest.id): interpreted plugins resolve their runtime by bare name via PATH")
        }
      }
    }
  }

  func testDefaultsManifestIsManifestOnlyAppKnowledge() throws {
    let root = try XCTUnwrap(
      try officialPluginRoots().first { $0.lastPathComponent == "defaults" })
    let defaults = try PluginManifest.load(from: root)
    // Manifest-only: no process, no binary — only data the host serves.
    XCTAssertNil(defaults.exec)
    XCTAssertEqual(defaults.activation, .manifestOnly)
    XCTAssertEqual(defaults.sourceCommands, [], "a manifest-only plugin performs nothing")
    for name in ["app save", "app print", "document open", "window new"] {
      XCTAssertNotNil(defaults.bindings[key(name)]?[""], name)
    }
  }

  func testPluginCommandNameConflictsFailEveryClaimant() {
    func manifest(id: String, commands: [String] = []) -> PluginManifest {
      PluginManifest(
        id: id, name: id, version: "1", description: "fixture",
        exec: ["/usr/bin/true"],
        commands: commands.map { PluginCommandRegistration(command: $0, subcommand: "go") })
    }
    // A topic word is never a plugin's own command, so it never claims one:
    // `validate()` holds it to the source commands instead.
    let core = manifest(id: "core", commands: ["tab"])
    XCTAssertEqual(PluginManifest.commandClaimFailures([core]), [:])
    XCTAssertThrowsError(try core.validate()) { error in
      XCTAssertTrue(
        "\(error)".contains("tab go is not a command Flash asks of the focused app"), "\(error)")
    }

    let shared = PluginManifest.commandClaimFailures([
      manifest(id: "a", commands: ["weather"]),
      manifest(id: "b", commands: ["weather"]),
    ])
    XCTAssertNotNil(shared["a"])
    XCTAssertNotNil(shared["b"])

    let distinct = PluginManifest.commandClaimFailures([
      manifest(id: "weather", commands: ["weather"]),
      manifest(id: "lamp", commands: ["lamp"]),
    ])
    XCTAssertTrue(distinct.isEmpty, "\(distinct)")
  }

  /// A plugin never takes a Flash topic as its own command: an entry under
  /// one declares a core command the plugin performs, and must be one.
  func testPluginCommandUnderAFlashTopicMustBeASourceCommand() throws {
    let bad = try temporaryPluginRoot(
      manifest: """
        {
          "id": "badtab", "name": "Bad Tab", "version": "1.0.0", "description": "fixture",
          "exec": ["/usr/bin/true"],
          "commands": [{ "command": "tab", "subcommand": "go", "description": "x" }]
        }
        """)
    defer { try? FileManager.default.removeItem(at: bad) }
    XCTAssertThrowsError(try PluginManifest.load(from: bad)) { error in
      XCTAssertTrue("\(error)".contains("tab go is not a command"), "\(error)")
    }
    let good = try temporaryPluginRoot(
      manifest: """
        {
          "id": "goodtab", "name": "Good Tab", "version": "1.0.0", "description": "fixture",
          "exec": ["/usr/bin/true"],
          "commands": [{ "command": "tab", "subcommand": "close", "description": "Close it" }]
        }
        """)
    defer { try? FileManager.default.removeItem(at: good) }
    let manifest = try PluginManifest.load(from: good)
    XCTAssertEqual(manifest.sourceCommands, [CommandName("tab", "close")])
    XCTAssertEqual(manifest.pluginCommands, [])
    XCTAssertEqual(PluginManifest.commandClaimFailures([manifest]), [:])
  }

  func testOfficialPluginsHaveDistinctFlashSubcommands() throws {
    var manifests: [PluginManifest] = []
    for root in try officialPluginRoots() {
      do {
        manifests.append(try PluginManifest.load(from: root))
      } catch {
        XCTFail("\(root.lastPathComponent) failed to load: \(error)")
      }
    }
    XCTAssertFalse(manifests.isEmpty)
    XCTAssertEqual(PluginManifest.commandClaimFailures(manifests), [:])
  }

  func testPluginCommandWithoutASubcommandFailsToLoad() throws {
    let root = try temporaryPluginRoot(
      manifest: """
        {
          "id": "bare", "name": "Bare", "version": "1.0.0", "description": "fixture",
          "exec": ["/usr/bin/true"],
          "commands": [{ "command": "bare", "subcommand": "", "description": "x" }]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue((error as? PluginError)?.isCommandConflict == true, "\(error)")
      XCTAssertTrue("\(error)".contains("requires a subcommand"), "\(error)")
    }
  }

  func testOfficialPluginInstallScriptsAvoidGlobalInstallTargets() throws {
    let banned = [
      "sudo", "brew install", "npm install -g", "deno install -g", "/usr/local/bin",
      "$HOME/.local/bin", "~/.local/bin",
    ]
    for (root, manifest) in try loadableOfficialManifests() {
      for field in (manifest.install.map { [$0] } ?? []) + (manifest.exec ?? []) {
        for needle in banned {
          XCTAssertFalse(
            field.contains(needle), "\(root.lastPathComponent) manifest contains \(needle)")
        }
      }
      for name in ["Cargo.toml", "src/main.rs"] {
        let file = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { continue }
        let body = try String(contentsOf: file)
        for needle in banned {
          XCTAssertFalse(
            body.contains(needle), "\(root.lastPathComponent)/\(name) contains \(needle)")
        }
      }
    }
  }

  func testManifestRootDiscoveryFollowsSymlinkedBundleDirectory() throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-symlink-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }

    let bundlePlugins = temp.appendingPathComponent("real/Plugins")
    let pluginRoot = bundlePlugins.appendingPathComponent("sample")
    try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
    try """
    {
      "id": "sample",
      "name": "Sample",
      "version": "0.1.0",
      "description": "Sample plugin",
      "install": "./install.sh",
      "exec": ["./start.sh"]
    }
    """.write(
      to: pluginRoot.appendingPathComponent("manifest.json"),
      atomically: true,
      encoding: .utf8)

    let linkedPlugins = temp.appendingPathComponent("app/Contents/Resources/Plugins")
    try FileManager.default.createDirectory(
      at: linkedPlugins.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: linkedPlugins,
      withDestinationURL: bundlePlugins)

    let roots = PluginRepository.manifestRoots(in: [linkedPlugins])
    XCTAssertEqual(roots.map(\.path), [pluginRoot.path])
  }

  // MARK: - Subprocess smoke tests (wire-level, host-free)

  func testOfficialPluginRespondsOverNDJSON() throws {
    try runPluginSmoke(pluginID: "screenshot")
  }

  func testRustPluginExitsWhenHostClosesStdin() throws {
    try runPluginStdinEOFSmoke(pluginID: "answers")
  }

  func testNewPluginScaffoldIsStrictlyDecodableAndBuilds() throws {
    let repository = repositoryRoot()
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-scaffold-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let plugins = temp.appendingPathComponent("Plugins")
    try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: plugins.appendingPathComponent("_flash_plugin_rust"),
      withDestinationURL: repository.appendingPathComponent("Plugins/_flash_plugin_rust"))

    let scaffold = Process()
    scaffold.executableURL = URL(fileURLWithPath: "/bin/bash")
    scaffold.arguments = [
      repository.appendingPathComponent("Scripts/new-plugin.sh").path,
      "fixture", "Fixture", "Scaffold fixture",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["FLASH_PLUGIN_PROJECT_DIR"] = temp.path
    scaffold.environment = environment
    try scaffold.run()
    scaffold.waitUntilExit()
    XCTAssertEqual(scaffold.terminationStatus, 0)

    let root = plugins.appendingPathComponent("fixture")
    let manifest = try JSONDecoder().decode(
      PluginManifest.self,
      from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    try manifest.validate()
    XCTAssertEqual(manifest.commands.map(\.subcommand), ["ping"])

    let check = Process()
    check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    check.arguments = ["cargo", "check", "--locked", "--quiet"]
    check.currentDirectoryURL = root
    check.environment = environment
    try check.run()
    check.waitUntilExit()
    XCTAssertEqual(check.terminationStatus, 0)
  }

  // MARK: - Fixture helpers

  private func key(_ text: String) -> CommandBindingKey {
    CommandBindingKey(text)!
  }

  private func decodedManifest(_ json: String) throws -> PluginManifest {
    let manifest = try JSONDecoder().decode(
      PluginManifest.self, from: try XCTUnwrap(json.data(using: .utf8)))
    try manifest.validate()
    return manifest
  }

  private func temporaryPluginRoot(manifest: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try manifest.write(
      to: root.appendingPathComponent("manifest.json"),
      atomically: true,
      encoding: .utf8)
    return root
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func officialPluginRoots() throws -> [URL] {
    let root = repositoryRoot().appendingPathComponent("Plugins")
    return try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    .filter {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func runPluginSmoke(pluginID: String) throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-smoke-\(pluginID)-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let dataDir = temp.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

    let pluginRoot = repositoryRoot().appendingPathComponent("Plugins/\(pluginID)")
    let binaryURL = pluginRoot.appendingPathComponent("flash-plugin-\(pluginID)")
    guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
      throw XCTSkip(
        "\(pluginID) binary not built — run `mise run build:plugins` before the protocol smoke test"
      )
    }
    let process = Process()
    process.executableURL = binaryURL
    process.arguments = []
    process.currentDirectoryURL = pluginRoot
    var env = ProcessInfo.processInfo.environment
    env["FLASH_PLUGIN_ID"] = pluginID
    env["FLASH_PLUGIN_VERSION"] = "0.1.0"
    env["FLASH_PLUGIN_DATA_DIR"] = dataDir.path
    process.environment = env

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()

    // The smoke test exercises the managed NDJSON protocol exactly as the
    // host drives it: a minimal initialize (protocol_version only, answered
    // immediately), an idle ping, and one perform.
    let collector = NDJSONLineCollectorForTests()
    let writeLock = NSLock()
    func send(_ object: [String: Any]) {
      guard var frame = try? JSONSerialization.data(withJSONObject: object) else { return }
      frame.append(0x0A)
      writeLock.lock()
      stdin.fileHandleForWriting.write(frame)
      writeLock.unlock()
    }
    let initialized = DispatchSemaphore(value: 0)
    let pinged = DispatchSemaphore(value: 0)
    let commandResponded = DispatchSemaphore(value: 0)

    stdout.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      for message in collector.ingest(data) {
        // A plugin→host request carries both `id` and `method`; the tested
        // command is refused in process, without any host RPC.
        if message["method"] is String {
          continue
        }
        switch (message["id"] as? NSNumber)?.intValue {
        case 1:
          initialized.signal()
        case 2:
          pinged.signal()
        case 3:
          commandResponded.signal()
        default:
          break
        }
      }
    }

    send([
      "id": 1,
      "method": "initialize",
      "params": ["protocol_version": PluginProtocol.version],
    ])
    if initialized.wait(timeout: .now() + 10) != .success {
      stdout.fileHandleForReading.readabilityHandler = nil
      process.terminate()
      XCTFail("\(pluginID) plugin did not answer initialize immediately")
      return
    }
    send(["id": 2, "method": "ping", "params": [:]])
    // An undeclared subcommand: the plugin answers `ok: false` with a
    // content-free error, which proves the perform path end to end without
    // running the command's real side effect.
    send([
      "id": 3,
      "method": "perform",
      "params": [
        "kind": "command",
        "args": [],
        "command": pluginID,
        "subcommand": "nonexistent",
      ],
    ])

    if pinged.wait(timeout: .now() + 10) != .success {
      stdout.fileHandleForReading.readabilityHandler = nil
      process.terminate()
      XCTFail("\(pluginID) plugin did not answer ping")
      return
    }
    if commandResponded.wait(timeout: .now() + 15) != .success {
      stdout.fileHandleForReading.readabilityHandler = nil
      process.terminate()
      XCTFail("\(pluginID) plugin did not respond to the command perform")
      return
    }
    // Shutdown is stdin EOF, nothing else.
    stdin.fileHandleForWriting.closeFile()

    if finished.wait(timeout: .now() + 5) != .success {
      stdout.fileHandleForReading.readabilityHandler = nil
      process.terminate()
      XCTFail("\(pluginID) plugin did not exit on stdin EOF")
      return
    }
    stdout.fileHandleForReading.readabilityHandler = nil

    let stderrBody =
      String(
        data: stderr.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, stderrBody)

    let messages = collector.messages()
    XCTAssertEqual(responseOK(id: 1, messages: messages), true, collector.raw())
    XCTAssertEqual(responseOK(id: 2, messages: messages), true, collector.raw())
    XCTAssertEqual(responseOK(id: 3, messages: messages), false, collector.raw())
  }

  private func runPluginStdinEOFSmoke(pluginID: String) throws {
    let pluginRoot = repositoryRoot().appendingPathComponent("Plugins/\(pluginID)")
    let binaryURL = pluginRoot.appendingPathComponent("flash-plugin-\(pluginID)")
    guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
      throw XCTSkip(
        "\(pluginID) binary not built — run `mise run build:plugins` before the stdin-EOF smoke test"
      )
    }

    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-parent-\(pluginID)-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let dataDir = temp.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = binaryURL
    process.currentDirectoryURL = pluginRoot
    var env = ProcessInfo.processInfo.environment
    env["FLASH_PLUGIN_ID"] = pluginID
    env["FLASH_PLUGIN_VERSION"] = "0.1.0"
    env["FLASH_PLUGIN_DATA_DIR"] = dataDir.path
    process.environment = env

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
      }
    }

    // Parent liveness IS stdin EOF: the host owns the pipe, so closing it
    // must end the serve loop and the process.
    stdin.fileHandleForWriting.closeFile()
    if finished.wait(timeout: .now() + 3) != .success {
      XCTFail("\(pluginID) plugin did not exit after its stdin closed")
      return
    }

    _ = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrBody =
      String(
        data: stderr.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, stderrBody)
  }

  private func responseOK(id: Int, messages: [[String: Any]]) -> Bool? {
    for message in messages {
      guard (message["id"] as? NSNumber)?.intValue == id else { continue }
      let result = message["result"] as? [String: Any]
      return result?["ok"] as? Bool
    }
    return nil
  }
}

/// Thread-safe accumulator for NDJSON lines streamed from a plugin's stdout.
/// `ingest` is called from the pipe's readability handler (a background
/// queue); `messages`/`raw` are read from the test thread.
private final class NDJSONLineCollectorForTests {
  private let lock = NSLock()
  private var buffer = Data()
  private var parsed: [[String: Any]] = []

  func ingest(_ data: Data) -> [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    buffer.append(data)
    var fresh: [[String: Any]] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = Data(buffer[buffer.startIndex..<newline])
      buffer = Data(buffer[buffer.index(after: newline)...])
      guard !line.isEmpty,
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
      else { continue }
      parsed.append(object)
      fresh.append(object)
    }
    return fresh
  }

  func messages() -> [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    return parsed
  }

  /// A rendering of the frames parsed so far, for failure diagnostics.
  func raw() -> String {
    lock.lock()
    defer { lock.unlock() }
    return parsed.map { String(describing: $0) }.joined(separator: "\n")
  }
}
