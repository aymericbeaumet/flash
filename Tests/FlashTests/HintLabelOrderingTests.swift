import CoreGraphics
import FlashCore
import XCTest

@testable import flash

final class HintLabelOrderingTests: XCTestCase {
  private let qwerty = Alphabet.resolve("<qwerty_homerow+qwerty_toprow>")

  // MARK: Center

  func testCenterRanksTheTargetNearestTheRegionCentreFirst() {
    let region = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let frames = [
      CGRect(x: 10, y: 900, width: 20, height: 20),  // top-left corner
      CGRect(x: 490, y: 490, width: 20, height: 20),  // centre
      CGRect(x: 700, y: 500, width: 20, height: 20),  // right of centre
    ]
    XCTAssertEqual(HintLabelOrdering.centerRanks(frames: frames, region: region), [1, 2, 0])
  }

  func testCenterFallsBackToTheTargetsBoundingBoxWithoutARegion() {
    let frames = [
      CGRect(x: 0, y: 0, width: 10, height: 10),
      CGRect(x: 200, y: 200, width: 10, height: 10),
      CGRect(x: 100, y: 100, width: 10, height: 10),
    ]
    XCTAssertEqual(HintLabelOrdering.centerRanks(frames: frames, region: nil), [2, 0, 1])
    XCTAssertEqual(HintLabelOrdering.centerRanks(frames: frames, region: .null), [2, 0, 1])
  }

  func testCenterOrderGivesTheOneKeyLabelsToTheCentralTargets() {
    let region = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let targets = [
      target("corner", CGRect(x: 0, y: 980, width: 20, height: 20)),
      target("centre", CGRect(x: 490, y: 490, width: 20, height: 20)),
    ]
    let hints = HintAssigner.assign(
      targets: targets, alphabet: qwerty.chars, leftHand: qwerty.leftHand,
      keyScores: qwerty.keyScores, keyRows: qwerty.keyRows, keyColumns: qwerty.keyColumns,
      order: .center, region: region)
    XCTAssertEqual(hints.map(\.target.id), ["corner", "centre"], "hints keep reading order")
    XCTAssertEqual(hints[1].label, String(qwerty.chars[0]), "the centre gets the best key")
    XCTAssertEqual(hints[0].label, String(qwerty.chars[1]))
  }

  // MARK: Zones

  func testZoneRowsFollowTheKeyboardForALayoutAlphabet() {
    let rows = HintLabelOrdering.zoneRows(
      alphabet: qwerty.chars, keyRows: qwerty.keyRows, keyColumns: qwerty.keyColumns)
    XCTAssertEqual(rows.map { String($0) }, ["qwertyuiop", "asdfghjkl"])
  }

  func testZoneRowsAreOneWrittenRowForALiteralAlphabet() {
    let literal = Alphabet.resolve("fjdk")
    XCTAssertEqual(
      HintLabelOrdering.zoneRows(
        alphabet: literal.chars, keyRows: literal.keyRows, keyColumns: literal.keyColumns),
      [Array("fjdk")])
  }

  func testZonesNameTheBandAndColumnATargetSitsIn() {
    let region = CGRect(x: 0, y: 0, width: 1000, height: 400)
    let rows = [Array("qwertyuiop"), Array("asdfghjkl;")]
    let frames = [
      CGRect(x: 5, y: 380, width: 10, height: 10),  // top-left
      CGRect(x: 990, y: 380, width: 10, height: 10),  // top-right
      CGRect(x: 5, y: 5, width: 10, height: 10),  // bottom-left
      CGRect(x: 990, y: 5, width: 10, height: 10),  // bottom-right
      CGRect(x: 495, y: 5, width: 10, height: 10),  // bottom middle
      CGRect(x: -500, y: 5000, width: 10, height: 10),  // outside: clamps
    ]
    XCTAssertEqual(
      HintLabelOrdering.zones(frames: frames, rows: rows, region: region),
      ["q", "p", "a", ";", "h", "q"])
  }

