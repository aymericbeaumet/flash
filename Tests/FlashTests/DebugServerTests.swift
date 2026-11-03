import AppKit
import FlashCore
import Network
import XCTest

@testable import flash

final class DebugServerTests: XCTestCase {
  /// The access token every test server answers; the helpers send it.
  static let token = HelpAccess.newToken()

  /// The regression: the loopback address is shared by every account and
  /// process on the Mac, and no browser header marks another account's
  /// client. Without the token a data endpoint answers nothing and a config
  /// write (code execution through `[monitors] run`) is refused; the page
  /// shell and the bundled manual stay public.
  func testTheDataEndpointsAnswerOnlyTheAccessToken() throws {
    let server = DebugServer(
      host: "127.0.0.1", port: 0, accessToken: Self.token,
      configHTTP: { _, _, _, completion in
        completion("200 OK", "text/plain; charset=utf-8", Data())
      },
      stateProvider: { ["secret": true] })
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    for path in [
      "/api/state", "/api/logs", "/api/traces", "/api/config", "/api/telemetry",
      "/api/clipboard/history?offset=0",
    ] {
      XCTAssertEqual(
        try fetchData(port: port, method: "GET", path: path, token: nil).status, 401, path)
      XCTAssertEqual(
        try fetchData(port: port, method: "GET", path: path, token: HelpAccess.newToken()).status,
        401, "\(path) with another token")
    }
    XCTAssertEqual(
      try fetchData(port: port, method: "PUT", path: "/api/config", token: nil).status, 401,
      "another account writing your configuration")
    XCTAssertEqual(try fetchData(port: port, method: "PUT", path: "/api/config").status, 200)
    XCTAssertEqual(try fetchData(port: port, method: "GET", path: "/api/state").status, 200)
    XCTAssertEqual(
      try fetchData(port: port, method: "GET", path: "/api/state?token=\(Self.token)", token: nil)
        .status, 200, "an event stream or an image carries it in its address")
    XCTAssertEqual(
      try fetchData(port: port, method: "GET", path: "/clipboard", token: nil).status, 200,
      "the page shell holds no data")
    XCTAssertNotEqual(
      try fetchData(port: port, method: "GET", path: "/api/docs", token: nil).status, 401,
      "the bundled manual is public")
  }

  func testAuthorizationReadsTheBearerHeaderOrTheAddressOnly() {
    let token = Self.token
    func request(_ target: String, _ headers: [String] = []) -> String {
      "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:4242\r\n"
        + headers.map { $0 + "\r\n" }.joined() + "\r\n"
    }
    XCTAssertTrue(
      DebugServer.isAuthorized(
        request: request("/api/state", ["Authorization: Bearer \(token)"]), token: token))
    XCTAssertTrue(
      DebugServer.isAuthorized(
        request: request("/api/state", ["authorization: bearer \(token)"]), token: token))
    XCTAssertTrue(
      DebugServer.isAuthorized(request: request("/api/events?token=\(token)"), token: token))
    XCTAssertFalse(DebugServer.isAuthorized(request: request("/api/state"), token: token))
    XCTAssertFalse(DebugServer.isAuthorized(request: request("/api/state?token="), token: token))
    XCTAssertFalse(
      DebugServer.isAuthorized(
        request: request("/api/state", ["Authorization: Basic \(token)"]), token: token))
    // One character off, whichever character the random token ends with.
    let wrong = String(token.dropLast()) + (token.hasSuffix("0") ? "1" : "0")
    XCTAssertNotEqual(wrong, token)
    XCTAssertFalse(
      DebugServer.isAuthorized(
        request: request("/api/state", ["Authorization: Bearer \(wrong)"]), token: token))
    XCTAssertFalse(
      DebugServer.isAuthorized(
        request: request("/api/state", ["Cookie: token=\(token)"]), token: token),
      "never a cookie: a cookie reaches every port of the host")
  }

  /// Flash opens the page with the token once; the page keeps it per origin.
  func testTheOpenedAddressCarriesTheToken() throws {
    let url = try XCTUnwrap(
      DebugServer.dashboardURL(host: "localhost", port: 4242, page: .clipboard, token: Self.token))
    XCTAssertEqual(url.absoluteString, "http://localhost:4242/clipboard?token=\(Self.token)")
  }

