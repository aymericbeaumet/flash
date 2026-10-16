import FlashCore
import XCTest

final class ProcessEnvironmentTests: XCTestCase {
  // MARK: env -0 parsing

  private func output(_ fields: [String], noise: String = "") -> Data {
    Data((noise + "\0" + FlashProcessEnvironment.environmentMarker + "\0").utf8)
      + Data(fields.joined(separator: "\0").utf8) + Data([0])
  }

  func testParsesEntriesAfterTheMarkerAndIgnoresLoginNoise() {
    let env = FlashProcessEnvironment.parse(
      environmentOutput: output(
        ["PATH=/opt/homebrew/bin:/usr/bin:/bin", "EDITOR=nvim"],
        noise: "Welcome back\nFAKE=from-a-login-file"))
    XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/bin:/bin")
    XCTAssertEqual(env["EDITOR"], "nvim")
    XCTAssertNil(env["FAKE"])
  }

  func testKeepsValuesVerbatim() {
    let env = FlashProcessEnvironment.parse(
      environmentOutput: output(["MULTI=line-one\nline-two", "FLAGS=a=b=c", "QUOTE='it's'"]))
    XCTAssertEqual(env["MULTI"], "line-one\nline-two")
    XCTAssertEqual(env["FLAGS"], "a=b=c")
    XCTAssertEqual(env["QUOTE"], "'it's'")
  }

  func testSkipsMalformedEntries() {
    let env = FlashProcessEnvironment.parse(
      environmentOutput: output(["NOVALUE", "9BAD=nope", "VALID=1", "=empty"]))
    XCTAssertEqual(env, ["VALID": "1"])
  }

  func testOutputWithoutTheMarkerYieldsNothing() {
    XCTAssertEqual(
      FlashProcessEnvironment.parse(environmentOutput: Data("PATH=/usr/bin\0".utf8)), [:])
  }

  // MARK: fallback PATH

  func testFallbackPathFillsEmptyPath() {
    let env = FlashProcessEnvironment.withFallbackPath([:])
    XCTAssertEqual(env["PATH"], FlashProcessEnvironment.fallbackPath)
  }

  func testFallbackPathKeepsExistingPath() {
    let env = FlashProcessEnvironment.withFallbackPath(["PATH": "/custom"])
    XCTAssertEqual(env["PATH"], "/custom")
  }

  // MARK: cache + overrides

  func testSeededEnvironmentHasUsablePath() {
    let env = FlashProcessEnvironment(seed: [:])
    XCTAssertFalse(env.environment["PATH", default: ""].isEmpty)
  }

  func testOverridesWinOverBaseWithoutMutatingCache() {
    let env = FlashProcessEnvironment(seed: ["PATH": "/base", "KEEP": "1"])
    let withOverrides = env.environment(withOverrides: ["PATH": "/over", "EXTRA": "x"])
    XCTAssertEqual(withOverrides["PATH"], "/over")
    XCTAssertEqual(withOverrides["EXTRA"], "x")
    XCTAssertEqual(withOverrides["KEEP"], "1")
    // The shared cache is untouched by override layering.
    XCTAssertEqual(env.environment["PATH"], "/base")
    XCTAssertNil(env.environment["EXTRA"])
  }

  func testApplyToProcessUsesCacheAndOverrides() {
    let env = FlashProcessEnvironment(seed: ["PATH": "/base"])
    let process = Process()
    env.apply(to: process, overrides: ["FLASH_PLUGIN_ID": "demo"])
    XCTAssertEqual(process.environment?["PATH"], "/base")
    XCTAssertEqual(process.environment?["FLASH_PLUGIN_ID"], "demo")
  }

  // MARK: live resolution (integration)

