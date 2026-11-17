import FlashOTLP
import Foundation
import XCTest

@testable import flash

/// `[telemetry.receiver]`, `[telemetry.exporter]`, the `#{flash.otel…}`
/// checks at load, a monitor over a received metric, and the page's command.
final class TelemetryConfigTests: XCTestCase {
  private func messages(_ config: Config) -> [String] {
    config.loadingDiagnostics.map(\.message)
  }

  func testBothAreOffByDefault() {
    let config = Config.default
    XCTAssertFalse(config.telemetry.receiver.enabled)
    XCTAssertEqual(config.telemetry.receiver.port, 4318)
    XCTAssertEqual(config.telemetry.exporter.endpoint, "")
    XCTAssertNil(config.telemetry.exportEndpoint)
    XCTAssertEqual(config.telemetry.exporter.signals, [.metrics, .traces], "logs are opt-in")
  }

  func testEveryKeyParses() {
    let config = ConfigLoader.parse(
      """
      [telemetry.receiver]
      enabled = true
      port = 14318
      max_series = 50
      max_points = 10
      max_logs = 0
      max_spans = 20

      [telemetry.exporter]
      endpoint = "https://collector.example/otlp"
      protocol = "http/json"
      compression = "gzip"
      headers = { "x-api-key" = "secret" }
      service_name = "flash-laptop"
      signals = ["metrics", "logs", "traces"]
      interval = 15
      """)
    XCTAssertEqual(messages(config), [])
    let receiver = config.telemetry.receiver
    XCTAssertEqual(
      receiver,
      .init(enabled: true, port: 14318, maxSeries: 50, maxPoints: 10, maxLogs: 0, maxSpans: 20))
    let exporter = config.telemetry.exporter
    XCTAssertEqual(exporter.endpoint, "https://collector.example/otlp")
    XCTAssertEqual(exporter.encoding, .json)
    XCTAssertTrue(exporter.gzip)
    XCTAssertEqual(exporter.headers, ["x-api-key": "secret"])
    XCTAssertEqual(exporter.serviceName, "flash-laptop")
    XCTAssertEqual(exporter.signals, [.metrics, .logs, .traces])
    XCTAssertEqual(exporter.intervalSeconds, 15)
    XCTAssertEqual(
      config.telemetry.exportEndpoint?.absoluteString, "https://collector.example/otlp")
  }

  func testMalformedValuesAreReported() {
    let config = ConfigLoader.parse(
      """
      [telemetry]
      receiver_port = 1

      [telemetry.receiver]
      enabled = "yes"
      port = 70000
      max_series = 0
      max_points = 1
      bogus = 1

      [telemetry.exporter]
      endpoint = "https://user:pass@collector.example/?token=x"
      protocol = "grpc"
      compression = "zstd"
      headers = { "Content-Type" = "text/plain" }
      service_name = ""
      signals = ["metrics", "metrics"]
      interval = 0
      """)
    let reported = messages(config)
    for expected in [
      "unknown config key 'telemetry.receiver_port'",
      "telemetry.receiver.enabled must be true or false",
      "telemetry.receiver.port must be an integer in 1..65535",
      "telemetry.receiver.max_series must be an integer in 1..10000",
      "telemetry.receiver.max_points must be an integer in 2..1000",
      "unknown config key 'telemetry.receiver.bogus'",
      "telemetry.exporter.endpoint must be empty or an http(s) URL",
      "telemetry.exporter.protocol must be \"http/protobuf\" or \"http/json\"",
      "telemetry.exporter.compression must be \"none\" or \"gzip\"",
      "telemetry.exporter.headers must be a table of header names",
      "telemetry.exporter.service_name must be a non-empty string",
      "telemetry.exporter.signals must be an array naming each",
      "telemetry.exporter.interval must be an integer between 1 and 3600",
    ] {
      XCTAssertTrue(reported.contains { $0.hasPrefix(expected) }, "\(expected)\n\(reported)")
    }
    XCTAssertEqual(config.telemetry, Config.Telemetry(), "nothing malformed is applied")
  }

  func testHeaderValuesNeverReachTheInspector() throws {
    let config = ConfigLoader.parse(
      """
      [telemetry.exporter]
      endpoint = "https://collector.example"
      headers = { "authorization" = "Bearer very-secret" }
      """)
    XCTAssertFalse(config.resolvedConfigJSON.contains("very-secret"))
    XCTAssertTrue(config.resolvedConfigJSON.contains("authorization"))
  }