  /// The token file is private, and one that is not is never trusted.
  func testTheTokenFileIsPrivateAndAnyOtherIsReplaced() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-help-token-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("help-token")
    let first = try HelpAccess.loadOrCreate(at: file)
    XCTAssertTrue(HelpAccess.isWellFormed(first))
    let mode = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
    XCTAssertEqual(mode.intValue & 0o777, 0o600)
    XCTAssertEqual(try HelpAccess.loadOrCreate(at: file), first, "it persists across launches")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    XCTAssertNil(HelpAccess.load(from: file), "readable by others: maybe read already")
    let replaced = try HelpAccess.loadOrCreate(at: file)
    XCTAssertNotEqual(replaced, first)
    XCTAssertTrue(HelpAccess.matches(replaced, replaced))
    XCTAssertFalse(HelpAccess.matches(first, replaced))
    XCTAssertFalse(HelpAccess.matches("", ""))
  }

  /// A local process could open connections and send nothing, holding
  /// Flash's file descriptors forever. A request must arrive whole before
  /// its deadline, and connections still sending theirs are capped.
  func testAConnectionThatSendsNothingIsClosedAndIdleOnesAreCapped() throws {
    let server = DebugServer(
      host: "127.0.0.1", port: 0, accessToken: Self.token, requestDeadlineMs: 200,
      stateProvider: { [:] })
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    let idle = IdleClient(port: port)
    defer { idle.cancel() }
    XCTAssertTrue(spin(timeout: 5) { idle.closed }, "an idle connection is closed at its deadline")

    let crowd = (0..<DebugServer.maxAwaitingRequests + 4).map { _ in IdleClient(port: port) }
    defer { for client in crowd { client.cancel() } }
    XCTAssertTrue(
      spin(timeout: 5) { crowd.filter(\.closed).count >= 4 },
      "past the cap a new connection is closed at once")
    XCTAssertTrue(spin(timeout: 5) { crowd.allSatisfy(\.closed) }, "the rest at their deadline")
    XCTAssertEqual(
      try fetchData(port: port, method: "GET", path: "/api/state").status, 200,
      "once the idle ones are gone, requests are answered again")
  }

  func testInspectorCannotBeFramedByAnotherWebsite() throws {
    let server = DebugServer(
      host: "127.0.0.1", port: 0, accessToken: Self.token, stateProvider: { [:] })
    server.start()
    defer { server.stop() }
    let page = try fetchData(port: waitForListeningPort(server), method: "GET", path: "/")
    XCTAssertEqual(
      page.response.value(forHTTPHeaderField: "Content-Security-Policy"), "frame-ancestors 'none'")
    XCTAssertEqual(page.response.value(forHTTPHeaderField: "X-Frame-Options"), "DENY")
    XCTAssertEqual(page.response.value(forHTTPHeaderField: "Referrer-Policy"), "no-referrer")
    XCTAssertEqual(
      page.response.value(forHTTPHeaderField: "Cross-Origin-Resource-Policy"), "same-origin",
      "another site cannot embed a clipboard image or a JSON body with a no-cors <img> or <script>")
  }

  /// A request that changes something is refused when a browser says it
  /// comes from another site, whatever its method: the config PUT must not
  /// rest on browsers preflighting it.
  func testAChangeFromAnotherSiteIsRefused() {
    func request(_ method: String, _ headers: [String]) -> String {
      "\(method) /api/config HTTP/1.1\r\nHost: 127.0.0.1:4242\r\n"
        + headers.map { $0 + "\r\n" }.joined() + "\r\n"
    }
    let refused: [(String, [String])] = [
      ("PUT", ["Origin: https://evil.example"]),
      ("POST", ["Origin: null"]),
      ("DELETE", ["Origin: http://127.0.0.1:9999"]),
      ("PUT", ["Sec-Fetch-Site: cross-site"]),
      ("POST", ["Origin: http://127.0.0.1:4242", "Sec-Fetch-Site: cross-site"]),
    ]
    for (method, headers) in refused {
      XCTAssertTrue(
        DebugServer.isCrossSiteChange(request: request(method, headers), port: 4242),
        "\(method) \(headers)")
    }
    let allowed: [(String, [String])] = [
      ("PUT", ["Origin: http://127.0.0.1:4242", "Sec-Fetch-Site: same-origin"]),
      ("PUT", ["Origin: http://localhost:4242"]),
      ("DELETE", []),
      ("GET", ["Origin: https://evil.example"]),
    ]
    for (method, headers) in allowed {
      XCTAssertFalse(
        DebugServer.isCrossSiteChange(request: request(method, headers), port: 4242),
        "\(method) \(headers)")
    }
  }

  func testInspectorPagePrefersTheAppBundleCopy() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-inspector-page-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let appCopy = directory.appendingPathComponent("app.html")
    let moduleCopy = directory.appendingPathComponent("module.html")
    try Data("staged dev page".utf8).write(to: appCopy)
    try Data("swiftpm build copy".utf8).write(to: moduleCopy)
    XCTAssertEqual(
      DebugServer.inspectorPage(appCopy: appCopy, moduleCopy: moduleCopy),
      "staged dev page")
    XCTAssertEqual(
      DebugServer.inspectorPage(
        appCopy: directory.appendingPathComponent("missing.html"), moduleCopy: moduleCopy),
      "swiftpm build copy")
    XCTAssertTrue(
      DebugServer.inspectorPage(appCopy: nil, moduleCopy: nil).contains("UI bundle missing"))
  }

  func testRuntimeSnapshotIsSerializableAndKeepsPluginSettingsPrivate() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.overlay.statusPopupController = StatusPopupController(
      terminals: delegate.overlay.statusTerminals, windowActionsEnabled: false)
    defer { delegate.overlay.statusTerminals.shutdown() }
    delegate.config = ConfigLoader.parse(
      """
      [plugins.sample]
      token = "private-test-token"
      """)
    let state = delegate.debugStateJSON()
    let data = try JSONSerialization.data(withJSONObject: state)
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(json.contains("private-test-token"))
    let runtime = try XCTUnwrap(state["runtime"] as? [String: Any])
    XCTAssertEqual(runtime["pid"] as? Int32, ProcessInfo.processInfo.processIdentifier)
    // Uptime is derived client-side from a fixed start time, never pushed.
    XCTAssertNil(runtime["uptime_seconds"])
    let started = try XCTUnwrap(runtime["started_at_unix_ms"] as? Int64)
    XCTAssertEqual(
      Double(started), delegate.runtimeStartedAt.timeIntervalSince1970 * 1000, accuracy: 1)
    XCTAssertEqual(runtime["keyboard_capture_active"] as? Bool, false)
    XCTAssertNotNil(state["snapshot_at_unix_ms"] as? Int64)
    XCTAssertEqual(state["overlay"] as? String, String(describing: delegate.overlay.inputMode))
    let mappings = try XCTUnwrap(state["mappings"] as? [String: Any])
    let rows = try XCTUnwrap(mappings["effective_rows"] as? [[String: String]])
    XCTAssertEqual(rows, mappings["rows"] as? [[String: String]])
    XCTAssertTrue(rows.contains { $0["key"] == "?" && $0["action"] == "flash mappings show" })
  }

  /// The snapshot is built on main on every change a browser watches, so it
  /// carries previews, not values: a clipboard entry's text and HTML stay
  /// behind `/api/clipboard/history`, and each snapshot names itself to the
  /// main-thread watchdog.
  func testRuntimeSnapshotCarriesClipboardPreviewsAndNotesMainActivity() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.overlay.statusPopupController = StatusPopupController(
      terminals: delegate.overlay.statusTerminals, windowActionsEnabled: false)
    defer { delegate.overlay.statusTerminals.shutdown() }
    delegate.clipboardEntries = [
      ClipboardModalEntry(
        id: "0123456789abcdef0123456789abcdef", kind: "html", preview: "hello",
        value: "hello world, the full copied text", html: "<b>hello</b>", mime: nil, files: [])
    ]
    let state = delegate.debugStateJSON()
    let clipboard = try XCTUnwrap(state["clipboard"] as? [[String: Any]])
    XCTAssertEqual(clipboard.count, 1)
    XCTAssertEqual(clipboard[0]["preview"] as? String, "hello")
    XCTAssertEqual(clipboard[0]["kind"] as? String, "html")
    XCTAssertNil(clipboard[0]["value"], "full text is served by the history endpoint")
    XCTAssertNil(clipboard[0]["html"], "formatted copies are served by the history endpoint")
    let json = try XCTUnwrap(
      String(data: try JSONSerialization.data(withJSONObject: state), encoding: .utf8))
    XCTAssertFalse(json.contains("full copied text"))
    XCTAssertTrue(
      MainThreadActivity.recent().hasPrefix("inspector_snapshot("),
      "the watchdog can name a slow snapshot: \(MainThreadActivity.recent())")
  }

  /// A plugin's snapshot row carries no command list — the top-level
  /// `commands` already names every plugin command with its source — and
  /// bounds each status segment to a preview.
  func testPluginStatusSnapshotDropsCommandsAndBoundsSegments() throws {
    let status = PluginStatus(
      id: "sample", name: "Sample", version: "0.1.0", description: "", origin: "official",
      root: "/tmp/sample", state: "running", activation: "resident", pid: nil,
      startedAtUnixMs: nil, sourceCount: 0, commandCount: 2, restartCount: 0, lastError: nil,
      lastLog: nil, cpuTimeMs: nil, memoryBytes: nil, onlyBundleIDs: [], priority: 25,
      commands: [
        PluginCommandRegistration(command: "sample", subcommand: "run"),
        PluginCommandRegistration(command: "sample", subcommand: "stop"),
      ],
      statusSegments: ["short": "ok", "long": String(repeating: "x", count: 2_000)])
    let object = status.jsonObject
    XCTAssertNil(object["commands"])
    XCTAssertEqual(object["command_count"] as? Int, 2)
    let segments = try XCTUnwrap(object["status_segments"] as? [String: String])
    XCTAssertEqual(segments["short"], "ok")
    let long = try XCTUnwrap(segments["long"])
    XCTAssertEqual(long.count, PluginStatus.segmentPreviewCharacters + 1)
    XCTAssertTrue(long.hasSuffix("…"))
  }

  func testDashboardLinksUsePagePaths() throws {
    let token = Self.token
    func link(_ host: String, _ page: DebugServer.Page) -> URL? {
      DebugServer.dashboardURL(host: host, port: 4242, page: page, token: token)
    }
    XCTAssertEqual(
      link("localhost", .home)?.absoluteString, "http://localhost:4242/?token=\(token)")
    XCTAssertEqual(
      link("127.0.0.1", .mappings)?.absoluteString, "http://127.0.0.1:4242/mappings?token=\(token)")
    // `:help <topic>` opens `/docs/<topic>`: each segment percent-encoded,
    // and a manual page keeps its directories, as on the published site.
    let topic = "plugin symbols #?%"
    let url = try XCTUnwrap(link("::1", .docs(page: topic)))
    XCTAssertEqual(
      url.absoluteString, "http://[::1]:4242/docs/plugin%20symbols%20%23%3F%25?token=\(token)")
    XCTAssertNil(url.fragment)
    XCTAssertEqual(url.query, "token=\(token)", "the token is the only query")
    XCTAssertEqual(DebugServer.Page(path: url.path(percentEncoded: true)), .docs(page: topic))
    XCTAssertEqual(link("localhost", .docs(page: nil))?.path, "/docs")
    XCTAssertEqual(
      link("localhost", .docs(page: "alternatives/neru"))?.absoluteString,
      "http://localhost:4242/docs/alternatives/neru?token=\(token)")
    XCTAssertNil(link("example.com", .home))
  }

  func testEveryPageRoundTripsThroughItsPath() {
    let pages: [DebugServer.Page] = [
      .home, .docs(page: nil), .docs(page: "getting-started"), .docs(page: "alternatives/neru"),
      .docs(page: "é/ü"), .mappings, .commands, .plugins(id: nil), .plugins(id: "tmux"), .state,
      .monitors, .telemetry, .logs,
      .clipboard, .search,
    ]
    for page in pages {
      XCTAssertEqual(DebugServer.Page(path: page.path), page, page.path)
      XCTAssertEqual(DebugServer.route(path: page.path), .app(found: true), page.path)
    }
  }

  /// Every page path, including deep links and reloads, receives the help
  /// app; data lives under `/api/`; anything else is not found.
  func testRoutesSeparatePagesFromEndpoints() {
    XCTAssertEqual(DebugServer.route(path: "/api/state"), .state)
    XCTAssertEqual(DebugServer.route(path: "/api/logs"), .logs)
    XCTAssertEqual(DebugServer.route(path: "/api/traces"), .traces)
    XCTAssertEqual(DebugServer.route(path: "/api/events"), .events)
    XCTAssertEqual(DebugServer.route(path: "/api/clipboard/history"), .clipboardHistory)
    XCTAssertEqual(DebugServer.route(path: "/api/config"), .config)
    XCTAssertEqual(DebugServer.route(path: "/api/config/purge"), .configPurge)
    XCTAssertEqual(DebugServer.route(path: "/api/telemetry"), .telemetry)
    let id = "0123456789abcdef0123456789abcdef"
    XCTAssertEqual(DebugServer.route(path: "/api/clipboard/\(id)"), .clipboardItem(id: id))
    XCTAssertEqual(DebugServer.route(path: "/api/clipboard/\(id)/pin"), .clipboardPin(id: id))
    XCTAssertEqual(DebugServer.route(path: "/api/clipboard/x\(id)/pin"), .missingEndpoint)
    XCTAssertEqual(DebugServer.route(path: "/api/clipboard/\(id)/pins"), .missingEndpoint)
    XCTAssertEqual(DebugServer.requestMethod("DELETE /api/clipboard/\(id) HTTP/1.1\r\n"), "DELETE")
    XCTAssertEqual(DebugServer.clipboardHistoryOffset("GET /api/clipboard/history HTTP/1.1\r\n"), 0)
    XCTAssertEqual(
      DebugServer.clipboardHistoryOffset("GET /api/clipboard/history?offset=100 HTTP/1.1\r\n"),
      100)
    for invalid in ["-1", "1.5", "abc", "10001", "", "1&offset=2", "1&other=2"] {
      XCTAssertNil(
        DebugServer.clipboardHistoryOffset(
          "GET /api/clipboard/history?offset=\(invalid) HTTP/1.1\r\n"))
    }
    for invalid in ["?other=1", "?offset", "?"] {
      XCTAssertNil(
        DebugServer.clipboardHistoryOffset(
          "GET /api/clipboard/history\(invalid) HTTP/1.1\r\n"))
    }
    XCTAssertEqual(DebugServer.route(path: "/api/docs"), .docs(file: "docs.json"))
    XCTAssertEqual(DebugServer.route(path: "/api/docs/search"), .docs(file: "search.json"))
    // A manual page links its files by their docs/ path, served as they are.
    XCTAssertEqual(
      DebugServer.route(path: "/docs/examples/statusbar/flash.toml"),
      .docs(file: "files/examples/statusbar/flash.toml"))
    XCTAssertEqual(
      DebugServer.route(path: "/docs/assets/hero.gif"), .docs(file: "files/assets/hero.gif"))
    for path in [
      "/api", "/api/", "/api/state/x", "/api/docs/x", "/api/config/x", "/api/clipboard",
      "/api/clipboard/",
      "/api/clipboard/\(id)/x", "/api/clipboard/NOT-32-HEX",
      "/api/clipboard/\(id.uppercased())",
    ] {
      XCTAssertEqual(DebugServer.route(path: path), .missingEndpoint, path)
    }
    for path in ["/docs/", "/docs/a/b", "/mappings/", "/plugins/tmux/"] {
      XCTAssertEqual(DebugServer.route(path: path), .app(found: true), path)
    }
    // Files are plain names of a known type: no dot file, `..`, encoded
    // separator or executable escapes into the bundle.
    for path in [
      "/home", "/missing", "/guides", "/guides/hints", "/state/x", "/mappings/gg", "/docs/%zz",
      "/index.html",
      "/docs/%2E%2E/secret.toml", "/docs/.hidden.toml", "/docs/a%2Fb.toml", "/docs/x.exe",
      "/docs/examples/x.md", "/docs/assets/logo.svg", "/docs/page.html",
    ] {
      XCTAssertEqual(DebugServer.route(path: path), .app(found: false), path)
    }
  }

  /// The manual comes from the bundle the build staged, read off main; a
  /// path that would leave it is not found.
  func testServesTheBundledManualAndItsFiles() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-docs-\(UUID().uuidString)", isDirectory: true)
    let files = root.appendingPathComponent("files/examples", isDirectory: true)
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"pages":[],"nav":[]}"#.utf8).write(to: root.appendingPathComponent("docs.json"))
    try Data("[]".utf8).write(to: root.appendingPathComponent("search.json"))
    try Data("[statusbar]\n".utf8).write(to: files.appendingPathComponent("flash.toml"))
    try Data("outside".utf8).write(
      to: root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent).toml"))
    defer {
      try? FileManager.default.removeItem(
        at: root.deletingLastPathComponent().appendingPathComponent(
          "\(root.lastPathComponent).toml"))
    }
    let server = DebugServer(
      host: "127.0.0.1", port: 0, accessToken: Self.token, docsRoot: root, stateProvider: { [:] })
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)

    let manual = try fetchData(port: port, method: "GET", path: "/api/docs")
    XCTAssertEqual(manual.status, 200)
    XCTAssertEqual(manual.type, "application/json; charset=utf-8")
    XCTAssertEqual(String(data: manual.body, encoding: .utf8), #"{"pages":[],"nav":[]}"#)
    XCTAssertEqual(try fetchData(port: port, method: "GET", path: "/api/docs/search").status, 200)
    let example = try fetchData(port: port, method: "GET", path: "/docs/examples/flash.toml")
    XCTAssertEqual(example.status, 200)
    XCTAssertEqual(example.type, "text/plain; charset=utf-8")
    XCTAssertEqual(String(data: example.body, encoding: .utf8), "[statusbar]\n")
    XCTAssertEqual(try fetchData(port: port, method: "GET", path: "/docs/missing.toml").status, 404)
    XCTAssertEqual(try fetchData(port: port, method: "PUT", path: "/api/docs").status, 405)
    XCTAssertNil(DebugServer.docsURL("../\(root.lastPathComponent).toml", root: root))
    XCTAssertNil(DebugServer.docsURL("files/x.toml", root: nil))

    let unbundled = DebugServer(
      host: "127.0.0.1", port: 0, accessToken: Self.token, docsRoot: nil, stateProvider: { [:] })
    unbundled.start()
    defer { unbundled.stop() }
    XCTAssertEqual(
      try fetchData(port: waitForListeningPort(unbundled), method: "GET", path: "/api/docs").status,
      404)
  }

  func testTracesSummarizeEachInteractionAcrossHostAndPlugins() {
    let logs: [[String: Any]] = [
      [
        "trace": "a1", "time_unix_ms": Int64(100), "level": "debug", "message": "[trace] begin",
        "fields": ["origin": "key"], "source": "core:AppDelegate.swift.route()",
      ],
      ["trace": "a1", "time_unix_ms": Int64(130), "level": "warn", "source": "plugin:tmux"],
      ["time_unix_ms": Int64(140), "level": "info", "source": "core:x"],
      [
        "trace": "b2", "time_unix_ms": Int64(200), "level": "debug", "message": "[trace] begin",
        "fields": ["origin": "cli"], "source": "core:y",
      ],
    ]
    let traces = DebugServer.traceSummaries(logs)
    XCTAssertEqual(traces.map { $0["trace"] as? String }, ["b2", "a1"], "newest first")
    let first = traces[1]
    XCTAssertEqual(first["origin"] as? String, "key")
    XCTAssertEqual(first["duration_ms"] as? Int64, 30)
    XCTAssertEqual(first["lines"] as? Int, 2)
    XCTAssertEqual(first["worst_level"] as? String, "warn")
    XCTAssertEqual(first["sources"] as? [String], ["core", "plugin:tmux"])
    XCTAssertEqual(
      DebugServer.queryValue("trace", in: "GET /api/logs?x=1&trace=a1 HTTP/1.1\r\n"), "a1")
    XCTAssertNil(DebugServer.queryValue("trace", in: "GET /api/logs HTTP/1.1\r\n"))
  }

  /// DNS rebinding: a page on its own hostname, rebound to 127.0.0.1, must
  /// not read the inspector; only requests naming this listener pass.
  func testInspectorServesOnlyRequestsForItsOwnLoopbackHost() {
    func request(_ host: String?) -> String {
      "GET /api/state HTTP/1.1\r\n" + (host.map { "Host: \($0)\r\n" } ?? "") + "Accept: */*\r\n\r\n"
    }
    for host in ["127.0.0.1:4242", "localhost:4242", "[::1]:4242", "LOCALHOST:4242"] {
      XCTAssertTrue(DebugServer.hostIsLoopback(request: request(host), port: 4242), host)
    }
    for host in ["evil.example:4242", "127.0.0.1:9999", "localhost", "127.0.0.1.evil.example:4242"]
    {
      XCTAssertFalse(DebugServer.hostIsLoopback(request: request(host), port: 4242), host)
    }
    XCTAssertFalse(DebugServer.hostIsLoopback(request: request(nil), port: 4242))
  }

  func testParsesLoopbackHostAndPort() {
    let localhost = DebugServer.parse(host: "localhost", port: 4242)
    XCTAssertEqual(localhost?.host, "localhost")
    XCTAssertEqual(localhost?.port.rawValue, 4242)

    let ipv4 = DebugServer.parse(host: "127.0.0.1", port: 4343)
    XCTAssertEqual(ipv4?.host, "127.0.0.1")
    XCTAssertEqual(ipv4?.port.rawValue, 4343)

    let ipv6 = DebugServer.parse(host: "::1", port: 4444)
    XCTAssertEqual(ipv6?.host, "::1")
    XCTAssertEqual(ipv6?.port.rawValue, 4444)
  }

  func testRejectsNonLoopbackHostAndOutOfRangePort() {
    XCTAssertNil(DebugServer.parse(host: "0.0.0.0", port: 4242))
    XCTAssertNil(DebugServer.parse(host: "192.168.1.10", port: 4242))
    XCTAssertNil(DebugServer.parse(host: "example.com", port: 4242))
    XCTAssertNil(DebugServer.parse(host: "localhost", port: -1))
    XCTAssertNil(DebugServer.parse(host: "localhost", port: 70000))
  }

  func testListenerBindsTheLoopbackAddressOnly() throws {
    XCTAssertEqual(DebugServer.bindAddress(host: "localhost"), .ipv4(.loopback))
    XCTAssertEqual(DebugServer.bindAddress(host: "127.0.0.1"), .ipv4(.loopback))
    XCTAssertEqual(DebugServer.bindAddress(host: "::1"), .ipv6(.loopback))

    // The socket itself, as `lsof` reports it: the loopback address, never
    // every address with only an interface restriction on top.
    let server = DebugServer(host: "localhost", port: 0, accessToken: Self.token) { ["ok": true] }
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    let lsof = Process()
    lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    lsof.arguments = ["-nP", "-a", "-p", "\(getpid())", "-iTCP:\(port)", "-sTCP:LISTEN"]
    let output = Pipe()
    lsof.standardOutput = output
    lsof.standardError = FileHandle.nullDevice
    try lsof.run()
    lsof.waitUntilExit()
    let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertTrue(listing.contains("127.0.0.1:\(port) (LISTEN)"), listing)
    XCTAssertFalse(listing.contains("*:\(port)"), listing)
  }

  func testLoopbackEndpointFilter() {
    XCTAssertTrue(
      DebugServer.isLoopback(
        endpoint: .hostPort(host: .name("localhost", nil), port: 4242)))
    XCTAssertTrue(
      DebugServer.isLoopback(
        endpoint: .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: 4242)))
    XCTAssertTrue(
      DebugServer.isLoopback(
        endpoint: .hostPort(host: .ipv6(IPv6Address("::1")!), port: 4242)))
    XCTAssertFalse(
      DebugServer.isLoopback(
        endpoint: .hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 4242)))
  }

  func testServesStateJSON() throws {
    let server = DebugServer(host: "localhost", port: 0, accessToken: Self.token) {
      ["ok": true]
    }
    server.start()
    defer { server.stop() }

    let port = try waitForListeningPort(server)
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/state"))
    let response = try fetch(url: url, deadline: Date().addingTimeInterval(10))
    XCTAssertEqual(response.status, 200)
    XCTAssertTrue(response.body.contains("\"ok\":true"), response.body)
  }

  func testServesSvelteInspectorBundleOnEveryPage() throws {
    let server = DebugServer(host: "localhost", port: 0, accessToken: Self.token) {
      ["ok": true]
    }
    server.start()
    defer { server.stop() }

    let port = try waitForListeningPort(server)
    let root = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
    let home = try fetch(url: root, deadline: Date().addingTimeInterval(10))
    XCTAssertEqual(home.status, 200)
    let body = home.body

    // The inspector UI is the Svelte single-file bundle shipped as a
    // resource; assert on stable, non-minified markers rather than the
    // old inline-JS internals.
    XCTAssertTrue(body.contains("<title>Flash</title>"), "missing help document title")
    XCTAssertTrue(body.contains("id=\"app\""), body)
    // The runtime data wiring survives minification as string literals.
    XCTAssertTrue(body.contains("/api/events"), body)
    XCTAssertTrue(body.contains("/api/state"), body)
    // Confirms it is the built bundle, not the missing-resource fallback.
    XCTAssertGreaterThan(body.count, 5_000, "served body looks like the fallback page")
    // The rename is complete — no "Flash Debug" anywhere.
    XCTAssertFalse(body.contains("Flash Debug"), body)

    // Direct loads and reloads of deep pages receive the same app; unknown
    // pages receive it with a 404 so it can render its own not-found view.
    for (path, status) in [
      ("/docs/getting-started", 200), ("/mappings?q=gg", 200), ("/state", 200),
      ("/missing", 404),
    ] {
      let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
      let response = try fetch(url: url, deadline: Date().addingTimeInterval(10))
      XCTAssertEqual(response.status, status, path)
      XCTAssertEqual(response.body, body, path)
    }
    let missing = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/missing"))
    let endpoint = try fetch(url: missing, deadline: Date().addingTimeInterval(10))
    XCTAssertEqual(endpoint.status, 404)
    XCTAssertEqual(endpoint.body, "not found")
  }

  /// The inspector has no clock: an open event stream registers nothing with
  /// the shared poll scheduler, and a burst of changes reaches it as exactly
  /// one pushed snapshot.
  func testAnOpenEventStreamRegistersNoCadenceAndReceivesOneSnapshotPerBurst() throws {
    var version = 0
    let server = DebugServer(host: "localhost", port: 0, accessToken: Self.token) {
      version += 1
      return ["version": version]
    }
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    let before = registrations(PollScheduler.shared)

    let stream = EventStreamClient(port: port)
    defer { stream.cancel() }
    XCTAssertTrue(
      spin { stream.count(of: "event: logs") == 1 && server.publication.streams == 1 },
      "the stream opens with the cached state and logs")
    XCTAssertEqual(stream.count(of: "event: state"), 1)
    XCTAssertEqual(
      registrations(PollScheduler.shared), before, "an open stream registers no cadence")

    for _ in 0..<5 { server.stateDidChange() }
    XCTAssertTrue(spin { stream.count(of: "event: patch") == 1 }, "the burst is pushed")
    spin(for: 0.3)
    XCTAssertEqual(stream.count(of: "event: patch"), 1, "a burst is one snapshot, then quiet")
    XCTAssertEqual(stream.count(of: "event: state"), 1)
    XCTAssertTrue(stream.text.contains("\"version\":2"), stream.text)
    XCTAssertEqual(registrations(PollScheduler.shared), before)

    stream.cancel()
    XCTAssertTrue(spin { server.publication.streams == 0 }, "the closed stream is released")
  }

  /// The regression: an event stream whose client stopped reading (a hung
  /// tab, a stopped process) kept every snapshot Flash pushed, unsent, with
  /// no bound. Past `maxStreamBacklogBytes` unsent, the stream is dropped;
  /// a browser's EventSource reconnects by itself.
  func testAStalledEventStreamIsDroppedOnceItsBacklogPassesTheCap() throws {
    var version = 0
    let filler = String(repeating: "x", count: 512 * 1024)
    // A patch carries only what changed: the filler changes with each push.
    let server = DebugServer(
      host: "localhost", port: 0, accessToken: Self.token, coalescingWindowMs: 5
    ) {
      version += 1
      return ["version": version, "filler": "\(version)" + filler]
    }
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    let stalled = StalledEventStreamClient(port: port)
    defer { stalled.cancel() }
    XCTAssertTrue(spin { server.publication.streams == 1 }, "the stream opens")
    let pushes = (DebugServer.maxStreamBacklogBytes / filler.utf8.count) * 4
    for _ in 0..<pushes {
      guard server.publication.streams == 1 else { break }
      server.stateDidChange()
      spin(for: 0.02)
    }
    XCTAssertTrue(
      spin { server.publication.streams == 0 },
      "a stream that reads nothing is dropped instead of buffering \(version) snapshots")
  }

  /// A stream receives the whole state once, then patches: each carries the
  /// top-level sections whose encoding changed and the snapshot it builds
  /// on, so a status-bar change does not resend the mappings. A stream that
  /// opened on a stale cache has nothing to build on and gets the next
  /// snapshot whole.
  func testStreamsReceivePatchesOfTheSectionsThatChanged() throws {
    var version = 0
    let mappings = String(repeating: "m", count: 64 * 1024)
    let server = DebugServer(
      host: "localhost", port: 0, accessToken: Self.token, coalescingWindowMs: 5
    ) {
      version += 1
      var state: [String: Any] = ["version": version, "mappings": mappings]
      if version == 1 { state["gone"] = true }
      return state
    }
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    let first = EventStreamClient(port: port)
    defer { first.cancel() }
    XCTAssertTrue(spin { first.count(of: "event: logs") == 1 })
    XCTAssertEqual(first.count(of: "event: state"), 1)
    XCTAssertTrue(first.text.contains("\"snapshot_seq\":1"), "a snapshot carries its number")

    // The cache goes stale before the second stream opens.
    server.stateDidChange()
    let second = EventStreamClient(port: port)
    defer { second.cancel() }
    XCTAssertTrue(
      spin { first.count(of: "event: patch") == 1 && second.count(of: "event: state") == 1 })
    let patch = try XCTUnwrap(Self.eventData("patch", in: first.text).last)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(patch.utf8)) as? [String: Any])
    XCTAssertEqual(object["base"] as? Int, 1)
    let set = try XCTUnwrap(object["set"] as? [String: Any])
    XCTAssertEqual(set["version"] as? Int, 2)
    XCTAssertEqual(set["snapshot_seq"] as? Int, 2)
    XCTAssertNil(set["mappings"], "an unchanged section is not resent")
    XCTAssertEqual(object["unset"] as? [String], ["gone"], "a section that went away is named")
    XCTAssertLessThan(patch.utf8.count, 1024)
    let whole = try XCTUnwrap(Self.eventData("state", in: second.text).last)
    XCTAssertTrue(
      whole.contains("\"version\":2") && whole.contains(mappings), "whole to a new stream")
    XCTAssertEqual(second.count(of: "event: patch"), 0)

    server.stateDidChange()
    XCTAssertTrue(
      spin { first.count(of: "event: patch") == 2 && second.count(of: "event: patch") == 1 })
    XCTAssertEqual(
      Self.eventData("patch", in: first.text).last, Self.eventData("patch", in: second.text).last,
      "one frame for every stream")
  }

  /// A change that names its sections rebuilds only those on main, over the
  /// last snapshot; any other change in the same burst rebuilds everything.
  func testAScopedChangeRebuildsOnlyItsSections() throws {
    var full = 0
    var scoped: [Set<String>] = []
    let server = DebugServer(
      host: "localhost", port: 0, accessToken: Self.token, coalescingWindowMs: 5,
      sectionsProvider: { sections in
        scoped.append(sections)
        return Dictionary(
          uniqueKeysWithValues: sections.map { ($0, "rebuilt \(scoped.count)" as Any) })
      },
      stateProvider: {
        full += 1
        return ["bar": "full \(full)", "plugins": "sampled \(full)"]
      })
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    XCTAssertEqual(full, 1, "start takes the whole state")

    server.stateDidChange(.sections(["bar"]))
    server.stateDidChange(.sections(["bar", "popups"]))
    let state = try fetchSpinningMain(port: port, path: "/api/state")
    XCTAssertEqual(full, 1)
    XCTAssertEqual(scoped, [["bar", "popups"]], "one rebuild of the burst's sections")
    XCTAssertTrue(state.contains("\"bar\":\"rebuilt 1\""), state)
    XCTAssertTrue(state.contains("\"plugins\":\"sampled 1\""), "the rest is the last snapshot's")

    server.stateDidChange(.sections(["bar"]))
    server.stateDidChange()
    _ = try fetchSpinningMain(port: port, path: "/api/state")
    XCTAssertEqual(full, 2, "a burst with an unscoped change rebuilds everything")
    XCTAssertEqual(scoped.count, 1)
    _ = try fetchSpinningMain(port: port, path: "/api/state?refresh=1")
    XCTAssertEqual(full, 3, "a refresh resamples everything")
  }

  /// Serving the cached state, the logs, the page and the manual never waits
  /// on main (these requests block it) and never encodes the state again:
  /// a request for a large state costs a fraction of one encoding of it.
  func testCachedRepliesNeitherWaitOnMainNorReencode() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-docs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"pages":[],"nav":[]}"#.utf8).write(to: root.appendingPathComponent("docs.json"))
    let rows = (0..<20_000).map { index -> [String: Any] in
      ["key": "k\(index)", "action": "flash window move --direction=\(index)", "scope": "normal"]
    }
    let state: [String: Any] = [
      "mappings": rows, "statusbar": ["runs": rows.prefix(2_000).map { $0 }],
    ]
    let server = DebugServer(
      host: "localhost", port: 0, accessToken: Self.token, docsRoot: root, stateProvider: { state })
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)

    func elapsed(_ work: () throws -> Void) rethrows -> TimeInterval {
      let start = Date()
      try work()
      return Date().timeIntervalSince(start)
    }
    func median(_ values: [TimeInterval]) -> TimeInterval { values.sorted()[values.count / 2] }
    let encode = median(
      (0..<3).map { _ in
        elapsed { _ = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) }
      })
    var replies: [TimeInterval] = []
    for _ in 0..<9 {
      replies.append(
        try elapsed {
          XCTAssertEqual(try fetchData(port: port, method: "GET", path: "/api/state").status, 200)
        })
    }
    XCTAssertLessThan(
      median(replies), encode / 2,
      "a reply of the cached \(state.count)-section state must not encode it again")
    for path in ["/api/logs", "/api/traces", "/api/docs", "/docs/normal-mode"] {
      XCTAssertEqual(try fetchData(port: port, method: "GET", path: path).status, 200, path)
    }
  }

  /// The page and the manual change only with the app: each carries a
  /// validator, and a browser asking with it gets a bodiless 304.
  func testThePageAndTheManualRevalidateWithTheirValidators() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-docs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"pages":[],"nav":[]}"#.utf8).write(to: root.appendingPathComponent("docs.json"))
    let server = DebugServer(
      host: "localhost", port: 0, accessToken: Self.token, docsRoot: root, stateProvider: { [:] })
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    for path in ["/docs/normal-mode", "/mappings", "/api/docs"] {
      let first = try fetchRaw(port: port, path: path)
      XCTAssertTrue(first.head.hasPrefix("HTTP/1.1 200 OK"), path)
      XCTAssertTrue(first.head.contains("Cache-Control: no-cache\r\n"), path)
      let etag = try XCTUnwrap(Self.header("ETag", in: first.head), path)
      let again = try fetchRaw(port: port, path: path, headers: ["If-None-Match: W/\"x\", \(etag)"])
      XCTAssertTrue(again.head.hasPrefix("HTTP/1.1 304 Not Modified"), "\(path): \(again.head)")
      XCTAssertEqual(Self.header("ETag", in: again.head), etag)
      XCTAssertNil(Self.header("Content-Length", in: again.head))
      XCTAssertTrue(again.body.isEmpty, path)
      let other = try fetchRaw(port: port, path: path, headers: ["If-None-Match: \"other\""])
      XCTAssertTrue(other.head.hasPrefix("HTTP/1.1 200 OK"), path)
      XCTAssertEqual(other.body, first.body, path)
    }
    XCTAssertEqual(
      Self.header("ETag", in: try fetchRaw(port: port, path: "/docs").head),
      Self.header("ETag", in: try fetchRaw(port: port, path: "/clipboard").head),
      "every page is the same document")
    let missing = try fetchRaw(port: port, path: "/missing")
    XCTAssertTrue(missing.head.hasPrefix("HTTP/1.1 404 Not Found"))
    XCTAssertNil(Self.header("ETag", in: missing.head), "a not-found page is not a cache entry")
    // Runtime data stays out of the browser's cache and carries no validator.
    for path in ["/api/state", "/api/logs", "/api/traces"] {
      let data = try fetchRaw(port: port, path: path)
      XCTAssertTrue(data.head.contains("Cache-Control: no-store\r\n"), "\(path): \(data.head)")
      XCTAssertNil(Self.header("ETag", in: data.head), path)
    }
    XCTAssertFalse(DebugServer.ifNoneMatch("GET / HTTP/1.1\r\nHost: x", matches: "\"a\""))
    XCTAssertTrue(DebugServer.ifNoneMatch("GET / HTTP/1.1\r\nif-none-match: *", matches: "\"a\""))
  }

  /// Chrome and other strict clients only open an EventSource after a real
  /// blank line. A multiline string drops the newline before its closing
  /// delimiter, so the last `\r` used to sit against `event:` and the
  /// inspector stayed disconnected.
  func testEventStreamHeadersEndOnABlankLine() throws {
    let server = DebugServer(host: "localhost", port: 0, accessToken: Self.token) { ["ok": true] }
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    let stream = EventStreamClient(port: port)
    defer { stream.cancel() }
    XCTAssertTrue(
      spin { stream.text.contains("\r\n\r\nevent:") },
      "headers must end before the first event, got \(Array(stream.text.prefix(180).utf8))")
    XCTAssertTrue(stream.text.contains("Connection: keep-alive\r\n"))
    XCTAssertFalse(stream.text.contains("Connection: close\r\n"))
  }

  /// Changes inside one window collapse into one snapshot; with no stream
  /// open nothing is taken, and a stream arriving on a stale cache gets a
  /// fresh snapshot.
  func testChangesCoalesceIntoOneSnapshotPerWindowOnlyWhileObserved() {
    var snapshots = 0
    let server = DebugServer(
      host: "localhost", port: 0, accessToken: Self.token, coalescingWindowMs: 20
    ) {
      snapshots += 1
      return [:]
    }
    defer { server.stop() }
    server.streamsDidChange(by: 1)
    for _ in 0..<10 { server.stateDidChange() }
    XCTAssertEqual(snapshots, 0, "the first change waits out the window")
    XCTAssertTrue(spin { snapshots == 1 })
    spin(for: 0.1)
    XCTAssertEqual(snapshots, 1, "ten changes, one snapshot")
    server.stateDidChange()
    XCTAssertTrue(spin { snapshots == 2 }, "the next burst is the next snapshot")

    server.streamsDidChange(by: -1)
    server.stateDidChange()
    server.stateDidChange()
    spin(for: 0.1)
    XCTAssertEqual(snapshots, 2, "nobody reads it, nothing is taken")
    XCTAssertTrue(server.publication.stale)
    server.streamsDidChange(by: 1)
    XCTAssertTrue(spin { snapshots == 3 }, "a stream opening on a stale cache gets a fresh one")
    XCTAssertFalse(server.publication.stale)
  }

  /// `/api/state` answers from the cache while it is current; a stale cache
  /// or an explicit `?refresh=1` takes one fresh snapshot.
  func testStateRequestsSnapshotOnlyWhenStaleOrAskedTo() throws {
    var snapshots = 0
    let server = DebugServer(
      host: "localhost", port: 0, accessToken: Self.token, coalescingWindowMs: 10
    ) {
      snapshots += 1
      return ["n": snapshots]
    }
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    XCTAssertEqual(snapshots, 1, "start seeds the cache")

    for _ in 0..<3 { server.stateDidChange() }
    spin(for: 0.1)
    XCTAssertEqual(snapshots, 1, "no stream is open")
    XCTAssertTrue(try fetchSpinningMain(port: port, path: "/api/state").contains("\"n\":2"))
    XCTAssertEqual(snapshots, 2, "the stale cache is refreshed once")
    XCTAssertTrue(try fetchSpinningMain(port: port, path: "/api/state").contains("\"n\":2"))
    XCTAssertEqual(snapshots, 2, "a current cache answers without a snapshot")
    XCTAssertTrue(
      try fetchSpinningMain(port: port, path: "/api/state?refresh=1").contains("\"n\":3"))
    XCTAssertEqual(snapshots, 3, "an explicit refresh resamples")
  }

  func testAssembleRequestHonorsContentLengthAndTheBodyCap() {
    let headers = "PUT /api/config HTTP/1.1\r\nHost: 127.0.0.1:4242\r\nContent-Length: 5\r\n\r\n"
    XCTAssertEqual(DebugServer.assembleRequest(Data(headers.utf8)), .incomplete)
    let ready = DebugServer.assembleRequest(Data((headers + "abcdeEXTRA").utf8))
    guard case .ready(let received, let body) = ready else {
      return XCTFail("expected a complete request")
    }
    XCTAssertTrue(received.contains("PUT /api/config"))
    XCTAssertEqual(body, Data("abcde".utf8))
    XCTAssertEqual(
      DebugServer.assembleRequest(Data("GET /api/state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)),
      .ready(headers: "GET /api/state HTTP/1.1\r\nHost: 127.0.0.1", body: Data()))
    var huge = Data("POST /api/config/purge HTTP/1.1\r\nContent-Length: 300000\r\n\r\n".utf8)
    XCTAssertEqual(DebugServer.assembleRequest(huge), .tooLarge)
    huge = Data(count: DebugServer.maxRequestBytes + 1)
    XCTAssertEqual(DebugServer.assembleRequest(huge), .tooLarge)
  }

  func testConfigPutDeliversABodyLargerThanTheOldReceive() throws {
    let payload = Data(repeating: 0x61, count: 20_000)
    let seen = LockedData()
    let server = DebugServer(
      host: "localhost", port: 0, accessToken: Self.token,
      configHTTP: { method, purge, body, done in
        seen.store(method: method, purge: purge, body: body)
        done("200 OK", "application/json; charset=utf-8", Data("{\"ok\":true}".utf8))
      },
      stateProvider: { [:] }
    )
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    XCTAssertEqual(
      try fetchBody(
        port: port, method: "PUT", path: "/api/config", body: payload,
        headers: ["Origin": "https://evil.example"]), 403)
    XCTAssertEqual(seen.method, "", "a refused change never reaches the handler")
    let saved = try fetchBody(port: port, method: "PUT", path: "/api/config", body: payload)
    XCTAssertEqual(saved, 200)
    XCTAssertEqual(seen.method, "PUT")
    XCTAssertEqual(seen.purge, false)
    XCTAssertEqual(seen.body, payload)

    let purged = try fetchBody(
      port: port, method: "POST", path: "/api/config/purge", body: Data("x".utf8))
    XCTAssertEqual(purged, 200)
    XCTAssertEqual(seen.method, "POST")
    XCTAssertEqual(seen.purge, true)

    let missing = DebugServer(host: "localhost", port: 0, accessToken: Self.token) { [:] }
    missing.start()
    defer { missing.stop() }
    let missingPort = try waitForListeningPort(missing)
    XCTAssertEqual(try fetchBody(port: missingPort, method: "GET", path: "/api/config"), 503)
  }

  func testClipboardItemServesBytesAndRejectsOtherMethods() throws {
    let id = "0123456789abcdef0123456789abcdef"
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let calls = LockedCounter()
    let server = DebugServer(
      host: "localhost", port: 0, accessToken: Self.token,
      clipboardHTTP: { method, itemID, done in
        calls.increment()
        if method == "GET", itemID == id {
          done("200 OK", "image/png", png)
        } else if method == "DELETE", itemID == id {
          done("200 OK", "application/json; charset=utf-8", Data("{\"ok\":true}".utf8))
        } else {
          done("404 Not Found", "text/plain; charset=utf-8", Data("not found".utf8))
        }
      },
      stateProvider: { [:] }
    )
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)

    let image = try fetchData(port: port, method: "GET", path: "/api/clipboard/\(id)")
    XCTAssertEqual(image.status, 200)
    XCTAssertEqual(image.type, "image/png")
    XCTAssertEqual(image.body, png)
    XCTAssertEqual(image.cache, "no-store")
    XCTAssertEqual(image.connection, "close", "finite byte responses cannot be pooled")

    let deleted = try fetchData(port: port, method: "DELETE", path: "/api/clipboard/\(id)")
    XCTAssertEqual(deleted.status, 200)
    XCTAssertEqual(String(decoding: deleted.body, as: UTF8.self), "{\"ok\":true}")

    let posted = try fetchData(port: port, method: "POST", path: "/api/clipboard/\(id)")
    XCTAssertEqual(posted.status, 405)
    XCTAssertEqual(posted.connection, "close", "finite text responses cannot be pooled")
    XCTAssertEqual(calls.value, 2, "an unsupported method never reaches the handler")

    let missing = DebugServer(host: "localhost", port: 0, accessToken: Self.token) { [:] }
    missing.start()
    defer { missing.stop() }
    let missingPort = try waitForListeningPort(missing)
    let unavailable = try fetchData(port: missingPort, method: "GET", path: "/api/clipboard/\(id)")
    XCTAssertEqual(unavailable.status, 503)
  }

  func testClipboardPinsArePutAndDeletedOnly() throws {
    let id = "0123456789abcdef0123456789abcdef"
    let lock = NSLock()
    var seen: [Bool] = []
    let server = DebugServer(
      host: "localhost", port: 0, accessToken: Self.token,
      clipboardPinHTTP: { pinned, itemID, done in
        XCTAssertEqual(itemID, id)
        lock.lock()
        seen.append(pinned)
        lock.unlock()
        done("200 OK", "application/json; charset=utf-8", Data("{\"ok\":true}".utf8))
      },
      stateProvider: { [:] }
    )
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    XCTAssertEqual(
      try fetchData(port: port, method: "PUT", path: "/api/clipboard/\(id)/pin").status, 200)
    XCTAssertEqual(
      try fetchData(port: port, method: "DELETE", path: "/api/clipboard/\(id)/pin").status, 200)
    XCTAssertEqual(
      try fetchData(port: port, method: "POST", path: "/api/clipboard/\(id)/pin").status, 405)
    XCTAssertEqual(
      try fetchData(port: port, method: "GET", path: "/api/clipboard/\(id)/pin").status, 405)
    lock.lock()
    XCTAssertEqual(seen, [true, false], "only PUT and DELETE reach the handler")
    lock.unlock()
  }

  func testClipboardHistoryPagesAreBoundedByTheHandlerAndValidateOffsets() throws {
    let calls = LockedCounter()
    let server = DebugServer(
      host: "localhost", port: 0, accessToken: Self.token,
      clipboardHistoryHTTP: { offset, done in
        calls.increment()
        let body = "{\"entries\":[],\"total\":\(offset),\"next_offset\":null}"
        done("200 OK", "application/json; charset=utf-8", Data(body.utf8))
      },
      stateProvider: { [:] }
    )
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)

    let page = try fetchData(port: port, method: "GET", path: "/api/clipboard/history?offset=100")
    XCTAssertEqual(page.status, 200)
    XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains("\"total\":100"))
    XCTAssertEqual(page.cache, "no-store")
    XCTAssertEqual(
      try fetchData(port: port, method: "GET", path: "/api/clipboard/history?offset=-1").status,
      400)
    XCTAssertEqual(
      try fetchData(port: port, method: "POST", path: "/api/clipboard/history").status,
      405)
    XCTAssertEqual(calls.value, 1)
  }

  func testWhenListeningAnswersFromTheListenerState() throws {
    let server = DebugServer(host: "localhost", port: 0, accessToken: Self.token) { ["ok": true] }
    server.start()
    defer { server.stop() }
    let ready = expectation(description: "ready")
    var bound: UInt16?
    server.whenListening(timeoutSeconds: 10) { port in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertNotNil(port)
      bound = port
      ready.fulfill()
    }
    wait(for: [ready], timeout: 10)

    // A second listener on the same port fails to bind: it answers nil at
    // once rather than at the deadline.
    let port = try XCTUnwrap(bound)
    let clash = DebugServer(host: "localhost", port: Int(port), accessToken: Self.token) { [:] }
    clash.start()
    defer { clash.stop() }
    let failed = expectation(description: "bind failure reported")
    let started = Date()
    clash.whenListening(timeoutSeconds: 30) { port in
      XCTAssertNil(port)
      XCTAssertLessThan(Date().timeIntervalSince(started), 10)
      failed.fulfill()
    }
    wait(for: [failed], timeout: 15)
  }

  private func registrations(_ scheduler: PollScheduler) -> [String] {
    let listed = DispatchSemaphore(value: 0)
    var ids: [String] = []
    scheduler.registeredIDs {
      ids = $0
      listed.signal()
    }
    listed.wait()
    return ids
  }

  /// Runs the main run loop, where the server's publication lives, until
  /// `condition` holds or `timeout` passes.
  @discardableResult
  private func spin(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { return false }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return true
  }

  private func spin(for seconds: TimeInterval) {
    spin(timeout: seconds) { false }
  }

  /// A request that may need the main thread to answer (a stale cache).
  private func fetchSpinningMain(port: UInt16, path: String) throws -> String {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
    HelpAccess.authorize(&request, token: Self.token)
    var body: String?
    URLSession.shared.dataTask(with: request) { data, _, _ in
      let text = String(decoding: data ?? Data(), as: UTF8.self)
      DispatchQueue.main.async { body = text }
    }.resume()
    XCTAssertTrue(spin { body != nil }, "no reply for \(path)")
    return body ?? ""
  }

  /// The data of every `event` frame in a stream's text, in order.
  static func eventData(_ event: String, in text: String) -> [String] {
    text.components(separatedBy: "\n\n").compactMap { frame in
      let lines = frame.components(separatedBy: "\n")
      guard let at = lines.firstIndex(of: "event: \(event)"), lines.count > at + 1,
        lines[at + 1].hasPrefix("data: ")
      else { return nil }
      return String(lines[at + 1].dropFirst("data: ".count))
    }
  }

  static func header(_ name: String, in head: String) -> String? {
    head.components(separatedBy: "\r\n").dropFirst().first {
      $0.lowercased().hasPrefix(name.lowercased() + ":")
    }
    .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
  }

  /// One request over a raw connection: the response head as sent, and its
  /// body. URLSession would answer a 304 from its own cache.
  private func fetchRaw(
    port: UInt16, path: String, headers: [String] = []
  ) throws -> (head: String, body: Data) {
    let connection = NWConnection(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let done = DispatchSemaphore(value: 0)
    let received = LockedBytes()
    func receive() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
        data, _, isComplete, error in
        if let data { received.append(data) }
        if isComplete || error != nil { done.signal() } else { receive() }
      }
    }
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        let request =
          "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
          + "Authorization: Bearer \(Self.token)\r\n" + headers.map { $0 + "\r\n" }.joined()
          + "\r\n"
        connection.send(content: Data(request.utf8), completion: .idempotent)
        receive()
      case .failed, .cancelled: done.signal()
      default: break
      }
    }
    connection.start(queue: DispatchQueue(label: "debug.tests.raw"))
    defer { connection.cancel() }
    guard done.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
    let bytes = received.value
    let marker = Data("\r\n\r\n".utf8)
    guard let split = bytes.range(of: marker) else { throw URLError(.badServerResponse) }
    return (
      String(decoding: bytes[..<split.lowerBound], as: UTF8.self) + "\r\n",
      Data(bytes[split.upperBound...])
    )
  }

  /// The bound port, once the `NWListener` reached `.ready`. Read through
  /// `whenListening`, on main: `listeningPort` belongs to the server's queue.
  /// The ceiling is generous so a loaded CI runner doesn't flake.
  private func waitForListeningPort(_ server: DebugServer) throws -> UInt16 {
    let ready = expectation(description: "listening")
    var bound: UInt16?
    server.whenListening(timeoutSeconds: 10) { port in
      bound = port
      ready.fulfill()
    }
    wait(for: [ready], timeout: 11)
    return try XCTUnwrap(bound, "DebugServer never started listening")
  }

  private typealias HTTPResponse = (
    status: Int, type: String?, cache: String?, connection: String?, body: Data,
    response: HTTPURLResponse
  )

  private func fetchData(
    port: UInt16, method: String, path: String, token: String? = DebugServerTests.token
  ) throws -> HTTPResponse {
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
    var request = URLRequest(url: url)
    request.httpMethod = method
    if let token { HelpAccess.authorize(&request, token: token) }
    let sem = DispatchSemaphore(value: 0)
    var result: Result<HTTPResponse, Error>?
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        result = .failure(error)
      } else if let http = response as? HTTPURLResponse {
        result = .success(
          (
            http.statusCode,
            http.value(forHTTPHeaderField: "Content-Type"),
            http.value(forHTTPHeaderField: "Cache-Control"),
            http.value(forHTTPHeaderField: "Connection"),
            data ?? Data(), http
          ))
      } else {
        result = .failure(URLError(.badServerResponse))
      }
      sem.signal()
    }.resume()
    guard sem.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
    return try XCTUnwrap(result).get()
  }

  private func fetchBody(
    port: UInt16, method: String, path: String, body: Data = Data(), headers: [String: String] = [:]
  ) throws -> Int {
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
    var request = URLRequest(url: url)
    request.httpMethod = method
    HelpAccess.authorize(&request, token: Self.token)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    if method != "GET" { request.httpBody = body }
    let sem = DispatchSemaphore(value: 0)
    var status = 0
    URLSession.shared.dataTask(with: request) { _, response, _ in
      status = (response as? HTTPURLResponse)?.statusCode ?? 0
      sem.signal()
    }.resume()
    XCTAssertEqual(sem.wait(timeout: .now() + 5), .success)
    return status
  }

  private func fetch(url: URL, deadline: Date) throws -> (status: Int, body: String) {
    var lastError: Error?
    while Date() < deadline {
      let sem = DispatchSemaphore(value: 0)
      var result: Result<(status: Int, body: String), Error>?
      var request = URLRequest(url: url)
      HelpAccess.authorize(&request, token: Self.token)
      URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
          result = .failure(error)
        } else {
          let status = (response as? HTTPURLResponse)?.statusCode ?? 0
          result = .success((status, String(data: data ?? Data(), encoding: .utf8) ?? ""))
        }
        sem.signal()
      }.resume()
      _ = sem.wait(timeout: .now() + 0.25)
      if let result {
        switch result {
        case .success(let response):
          return response
        case .failure(let error):
          lastError = error
        }
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    if let lastError { throw lastError }
    return (0, "")
  }
}

