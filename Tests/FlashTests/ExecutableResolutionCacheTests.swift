import Foundation
import XCTest

@testable import flash

/// Bare-name executable resolution is remembered for the life of the
/// resident, since one `mise which` spawn can stall for seconds. A remembered
/// path is served only while it is still executable, and a miss resolves
/// exactly as an uncached lookup.
final class ExecutableResolutionCacheTests: XCTestCase {
  private let key = ExecutableResolutionCache.Key(
    name: "tool", directory: URL(fileURLWithPath: "/tmp/flash-root"), searchPath: "/usr/bin:/bin")

  func testAHitIsServedWithoutResolvingAgain() {
    let cache = ExecutableResolutionCache(isExecutable: { _ in true })
    var resolutions = 0
    let resolve = { () -> String? in
      resolutions += 1
      return "/opt/tool"
    }
    XCTAssertEqual(cache.resolve(key, resolve), "/opt/tool")
    XCTAssertEqual(cache.resolve(key, resolve), "/opt/tool")
    XCTAssertEqual(resolutions, 1)
  }

  func testAFailedResolutionIsNeverRemembered() {
    let cache = ExecutableResolutionCache(isExecutable: { _ in true })
    var answers: [String?] = [nil, "/opt/tool"]
    var resolutions = 0
    let resolve = { () -> String? in
      resolutions += 1
      return answers.removeFirst()
    }
    XCTAssertNil(cache.resolve(key, resolve))
    XCTAssertEqual(cache.resolve(key, resolve), "/opt/tool", "a tool installed later is found")
    XCTAssertEqual(cache.resolve(key, resolve), "/opt/tool")
    XCTAssertEqual(resolutions, 2)
  }

  func testARememberedPathThatIsNoLongerExecutableIsResolvedAfresh() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory
      .appendingPathComponent("flash-resolution-\(UUID().uuidString)")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    let paths = ["first", "second", "third"].map { directory.appendingPathComponent($0).path }
    for path in paths {
      XCTAssertTrue(
        fm.createFile(
          atPath: path, contents: Data("#!/bin/sh\n".utf8),
          attributes: [.posixPermissions: 0o755]))
    }
    let cache = ExecutableResolutionCache()
    var answers = paths
    var resolutions = 0
    let resolve = { () -> String? in
      resolutions += 1
      return answers.removeFirst()
    }
    XCTAssertEqual(cache.resolve(key, resolve), paths[0])
    XCTAssertEqual(cache.resolve(key, resolve), paths[0])
    XCTAssertEqual(resolutions, 1)

    // A toolchain upgrade removed the remembered binary.
    try fm.removeItem(atPath: paths[0])
    XCTAssertEqual(cache.resolve(key, resolve), paths[1])
    XCTAssertEqual(cache.resolve(key, resolve), paths[1])
    XCTAssertEqual(resolutions, 2)

    // Still a file, but no longer executable.
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths[1])
    XCTAssertEqual(cache.resolve(key, resolve), paths[2])
    XCTAssertEqual(resolutions, 3)
  }

  func testAKeySeparatesEverythingAResolutionReads() {
    let cache = ExecutableResolutionCache(isExecutable: { _ in true })
    var resolutions = 0
    let resolve = { () -> String? in
      resolutions += 1
      return "/opt/tool\(resolutions)"
    }
    typealias Key = ExecutableResolutionCache.Key
    let keys = [
      Key(name: "tool", directory: nil, searchPath: "/bin"),
      Key(name: "other", directory: nil, searchPath: "/bin"),
      Key(name: "tool", directory: URL(fileURLWithPath: "/tmp/flash-a"), searchPath: "/bin"),
      Key(name: "tool", directory: URL(fileURLWithPath: "/tmp/flash-b"), searchPath: "/bin"),
      Key(name: "tool", directory: nil, searchPath: "/usr/local/bin:/bin"),
    ]
    for key in keys { _ = cache.resolve(key, resolve) }
    XCTAssertEqual(resolutions, keys.count, "mise pins are per directory, the walk per PATH")
    for (index, key) in keys.enumerated() {
      XCTAssertEqual(cache.resolve(key, resolve), "/opt/tool\(index + 1)")
    }
    XCTAssertEqual(resolutions, keys.count)
    XCTAssertEqual(
      Key(name: "tool", directory: URL(fileURLWithPath: "/tmp/flash-a/./"), searchPath: "/bin"),
      keys[2], "one directory however it is spelled")
  }
}
