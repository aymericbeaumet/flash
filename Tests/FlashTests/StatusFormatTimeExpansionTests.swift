import Foundation
import XCTest

@testable import flash

/// Time is applied to a compiled program's text nodes: the format compiles
/// once, and a clock tick runs `strftime` over the text, never the parser.
final class StatusFormatTimeExpansionTests: XCTestCase {
  private var context: StatusFormatContext {
    var context = StatusFormatContext()
    context.now = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13:20 UTC
    context.timeZone = TimeZone(secondsFromGMT: 0)!
    context.values = ["name": "fmt %H"]
    return context
  }

  func testCompileRecordsTheConversionsOnce() {
    let program = StatusFormatProgram.compile(source: "#[bold]%H:%M#[nobold] #{name}")
    XCTAssertTrue(program.hasTimeConversions)
    XCTAssertEqual(program.strftimeResolution, .minute)
    let plain = StatusFormatProgram.compile(source: "#{name} 100%%")
    XCTAssertTrue(plain.hasTimeConversions)
    XCTAssertNil(plain.strftimeResolution, "%% is literal")
    XCTAssertFalse(StatusFormatProgram.compile(source: "#{name}").hasTimeConversions)
  }

  func testTextNodesExpandWithoutRecompilingTheFormat() {
    let program = StatusFormatProgram.compile(
      source: "#[bold]%H:%M#[nobold] #{name} #{?name,%S,} 100%%")
    let evaluation = program.evaluate(context, expandTime: true)
    XCTAssertEqual(evaluation.text, "#[bold]22:13#[nobold] fmt %H 20 100%")
    XCTAssertTrue(evaluation.dependencies.containsTime)
    XCTAssertEqual(evaluation.dependencies.timeResolution, .second)
    let untimed = program.evaluate(context, expandTime: false)
    XCTAssertEqual(untimed.text, "#[bold]%H:%M#[nobold] fmt %H %S 100%%")
    XCTAssertFalse(untimed.dependencies.timeResolution != nil)
  }

  func testJobCommandsTakeTheFormatTimeAndTheirOutputDoesNot() {
    let program = StatusFormatProgram.compile(source: "#(echo %H) #{name}")
    var context = self.context
    context.jobs = ["echo %H": "at %M"]
    let evaluation = program.evaluate(context, expandTime: true)
    XCTAssertEqual(evaluation.jobs.map(\.command), ["echo 22"])
    XCTAssertEqual(evaluation.jobs.map(\.rawCommand), ["echo %H"], "the key is the template")
    XCTAssertEqual(evaluation.text, "at %M fmt %H")
  }
}