private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var method = ""
  private(set) var purge = false
  private(set) var body = Data()

  func store(method: String, purge: Bool, body: Data) {
    lock.lock()
    self.method = method
    self.purge = purge
    self.body = body
    lock.unlock()
  }
}

private final class LockedBytes: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  func append(_ data: Data) {
    lock.lock()
    bytes.append(data)
    lock.unlock()
  }
  var value: Data {
    lock.lock()
    defer { lock.unlock() }
    return bytes
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

/// A raw `/api/events` subscriber accumulating everything the server sends.
private final class EventStreamClient {
  private let connection: NWConnection
  private let lock = NSLock()
  private var received = ""

  init(port: UInt16) {
    connection = NWConnection(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.stateUpdateHandler = { [weak self] state in
      guard let self, case .ready = state else { return }
      let request =
        "GET /api/events HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        + "Authorization: Bearer \(DebugServerTests.token)\r\n\r\n"
      self.connection.send(content: request.data(using: .utf8), completion: .idempotent)
      self.receive()
    }
    connection.start(queue: DispatchQueue(label: "debug.tests.stream"))
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return received
  }

  func count(of marker: String) -> Int {
    text.components(separatedBy: marker).count - 1
  }

  func cancel() { connection.cancel() }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data {
        self.lock.lock()
        self.received += String(decoding: data, as: UTF8.self)
        self.lock.unlock()
      }
      if !isComplete, error == nil { self.receive() }
    }
  }
}

