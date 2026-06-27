import AppKit
import XCTest

@testable import flash

final class MarkdownRendererTests: XCTestCase {

  func testRenderEmitsHeadingTextWithBoldSystemFont() {
    let attributed = FlashMarkdownRenderer.render("# Hello world")
    XCTAssertTrue(attributed.string.hasPrefix("Hello world"))
    let attrs = attributed.attributes(at: 0, effectiveRange: nil)
    let font = attrs[.font] as? NSFont
    XCTAssertNotNil(font)
    XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    XCTAssertGreaterThan(font?.pointSize ?? 0, 18)
  }

  func testRenderInlineCodeUsesMonospaceFontAndCodeForeground() {
    let style = FlashMarkdownRenderer.Style.modal
    let attributed = FlashMarkdownRenderer.render("Press `ctrl-c` to copy.")
    let rendered = attributed.string
    guard let codeRange = rendered.range(of: "ctrl-c") else {
      return XCTFail("expected to find the inline code text in the rendered output")
    }
    let nsRange = NSRange(codeRange, in: rendered)
    let attrs = attributed.attributes(at: nsRange.location, effectiveRange: nil)
    let font = attrs[.font] as? NSFont
    XCTAssertEqual(font?.familyName, style.codeFont.familyName)
    XCTAssertEqual(attrs[.foregroundColor] as? NSColor, style.codeForeground)
  }

  func testRenderFencedCodeBlockKeepsMonospacedFontAndIndents() {
    let style = FlashMarkdownRenderer.Style.modal
    let source = """
      Intro paragraph.

      ```text
      one
      two
      ```
      """
    let attributed = FlashMarkdownRenderer.render(source)
    guard let codeRange = attributed.string.range(of: "one\ntwo") else {
      return XCTFail("expected fenced block contents in the rendered output")
    }
    let nsRange = NSRange(codeRange, in: attributed.string)
    let attrs = attributed.attributes(at: nsRange.location, effectiveRange: nil)
    let font = attrs[.font] as? NSFont
    XCTAssertEqual(font?.familyName, style.codeFont.familyName)
    let para = attrs[.paragraphStyle] as? NSParagraphStyle
    XCTAssertEqual(para?.firstLineHeadIndent, style.codeBlockPadding)
  }

  func testRenderStrongAndEmphasisToggleFontTraits() {
    let attributed = FlashMarkdownRenderer.render("This is **bold** and *italic*.")
    func font(forContaining substring: String) -> NSFont? {
      guard let range = attributed.string.range(of: substring) else { return nil }
      let nsRange = NSRange(range, in: attributed.string)
      let attrs = attributed.attributes(at: nsRange.location, effectiveRange: nil)
      return attrs[.font] as? NSFont
    }
    XCTAssertTrue(
      font(forContaining: "bold")?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    XCTAssertTrue(
      font(forContaining: "italic")?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
  }

  func testRenderListPrefixesItemsWithBullet() {
    let source = """
      - first
      - second
      """
    let rendered = FlashMarkdownRenderer.render(source).string
    XCTAssertTrue(rendered.contains("• first"))
    XCTAssertTrue(rendered.contains("• second"))
  }

  func testRenderLinkAttachesURLAttributeAndUnderline() {
    let attributed = FlashMarkdownRenderer.render("See [the docs](https://example.com).")
    guard let range = attributed.string.range(of: "the docs") else {
      return XCTFail("expected to find the link text in the rendered output")
    }
    let nsRange = NSRange(range, in: attributed.string)
    let attrs = attributed.attributes(at: nsRange.location, effectiveRange: nil)
    XCTAssertEqual(attrs[.link] as? URL, URL(string: "https://example.com"))
    XCTAssertEqual(attrs[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
  }

  func testRenderThematicBreakProducesHorizontalRule() {
    let source = """
      Above

      ---

      Below
      """
    let rendered = FlashMarkdownRenderer.render(source).string
    XCTAssertTrue(rendered.contains("─"))
  }

  func testRenderTrimsTrailingNewlines() {
    let source = """
      One


      """
    let rendered = FlashMarkdownRenderer.render(source).string
    XCTAssertFalse(rendered.hasSuffix("\n\n"))
  }

  func testPlainTextStripsMarkdownSyntaxForSizingFallback() {
    let source = """
      # Title

      Body with `code` and **bold**.

      - item
      """
    let plain = FlashMarkdownRenderer.plainText(source)
    XCTAssertTrue(plain.contains("Title"))
    XCTAssertTrue(plain.contains("Body with code and bold."))
    XCTAssertTrue(plain.contains("item"))
    XCTAssertFalse(plain.contains("#"))
    XCTAssertFalse(plain.contains("**"))
  }
}
