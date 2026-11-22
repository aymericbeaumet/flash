import AppKit
import XCTest

@testable import flash

/// A paste that borrows the clipboard puts the user's copy back as it was,
/// and marks what it writes transient so no clipboard history records it.
/// Every test uses a private pasteboard, never the user's.
final class PasteboardLoanTests: XCTestCase {
  private var pasteboard: NSPasteboard!

  override func setUp() {
    pasteboard = NSPasteboard(name: NSPasteboard.Name("flash.tests.loan.\(UUID().uuidString)"))
  }

  override func tearDown() {
    pasteboard.releaseGlobally()
  }

  func testTheLentTextIsTheOnlyStringAndIsTransient() {
    pasteboard.clearContents()
    pasteboard.setString("mine", forType: .string)
    XCTAssertTrue(PasteboardSnapshot.lend("register a", to: pasteboard))
    XCTAssertEqual(pasteboard.string(forType: .string), "register a")
    XCTAssertTrue(
      pasteboard.pasteboardItems?.first?.types.contains(PasteboardSnapshot.transientType) == true)
  }

  func testRestoringPutsBackEveryItemAndTypeInOrder() {
    pasteboard.clearContents()
    let rich = NSPasteboardItem()
    rich.setString("<b>hi</b>", forType: .html)
    rich.setString("hi", forType: .string)
    let file = NSPasteboardItem()
    file.setString("file:///tmp/a", forType: .fileURL)
    pasteboard.writeObjects([rich, file])
    let saved = PasteboardSnapshot.capture(pasteboard)

    PasteboardSnapshot.lend("borrowed", to: pasteboard)
    XCTAssertTrue(saved.restore(to: pasteboard))

    let items = pasteboard.pasteboardItems ?? []
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items[0].string(forType: .html), "<b>hi</b>")
    XCTAssertEqual(items[0].string(forType: .string), "hi")
    XCTAssertEqual(items[1].string(forType: .fileURL), "file:///tmp/a")
    XCTAssertEqual(
      Array(items[0].types.prefix(2)), [.html, .string], "the copy's preferred type stays first")
    XCTAssertTrue(
      items[0].types.contains(PasteboardSnapshot.transientType),
      "the copy put back is not recorded a second time")
  }

  func testAnEmptyClipboardIsRestoredEmpty() {
    pasteboard.clearContents()
    let saved = PasteboardSnapshot.capture(pasteboard)
    PasteboardSnapshot.lend("borrowed", to: pasteboard)
    XCTAssertTrue(saved.restore(to: pasteboard))
    XCTAssertNil(pasteboard.string(forType: .string))
  }

  /// The watcher that feeds clipboard history skips the loan.
  func testClipboardHistoryIgnoresTheLoan() {
    XCTAssertTrue(ClipboardMonitor.unrecordedTypes.contains(PasteboardSnapshot.transientType))
  }
}
