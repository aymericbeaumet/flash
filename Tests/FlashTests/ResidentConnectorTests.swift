import XCTest

@testable import flash

/// How the CLI reaches a resident that may not be running: connect, else
/// start the bundle it lives in and wait for the socket, every wait bounded.
final class ResidentConnectorTests: XCTestCase {
  /// Scripted effects: each attempt's answer in turn, and a log of what the
  /// connector did. Waiting advances the fake clock.
  private final class Script {
    var attempts: [ResidentConnector.Attempt<String>]
    var running = false
    var bundle: URL? = URL(fileURLWithPath: "/Applications/Flash.app")
    var launchFailure: String?
    var watchFailure: String?
    var log: [String] = []
    var clock: TimeInterval = 100
    /// How long each wait takes on the fake clock; nil waits out the time
    /// it was given, like a directory that never changes.
    var waitTakes: TimeInterval? = 1

    init(_ attempts: [ResidentConnector.Attempt<String>]) {
      self.attempts = attempts
    }

    var seams: ResidentConnector.Seams<String> {
      ResidentConnector.Seams(
        attempt: { [self] in
          log.append("attempt")
          return attempts.isEmpty ? .absent : attempts.removeFirst()
        },
        residentRunning: { [self] in running },
        bundle: { [self] in bundle },
        launch: { [self] url in
          log.append("launch \(url.lastPathComponent)")
          return launchFailure
        },
        watch: { [self] in
          log.append("watch")
          return watchFailure
        },
        wait: { [self] seconds in
          log.append("wait")
          clock += waitTakes.map { min($0, seconds) } ?? seconds
        },
        now: { [self] in clock })
    }
  }

  func testARunningResidentIsUsedAsIs() {
    let script = Script([.connected("c")])
    guard case .connected("c") = ResidentConnector.connect(launching: true, seams: script.seams)
    else { return XCTFail() }
    XCTAssertEqual(script.log, ["attempt"])
  }

  /// No resident: watch the directory first, then open the bundle, then try
  /// again each time the directory changes until the socket answers.
  func testAMissingResidentIsStartedAndAwaited() {
    let script = Script([.absent, .absent, .absent, .connected("c")])
    guard case .connected("c") = ResidentConnector.connect(launching: true, seams: script.seams)
    else { return XCTFail() }
    XCTAssertEqual(
      script.log,
      ["attempt", "watch", "launch Flash.app", "attempt", "wait", "attempt", "wait", "attempt"])
  }

  func testTheWaitIsBounded() {
    let script = Script([])
    script.waitTakes = nil
    guard
      case .didNotStart(let seconds) = ResidentConnector.connect(
        launching: true, deadline: 15, seams: script.seams)
    else { return XCTFail() }
    XCTAssertEqual(seconds, 15)
    XCTAssertEqual(script.log.filter { $0.hasPrefix("launch") }.count, 1)
    XCTAssertEqual(script.clock, 115)
  }

  /// A resident that runs without a socket is starting, or is a Flash that
  /// does not speak it: wait for it, never start a second one.
  func testARunningResidentWithoutASocketIsAwaitedNotRelaunched() {
    let script = Script([])
    script.running = true
    script.waitTakes = nil
    guard case .notAnswering = ResidentConnector.connect(launching: true, seams: script.seams)
    else { return XCTFail() }
    XCTAssertFalse(script.log.contains { $0.hasPrefix("launch") })

    let starting = Script([.absent, .connected("c")])
    starting.running = true
    guard case .connected = ResidentConnector.connect(launching: true, seams: starting.seams)
    else { return XCTFail() }
  }

  func testWithoutLaunchingOrABundleNothingStarts() {
    let quitting = Script([])
    guard case .notRunning = ResidentConnector.connect(launching: false, seams: quitting.seams)
    else { return XCTFail() }
    XCTAssertEqual(quitting.log, ["attempt"])

    let unbundled = Script([])
    unbundled.bundle = nil
    guard case .notRunning = ResidentConnector.connect(launching: true, seams: unbundled.seams)
    else { return XCTFail() }
    XCTAssertEqual(unbundled.log, ["attempt"])
  }

  func testFailuresAreReportedAtOnce() {
    let refused = Script([.failed("served by another account")])
    guard
      case .failed("served by another account") = ResidentConnector.connect(
        launching: true, seams: refused.seams)
    else { return XCTFail() }

    let launch = Script([])
    launch.launchFailure = "damaged"
    guard
      case .launchFailed("damaged") = ResidentConnector.connect(
        launching: true, seams: launch.seams)
    else { return XCTFail() }
    XCTAssertEqual(launch.log, ["attempt", "watch", "launch Flash.app"])

    let watch = Script([])
    watch.watchFailure = "not ours"
    guard case .failed("not ours") = ResidentConnector.connect(launching: true, seams: watch.seams)
    else { return XCTFail() }
    XCTAssertFalse(watch.log.contains { $0.hasPrefix("launch") })
  }
}