  func testZoneLabelsStartWithTheZoneKeyAndStayPrefixFree() {
    let region = CGRect(x: 0, y: 0, width: 1000, height: 400)
    var targets: [JumpTarget] = []
    for index in 0..<40 {
      let x = CGFloat(index % 10) * 100 + 5
      let y = index < 20 ? CGFloat(380) : CGFloat(5)
      targets.append(target("t\(index)", CGRect(x: x, y: y, width: 10, height: 10)))
    }
    let hints = HintAssigner.assign(
      targets: targets, alphabet: qwerty.chars, leftHand: qwerty.leftHand,
      keyScores: qwerty.keyScores, keyRows: qwerty.keyRows, keyColumns: qwerty.keyColumns,
      order: .zones, region: region)
    XCTAssertEqual(hints.count, 40)
    let labels = hints.map(\.label)
    XCTAssertEqual(Set(labels).count, 40)
    for (i, a) in labels.enumerated() {
      for (j, b) in labels.enumerated() where i != j {
        XCTAssertFalse(a.hasPrefix(b), "label \(a) starts with label \(b)")
      }
    }
    // Two targets per zone: one top-left, one one row down in the same zone.
    XCTAssertTrue(hints[0].label.hasPrefix("q"), hints[0].label)
    XCTAssertTrue(hints[9].label.hasPrefix("p"), hints[9].label)
    XCTAssertTrue(hints[20].label.hasPrefix("a"), hints[20].label)
    XCTAssertTrue(hints[29].label.hasPrefix("l"), hints[29].label)
    XCTAssertTrue(labels.allSatisfy { $0.count == 2 }, "\(labels)")
  }

