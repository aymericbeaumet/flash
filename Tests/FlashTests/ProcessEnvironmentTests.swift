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

  func testResolveMissingShellReturnsNil() {
    let resolved = FlashProcessEnvironment.resolveLoginShellEnvironment(
      shellPath: "/nonexistent/shell", timeout: 2)
    XCTAssertNil(resolved)
  }
}
