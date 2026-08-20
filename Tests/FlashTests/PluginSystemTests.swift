import FlashCore
import Foundation
import XCTest

@testable import flash

final class PluginSystemTests: XCTestCase {
  /// Single-row conveniences over the atomic plural decoders — the wire only
  /// ever carries arrays, so production has no singular path.
  private func decodeCandidate(
    from raw: [String: Any], sourceID: String, allowed: Set<String>
  ) -> Candidate? {
    PluginWireCodec.catalogCandidates(from: [raw], sourceID: sourceID, allowedSources: allowed)?
      .first
  }

  private func decodeQueryAnswer(
    from raw: [String: Any], sourceID: String, source: String
  ) -> Candidate? {
    PluginWireCodec.queryAnswers(from: [raw], sourceID: sourceID, source: source)?.first
  }

  func testNullOptionalFieldsDecodeAsAbsent() throws {
    // `{"url": null}` is the natural serialization of an absent optional in
    // most languages; it must decode like a missing key, not atomically
    // reject the snapshot.
    let candidate = try XCTUnwrap(
      decodeCandidate(
        from: [
          "title": "Row",
          "url": NSNull(),
          "effect": NSNull(),
          "metadata": ["source": "safe.items"],
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

  func testOfficialPluginManifestsLoadAndRegisterExpectedCommands() throws {
    let roots = try officialPluginRoots()
    let manifests = try roots.map { try PluginManifest.load(from: $0) }
    let ids = Set(manifests.map(\.id))
    // Plugins are discovered by globbing Plugins/*/manifest.json — a new
    // plugin needs no test edit. Each manifest id must match its directory
    // name, and the floor guards against a glob misfire silently passing
    // an empty set.
    XCTAssertEqual(
      ids, Set(roots.map(\.lastPathComponent)),
      "every manifest id must match its plugin directory name")
    XCTAssertGreaterThanOrEqual(
      roots.count, 10, "official plugin discovery found implausibly few plugins")

    let runCommandRequired: Set<String> = [
      "media", "slack", "spotify",
    ]
    for (root, manifest) in zip(roots, manifests) {
      // Bundled plugins have no install step (`install` is
      // third-party-only). Compiled plugins (Rust default, plus the Go/Zig
      // polyglot exercisers) exec their built binary by convention;
      // interpreted ones (python/ruby/bun) exec a mise-pinned runtime by
      // bare name; manifest-only plugins such as `defaults` omit `exec`
      // entirely. See Scripts/build-plugins.sh.
      XCTAssertNil(manifest.install, "\(manifest.id): official plugins declare no install step")
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
      XCTAssertFalse(manifest.description.isEmpty)
      if runCommandRequired.contains(manifest.id) {
        XCTAssertTrue(
          manifest.commands.contains { $0.subcommand == "run" },
          "\(manifest.id) is missing the run subcommand")
      }
    }
    for root in roots {
      let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
      let object = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: data) as? [String: Any])
      for source in object["sources"] as? [[String: Any]] ?? [] {
        XCTAssertNotNil(
          source["priority"],
          "\(root.lastPathComponent) source \(source["name"] ?? "<unnamed>") must declare priority")
      }
    }
    let tmux = try XCTUnwrap(manifests.first { $0.id == "tmux" })
    XCTAssertNil(tmux.install)
    XCTAssertEqual(tmux.exec, ["./flash-plugin-tmux"])
    XCTAssertTrue(tmux.volatile)
    XCTAssertEqual(tmux.priority, 20)
    // Discovery is process/PTY based, so the source must not require a static
    // terminal bundle allowlist or own any terminal key mappings.
    XCTAssertTrue(tmux.onlyBundleIDs.isEmpty)
    XCTAssertTrue(try XCTUnwrap(tmux.hintsProvider).fallbackOnEmpty)
    XCTAssertTrue(tmux.sourceActions.contains("tab_new"))
    XCTAssertTrue(tmux.sourceActions.contains("pane_split_vertical"))
    XCTAssertTrue(tmux.sourceActions.contains("pane_split_horizontal"))
    XCTAssertTrue(tmux.sourceActions.contains("pane_close"))
    XCTAssertTrue(tmux.sourceActions.contains("app_reload"))
    XCTAssertEqual(tmux.navigationSchemes, ["tmux"])
    XCTAssertTrue(tmux.mappings.isEmpty)
    XCTAssertEqual(
      tmux.candidateSourceDescriptors,
      [CandidateSourceDescriptor(name: "tmux.windows", kind: .locations, priority: .high)])
    for id in ["chromium", "firefox", "safari"] {
      let manifest = try XCTUnwrap(manifests.first { $0.id == id })
      XCTAssertFalse(manifest.candidateSourceDescriptors.isEmpty)
      XCTAssertTrue(
        manifest.candidateSourceDescriptors.allSatisfy { $0.kind == .locations },
        "\(id) must classify tab sources as locations")
      XCTAssertTrue(
        manifest.candidateSourceDescriptors.allSatisfy { $0.priority == .high },
        "\(id) must rank tab sources as high-priority locations")
    }
    let slack = try XCTUnwrap(manifests.first { $0.id == "slack" })
    XCTAssertTrue(slack.candidateSourceDescriptors.isEmpty)
    XCTAssertTrue(slack.navigationSchemes.isEmpty)
    XCTAssertEqual(slack.capabilities, [.network])
    let defaults = try XCTUnwrap(manifests.first { $0.id == "defaults" })
    // Manifest-only: no process, no binary — every verb resolves through
    // the host's inline-keystroke path.
    XCTAssertNil(defaults.exec)
    XCTAssertEqual(
      Set(defaults.verbs.map(\.name)),
      ["app_save", "app_print", "document_open", "window_new"])
    XCTAssertTrue(
      defaults.verbs.allSatisfy { !($0.inlineKeystrokes[""] ?? "").isEmpty },
      "manifest-only verbs must carry a default inline keystroke")
    let calculator = try XCTUnwrap(manifests.first { $0.id == "calculator" })
    XCTAssertTrue(calculator.providesQueryEvaluation)
    XCTAssertEqual(calculator.queriesProvider?.surfaces, [.flashlight])
    // network_fetch, not network: the ECB refresh goes through host.fetch
    // against the manifest fetch_urls allowlist, so the calculator keeps a
    // fully network-denied deny-default sandbox.
    XCTAssertEqual(calculator.capabilities, [.networkFetch])
    XCTAssertEqual(calculator.fetchURLs, ["https://www.ecb.europa.eu/"])
    XCTAssertNotNil(calculator.sandbox)

    XCTAssertTrue(
      commandNames(for: "spotify", manifests: manifests).isSuperset(of: [
        "login", "status", "pause", "play", "toggle", "next", "previous", "search", "run",
      ]))
    XCTAssertTrue(
      commandNames(for: "slack", manifests: manifests).isSuperset(of: [
        "login", "version", "run",
      ]))
    let system = try XCTUnwrap(manifests.first { $0.id == "system" })
    XCTAssertEqual(system.capabilities, [.accessibility, .open])
    XCTAssertEqual(system.listen, ["core:power.changed"])
    XCTAssertEqual(system.statusSegments, ["battery"])
    XCTAssertEqual(
      system.candidateSourceDescriptors,
      [CandidateSourceDescriptor(name: "system.actions", priority: .normal)])
    XCTAssertTrue(
      commandNames(for: "system", manifests: manifests).isSuperset(of: [
        "", "lock", "sleep", "displaysleep", "restart", "shutdown", "logout", "trash", "dark",
        "screensaver", "caffeinate", "decaffeinate",
      ]))

    let screenshot = try XCTUnwrap(manifests.first { $0.id == "screenshot" })
    XCTAssertEqual(
      Set(screenshot.commands.map(\.subcommand)),
      [
        "", "options", "screen", "selection", "window",
        "screen_clipboard", "selection_clipboard", "window_clipboard",
      ])
    XCTAssertEqual(
      Set(screenshot.verbs.map(\.name)),
      [
        "screenshot_options", "screenshot_screen", "screenshot_selection",
        "screenshot_window", "screenshot_screen_clipboard", "screenshot_selection_clipboard",
        "screenshot_window_clipboard",
      ])
  }

  func testClipboardManifestRegistersBrowseCommand() throws {
    let root = try XCTUnwrap(
      try officialPluginRoots().first { $0.lastPathComponent == "clipboard" })
    let manifest = try PluginManifest.load(from: root)
    let browse = try XCTUnwrap(
      manifest.commands.first { $0.command == "clipboard" && $0.subcommand.isEmpty },
      "clipboard plugin must register the bare `:clipboard` history command")
    XCTAssertFalse(browse.description.isEmpty)
  }

  func testQueriesManifestRegistrationDefaultsToFlashlightSurface() throws {
    let data = try XCTUnwrap(
      """
      {
        "id": "answers",
        "name": "Answers",
        "version": "1.0.0",
        "description": "Pure query answers",
        "install": "true",
        "exec": ["./flash-plugin-answers"],
        "queries": {}
      }
      """.data(using: .utf8))
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

    XCTAssertTrue(manifest.providesQueryEvaluation)
    XCTAssertEqual(manifest.queriesProvider?.surfaces, [.flashlight])
  }

  func testQueriesManifestRejectsRegexAndOtherUnknownFields() throws {
    let root = try temporaryPluginRoot(
      manifest: """
        {
          "id": "bad-query-router",
          "name": "Bad query router",
          "version": "1.0.0",
          "description": "fixture",
          "install": "true",
          "exec": ["/usr/bin/true"],
          "queries": { "regex": "^.+$" }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue(
        String(describing: error).contains("manifest.json queries unknown field regex"))
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
          "commands": {
            "items": [
              { "command": "no-process", "subcommand": "ping", "description": "x" }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue(
        String(describing: error).contains("without exec cannot declare commands"))
    }
  }

  func testManifestOnlyPluginRequiresInlineKeystrokeVerbs() throws {
    let root = try temporaryPluginRoot(
      manifest: """
        {
          "id": "no-process",
          "name": "No process",
          "version": "1.0.0",
          "description": "fixture",
          "install": "true",
          "verbs": {
            "items": [
              { "name": "needs_rpc", "description": "no keystroke" }
            ]
          }
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

  func testManifestRejectsUnknownNestedProviderFields() throws {
    let fixtures: [(String, String)] = [
      (
        #"""
        "commands": {
          "items": [{ "command": "demo", "description": "Demo", "descrption": "typo" }]
        }
        """#,
        "manifest.json commands.items[0] unknown field descrption"
      ),
      (
        #"""
        "sources": [{ "name": "demo.items", "priority": "normal", "priorty": 2 }]
        """#,
        "manifest.json sources[0] unknown field priorty"
      ),
      (
        #"""
        "help": { "topics": [{ "name": "demo", "title": "Demo", "summray": "typo" }] }
        """#,
        "manifest.json help.topics[0] unknown field summray"
      ),
    ]

    for (provider, expected) in fixtures {
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "nested",
            "name": "Nested",
            "version": "1.0.0",
            "description": "Nested schema fixture",
            "install": "true",
            "exec": ["/usr/bin/true"],
            \(provider)
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }

      XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
        XCTAssertTrue(String(describing: error).contains(expected), String(describing: error))
      }
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
          "mappings": {
            "items": [{ "key": "x", "mode": "command", "command": ["true"] }]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue(
        String(describing: error).contains(
          "plugin mapping mode command must be all, normal, or insert"))
    }
  }

  func testManifestRejectsMalformedCommandAndShebangFields() throws {
    let fixtures = [
      #""""commands": { "items": [{ "command": "demo", "description": 42 }] }"""#,
      #""""commands": { "items": [{ "command": "demo", "_url": 42 }] }"""#,
      #""""shebangs": { "items": [{ "token": 42 }] }"""#,
    ]

    for provider in fixtures {
      let root = try temporaryPluginRoot(
        manifest: """
          {
            "id": "malformed",
            "name": "Malformed",
            "version": "1.0.0",
            "description": "Malformed field fixture",
            "install": "true",
            "exec": ["/usr/bin/true"],
            \(provider)
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      XCTAssertThrowsError(try PluginManifest.load(from: root))
    }
  }

  func testCandidateSourcePluginsDeclareAuthoritativeWarmStartup() throws {
    let roots = try officialPluginRoots()
    let manifests = try roots.map { try PluginManifest.load(from: $0) }
    let candidateIDs = Set(
      manifests.filter { !$0.candidateSourceDescriptors.isEmpty }.map(\.id))
    XCTAssertEqual(
      candidateIDs,
      [
        "chromium", "contacts", "emojis", "files", "firefox", "github", "history",
        "httpstatus", "kitty", "netinfo", "notes", "processes", "reminders", "safari",
        "searchengines", "shortcuts", "snippets", "system", "tmux", "windows",
      ])

    for root in roots where candidateIDs.contains(root.lastPathComponent) {
      // Source-level greps apply to Rust plugins only; the non-Rust
      // polyglot plugins (emojis/bun, searchengines/zig) satisfy the same
      // warm-startup contract through the host's runtime readiness gate
      // (the first sources.snapshot pull must decode before warm reads).
      let mainRS = root.appendingPathComponent("src/main.rs")
      guard FileManager.default.fileExists(atPath: mainRS.path) else { continue }
      let body = try String(contentsOf: mainRS)
      XCTAssertTrue(
        body.contains("async fn on_start"),
        "\(root.lastPathComponent) must warm manifest sources during on_start")
      XCTAssertTrue(
        body.contains("set_locations("),
        "\(root.lastPathComponent) must publish an authoritative warm snapshot")
      XCTAssertTrue(
        body.contains(#""plugin:\#(root.lastPathComponent)""#),
        "\(root.lastPathComponent) must publish under its canonical plugin:<id> key")
      XCTAssertFalse(
        body.contains("candidate_query"),
        "\(root.lastPathComponent) cannot override SDK-owned source snapshots")
    }
  }

  func testPluginProtocolVersionRequiresExactV1() {
    XCTAssertEqual(PluginWireCodec.protocolVersion, 1)
    XCTAssertTrue(
      PluginWireCodec.acceptsProtocolVersion([
        "ok": true,
        "protocol_version": 1,
      ]))
    XCTAssertFalse(PluginWireCodec.acceptsProtocolVersion(["protocol_version": 3]))
    XCTAssertFalse(PluginWireCodec.acceptsProtocolVersion(["ok": true]))
    XCTAssertFalse(PluginWireCodec.acceptsProtocolVersion(nil))
  }

  func testQueryEvaluatorAnswerPayloadsAreRejectedAtomicallyAboveTheCap() {
    let answer: [String: Any] = [
      "title": "2",
      "effect": ["type": "copy_text", "text": "2"],
    ]
    XCTAssertEqual(PluginWireCodec.maxQueryAnswersPerEvaluator, 16)
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

  func testUnloadedPluginSnapshotSettlesImmediatelyWithoutWireTimeout() throws {
    let data = try XCTUnwrap(
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
      """.data(using: .utf8))
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-cold-\(UUID().uuidString)")
    let process = PluginProcess(
      root: root,
      manifest: manifest,
      origin: .official,
      baseDataDir: root)
    let source = PluginFlashSource(plugin: process)
    let settled = expectation(description: "known-dead adapter settles")
    let started = CFAbsoluteTimeGetCurrent()

    source.snapshotCandidates(
      in: FlashSourceEnvironment(runningApplications: []),
      scope: .all
    ) { candidates in
      XCTAssertTrue(candidates.isEmpty)
      XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 0.05)
      settled.fulfill()
    }

    wait(for: [settled], timeout: 1)
  }

  func testWarmRequestsOnlyDispatchInReadyOrDegradedStates() {
    // The one shared predicate: state factor isolated by holding the
    // queue-confined factors true.
    func dispatchable(_ state: PluginRuntimeState) -> Bool {
      PluginProcess.warmRequestIsDispatchable(
        state: state, initializationCompleted: true, processRunning: true)
    }
    XCTAssertTrue(dispatchable(.ready))
    XCTAssertTrue(dispatchable(.degraded))
    XCTAssertFalse(dispatchable(.unloaded))
    XCTAssertFalse(dispatchable(.installing))
    XCTAssertFalse(dispatchable(.starting))
    XCTAssertFalse(dispatchable(.crashed))
    XCTAssertFalse(dispatchable(.stopped))
  }

  func testPluginProcessRechecksWarmReadinessAtTheWireQueueBoundary() {
    XCTAssertTrue(
      PluginProcess.warmRequestIsDispatchable(
        state: .ready, initializationCompleted: true, processRunning: true))
    XCTAssertTrue(
      PluginProcess.warmRequestIsDispatchable(
        state: .degraded, initializationCompleted: true, processRunning: true))
    XCTAssertFalse(
      PluginProcess.warmRequestIsDispatchable(
        state: .degraded, initializationCompleted: false, processRunning: true))
    XCTAssertFalse(
      PluginProcess.warmRequestIsDispatchable(
        state: .starting, initializationCompleted: false, processRunning: true))
    XCTAssertFalse(
      PluginProcess.warmRequestIsDispatchable(
        state: .ready, initializationCompleted: true, processRunning: false))
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

  func testPluginCandidateCannotSpoofRoutingOwner() throws {
    let candidate = try XCTUnwrap(
      decodeCandidate(
        from: [
          "title": "Owned result",
          "metadata": [
            "source": "safe.items",
            "source_id": "plugin:attacker",
          ],
        ],
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))

    XCTAssertEqual(candidate.source, "safe.items")
    XCTAssertEqual(candidate.sourceID, "plugin:safe")

    XCTAssertNil(
      decodeCandidate(
        from: [
          "title": "Impostor",
          "metadata": ["source": "other.items"],
        ],
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))
  }

  func testPluginCatalogPayloadIsStrictBoundedAndAtomic() throws {
    let valid: [String: Any] = [
      "title": "Safe result",
      "url": "https://example.com/item",
      "metadata": [
        "source": "safe.items",
        "kind": "document",
      ],
    ]
    XCTAssertEqual(
      PluginWireCodec.catalogCandidates(
        from: [valid],
        sourceID: "plugin:safe",
        allowedSources: ["safe.items"])?.count,
      1)

    var unknownKey = valid
    unknownKey["command"] = "spoof"
    XCTAssertNil(
      PluginWireCodec.catalogCandidates(
        from: [valid, unknownKey],
        sourceID: "plugin:safe",
        allowedSources: ["safe.items"]),
      "one malformed row rejects the complete warm snapshot")

    var nonStringMetadata = valid
    nonStringMetadata["metadata"] = [
      "source": "safe.items",
      "pid": 123,
    ]
    XCTAssertNil(
      decodeCandidate(
        from: nonStringMetadata,
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))

    var relativeURL = valid
    relativeURL["url"] = "relative/path"
    XCTAssertNil(
      decodeCandidate(
        from: relativeURL,
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))

    var oversizedTitle = valid
    oversizedTitle["title"] = String(
      repeating: "x",
      count: PluginWireCodec.maxCandidateTitleBytes + 1)
    XCTAssertNil(
      decodeCandidate(
        from: oversizedTitle,
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))

    XCTAssertNil(
      PluginWireCodec.catalogCandidates(
        from: Array(
          repeating: valid,
          count: PluginWireCodec.maxCatalogCandidates + 1),
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

  func testLiveSourceModeDecodesAndValidates() throws {
    let live = try JSONDecoder().decode(
      CandidateSourceDescriptor.self,
      from: Data(#"{"name": "files.results", "mode": "live"}"#.utf8))
    XCTAssertEqual(live.mode, .live)
    XCTAssertEqual(live.kind, .standard)
    let warm = try JSONDecoder().decode(
      CandidateSourceDescriptor.self,
      from: Data(#"{"name": "notes.notes"}"#.utf8))
    XCTAssertEqual(warm.mode, .warm)
    // Unknown mode strings are rejected, not defaulted.
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        CandidateSourceDescriptor.self,
        from: Data(#"{"name": "x", "mode": "lazy"}"#.utf8)))
    // Encoding omits the default mode, mirroring kind/priority.
    let encoded = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(warm)) as? [String: Any]
    XCTAssertNil(encoded?["mode"])
    let encodedLive = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(live)) as? [String: Any]
    XCTAssertEqual(encodedLive?["mode"] as? String, "live")
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
      try loadManifest(sources: #"[{"name": "a.b", "kind": "locations", "mode": "live"}]"#))
    // Mixed warm/live in one plugin is invalid.
    XCTAssertThrowsError(
      try loadManifest(sources: #"[{"name": "a.b", "mode": "live"}, {"name": "a.c"}]"#))
    // All-live is valid.
    let manifest = try loadManifest(
      sources: #"[{"name": "a.b", "mode": "live"}, {"name": "a.c", "mode": "live"}]"#)
    XCTAssertTrue(manifest.sources.allSatisfy { $0.mode == .live })
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
      decodeCandidate(
        from: [
          "title": "Docs",
          "effect": ["type": "open", "url": "https://example.com/docs"],
          "metadata": ["source": "safe.items"],
        ],
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))
    XCTAssertEqual(openURLRow.effect, .openURL("https://example.com/docs"))
    let openAppRow = try XCTUnwrap(
      decodeCandidate(
        from: [
          "title": "Calculator",
          "effect": ["type": "open", "bundle_id": "com.apple.calculator"],
          "metadata": ["source": "safe.items"],
        ],
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))
    XCTAssertEqual(openAppRow.effect, .openApplication("com.apple.calculator"))

    // Schemeless URLs, both-keys, and neither-key forms are rejected.
    XCTAssertNil(
      decodeCandidate(
        from: [
          "title": "bad",
          "effect": ["type": "open", "url": "not a url"],
          "metadata": ["source": "safe.items"],
        ],
        sourceID: "plugin:safe",
        allowed: ["safe.items"]))
    XCTAssertNil(
      decodeCandidate(
        from: [
          "title": "bad",
          "effect": [
            "type": "open",
            "url": "https://example.com",
            "bundle_id": "com.example",
          ],
          "metadata": ["source": "safe.items"],
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

  func testQueryAnswerFieldAndAggregateLimitsAreStrict() {
    let oversizedField = String(
      repeating: "x",
      count: PluginWireCodec.maxQueryFieldBytes + 1)
    XCTAssertNil(
      decodeQueryAnswer(
        from: [
          "title": oversizedField,
          "effect": ["type": "copy_text", "text": "x"],
        ],
        sourceID: "plugin:calculator",
        source: "calculator"))

    let largeAnswer: [String: Any] = [
      "title": String(repeating: "t", count: PluginWireCodec.maxQueryFieldBytes),
      "subtitle": String(repeating: "s", count: PluginWireCodec.maxQueryFieldBytes),
      "effect": [
        "type": "copy_text",
        "text": String(repeating: "e", count: PluginWireCodec.maxQueryFieldBytes),
      ],
    ]
    XCTAssertNil(
      PluginWireCodec.queryAnswers(
        from: Array(
          repeating: largeAnswer,
          count: PluginWireCodec.maxQueryAnswersPerEvaluator),
        sourceID: "plugin:calculator",
        source: "calculator"),
      "individually valid answers must still fit the aggregate response budget")
  }

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

  func testOfficialPluginInstallScriptsAvoidGlobalInstallTargets() throws {
    let banned = [
      "sudo", "brew install", "npm install -g", "deno install -g", "/usr/local/bin",
      "$HOME/.local/bin", "~/.local/bin",
    ]
    // Bundled plugins are Rust binaries with no shell install step: the
    // manifest's `install`/`start` strings and the crate sources must not
    // reach for global install locations.
    for root in try officialPluginRoots() {
      let manifest = try PluginManifest.load(from: root)
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
          "only_urls": ["https://open.spotify.com/*"],
          "commands": {
            "items": [
              { "command": "spotify", "subcommand": "pause", "description": "Pause playback" }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.id, "spotify")
    XCTAssertEqual(manifest.install, "npm install")
    XCTAssertEqual(manifest.exec, ["npm", "start"])
    XCTAssertEqual(manifest.listen, ["core:apps.*", "core:config.*"])
    XCTAssertEqual(manifest.onlyBundleIDs, ["com.spotify.client"])
    XCTAssertEqual(manifest.onlyURLs, ["https://open.spotify.com/*"])
    XCTAssertEqual(manifest.commands.first?.command, "spotify")
    XCTAssertEqual(manifest.commands.first?.subcommand, "pause")
    XCTAssertTrue(manifest.mappings.isEmpty, "absent mappings key defaults to []")
  }

  func testManifestRejectsLegacyTopLevelKeys() throws {
    for key in ["manifest_version", "subscriptions", "bundle_ids", "candidates"] {
      let value: String
      switch key {
      case "manifest_version":
        value = "2"
      case "subscriptions":
        value = #"["core:config.*"]"#
      case "bundle_ids":
        value = #"["com.example.app"]"#
      case "candidates":
        value = #"{"sources": [{"name": "example.items"}]}"#
      default:
        value = "null"
      }
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
          "mappings": {
            "items": [
              { "key": "q", "command": ["flash", "plugin_command", "--command=slack", "--subcommand=run"] },
              {
                "key": "ctrl+k",
                "mode": "insert",
                "command": ["flash", "hints_dismiss"],
                "only_bundle_ids": ["com.tinyspeck.slackmacgap"],
                "only_urls": ["slack://*"],
                "priority": 40
              }
            ]
          }
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
    XCTAssertEqual(second.selector.onlyURLs, ["slack://*"])
    XCTAssertEqual(second.priority, 40)
  }

  func testSafariPluginOverridesHardRefreshBinding() throws {
    let root = try XCTUnwrap(
      try officialPluginRoots().first { $0.lastPathComponent == "safari" })
    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(
      manifest.onlyBundleIDs,
      ["com.apple.Safari", "com.apple.SafariTechnologyPreview"])
    let mapping = try XCTUnwrap(manifest.mappings.first)
    XCTAssertEqual(manifest.mappings.count, 1)
    XCTAssertEqual(mapping.key, "R")
    XCTAssertEqual(mapping.scope, .normal)
    // Safari's "Reload Page From Origin" is ⌘⌥R, unlike the ⌘⇧R that the
    // built-in `R` → app_reload(force) default sends for Firefox/Chrome.
    XCTAssertEqual(mapping.command, ["flash", "send_key", "--keys=cmd+option+r"])
    // The mappings provider scopes itself to release Safari only (the
    // technology preview reload shortcut is different on some builds),
    // while the manifest-wide `only_bundle_ids` include the preview.
    XCTAssertEqual(mapping.selector.onlyBundleIDs, ["com.apple.Safari"])
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

  func testManifestDecodesProviderSectionsAcrossKinds() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "multi",
          "name": "Multi",
          "version": "0.1.0",
          "description": "Every surface in split provider sections",
          "install": "true",
          "exec": ["/usr/bin/true"],
          "only_bundle_ids": ["com.example.app"],
          "sources": [
            { "name": "multi.items" }
          ],
          "navigation": { "schemes": ["multi"] },
          "source_actions": ["resource_archive", "resource_next"],
          "status": { "segments": ["battery"] },
          "hints": { "fallback_on_empty": true },
          "commands": {
            "items": [
              { "command": "multi", "subcommand": "go", "description": "Go" }
            ]
          },
          "mappings": {
            "items": [
              { "key": "q", "command": ["flash", "hints_dismiss"] }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertTrue(manifest.providesHints)
    XCTAssertTrue(try XCTUnwrap(manifest.hintsProvider).fallbackOnEmpty)
    XCTAssertTrue(manifest.providesCandidates)
    XCTAssertEqual(manifest.candidateSources, ["multi.items"])
    XCTAssertEqual(manifest.navigationSchemes, ["multi"])
    XCTAssertEqual(manifest.sourceActions, ["resource_archive", "resource_next"])
    XCTAssertEqual(manifest.statusSegments, ["battery"])
    XCTAssertEqual(manifest.commands.map(\.subcommand), ["go"])
    XCTAssertEqual(manifest.mappings.map(\.key), ["q"])
  }

  func testPluginRegistrationInventoryCountsManifestSurfaces() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "multi",
          "name": "Multi",
          "version": "0.1.0",
          "description": "Every surface in split provider sections",
          "install": "true",
          "exec": ["/usr/bin/true"],
          "listen": ["core:apps.*", "core:config.*"],
          "capabilities": ["accessibility"],
          "sources": [
            { "name": "multi.items" }
          ],
          "navigation": { "schemes": ["multi"] },
          "source_actions": ["resource_archive", "resource_next"],
          "status": { "segments": ["battery"] },
          "hints": {},
          "commands": {
            "items": [
              { "command": "multi", "subcommand": "go", "description": "Go" }
            ]
          },
          "mappings": {
            "items": [
              { "key": "q", "command": ["flash", "hints_dismiss"] }
            ]
          },
          "shebangs": {
            "command": "multi",
            "items": [
              { "token": "m", "description": "Multi" }
            ]
          },
          "verbs": {
            "command": "multi",
            "items": [
              { "name": "multi_open", "description": "Open" }
            ]
          },
          "help": {
            "topics": [
              { "name": "multi", "title": "Multi", "summary": "Multi", "body": "# Multi" }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    let inventory = PluginRegistrationInventory(manifests: [manifest])
    XCTAssertEqual(inventory.plugins, 1)
    XCTAssertEqual(inventory.commands, 1)
    XCTAssertEqual(inventory.mappings, 1)
    XCTAssertEqual(inventory.shebangs, 1)
    XCTAssertEqual(inventory.verbs, 1)
    XCTAssertEqual(inventory.candidateSources, 1)
    XCTAssertEqual(inventory.sourceActions, 2)
    XCTAssertEqual(inventory.statusSegments, 1)
    XCTAssertEqual(inventory.navigationSchemes, 1)
    XCTAssertEqual(inventory.helpTopics, 1)
    XCTAssertEqual(inventory.listeners, 2)
    XCTAssertEqual(inventory.hintProviders, 1)
    XCTAssertEqual(inventory.capabilityRequests, 1)
  }

  func testProvidesFlagsFalseWithoutMatchingProvider() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "cmdsonly",
          "name": "Commands Only",
          "version": "0.1.0",
          "description": "No hints, no candidates",
          "install": "true",
          "exec": ["/usr/bin/true"],
          "commands": {
            "items": [
              { "command": "x", "subcommand": "", "description": "X" }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertFalse(manifest.providesHints)
    XCTAssertFalse(manifest.providesCandidates)
  }

  func testCommandEntriesOwnSelectors() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "scoped",
          "name": "Scoped",
          "version": "0.1.0",
          "description": "App-scoped commands",
          "install": "true",
          "exec": ["/usr/bin/true"],
          "only_bundle_ids": ["com.example.app"],
          "commands": {
            "items": [
              { "command": "scoped", "subcommand": "here", "description": "Uses root scope" },
              {
                "command": "scoped",
                "subcommand": "elsewhere",
                "description": "Overrides scope",
                "only_bundle_ids": ["com.other.app"],
                "only_urls": ["https://example.com/*"]
              }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    let here = try XCTUnwrap(manifest.commands.first { $0.subcommand == "here" })
    XCTAssertTrue(here.selector.onlyBundleIDs.isEmpty, "root selector is not copied into entries")
    let elsewhere = try XCTUnwrap(manifest.commands.first { $0.subcommand == "elsewhere" })
    XCTAssertEqual(elsewhere.selector.onlyBundleIDs, ["com.other.app"])
    XCTAssertEqual(elsewhere.selector.onlyURLs, ["https://example.com/*"])
  }

  func testMappingsProviderModeFoldsIntoEntries() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "moded",
          "name": "Moded",
          "version": "0.1.0",
          "description": "Provider-level mode gate",
          "install": "true",
          "exec": ["/usr/bin/true"],
          "mappings": {
            "modes": ["insert"],
            "items": [
              { "key": "j", "command": ["flash", "hints_dismiss"] }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    let mapping = try XCTUnwrap(manifest.mappings.first)
    XCTAssertEqual(mapping.mode, "insert", "single provider mode folds into the default entry")
    XCTAssertEqual(mapping.scope, .insert)
  }

  func testShebangProviderFoldsCommandAndScope() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "banger",
          "name": "Banger",
          "version": "0.1.0",
          "description": "Flashlight bangs",
          "install": "true",
          "exec": ["/usr/bin/true"],
          "only_bundle_ids": ["com.example.app"],
          "shebangs": {
            "command": "search",
            "items": [
              { "token": "r", "description": "Reddit" },
              { "token": "*", "_note": "catch-all" },
              { "token": "gh", "command": "github", "only_bundle_ids": ["com.other.app"] }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(Set(manifest.shebangs.map(\.token)), ["r", "*", "gh"])
    let reddit = try XCTUnwrap(manifest.shebangs.first { $0.token == "r" })
    XCTAssertEqual(reddit.command, "search", "entry inherits the provider's command")
    XCTAssertTrue(reddit.selector.onlyBundleIDs.isEmpty)
    let catchAll = try XCTUnwrap(manifest.shebangs.first { $0.token == "*" })
    XCTAssertEqual(catchAll.command, "search")
    XCTAssertEqual(catchAll.meta["_note"], "catch-all", "_-prefixed fields are retained as meta")
    let github = try XCTUnwrap(manifest.shebangs.first { $0.token == "gh" })
    XCTAssertEqual(github.command, "github", "entry's own command wins")
    XCTAssertEqual(github.selector.onlyBundleIDs, ["com.other.app"])
  }

  func testSelectorPatternMatchingAndSpecificity() {
    let bundleOnly = PluginSelector(onlyBundleIDs: ["com.example.app"])
    let bundleAndURL = PluginSelector(
      onlyBundleIDs: ["com.example.app"],
      onlyURLs: ["https://example.com/work/*"])
    let context = PluginSelectorContext(
      bundleID: "com.example.app",
      url: "https://example.com/work/42")

    XCTAssertTrue(PluginPattern("core:apps.*").matches("core:apps.launched"))
    XCTAssertFalse(PluginPattern("core:apps.*").matches("core:config.changed"))
    XCTAssertTrue(bundleAndURL.matches(context))
    XCTAssertFalse(bundleAndURL.matches(PluginSelectorContext(bundleID: "com.example.app")))
    XCTAssertGreaterThan(
      try XCTUnwrap(bundleAndURL.specificity(in: context)),
      try XCTUnwrap(bundleOnly.specificity(in: context)))
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

  private func commandNames(for id: String, manifests: [PluginManifest]) -> Set<String> {
    let manifest = manifests.first { $0.id == id }
    return Set(manifest?.commands.map(\.subcommand) ?? [])
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

    // The smoke test exercises only the managed NDJSON protocol. The
    // plugin owns subprocess execution now. Initialization does not respond
    // until on_start and any required warm-source publication complete.
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
          commandResponded.signal()
        default:
          break
        }
      }
    }

    send([
      "id": 1,
      "method": "initialize",
      "params": [
        "protocol_version": PluginWireCodec.protocolVersion,
        "running_applications": [
          [
            "bundle_id": "com.example.Test",
            "localized_name": "Test",
            "pid": 42,
          ]
        ],
      ],
    ])
    send(["id": -1, "method": "heartbeat", "params": [:]])
    send([
      "id": 2,
      "method": "command.invoke",
      "params": [
        "args": ["--version"],
        "command": pluginID,
        "subcommand": "run",
        "raw": ":\(pluginID) run --version",
      ],
    ])

    if initialized.wait(timeout: .now() + 15) != .success {
      stdout.fileHandleForReading.readabilityHandler = nil
      process.terminate()
      XCTFail("\(pluginID) plugin did not complete warm initialization")
      return
    }
    if commandResponded.wait(timeout: .now() + 5) != .success {
      stdout.fileHandleForReading.readabilityHandler = nil
      process.terminate()
      XCTFail("\(pluginID) plugin did not respond to command.invoke")
      return
    }
    send(["method": "shutdown", "params": ["reason": "test"]])
    stdin.fileHandleForWriting.closeFile()

    if finished.wait(timeout: .now() + 5) != .success {
      stdout.fileHandleForReading.readabilityHandler = nil
      process.terminate()
      XCTFail("\(pluginID) plugin did not exit")
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
    XCTAssertEqual(responseOK(id: -1, messages: messages), true, collector.raw())
    XCTAssertEqual(responseOK(id: 2, messages: messages), true, collector.raw())
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