  func testMultiRelabelKeepsAPersistingTargetsLabelUnderEveryOrder() {
    let region = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let corner = target("corner", CGRect(x: 0, y: 980, width: 20, height: 20))
    let centre = target("centre", CGRect(x: 490, y: 490, width: 20, height: 20))
    let extra = target("extra", CGRect(x: 600, y: 600, width: 20, height: 20))
    for order in Config.LabelOrder.allCases {
      let before = HintAssigner.assign(
        targets: [corner, centre], alphabet: qwerty.chars, leftHand: qwerty.leftHand,
        keyScores: qwerty.keyScores, keyRows: qwerty.keyRows, keyColumns: qwerty.keyColumns,
        order: order, region: region)
      let after = HintAssigner.assign(
        targets: [corner, extra, centre], alphabet: qwerty.chars, leftHand: qwerty.leftHand,
        keyScores: qwerty.keyScores, keyRows: qwerty.keyRows, keyColumns: qwerty.keyColumns,
        order: order, region: region, preserving: before)
      let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.target.id, $0.label) })
      XCTAssertEqual(byID["corner"], before[0].label, "\(order)")
      XCTAssertEqual(byID["centre"], before[1].label, "\(order)")
      XCTAssertEqual(Set(after.map(\.label)).count, 3, "\(order)")
    }
  }

  // MARK: Key priority

  func testKeyPriorityPutsTheListedKeysFirstInWrittenOrder() {
    let prioritized = qwerty.prioritizing("fj dk")
    XCTAssertEqual(String(prioritized.chars.prefix(4)), "fjdk")
    XCTAssertEqual(Set(prioritized.chars), Set(qwerty.chars))
    XCTAssertEqual(
      Array(prioritized.chars.dropFirst(4)), qwerty.chars.filter { !"fjdk".contains($0) },
      "the other keys keep their layout order")
    XCTAssertGreaterThan(prioritized.keyScores["k"]!, prioritized.keyScores["f"]! - 4)
    XCTAssertGreaterThan(prioritized.keyScores["k"]!, qwerty.keyScores.values.max()!)
  }

  func testKeyPriorityIgnoresKeysOutsideTheAlphabetAndReportsThem() {
    XCTAssertEqual(qwerty.unknownPriorityKeys("fz1j"), ["z", "1"])
    XCTAssertEqual(qwerty.prioritizing("").chars, qwerty.chars)
    XCTAssertEqual(qwerty.prioritizing("zx").chars, qwerty.chars)
    XCTAssertEqual(Alphabet.priorityKeys("F f J"), ["f", "j"])
  }

  func testKeyPriorityConfigResolvesIntoTheAlphabetAndDiagnosesUnknownKeys() throws {
    let c = ConfigLoader.parse("[hints]\nkey_priority = \"fjdk\"")
    XCTAssertEqual(c.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(String(c.resolvedAlphabet.chars.prefix(4)), "fjdk")
    let hints = try XCTUnwrap(json(c.resolvedConfigJSON)?["hints"] as? [String: Any])
    XCTAssertEqual(hints["key_priority"] as? String, "fjdk")

    let unknown = ConfigLoader.parse("[hints]\nkey_priority = \"fz\"")
    XCTAssertTrue(
      unknown.loadingDiagnostics.contains { $0.message.contains("hints.key_priority: z") },
      "\(unknown.loadingDiagnostics.map(\.message))")
    XCTAssertEqual(String(unknown.resolvedAlphabet.chars.prefix(1)), "f")

    let invalid = ConfigLoader.parse("[hints]\nkey_priority = \"ff\"")
    XCTAssertTrue(
      invalid.loadingDiagnostics.contains { $0.message.contains("hints.key_priority must") },
      "\(invalid.loadingDiagnostics.map(\.message))")
    XCTAssertEqual(invalid.hints.keyPriority, "")
  }

  func testLabelOrderAndAdjustDigitsParseValidateAndResolve() throws {
    XCTAssertEqual(Config().hints.labelOrder, .reading)
    XCTAssertEqual(Config().hints.adjustDigits, .width)
    let c = ConfigLoader.parse("[hints]\nlabel_order = \"zones\"\nadjust_digits = \"grid\"")
    XCTAssertEqual(c.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(c.hints.labelOrder, .zones)
    XCTAssertEqual(c.hints.adjustDigits, .grid)
    let hints = try XCTUnwrap(json(c.resolvedConfigJSON)?["hints"] as? [String: Any])
    XCTAssertEqual(hints["label_order"] as? String, "zones")
    XCTAssertEqual(hints["adjust_digits"] as? String, "grid")

    let invalid = ConfigLoader.parse("[hints]\nlabel_order = \"random\"\nadjust_digits = 3")
    XCTAssertEqual(invalid.hints.labelOrder, .reading)
    XCTAssertEqual(invalid.hints.adjustDigits, .width)
    XCTAssertTrue(
      invalid.loadingDiagnostics.contains { $0.message.contains("hints.label_order must be") })
    XCTAssertTrue(
      invalid.loadingDiagnostics.contains { $0.message.contains("hints.adjust_digits must be") })
  }

  func testPositionAndPointerSettingsParseValidateAndResolve() throws {
    let c = ConfigLoader.parse(
      """
      [hints]
      position_history_size = 4
      position_history_scope = "app"
      pointer_follows_focus = true
      pointer_step = 20
      pointer_acceleration = 0
      pointer_max_step = 40
      """)
    XCTAssertEqual(c.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(c.hints.positionHistorySize, 4)
    XCTAssertEqual(c.hints.positionHistoryScope, .app)
    XCTAssertTrue(c.hints.pointerFollowsFocus)
    XCTAssertEqual(c.hints.pointerStep, 20)
    XCTAssertEqual(c.hints.pointerAcceleration, 0)
    XCTAssertEqual(c.hints.pointerMaxStep, 40)
    let hints = try XCTUnwrap(json(c.resolvedConfigJSON)?["hints"] as? [String: Any])
    XCTAssertEqual(hints["position_history_scope"] as? String, "app")
    XCTAssertEqual(hints["pointer_step"] as? Int, 20)

    let invalid = ConfigLoader.parse(
      "[hints]\nposition_history_size = 0\nposition_history_scope = \"window\"\npointer_step = 0")
    XCTAssertEqual(invalid.hints.positionHistorySize, 16)
    XCTAssertEqual(invalid.hints.positionHistoryScope, .global)
    XCTAssertEqual(invalid.hints.pointerStep, 12)
    XCTAssertEqual(invalid.loadingDiagnostics.count, 3, "\(invalid.loadingDiagnostics)")
  }

  // MARK: Adjust digits

  func testAdjustDigitsInterpolateAcrossTheWidthOrTheKeypadGrid() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 60)
    let centre = CGPoint(x: 50, y: 30)
    XCTAssertEqual(
      HintAdjustmentInterpreter.apply(.interpolate(3), to: centre, in: frame, digits: .width),
      CGPoint(x: 30, y: 30))
    let one = HintAdjustmentInterpreter.apply(
      .interpolate(1), to: centre, in: frame, digits: .grid)
    XCTAssertEqual(one.x, 100 / 6, accuracy: 0.001)
    XCTAssertEqual(one.y, 10, accuracy: 0.001)
    XCTAssertEqual(
      HintAdjustmentInterpreter.apply(.interpolate(5), to: centre, in: frame, digits: .grid),
      CGPoint(x: 50, y: 30))
    let nine = HintAdjustmentInterpreter.apply(
      .interpolate(9), to: centre, in: frame, digits: .grid)
    XCTAssertEqual(nine.x, 100 - 100 / 6, accuracy: 0.001)
    XCTAssertEqual(nine.y, 50, accuracy: 0.001)
  }

  // MARK: Helpers

  private func target(_ id: String, _ frame: CGRect) -> JumpTarget {
    JumpTarget(id: id, frame: frame, role: "AXButton", accessibilityLabel: id, providerID: "test")
  }

  private func json(_ text: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
  }
}