  func testResolveLoginShellEnvironmentReturnsPath() throws {
    // Keep runner-specific login files out of this shell integration test.
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-login-sh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let resolved = FlashProcessEnvironment.resolveLoginShellEnvironment(
      shellPath: "/bin/sh", timeout: 10,
      environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
    let env = try XCTUnwrap(resolved)
    XCTAssertNotNil(env["PATH"])
  }

  /// zsh's `export -p` prints its tied `PATH` as `export -T PATH path=( … )`,
  /// which a line parser drops; the login `PATH` must still come through.
  func testResolveKeepsAZshLoginPathAndIgnoresLoginOutput() throws {
    let zsh = "/bin/zsh"
    guard FileManager.default.isExecutableFile(atPath: zsh) else { throw XCTSkip("no zsh") }
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-login-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try """
    path=(/flash/login/shims $path)
    export MULTI=$'one\\ntwo'
    echo "a login file that talks"
    """.write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
    let resolved = FlashProcessEnvironment.resolveLoginShellEnvironment(
      shellPath: zsh, timeout: 10,
      environment: ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin"])
    let env = try XCTUnwrap(resolved)
    XCTAssertEqual(env["PATH"]?.split(separator: ":").first, "/flash/login/shims")
    XCTAssertEqual(env["MULTI"], "one\ntwo")
  }

  /// The resolver waits on its own threads: a saturated shared dispatch pool
  /// (a busy launch, a parallel test run) must not starve it into a timeout.
  func testResolveDoesNotWaitOnTheSharedDispatchPool() throws {
    let release = DispatchSemaphore(value: 0)
    let blockers = 256
    for _ in 0..<blockers {
      DispatchQueue.global(qos: .userInitiated).async { release.wait() }
    }
    defer { for _ in 0..<blockers { release.signal() } }
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-login-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let resolved = FlashProcessEnvironment.resolveLoginShellEnvironment(
      shellPath: "/bin/sh", timeout: 3,
      environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
    XCTAssertNotNil(resolved?["PATH"])
  }

  func testResolveMissingShellReturnsNil() {
    let resolved = FlashProcessEnvironment.resolveLoginShellEnvironment(
      shellPath: "/nonexistent/shell", timeout: 2)
    XCTAssertNil(resolved)
  }

  // MARK: refresh ownership

  /// A shell that cannot be run, times out or prints nothing leaves the
  /// environment in effect alone: launchd's bare `PATH` must never replace a
  /// resolved one because one refresh failed.
  func testFailedRefreshKeepsThePreviousEnvironment() {
    let env = FlashProcessEnvironment(seed: ["PATH": "/seed", "MARK": "1"])
    let done = expectation(description: "refresh completes")
    env.refresh(shellPath: "/nonexistent/shell", timeout: 1) { environment in
      XCTAssertEqual(environment["PATH"], "/seed")
      XCTAssertEqual(environment["MARK"], "1")
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    XCTAssertEqual(env.environment["PATH"], "/seed")
    XCTAssertEqual(env.environment["MARK"], "1")
  }

  /// Refreshes run one at a time and store in request order: the second
  /// request's result stands even when the first run finishes after it was
  /// made, and that second request never joins the run already in progress.
  func testOverlappingRefreshesStoreInRequestOrder() {
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var runs = 0
    let env = FlashProcessEnvironment(seed: ["PATH": "/seed"]) { _, _ in
      lock.lock()
      runs += 1
      let run = runs
      lock.unlock()
      if run == 1 {
        firstStarted.signal()
        releaseFirst.wait()
        return ["PATH": "/first"]
      }
      return ["PATH": "/second"]
    }
    let first = expectation(description: "first completes")
    let second = expectation(description: "second completes")
    env.refresh {
      XCTAssertEqual($0["PATH"], "/first")
      first.fulfill()
    }
    XCTAssertEqual(firstStarted.wait(timeout: .now() + 5), .success)
    env.refresh {
      XCTAssertEqual($0["PATH"], "/second")
      second.fulfill()
    }
    releaseFirst.signal()
    wait(for: [first, second], timeout: 5, enforceOrder: true)
    XCTAssertEqual(env.environment["PATH"], "/second")
    XCTAssertEqual(runs, 2)
  }

  /// Nothing waits while no refresh was ever asked (the CLI, unit tests);
  /// once one is, waiters run only after the first resolution has landed,
  /// even a failed one, which keeps the seed.
  func testWhenResolvedWaitsForTheFirstResolutionOnly() {
    let seeded = FlashProcessEnvironment(seed: ["PATH": "/seed"])
    XCTAssertEqual(seeded.phase, .seeded)
    let atOnce = expectation(description: "runs at once while seeded")
    seeded.whenResolved(on: .global()) { atOnce.fulfill() }
    wait(for: [atOnce], timeout: 2)

    let release = DispatchSemaphore(value: 0)
    let env = FlashProcessEnvironment(seed: ["PATH": "/seed"]) { _, _ in
      release.wait()
      return nil
    }
    env.refresh()
    XCTAssertEqual(env.phase, .resolving)
    let resolved = expectation(description: "runs once resolved")
    var ranBeforeRelease = false
    env.whenResolved(on: .global()) {
      ranBeforeRelease = env.phase != .resolved
      resolved.fulfill()
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(env.phase, .resolving, "the waiter is held")
    release.signal()
    wait(for: [resolved], timeout: 5)
    XCTAssertFalse(ranBeforeRelease)
    XCTAssertEqual(env.phase, .resolved, "a failed resolution still resolves")
    XCTAssertEqual(env.environment["PATH"], "/seed", "and keeps the seed")
    let later = expectation(description: "runs at once once resolved")
    env.whenResolved(on: .global()) { later.fulfill() }
    wait(for: [later], timeout: 2)
  }

  /// Requests made during a run share one follow-up run.
  func testRequestsDuringARunShareOneFollowUp() {
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var runs = 0
    let env = FlashProcessEnvironment(seed: [:]) { _, _ in
      lock.lock()
      runs += 1
      let run = runs
      lock.unlock()
      if run == 1 {
        firstStarted.signal()
        releaseFirst.wait()
      }
      return ["RUN": "\(run)"]
    }
    env.refresh()
    XCTAssertEqual(firstStarted.wait(timeout: .now() + 5), .success)
    let later = (0..<3).map { expectation(description: "request \($0)") }
    for expectation in later {
      env.refresh {
        XCTAssertEqual($0["RUN"], "2")
        expectation.fulfill()
      }
    }
    releaseFirst.signal()
    wait(for: later, timeout: 5)
    XCTAssertEqual(runs, 2)
  }
}
