import Foundation
import XCTest

@testable import flash

final class PluginJSONTests: XCTestCase {
  private func decoded(_ json: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data("[\(json)]".utf8)) as! [Any]
  }

  func testIntegerAcceptsEveryIntegerEncodingAndRejectsTheRest() throws {
    let values = try decoded("1, -7, 0, 9007199254740993, true, 1.5, \"3\", null") as! [Any]
    XCTAssertEqual(PluginJSON.integer(values[0]), 1)
    XCTAssertEqual(PluginJSON.integer(values[1]), -7)
    XCTAssertEqual(PluginJSON.integer(values[2]), 0)
    XCTAssertEqual(PluginJSON.integer(values[3]), 9_007_199_254_740_993)
    XCTAssertNil(PluginJSON.integer(values[4]), "booleans are not integers")
    XCTAssertNil(PluginJSON.integer(values[5]), "a fraction is not an integer")
    XCTAssertNil(PluginJSON.integer(values[6]))
    XCTAssertNil(PluginJSON.integer(values[7]))
    XCTAssertEqual(PluginJSON.integer(NSNumber(value: Int8(-3))), -3)
    XCTAssertEqual(PluginJSON.integer(NSNumber(value: UInt16(65_535))), 65_535)
    XCTAssertEqual(PluginJSON.integer(NSNumber(value: UInt64(Int.max))), Int.max)
    XCTAssertNil(PluginJSON.integer(NSNumber(value: UInt64.max)), "past Int.max is rejected")
    XCTAssertEqual(PluginJSON.integer(NSNumber(value: Int64.min)), Int.min)
    XCTAssertNil(PluginJSON.pid(NSNumber(value: 0)))
    XCTAssertEqual(PluginJSON.pid(NSNumber(value: 42)), 42)
  }
}