  /// The exporter aimed at Flash's own receiver would feed its telemetry
  /// back into itself: reported, and the exporter stays off.
  func testTheExporterNeverTargetsTheReceiver() {
    for endpoint in [
      "http://127.0.0.1:4318", "http://localhost:4318/", "http://[::1]:4318",
      "http://127.0.0.2:4318",
    ] {
      let config = ConfigLoader.parse(
        """
        [telemetry.receiver]
        enabled = true

        [telemetry.exporter]
        endpoint = "\(endpoint)"
        """)
      XCTAssertNil(config.telemetry.exportEndpoint, endpoint)
      XCTAssertTrue(
        messages(config).contains { $0.contains("Flash's own receiver") }, endpoint)
    }
    let elsewhere = ConfigLoader.parse(
      """
      [telemetry.receiver]
      enabled = true

      [telemetry.exporter]
      endpoint = "http://127.0.0.1:4319"
      """)
    XCTAssertNotNil(elsewhere.telemetry.exportEndpoint)
    XCTAssertEqual(messages(elsewhere), [])
  }

  func testTheReceiverCannotShareTheHelpServersPort() {
    let config = ConfigLoader.parse(
      """
      [telemetry.receiver]
      enabled = true
      port = 4242
      """)
    XCTAssertTrue(messages(config).contains { $0.contains("debug.http_inspector_port") })
  }

  func testStatusFormatsAreCheckedForTheirTelemetryValues() {
    let off = ConfigLoader.parse(
      """
      [statusbar]
      template = "#{flash.otel:claude_code.cost.usage}"
      """)
    XCTAssertTrue(
      messages(off).contains {
        $0.contains(
          "reads flash.otel:claude_code.cost.usage, but [telemetry.receiver] is not enabled")
      }, "\(messages(off))")
    let on = ConfigLoader.parse(
      """
      [telemetry.receiver]
      enabled = true

      [statusbar]
      template = "#{flash.otel.p95:x} #{flash.otel.median:x}"

      [monitors.cost]
      value = "#{flash.otel.total:claude_code.cost.usage}"
      warning = 5
      """)
    XCTAssertEqual(
      messages(on).filter { $0.contains("flash.otel") },
      [
        "statusbar.template has invalid telemetry value flash.otel.median:x; write "
          + "#{flash.otel[.<field>]:<metric>[<attribute>=<value>]…}"
      ])
  }

  // MARK: A monitor over a received metric

  private func deltaCost(_ amount: Double, session: String, time: UInt64) -> OTLPExport {
    var point = Opentelemetry_Proto_Metrics_V1_NumberDataPoint()
    point.asDouble = amount
    point.startTimeUnixNano = time - 60_000_000_000
    point.timeUnixNano = time
    point.attributes = OTLPValues.keyValues(["session.id": session, "model": "claude-sonnet-4-5"])
    var metric = Opentelemetry_Proto_Metrics_V1_Metric()
    metric.name = "claude_code.cost.usage"
    metric.unit = "USD"
    metric.sum.aggregationTemporality = .delta
    metric.sum.isMonotonic = true
    metric.sum.dataPoints = [point]
    return .metrics(TelemetryStoreTests.request([metric]))
  }

  func testAMonitorAndTheBarFollowAReceivedMetric() {
    let queue = DispatchQueue(label: "telemetry.monitor.tests")
    let store = TelemetryStore(scheduler: PollScheduler())
    let controller = FlashStatusBarController(
      template: .init(template: "$#{e|+|f|2:#{flash.otel.total:claude_code.cost.usage},0}"),
      scheduler: PollScheduler(), queue: queue, telemetry: store)
    store.setHandlers(
      changed: nil, observedChanged: { [weak controller] in controller?.telemetryDidChange() })
    controller.updateMonitors([
      "claude_cost": StatusMonitorSpec(
        value: .init(template: "#{flash.otel.total:claude_code.cost.usage}"),
        message: .init(template: "Claude Code spend"), warning: 5, error: 20)
    ])
    controller.start()
    defer { controller.stop() }
    queue.sync {}
    func snapshot() -> MonitorSnapshot? {
      queue.sync { controller.lastPublishedMonitors.first { $0.id == "claude_cost" } }
    }
    func bar() -> String {
      queue.sync {
        (controller.lastPublishedModel?.document.runs.map(\.text).joined() ?? "")
          .trimmingCharacters(in: .whitespaces)
      }
    }
    XCTAssertEqual(snapshot()?.level, .unknown, "nothing received yet")
    _ = store.ingest(deltaCost(1.25, session: "a", time: 1_800_000_060_000_000_000))
    queue.sync {}
    XCTAssertEqual(snapshot()?.value, 1.25)
    XCTAssertEqual(snapshot()?.level, .ok)
    XCTAssertEqual(bar(), "$1.25")
    _ = store.ingest(deltaCost(4, session: "b", time: 1_800_000_060_000_000_000))
    queue.sync {}
    XCTAssertEqual(snapshot()?.value, 5.25, "both sessions add up")
    XCTAssertEqual(snapshot()?.level, .warning)
    XCTAssertEqual(bar(), "$5.25")
  }