/// An `/api/events` subscriber that sends its request and never reads.
private final class StalledEventStreamClient {
  private let connection: NWConnection

  init(port: UInt16) {
    let connection = NWConnection(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    self.connection = connection
    connection.stateUpdateHandler = { state in
      guard case .ready = state else { return }
      let request =
        "GET /api/events HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        + "Authorization: Bearer \(DebugServerTests.token)\r\n\r\n"
      connection.send(content: request.data(using: .utf8), completion: .idempotent)
    }
    connection.start(queue: DispatchQueue(label: "debug.tests.stalled-stream"))
  }

  func cancel() { connection.cancel() }
}

/// A connection that opens and never sends a byte.
private final class IdleClient {
  private let connection: NWConnection
  private let lock = NSLock()
  private var isClosed = false

  init(port: UInt16) {
    connection = NWConnection(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.stateUpdateHandler = { [weak self] state in
      guard let self, case .ready = state else { return }
      self.receive()
    }
    connection.start(queue: DispatchQueue(label: "debug.tests.idle"))
  }

  var closed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isClosed
  }

  func cancel() { connection.cancel() }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
      [weak self] _, _, isComplete, error in
      guard let self else { return }
      if isComplete || error != nil {
        self.lock.lock()
        self.isClosed = true
        self.lock.unlock()
      } else {
        self.receive()
      }
    }
  }
}
