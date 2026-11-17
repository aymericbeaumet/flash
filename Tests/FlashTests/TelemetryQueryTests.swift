import XCTest

@testable import flash

/// `#{flash.otel[.<field>]:<metric>[<attribute>=<value>]…}`: the status
/// format's read of a received metric.
final class TelemetryQueryTests: XCTestCase {
  func testTheBareFormReadsTheLatestValue() throws {
    let query = try XCTUnwrap(TelemetryQuery(key: "flash.otel:claude_code.cost.usage"))
    XCTAssertEqual(query.field, .latest)
    XCTAssertEqual(query.metric, "claude_code.cost.usage")
    XCTAssertEqual(query.filters, [])
  }

  func testEveryFieldParses() throws {
    let fields: [String: TelemetryQuery.Field] = [
      "latest": .latest, "rate": .rate, "total": .total, "count": .count, "sum": .sum,
      "min": .min, "max": .max, "mean": .mean, "p50": .percentile(50),
      "p99.9": .percentile(99.9), "p1": .percentile(1),
    ]
    for (text, field) in fields {
      let query = try XCTUnwrap(TelemetryQuery(key: "flash.otel.\(text):m"), text)
      XCTAssertEqual(query.field, field, text)
      XCTAssertEqual(query.field.description, text)
    }
    for bad in ["p0", "p100", "p", "p.5", "p5.", "p1.2.3", "p-1", "avg", "", "Rate", "p１"] {
      XCTAssertNil(TelemetryQuery(key: "flash.otel.\(bad):m"), bad)
    }
  }

  func testFiltersMatchExactlyNegateAndGlob() throws {
    let query = try XCTUnwrap(
      TelemetryQuery(
        key: "flash.otel.rate:claude_code.token.usage[type=input][model=claude-*][speed!=fast]"))
    XCTAssertEqual(query.field, .rate)
    XCTAssertEqual(query.metric, "claude_code.token.usage")
    XCTAssertEqual(
      query.filters,
      [
        .init(key: "type", pattern: "input", negated: false),
        .init(key: "model", pattern: "claude-*", negated: false),
        .init(key: "speed", pattern: "fast", negated: true),
      ])
    XCTAssertTrue(query.matches(["type": "input", "model": "claude-opus-4"]))
    XCTAssertTrue(query.matches(["type": "input", "model": "claude-x", "speed": "normal"]))
    XCTAssertFalse(query.matches(["type": "input", "model": "claude-x", "speed": "fast"]))
    XCTAssertFalse(query.matches(["type": "output", "model": "claude-x"]))
    XCTAssertFalse(query.matches(["type": "input", "model": "gpt"]))
  }

  func testAnEmptyValueMatchesAMissingAttribute() throws {
    let missing = try XCTUnwrap(TelemetryQuery(key: "flash.otel:m[agent.name=]"))
    XCTAssertTrue(missing.matches([:]))
    XCTAssertTrue(missing.matches(["agent.name": ""]))
    XCTAssertFalse(missing.matches(["agent.name": "reviewer"]))
    let present = try XCTUnwrap(TelemetryQuery(key: "flash.otel:m[agent.name!=]"))
    XCTAssertTrue(present.matches(["agent.name": "reviewer"]))
    XCTAssertFalse(present.matches([:]))
  }

  func testGlobsMatchRunsAndNothingElse() {
    let glob = TelemetryQuery.Filter.glob
    XCTAssertTrue(glob("*", ""))
    XCTAssertTrue(glob("a*c", "abbbc"))
    XCTAssertTrue(glob("*opus*", "claude-opus-4-1"))
    XCTAssertFalse(glob("a*c", "abcd"))
    XCTAssertFalse(glob("a?c", "abc"), "? is a literal")
    XCTAssertTrue(glob("a?c", "a?c"))
    XCTAssertTrue(glob("**", "x"))
  }

  func testMalformedFormsAreRejected() {
    for key in [
      "flash.otel", "flash.otel:", "flash.otel.:m", "flash.otel:m[", "flash.otel:m[a]",
      "flash.otel:m[=v]", "flash.otel:m[a=v]x", "flash.otel:m[a=v", "flash.otel:m[a[b=v]",
      "flash.otel:m x", "flash.otel:m]", "flash.otel:mé", "flash.otel.sum:", "flash.otelx:m",
      "flash.otel:m[a b=v]",
    ] {
      XCTAssertNil(TelemetryQuery(key: key), key)
    }
    XCTAssertFalse(TelemetryQuery.isTelemetryKey("flash.otelx:m"))
    XCTAssertTrue(TelemetryQuery.isTelemetryKey("flash.otel.x"))
  }

  func testPrometheusAndSlashNamesAreMetricNames() {
    XCTAssertEqual(
      TelemetryQuery(key: "flash.otel:job:http_requests:rate5m")?.metric, "job:http_requests:rate5m"
    )
    XCTAssertEqual(
      TelemetryQuery(key: "flash.otel:http.server/duration-ms")?.metric, "http.server/duration-ms")
  }

  /// The form is an ordinary value name to the shared language: tmux reads
  /// no modifier from it, and a conditional or comparison carries it whole.
  func testTheLanguageReadsTheFormAsOneValueName() {
    let key = "flash.otel.rate:claude_code.token.usage[type=input]"
    let program = StatusFormatProgram.compile(
      source: "#{\(key)} #{?\(key),busy,idle} #{p-6:\(key)} #{e|*|f|1:#{\(key)},60}")
    XCTAssertEqual(program.diagnostics, [])
    XCTAssertEqual(program.dependencies.values, [key])
    var context = StatusFormatContext()
    context.values[key] = "2.5"
    XCTAssertEqual(program.evaluate(context).text, "2.5 busy    2.5 150.0")
    XCTAssertEqual(program.evaluate(StatusFormatContext()).text, " idle        0.0")
  }

  func testNumbersShowAsTheBarShowsThem() {
    XCTAssertEqual(TelemetryNumber.format(42), "42")
    XCTAssertEqual(TelemetryNumber.format(-3), "-3")
    XCTAssertEqual(TelemetryNumber.format(0), "0")
    XCTAssertEqual(TelemetryNumber.format(-0.0), "0")
    XCTAssertEqual(TelemetryNumber.format(0.25), "0.25")
    XCTAssertEqual(TelemetryNumber.format(1.0 / 3), "0.333333")
    XCTAssertEqual(TelemetryNumber.format(0.0000001), "0")
    XCTAssertEqual(TelemetryNumber.format(1_234_567), "1234567")
    XCTAssertEqual(TelemetryNumber.format(.nan), "")
    XCTAssertEqual(TelemetryNumber.format(.infinity), "")
  }
}