  /// docs/telemetry.md's Claude Code example, as written there: it loads
  /// without a diagnostic and reads Claude Code's metrics.
  func testTheClaudeCodeExampleLoadsCleanAndReads() throws {
    let guide = try String(
      contentsOf: TelemetryStoreTests.fixtures.deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/telemetry.md"),
      encoding: .utf8)
    let blocks = guide.components(separatedBy: "```toml\n").dropFirst().map {
      $0.components(separatedBy: "```")[0]
    }
    let example = try XCTUnwrap(blocks.first { $0.contains("[statusbar]") })
    let monitor = try XCTUnwrap(blocks.first { $0.contains("[monitors.claude_spend]") })
    let config = ConfigLoader.parse(
      "[telemetry.receiver]\nenabled = true\n\n" + example + "\n" + monitor)
    XCTAssertEqual(messages(config), [])
    XCTAssertNotNil(config.monitors["claude_spend"])

    let store = TelemetryStore(scheduler: PollScheduler())
    _ = store.ingest(deltaCost(0.4, session: "a", time: 1_800_000_060_000_000_000))
    _ = store.ingest(deltaCost(1.1, session: "a", time: 1_800_000_120_000_000_000))
    var tokens = Opentelemetry_Proto_Metrics_V1_Metric()
    tokens.name = "claude_code.token.usage"
    tokens.sum.aggregationTemporality = .delta
    tokens.sum.isMonotonic = true
    for (type, count) in [("input", 9000.0), ("output", 1200)] {
      var point = Opentelemetry_Proto_Metrics_V1_NumberDataPoint()
      point.asDouble = count
      point.startTimeUnixNano = 1_800_000_060_000_000_000
      point.timeUnixNano = 1_800_000_120_000_000_000
      point.attributes = OTLPValues.keyValues(["session.id": "a", "type": type])
      tokens.sum.dataPoints.append(point)
    }
    _ = store.ingest(.metrics(TelemetryStoreTests.request([tokens])))
    let template = config.statusBar.template
    var context = StatusFormatContext()
    context.values = store.values(for: template.program.dependencies.values)
    context.now = Date(timeIntervalSince1970: 0)
    context.timeZone = TimeZone(identifier: "UTC")!
    let text = StatusFormatDocument.parse(template.program.evaluate(context, expandTime: true))
      .runs.filter { !$0.isStyleBoundary }.map(\.text).joined()
    XCTAssertEqual(
      text.trimmingCharacters(in: .whitespacesAndNewlines), "Claude $1.50 1200 tok/min · 00:00")
  }

  // MARK: The page and its command

  func testTheTelemetryPageAndItsCommand() {
    XCTAssertEqual(DebugServer.Page(path: "/telemetry"), .telemetry)
    XCTAssertEqual(DebugServer.Page.telemetry.path, "/telemetry")
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "telemetry", "show"])?.command, .showTelemetry)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "telemetry", "show"])?.command?.diagnosticDescription,
      "flash telemetry show")
    XCTAssertNil(parseMappingCommand(argv: ["flash", "telemetry", "show", "--name=x"]))
    XCTAssertTrue(URLEventHandler.isTopic("telemetry"))
  }

  func testTheStateCarriesNoHeaderValues() throws {
    let delegate = AppDelegate()
    delegate.config = ConfigLoader.parse(
      """
      [telemetry.exporter]
      endpoint = "https://collector.example"
      headers = { "x-api-key" = "very-secret" }
      """)
    let state = delegate.telemetryStateJSON()
    let data = try JSONSerialization.data(withJSONObject: state)
    let text = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(text.contains("very-secret"), text)
    XCTAssertTrue(text.contains("x-api-key"), text)
    let receiver = try XCTUnwrap(state["receiver"] as? [String: Any])
    XCTAssertEqual(receiver["enabled"] as? Bool, false)
    XCTAssertEqual(receiver["listening"] as? Bool, false)
  }
}
