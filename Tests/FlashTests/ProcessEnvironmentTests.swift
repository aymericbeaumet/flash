import FlashCore
import XCTest

final class ProcessEnvironmentTests: XCTestCase {
  // MARK: export -p parsing

  func testParsesZshUnquotedAndSingleQuoted() {
    let output = """
      export PATH=/opt/homebrew/bin:/usr/bin:/bin
      export EDITOR='nvim'
      export GREETING='hello world'
      """
    let env = FlashProcessEnvironment.parse(exportOutput: output)
    XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/bin:/bin")
    XCTAssertEqual(env["EDITOR"], "nvim")
    XCTAssertEqual(env["GREETING"], "hello world")
  }

  func testParsesBashDeclareXWithEscapes() {
    let output = """
      declare -x PATH="/usr/bin:/bin"
      declare -x QUOTE="say \\"hi\\""
      declare -x LITERAL="a\\\\b"
      declare -x DOLLAR="\\$HOME"
      """
    let env = FlashProcessEnvironment.parse(exportOutput: output)
    XCTAssertEqual(env["PATH"], "/usr/bin:/bin")
    XCTAssertEqual(env["QUOTE"], "say \"hi\"")
    XCTAssertEqual(env["LITERAL"], "a\\b")
    XCTAssertEqual(env["DOLLAR"], "$HOME")
  }

  func testSingleQuotedEmbeddedQuote() {
    // sh renders an embedded single quote as the `'\''` close-escape-reopen.
    let output = "export MSG='it'\\''s fine'"
    let env = FlashProcessEnvironment.parse(exportOutput: output)
    XCTAssertEqual(env["MSG"], "it's fine")
  }

  func testAnsiCQuoting() {
    let output = "export TABBED=$'a\\tb\\nc'"
    let env = FlashProcessEnvironment.parse(exportOutput: output)
    XCTAssertEqual(env["TABBED"], "a\tb\nc")
  }

  func testSkipsExportedButUnsetAndMalformed() {
    let output = """
      export NOVALUE
      export VALID=1
      not an assignment line
      export 9BAD=nope
      """
    let env = FlashProcessEnvironment.parse(exportOutput: output)
    XCTAssertEqual(env["VALID"], "1")
    XCTAssertNil(env["NOVALUE"])
    XCTAssertNil(env["9BAD"])
  }

  func testMultilineValueDoesNotCorruptFollowingVars() {
    // A value with a raw newline spans two lines; the continuation must not be
    // mistaken for a new assignment, and later vars must still parse.
    let output = """
      export MULTI=line-one
      line-two
      export AFTER=ok
      """
    let env = FlashProcessEnvironment.parse(exportOutput: output)
    XCTAssertEqual(env["MULTI"], "line-one")
    XCTAssertEqual(env["AFTER"], "ok")
    XCTAssertNil(env["line-two"])
  }

  func testValueContainingEqualsSign() {
    let output = "export FLAGS=a=b=c"
    let env = FlashProcessEnvironment.parse(exportOutput: output)
    XCTAssertEqual(env["FLAGS"], "a=b=c")
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
    // /bin/sh is always present; a login sh dumps at least PATH.
    let resolved = FlashProcessEnvironment.resolveLoginShellEnvironment(
      shellPath: "/bin/sh", timeout: 5)
    let env = try XCTUnwrap(resolved)
    XCTAssertNotNil(env["PATH"])
  }

  func testResolveMissingShellReturnsNil() {
    let resolved = FlashProcessEnvironment.resolveLoginShellEnvironment(
      shellPath: "/nonexistent/shell", timeout: 2)
    XCTAssertNil(resolved)
  }
}
