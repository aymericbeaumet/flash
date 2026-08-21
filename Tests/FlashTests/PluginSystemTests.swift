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
    PluginWireCodec.catalogRows(from: [raw], sourceID: sourceID, allowedSources: allowed)?
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
        sourceID: "plugin:calculator",
        source: "calculator"))
    XCTAssertEqual(answer.title, "2")

    // Required fields stay required: null means absent, and an absent query
    // effect is still a rejection.
    XCTAssertNil(
      decodeQueryAnswer(
        from: ["title": "x", "effect": NSNull()],
        sourceID: "plugin:calculator",
        source: "calculator"))
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
      PluginWireCodec.catalogRows(
        from: [valid],
        sourceID: "plugin:safe",
        allowedSources: ["safe.items"])?.rows.count,
      1)

    var unknownKey = valid
    unknownKey["command"] = "spoof"
    XCTAssertNil(
      PluginWireCodec.catalogRows(
        from: [valid, unknownKey],
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
      PluginWireCodec.catalogRows(
        from: Array(
          repeating: valid,
          count: PluginProtocol.maxCatalogRows + 1),
        sourceID: "plugin:safe",
        allowedSources: ["safe.items"]))
  }

  func testPluginHintTargetCannotSpoofProviderOwnership() throws {
    let target = try XCTUnwrap(
      PluginWireCodec.target(
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
        sourceID: "plugin:safe"))

    XCTAssertEqual(target.sourceID, "plugin:safe")
  }

  func testQueryAnswerHasANarrowShapeAndGetsHostOwnedSemantics() throws {
    let candidate = try XCTUnwrap(
      decodeQueryAnswer(
        from: [
          "title": "2",
          "subtitle": "1+1",
          "effect": ["type": "copy_text", "text": "2"],
        ],
        sourceID: "plugin:calculator",
        source: "calculator"))
    guard case .copyText(let text) = candidate.effect else {
      return XCTFail("expected copy_text effect")
    }
    XCTAssertEqual(text, "2")
    XCTAssertEqual(candidate.source, "calculator")
    XCTAssertEqual(candidate.sourceID, "plugin:calculator")
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
        sourceID: "plugin:calculator",
        source: "calculator"))
    XCTAssertNil(
      decodeQueryAnswer(
        from: [
          "title": "empty",
          "effect": ["type": "copy_text", "text": ""],
        ],
        sourceID: "plugin:calculator",
        source: "calculator"))
    XCTAssertNil(
      decodeQueryAnswer(
        from: [
          "title": "spoof",
          "url": "https://example.com",
          "effect": ["type": "copy_text", "text": "spoof"],
        ],
        sourceID: "plugin:calculator",
        source: "calculator"))
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
        sourceID: "plugin:calculator",
        source: "calculator"))
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
        sourceID: "plugin:calculator",
        source: "calculator")?.count,
      16)
    XCTAssertNil(
      PluginWireCodec.queryAnswers(
        from: Array(repeating: answer, count: 17),
        sourceID: "plugin:calculator",
        source: "calculator"))
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
        sourceID: "plugin:calculator",
        source: "calculator"))

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
        sourceID: "plugin:calculator",
        source: "calculator"),
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
        sourceID: "plugin:calculator",
        source: "calculator"))
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
        "verbs": [
          { "name": "noop", "keystrokes": { "": "cmd+s" } }
        ]
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
    let decoded = PluginWireCodec.catalogRows(
      from: good, sourceID: "plugin:safe", allowedSources: ["safe.items"])!
    store.publish(pluginID: "safe", rows: decoded.rows, encodedBytes: decoded.encodedBytes)
    XCTAssertEqual(store.rows(for: "safe").map(\.title), ["Good"])

    // An over-quota publish decodes to nil and never touches the store —
    // the previous catalog is retained by construction.
    let overQuota = Array(
      repeating: ["source": "safe.items", "title": "Row"] as [String: Any],
      count: PluginProtocol.maxCatalogRows + 1)
    XCTAssertNil(
      PluginWireCodec.catalogRows(
        from: overQuota, sourceID: "plugin:safe", allowedSources: ["safe.items"]))
    XCTAssertEqual(store.rows(for: "safe").map(\.title), ["Good"])

    // Empty rows are an authoritative empty, not a rejection.
    store.publish(pluginID: "safe", rows: [], encodedBytes: 0)
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
      store.publish(pluginID: "p", rows: [Candidate(title: "\(index)")], encodedBytes: 1)
    }
    wait(for: [first], timeout: 2)
    XCTAssertEqual(ticks, 1, "a publish burst collapses to one tick")
    // A later publish schedules a fresh (interval-spaced) tick.
    store.publish(pluginID: "p", rows: [Candidate(title: "later")], encodedBytes: 1)
    wait(for: [second], timeout: 2)
    XCTAssertEqual(store.rows(for: "p").map(\.title), ["later"])
  }

  // MARK: - Status segments

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
      ["session": "main", "window": "2"])
    // "" clears one segment; undeclared names are ignored.
    process.applyStatusSegments(["segments": ["session": "", "undeclared": "x"]])
    XCTAssertEqual(process.statusBarInfo().statusSegments, ["window": "2"])
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
      try activation(#", "exec": ["/usr/bin/true"], "sources": [{"name": "a.b"}]"#), .resident)
    XCTAssertEqual(try activation(#", "exec": ["/usr/bin/true"], "query": {}"#), .resident)
    XCTAssertEqual(try activation(#", "exec": ["/usr/bin/true"], "hints": {}"#), .resident)
    XCTAssertEqual(
      try activation(#", "exec": ["/usr/bin/true"], "status": ["state"]"#), .resident)
    XCTAssertEqual(
      try activation(#", "exec": ["/usr/bin/true"], "listen": ["core:apps.*"]"#), .resident)
    // On-demand: only perform-driven surfaces.
    XCTAssertEqual(
      try activation(
        #", "exec": ["/usr/bin/true"], "commands": [{"command": "x", "description": "x"}]"#),
      .onDemand)
    XCTAssertEqual(
      try activation(
        #", "exec": ["/usr/bin/true"], "bangs": {"command": "x", "items": [{"token": "x"}]}"#),
      .onDemand)
    XCTAssertEqual(
      try activation(#", "exec": ["/usr/bin/true"], "navigation": ["act"]"#), .onDemand)
    // Manifest-only: no exec at all.
    XCTAssertEqual(
      try activation(#", "verbs": [{"name": "v", "keystrokes": {"": "cmd+s"}}]"#),
      .manifestOnly)
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

  func testManifestRejectsUnknownNestedFieldsUniformly() throws {
    let fixtures: [(String, String)] = [
      (
        #""commands": [{ "command": "demo", "description": "Demo", "descrption": "typo" }]"#,
        "manifest.json commands[0] unknown field descrption"
      ),
      (
        #""sources": [{ "name": "demo.items", "priority": "normal", "priorty": 2 }]"#,
        "manifest.json sources[0] unknown field priorty"
      ),
      (
        #""sources": [{ "name": "demo.items", "mode": "live" }]"#,
        "manifest.json sources[0] unknown field mode"
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
        #""bangs": { "command": "x", "items": [{ "token": "x", "candidate_source": "y" }] }"#,
        "manifest.json bangs.items[0] unknown field candidate_source"
      ),
      (
        #""verbs": [{ "name": "v", "inline_keystrokes": { "": "cmd+s" } }]"#,
        "manifest.json verbs[0] unknown field inline_keystrokes"
      ),
      (
        #""sandbox": { "read": ["~/Library"] }"#,
        "manifest.json sandbox unknown field read"
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
            { "name": "multi.items" }
          ],
          "navigation": ["multi"],
          "actions": ["resource_archive", "resource_next"],
          "status": ["battery"],
          "hints": { "fallback_on_empty": true },
          "query": { "prefixes": ["="] },
          "commands": [
            { "command": "multi", "subcommand": "go", "description": "Go", "timeout_ms": 300000 }
          ],
          "bangs": {
            "command": "multi",
            "items": [
              { "token": "m", "description": "Multi", "source": "multi.items" }
            ]
          },
          "verbs": [
            { "name": "multi_open", "description": "Open" }
          ],
          "mappings": [
            { "key": "q", "command": ["flash", "hints_dismiss"] }
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
    XCTAssertEqual(manifest.actions, ["resource_archive", "resource_next"])
    XCTAssertEqual(manifest.statusSegments, ["battery"])
    XCTAssertEqual(manifest.commands.map(\.subcommand), ["go"])
    XCTAssertEqual(manifest.commands.first?.timeoutMs, 300_000)
    XCTAssertEqual(manifest.bangCommand, "multi")
    XCTAssertEqual(manifest.bangs.map(\.token), ["m"])
    XCTAssertEqual(manifest.bangs.first?.source, "multi.items")
    XCTAssertEqual(manifest.verbs.map(\.name), ["multi_open"])
    XCTAssertEqual(manifest.mappings.map(\.key), ["q"])
    XCTAssertEqual(manifest.activation, .resident)
  }

  func testManifestDecodesMappingsWithDefaults() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "slack",
          "name": "Slack",
          "version": "0.1.0",
          "description": "Slack",
          "install": "true",
          "exec": ["/usr/bin/true"],
          "mappings": [
            { "key": "q", "command": ["flash", "plugin_command", "--command=slack", "--subcommand=run"] },
            {
              "key": "ctrl+k",
              "mode": "insert",
              "command": ["flash", "hints_dismiss"],
              "only_bundle_ids": ["com.tinyspeck.slackmacgap"],
              "priority": 40
            }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.mappings.count, 2)

    let first = try XCTUnwrap(manifest.mappings.first)
    XCTAssertEqual(first.key, "q")
    XCTAssertEqual(first.mode, "normal", "mode defaults to normal")
    XCTAssertEqual(first.scope, .normal)
    XCTAssertTrue(first.selector.onlyBundleIDs.isEmpty, "only_bundle_ids defaults to []")
    XCTAssertNil(first.priority, "priority is optional")

    let second = manifest.mappings[1]
    XCTAssertEqual(second.mode, "insert")
    XCTAssertEqual(second.scope, .insert)
    XCTAssertEqual(second.selector.onlyBundleIDs, ["com.tinyspeck.slackmacgap"])
    XCTAssertEqual(second.priority, 40)
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
            { "key": "x", "mode": "command", "command": ["true"] }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue(
        String(describing: error).contains(
          "plugin mapping mode command must be all, normal, or insert"))
    }
  }

  func testManifestRejectsMalformedCommandAndBangFields() throws {
    let fixtures = [
      #""commands": [{ "command": "demo", "description": 42 }]"#,
      #""bangs": { "command": "demo", "items": [{ "token": 42 }] }"#,
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
          "sources": [{ "name": "banger.items" }],
          "bangs": {
            "command": "banger",
            "items": [{ "token": "b", "source": "typo.items" }]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue(
        String(describing: error).contains("must name a declared sources[] entry"),
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

  func testManifestOnlyPluginRequiresKeystrokeVerbs() throws {
    let root = try temporaryPluginRoot(
      manifest: """
        {
          "id": "no-process",
          "name": "No process",
          "version": "1.0.0",
          "description": "fixture",
          "install": "true",
          "verbs": [
            { "name": "needs_rpc", "description": "no keystroke" }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue(
        String(describing: error).contains("requires verb needs_rpc to declare a default"))
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

  func testLiveSourceFlagDecodesAndValidates() throws {
    let live = try JSONDecoder().decode(
      CandidateSourceDescriptor.self,
      from: Data(#"{"name": "files.results", "live": true}"#.utf8))
    XCTAssertTrue(live.live)
    XCTAssertEqual(live.kind, .standard)
    let warm = try JSONDecoder().decode(
      CandidateSourceDescriptor.self,
      from: Data(#"{"name": "notes.notes"}"#.utf8))
    XCTAssertFalse(warm.live)
    // Encoding omits the default, mirroring kind/priority.
    let encoded = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(warm)) as? [String: Any]
    XCTAssertNil(encoded?["live"])
    let encodedLive = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(live)) as? [String: Any]
    XCTAssertEqual(encodedLive?["live"] as? Bool, true)
  }

  func testManifestRejectsLiveLocationAndMixedModeSources() throws {
    func loadManifest(sources: String) throws -> PluginManifest {
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "livetest",
            "name": "Live",
            "version": "1.0.0",
            "description": "fixture",
            "exec": ["/usr/bin/true"],
            "sources": \(sources)
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      return try PluginManifest.load(from: root)
    }
    // live + locations is invalid.
    XCTAssertThrowsError(
      try loadManifest(sources: #"[{"name": "a.b", "kind": "locations", "live": true}]"#))
    // Mixed warm/live in one plugin is invalid.
    XCTAssertThrowsError(
      try loadManifest(sources: #"[{"name": "a.b", "live": true}, {"name": "a.c"}]"#))
    // All-live is valid.
    let manifest = try loadManifest(
      sources: #"[{"name": "a.b", "live": true}, {"name": "a.c", "live": true}]"#)
    XCTAssertTrue(manifest.sources.allSatisfy(\.live))
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
          { "command": "x", "subcommand": "", "description": "X" }
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
          { "name": "cold.items", "kind": "locations", "priority": "normal" }
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
    let decoded = PluginWireCodec.catalogRows(
      from: [["source": "cold.items", "title": "Warm row"]],
      sourceID: "plugin:cold-source",
      allowedSources: ["cold.items"])!
    store.publish(
      pluginID: "cold-source", rows: decoded.rows, encodedBytes: decoded.encodedBytes)
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
        "FLASH_PLUGIN_ID": "calculator",
        "FLASH_PLUGIN_CONFIG": "{}",
      ])

    XCTAssertEqual(environment["HOME"], "/Users/demo")
    XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/bin")
    XCTAssertEqual(environment["FLASH_PLUGIN_ID"], "calculator")
    XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
    XCTAssertNil(environment["SLACK_API_TOKEN"])
    XCTAssertNil(environment["SSH_AUTH_SOCK"])
  }

  func testStorageEntryMergeEnforcesBounds() {
    XCTAssertEqual(
      PluginHostRPC.applyingStorageEntry(key: "a", value: "1", to: [:]), ["a": "1"])
    XCTAssertEqual(
      PluginHostRPC.applyingStorageEntry(key: "a", value: nil, to: ["a": "1", "b": "2"]),
      ["b": "2"])
    // Deleting an absent key is a no-op, not an error.
    XCTAssertEqual(PluginHostRPC.applyingStorageEntry(key: "x", value: nil, to: [:]), [:])
    // Oversized values are rejected.
    XCTAssertNil(
      PluginHostRPC.applyingStorageEntry(
        key: "a",
        value: String(repeating: "x", count: PluginHostRPC.maxStorageValueBytes + 1),
        to: [:]))
    // A full table rejects new keys but still allows updates and deletes.
    var full: [String: String] = [:]
    for index in 0..<PluginHostRPC.maxStorageEntries { full["k\(index)"] = "v" }
    XCTAssertNil(PluginHostRPC.applyingStorageEntry(key: "new", value: "v", to: full))
    XCTAssertNotNil(PluginHostRPC.applyingStorageEntry(key: "k0", value: "updated", to: full))
    XCTAssertEqual(
      PluginHostRPC.applyingStorageEntry(key: "k0", value: nil, to: full)?.count,
      PluginHostRPC.maxStorageEntries - 1)
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
    XCTAssertTrue(FlashLog.jsonLine(records[0]).contains("\"source\":\"core:test\""))
  }

  // MARK: - Clipboard dashboard decode

  func testDecodeClipboardModalEntriesRoundTripsPluginJSON() throws {
    // The shape the Rust clipboard plugin emits for `:clipboard`.
    let json = """
      [{"preview":"hello","value":"hello"},{"preview":"two…","value":"two lines\\nof text"}]
      """
    let entries = try XCTUnwrap(AppDelegate.decodeClipboardModalEntries(json))
    XCTAssertEqual(entries.map(\.preview), ["hello", "two…"])
    XCTAssertEqual(entries.map(\.value), ["hello", "two lines\nof text"])
  }

  func testDecodeClipboardModalEntriesAcceptsEmptyHistory() throws {
    let entries = try XCTUnwrap(AppDelegate.decodeClipboardModalEntries("[]"))
    XCTAssertTrue(entries.isEmpty)
  }

  func testDecodeClipboardModalEntriesRejectsMalformedJSON() {
    XCTAssertNil(AppDelegate.decodeClipboardModalEntries("not json"))
    XCTAssertNil(
      AppDelegate.decodeClipboardModalEntries("[{\"preview\":\"x\"}]"),
      "an entry missing the required `value` field decodes to nil")
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

  func testDefaultsManifestIsManifestOnlyWithKeystrokeVerbs() throws {
    let root = try XCTUnwrap(
      try officialPluginRoots().first { $0.lastPathComponent == "defaults" })
    let defaults = try PluginManifest.load(from: root)
    // Manifest-only: no process, no binary — every verb resolves through
    // the host's keystroke path.
    XCTAssertNil(defaults.exec)
    XCTAssertEqual(defaults.activation, .manifestOnly)
    XCTAssertEqual(
      Set(defaults.verbs.map(\.name)),
      ["app_save", "app_print", "document_open", "window_new"])
    XCTAssertTrue(
      defaults.verbs.allSatisfy { !($0.keystrokes[""] ?? "").isEmpty },
      "manifest-only verbs must carry a default keystroke")
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

  func testOfficialPluginsRespondOverNDJSONWithMockedCLIs() throws {
    let cases = [
      ("slack", "slack"),
      ("spotify", "spotify_player"),
    ]
    for (pluginID, binary) in cases {
      try runPluginSmoke(pluginID: pluginID, binary: binary)
    }
  }

  func testRustPluginExitsWhenHostClosesStdin() throws {
    try runPluginStdinEOFSmoke(pluginID: "calculator")
  }

  // MARK: - Fixture helpers

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

  private func runPluginSmoke(pluginID: String, binary: String) throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-smoke-\(pluginID)-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let dataDir = temp.appendingPathComponent("data")
    let binDir = dataDir.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    let mock = binDir.appendingPathComponent(binary)
    try """
    #!/bin/sh
    printf '\(binary) %s\\n' "$*"
    """.write(to: mock, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mock.path)

    let pluginRoot = repositoryRoot().appendingPathComponent("Plugins/\(pluginID)")
    let binaryURL = pluginRoot.appendingPathComponent("flash-plugin-\(pluginID)")
    guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
      throw XCTSkip(
        "\(pluginID) binary not built — run Scripts/build-plugins.sh before the protocol smoke test"
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
    env["PATH"] = "\(binDir.path):\(env["PATH"] ?? "")"
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
        // command should complete without host-side subprocess RPCs.
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
    send([
      "id": 3,
      "method": "perform",
      "params": [
        "kind": "command",
        "args": ["--version"],
        "command": pluginID,
        "subcommand": "run",
        "raw": ":\(pluginID) run --version",
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
    XCTAssertEqual(responseOK(id: 3, messages: messages), true, collector.raw())
  }

  private func runPluginStdinEOFSmoke(pluginID: String) throws {
    let pluginRoot = repositoryRoot().appendingPathComponent("Plugins/\(pluginID)")
    let binaryURL = pluginRoot.appendingPathComponent("flash-plugin-\(pluginID)")
    guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
      throw XCTSkip(
        "\(pluginID) binary not built — run Scripts/build-plugins.sh before the stdin-EOF smoke test"
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
