import XCTest

@testable import flash

final class HintActivationStatsTests: XCTestCase {
  func testNearestRankMatchesTheBenchmarkScript() {
    let values = (1...100).map(Double.init)
    XCTAssertEqual(HintActivationStats.nearestRank(values, percentile: 50), 50)
    XCTAssertEqual(HintActivationStats.nearestRank(values, percentile: 95), 95)
    XCTAssertEqual(HintActivationStats.nearestRank([7], percentile: 95), 7)
    XCTAssertEqual(HintActivationStats.nearestRank([3, 1, 2], percentile: 50), 2)
    XCTAssertNil(HintActivationStats.nearestRank([], percentile: 50))
  }

  func testPercentilesCoverShownActivationsAndEmptiesAreCounted() throws {
    var stats = HintActivationStats()
    for ms in [10.0, 20, 30, 40] {
      stats.record(bundleIdentifier: "org.mozilla.firefox", ms: ms, empty: false)
    }
    // An empty activation's time is how long Flash took to give up, not to
    // show hints: it is counted, never averaged into the latency.
    stats.record(bundleIdentifier: "org.mozilla.firefox", ms: 1_500, empty: true)
    let summary = try XCTUnwrap(stats.summaries.first)
    XCTAssertEqual(summary.bundleIdentifier, "org.mozilla.firefox")
    XCTAssertEqual(summary.count, 5)
    XCTAssertEqual(summary.empty, 1)
    XCTAssertEqual(summary.p50Ms, 20)
    XCTAssertEqual(summary.p95Ms, 40)
  }

  func testAnAppThatNeverShowedHintsHasNoPercentiles() throws {
    var stats = HintActivationStats()
    stats.record(bundleIdentifier: "org.alacritty", ms: 3, empty: true)
    let summary = try XCTUnwrap(stats.summaries.first)
    XCTAssertEqual(summary.count, 1)
    XCTAssertEqual(summary.empty, 1)
    XCTAssertNil(summary.p50Ms)
    XCTAssertNil(summary.p95Ms)
  }

  func testEachAppKeepsOnlyItsRecentActivations() throws {
    var stats = HintActivationStats()
    for _ in 0..<HintActivationStats.samplesPerApp {
      stats.record(bundleIdentifier: "com.tinyspeck.slackmacgap", ms: 1_000, empty: true)
    }
    for _ in 0..<HintActivationStats.samplesPerApp {
      stats.record(bundleIdentifier: "com.tinyspeck.slackmacgap", ms: 50, empty: false)
    }
    let summary = try XCTUnwrap(stats.summaries.first)
    XCTAssertEqual(summary.count, HintActivationStats.samplesPerApp)
    XCTAssertEqual(summary.empty, 0, "the older empties rolled out of the window")
    XCTAssertEqual(summary.p95Ms, 50)

    // Half-way through the next lap the ring holds both kinds.
    for _ in 0..<(HintActivationStats.samplesPerApp / 2) {
      stats.record(bundleIdentifier: "com.tinyspeck.slackmacgap", ms: 1_000, empty: true)
    }
    XCTAssertEqual(stats.summaries.first?.empty, HintActivationStats.samplesPerApp / 2)
    XCTAssertEqual(stats.summaries.first?.count, HintActivationStats.samplesPerApp)
  }

  func testSummariesAreBusiestFirstThenByBundle() {
    var stats = HintActivationStats()
    stats.record(bundleIdentifier: "b.app", ms: 1, empty: false)
    stats.record(bundleIdentifier: "a.app", ms: 1, empty: false)
    stats.record(bundleIdentifier: "c.app", ms: 1, empty: false)
    stats.record(bundleIdentifier: "c.app", ms: 1, empty: false)
    XCTAssertEqual(stats.summaries.map(\.bundleIdentifier), ["c.app", "a.app", "b.app"])
  }

  func testTheLeastRecentlyActivatedAppIsForgottenPastTheCap() {
    var stats = HintActivationStats()
    for index in 0..<HintActivationStats.maxApps {
      stats.record(bundleIdentifier: "app.\(index)", ms: 1, empty: false)
    }
    // app.0 is used again, so app.1 is now the least recent.
    stats.record(bundleIdentifier: "app.0", ms: 1, empty: false)
    stats.record(bundleIdentifier: "app.new", ms: 1, empty: false)
    let bundles = Set(stats.summaries.map(\.bundleIdentifier))
    XCTAssertEqual(bundles.count, HintActivationStats.maxApps)
    XCTAssertTrue(bundles.contains("app.0"))
    XCTAssertTrue(bundles.contains("app.new"))
    XCTAssertFalse(bundles.contains("app.1"))
  }

  func testUnknownAppsAreNotRecorded() {
    var stats = HintActivationStats()
    stats.record(bundleIdentifier: "", ms: 1, empty: false)
    XCTAssertTrue(stats.summaries.isEmpty)
  }
}
