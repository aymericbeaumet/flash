import Foundation

/// Recent hint activations per app, the in-memory record behind `flash
/// status` (`hints`) and `flash doctor` (`hint_activations`). Owned by
/// `AppDelegate` on the main thread and fed from the same measurements as
/// `[latency] hints_visible` / `hints_empty`, so it costs one array write per
/// activation. Bounded twice over: each app keeps its last `samplesPerApp`
/// activations, and only the `maxApps` most recently activated apps are
/// kept. Nothing is persisted; the record starts empty with the resident.
struct HintActivationStats: Equatable {
  static let samplesPerApp = 50
  static let maxApps = 32

  struct Summary: Equatable {
    var bundleIdentifier: String
    /// Activations in the window, empty ones included.
    var count: Int
    /// Activations whose app yielded no hints.
    var empty: Int
    /// Nearest-rank percentiles over the activations that showed hints; nil
    /// when none did. An empty activation's time is how long Flash took to
    /// give up, so it never enters the latency.
    var p50Ms: Double?
    var p95Ms: Double?
  }

  private struct Sample: Equatable {
    var ms: Double
    var empty: Bool
  }

  private struct App: Equatable {
    var samples: [Sample] = []
    /// Where the next sample goes once `samples` is full.
    var next = 0
    var lastRecorded: UInt64 = 0
  }

  private var apps: [String: App] = [:]
  private var recorded: UInt64 = 0

  mutating func record(bundleIdentifier: String, ms: Double, empty: Bool) {
    guard !bundleIdentifier.isEmpty else { return }
    if apps[bundleIdentifier] == nil, apps.count >= Self.maxApps,
      let stalest = apps.min(by: { $0.value.lastRecorded < $1.value.lastRecorded })?.key
    {
      apps.removeValue(forKey: stalest)
    }
    recorded &+= 1
    var app = apps[bundleIdentifier] ?? App()
    let sample = Sample(ms: ms, empty: empty)
    if app.samples.count < Self.samplesPerApp {
      app.samples.append(sample)
    } else {
      app.samples[app.next] = sample
      app.next = (app.next + 1) % Self.samplesPerApp
    }
    app.lastRecorded = recorded
    apps[bundleIdentifier] = app
  }

  /// Busiest app first, then by bundle identifier.
  var summaries: [Summary] {
    apps.map { bundleIdentifier, app in
      let shown = app.samples.filter { !$0.empty }.map(\.ms).sorted()
      return Summary(
        bundleIdentifier: bundleIdentifier,
        count: app.samples.count,
        empty: app.samples.count - shown.count,
        p50Ms: Self.nearestRank(shown, percentile: 50),
        p95Ms: Self.nearestRank(shown, percentile: 95))
    }
    .sorted {
      $0.count != $1.count ? $0.count > $1.count : $0.bundleIdentifier < $1.bundleIdentifier
    }
  }

  /// The nearest-rank percentile, as `Scripts/hints-latency-summary.py`
  /// computes it; nil for no values.
  static func nearestRank(_ values: [Double], percentile: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let ordered = values.sorted()
    let rank = max(1, Int((percentile / 100 * Double(ordered.count)).rounded(.up)))
    return ordered[min(rank, ordered.count) - 1]
  }
}
