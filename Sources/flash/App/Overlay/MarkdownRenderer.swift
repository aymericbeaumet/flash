import AppKit
import Markdown

/// Converts a CommonMark + GFM markdown source into an `NSAttributedString`
/// suitable for the modal text view. The renderer is intentionally
/// stateless — `render(_:style:)` builds the entire output in one pass —
/// so the modal can re-render on demand (font size change, dark-mode
/// toggle, …) without holding onto intermediate state.
///
/// Why a hand-rolled tree walk instead of swift-markdown's `MarkupVisitor`:
/// `MarkupVisitor` would make us thread Result-type closures through every
/// recursive helper, and we get the same behaviour from a plain
/// `switch markup` here for ~10× less ceremony. The trade-off is that
/// new node types added in future cmark-gfm versions silently fall
/// through to `defaultRenderBlock` / `defaultRenderInline` instead of
/// failing the compile — acceptable: the worst case is the markdown
/// renders as flat paragraph text, never lost.
enum FlashMarkdownRenderer {
  struct Style {
    var bodyFont: NSFont
    var bodyColor: NSColor
    var dimColor: NSColor
    var codeFont: NSFont
    /// Inline `` `code` `` — a small warm accent pill inside prose.
    var codeForeground: NSColor
    var codeBackground: NSColor
    /// Fenced ``` code blocks ``` — neutral, unbackgrounded text. Kept
    /// distinct from inline code so a whole block (e.g. the `:mappings`
    /// table) reads as a calm monospace surface rather than a wall of
    /// accent-colored text. No background: a per-glyph fill stripes
    /// across multi-line blocks, and the modal panel is already the
    /// surface.
    var codeBlockForeground: NSColor
    var linkColor: NSColor
    var blockquoteColor: NSColor
    var ruleColor: NSColor
    /// Multipliers relative to `bodyFont.pointSize` for h1…h6.
    var headingScales: [CGFloat]
    var paragraphSpacing: CGFloat
    var lineSpacing: CGFloat
    var listIndent: CGFloat
    var blockquoteIndent: CGFloat
    var codeBlockPadding: CGFloat

    static let modal = Style(
      bodyFont: NSFont.systemFont(ofSize: 14, weight: .regular),
      bodyColor: OverlayPanel.nordSnowStorm2,
      dimColor: OverlayPanel.nordSnowStorm1,
      codeFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
      codeForeground: OverlayPanel.nordAuroraYellow,
      codeBackground: OverlayPanel.nordPolarNight1.withAlphaComponent(0.55),
      codeBlockForeground: OverlayPanel.nordSnowStorm1,
      linkColor: OverlayPanel.nordFrost2,
      blockquoteColor: OverlayPanel.nordSnowStorm1,
      ruleColor: OverlayPanel.nordSnowStorm1.withAlphaComponent(0.35),
      headingScales: [1.70, 1.40, 1.20, 1.10, 1.05, 1.00],
      paragraphSpacing: 8,
      lineSpacing: 2,
      listIndent: 18,
      blockquoteIndent: 14,
      codeBlockPadding: 6)
  }

  static func render(_ source: String, style: Style = .modal) -> NSAttributedString {
    let document = Document(parsing: source)
    let out = NSMutableAttributedString()
    var ctx = RenderContext(style: style, depth: 0)
    for child in document.children {
      renderBlock(child, into: out, context: &ctx)
    }
    trimTrailingNewlines(out)
    return out
  }

  /// Plain-text fallback (without markdown styling) — used in size
  /// computations so the modal chrome can be sized before the rendered
  /// attributed string lands.
  static func plainText(_ source: String) -> String {
    let document = Document(parsing: source)
    var buffer = ""
    for child in document.children {
      appendPlainText(child, into: &buffer)
    }
    return buffer
  }

  // MARK: Rendering context

  private struct RenderContext {
    let style: Style
    var depth: Int
    var inBlockquote: Bool = false
  }

  // MARK: Block-level rendering

  private static func renderBlock(
    _ markup: Markup,
    into out: NSMutableAttributedString,
    context: inout RenderContext
  ) {
    switch markup {
    case let heading as Heading:
      renderHeading(heading, into: out, context: &context)
    case let paragraph as Paragraph:
      renderParagraph(paragraph, into: out, context: &context)
    case let code as CodeBlock:
      renderCodeBlock(code, into: out, context: &context)
    case let list as UnorderedList:
      renderList(list, ordered: false, startIndex: 1, into: out, context: &context)
    case let list as OrderedList:
      renderList(list, ordered: true, startIndex: Int(list.startIndex), into: out, context: &context)
    case let quote as BlockQuote:
      renderBlockquote(quote, into: out, context: &context)
    case is ThematicBreak:
      renderThematicBreak(into: out, context: &context)
    case let html as HTMLBlock:
      // Render the raw HTML as inline code so the user sees something
      // legible instead of dropped content. We don't try to render
      // HTML — it has its own rendering stack and the modal is plain
      // text only.
      renderRawText(html.rawHTML, into: out, context: &context)
    case let table as Table:
      renderTable(table, into: out, context: &context)
    default:
      defaultRenderBlock(markup, into: out, context: &context)
    }
  }

  private static func defaultRenderBlock(
    _ markup: Markup,
    into out: NSMutableAttributedString,
    context: inout RenderContext
  ) {
    for child in markup.children {
      renderBlock(child, into: out, context: &context)
    }
  }

  private static func renderHeading(
    _ heading: Heading,
    into out: NSMutableAttributedString,
    context: inout RenderContext
  ) {
    let level = max(1, min(6, heading.level))
    let scale = context.style.headingScales[level - 1]
    let pointSize = context.style.bodyFont.pointSize * scale
    let font = NSFont.systemFont(ofSize: pointSize, weight: .bold)
    let para = paragraphStyle(
      lineSpacing: context.style.lineSpacing,
      paragraphSpacing: context.style.paragraphSpacing,
      firstLineHeadIndent: 0,
      headIndent: 0)
    var attrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: context.style.bodyColor,
      .paragraphStyle: para,
    ]
    let line = NSMutableAttributedString()
    renderInlineChildren(of: heading, into: line, style: context.style, attrs: attrs)
    out.append(line)
    out.append(NSAttributedString(string: "\n", attributes: attrs))
    // Trailing blank line for visual breathing room between heading
    // and the next block. Encoded as a small paragraph so paragraph
    // spacing kicks in.
    attrs[.font] = NSFont.systemFont(ofSize: pointSize * 0.4)
    out.append(NSAttributedString(string: "\n", attributes: attrs))
  }

  private static func renderParagraph(
    _ paragraph: Paragraph,
    into out: NSMutableAttributedString,
    context: inout RenderContext
  ) {
    let para = paragraphStyle(
      lineSpacing: context.style.lineSpacing,
      paragraphSpacing: context.style.paragraphSpacing,
      firstLineHeadIndent: 0,
      headIndent: 0)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: context.style.bodyFont,
      .foregroundColor: context.style.bodyColor,
      .paragraphStyle: para,
    ]
    renderInlineChildren(of: paragraph, into: out, style: context.style, attrs: attrs)
    out.append(NSAttributedString(string: "\n\n", attributes: attrs))
  }

  private static func renderCodeBlock(
    _ code: CodeBlock,
    into out: NSMutableAttributedString,
    context: inout RenderContext
  ) {
    // No per-glyph background here on purpose. NSLayoutManager paints
    // `.backgroundColor` per line fragment, so the inter-line leading
    // stays unpainted and a multi-line block reads as ugly zebra
    // stripes. The modal is already a dark panel, so the block just
    // needs a calm, distinct monospace foreground — it sits cleanly on
    // the modal's own gradient.
    let para = paragraphStyle(
      lineSpacing: context.style.lineSpacing,
      paragraphSpacing: context.style.paragraphSpacing,
      firstLineHeadIndent: 0,
      headIndent: 0)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: context.style.codeFont,
      .foregroundColor: context.style.codeBlockForeground,
      .paragraphStyle: para,
    ]
    let text = code.code.trimmingCharacters(in: .newlines)
    out.append(NSAttributedString(string: text, attributes: attrs))
    out.append(NSAttributedString(string: "\n\n", attributes: attrs))
  }

  private static func renderList(
    _ list: Markup,
    ordered: Bool,
    startIndex: Int,
    into out: NSMutableAttributedString,
    context: inout RenderContext
  ) {
    let para = paragraphStyle(
      lineSpacing: context.style.lineSpacing,
      paragraphSpacing: context.style.paragraphSpacing / 2,
      firstLineHeadIndent: CGFloat(context.depth) * context.style.listIndent,
      headIndent:
        CGFloat(context.depth) * context.style.listIndent + context.style.listIndent)
    let baseAttrs: [NSAttributedString.Key: Any] = [
      .font: context.style.bodyFont,
      .foregroundColor: context.style.bodyColor,
      .paragraphStyle: para,
    ]
    let markerAttrs: [NSAttributedString.Key: Any] = [
      .font: context.style.bodyFont,
      .foregroundColor: context.style.dimColor,
      .paragraphStyle: para,
    ]
    var index = startIndex
    for child in list.children where child is ListItem {
      let item = child as! ListItem
      let marker: String
      if ordered {
        marker = "\(index). "
      } else if let checkbox = item.checkbox {
        marker = checkbox == .checked ? "[x] " : "[ ] "
      } else {
        marker = "• "
      }
      out.append(NSAttributedString(string: marker, attributes: markerAttrs))

      var itemContext = context
      itemContext.depth = context.depth + 1
      var first = true
      for itemChild in item.children {
        if first, let paragraph = itemChild as? Paragraph {
          let inline = NSMutableAttributedString()
          renderInlineChildren(of: paragraph, into: inline, style: context.style, attrs: baseAttrs)
          out.append(inline)
          out.append(NSAttributedString(string: "\n", attributes: baseAttrs))
          first = false
        } else {
          renderBlock(itemChild, into: out, context: &itemContext)
          first = false
        }
      }
      index += 1
    }
    out.append(NSAttributedString(string: "\n", attributes: baseAttrs))
  }

  private static func renderBlockquote(
    _ quote: BlockQuote,
    into out: NSMutableAttributedString,
    context: inout RenderContext
  ) {
    let para = paragraphStyle(
      lineSpacing: context.style.lineSpacing,
      paragraphSpacing: context.style.paragraphSpacing,
      firstLineHeadIndent: context.style.blockquoteIndent,
      headIndent: context.style.blockquoteIndent)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: italicized(context.style.bodyFont),
      .foregroundColor: context.style.blockquoteColor,
      .paragraphStyle: para,
    ]
    var childContext = context
    childContext.inBlockquote = true
    for child in quote.children {
      if let paragraph = child as? Paragraph {
        renderInlineChildren(of: paragraph, into: out, style: context.style, attrs: attrs)
        out.append(NSAttributedString(string: "\n\n", attributes: attrs))
      } else {
        renderBlock(child, into: out, context: &childContext)
      }
    }
  }

  private static func renderThematicBreak(
    into out: NSMutableAttributedString,
    context: inout RenderContext
  ) {
    let para = paragraphStyle(
      lineSpacing: context.style.lineSpacing,
      paragraphSpacing: context.style.paragraphSpacing,
      firstLineHeadIndent: 0,
      headIndent: 0)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: context.style.bodyFont,
      .foregroundColor: context.style.ruleColor,
      .paragraphStyle: para,
    ]
    out.append(
      NSAttributedString(
        string: String(repeating: "─", count: 40) + "\n\n",
        attributes: attrs))
  }

  private static func renderTable(
    _ table: Table,
    into out: NSMutableAttributedString,
    context: inout RenderContext
  ) {
    let para = paragraphStyle(
      lineSpacing: context.style.lineSpacing,
      paragraphSpacing: context.style.paragraphSpacing,
      firstLineHeadIndent: 0,
      headIndent: 0)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: context.style.codeFont,
      .foregroundColor: context.style.bodyColor,
      .paragraphStyle: para,
    ]
    // Cheap tab-separated rendering. Real column alignment would need
    // a measurement pass; the modal is monospace by default in the code
    // font, so tabs plus the user's font width are "good enough" for
    // the kinds of tables we render (plugin status, mapping reference).
    var cellsByRow: [[String]] = []
    cellsByRow.append(table.head.cells.map { $0.plainText })
    for row in table.body.rows {
      cellsByRow.append(row.cells.map { $0.plainText })
    }
    let widths = columnWidths(rows: cellsByRow)
    for (index, row) in cellsByRow.enumerated() {
      let line = row.enumerated().map { idx, cell -> String in
        let pad = max(0, widths[idx] - cell.count)
        return cell + String(repeating: " ", count: pad)
      }.joined(separator: "  ")
      out.append(NSAttributedString(string: line + "\n", attributes: attrs))
      if index == 0 {
        let rule = widths.map { String(repeating: "─", count: $0) }.joined(separator: "  ")
        out.append(NSAttributedString(string: rule + "\n", attributes: attrs))
      }
    }
    out.append(NSAttributedString(string: "\n", attributes: attrs))
  }

  private static func columnWidths(rows: [[String]]) -> [Int] {
    let columnCount = rows.map(\.count).max() ?? 0
    var widths = [Int](repeating: 0, count: columnCount)
    for row in rows {
      for (idx, cell) in row.enumerated() {
        widths[idx] = max(widths[idx], cell.count)
      }
    }
    return widths
  }

  private static func renderRawText(
    _ raw: String,
    into out: NSMutableAttributedString,
    context: inout RenderContext
  ) {
    let attrs: [NSAttributedString.Key: Any] = [
      .font: context.style.codeFont,
      .foregroundColor: context.style.dimColor,
    ]
    out.append(NSAttributedString(string: raw + "\n", attributes: attrs))
  }

  // MARK: Inline-level rendering

  private static func renderInlineChildren(
    of markup: Markup,
    into out: NSMutableAttributedString,
    style: Style,
    attrs: [NSAttributedString.Key: Any]
  ) {
    for child in markup.children {
      renderInline(child, into: out, style: style, attrs: attrs)
    }
  }

  private static func renderInline(
    _ markup: Markup,
    into out: NSMutableAttributedString,
    style: Style,
    attrs: [NSAttributedString.Key: Any]
  ) {
    switch markup {
    case let text as Text:
      out.append(NSAttributedString(string: text.string, attributes: attrs))
    case let strong as Strong:
      var newAttrs = attrs
      let base = (attrs[.font] as? NSFont) ?? style.bodyFont
      newAttrs[.font] = bolded(base)
      renderInlineChildren(of: strong, into: out, style: style, attrs: newAttrs)
    case let emphasis as Emphasis:
      var newAttrs = attrs
      let base = (attrs[.font] as? NSFont) ?? style.bodyFont
      newAttrs[.font] = italicized(base)
      renderInlineChildren(of: emphasis, into: out, style: style, attrs: newAttrs)
    case let strike as Strikethrough:
      var newAttrs = attrs
      newAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      renderInlineChildren(of: strike, into: out, style: style, attrs: newAttrs)
    case let inlineCode as InlineCode:
      var newAttrs = attrs
      newAttrs[.font] = style.codeFont
      newAttrs[.foregroundColor] = style.codeForeground
      newAttrs[.backgroundColor] = style.codeBackground
      out.append(NSAttributedString(string: inlineCode.code, attributes: newAttrs))
    case let link as Link:
      var newAttrs = attrs
      newAttrs[.foregroundColor] = style.linkColor
      newAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
      if let destination = link.destination, !destination.isEmpty,
        let url = URL(string: destination)
      {
        newAttrs[.link] = url
      }
      renderInlineChildren(of: link, into: out, style: style, attrs: newAttrs)
    case is SoftBreak:
      out.append(NSAttributedString(string: " ", attributes: attrs))
    case is LineBreak:
      out.append(NSAttributedString(string: "\n", attributes: attrs))
    case let inlineHTML as InlineHTML:
      out.append(NSAttributedString(string: inlineHTML.rawHTML, attributes: attrs))
    case let image as Image:
      // We can't render images in the modal text view; emit the alt
      // text in italics so the page still reads.
      var newAttrs = attrs
      let base = (attrs[.font] as? NSFont) ?? style.bodyFont
      newAttrs[.font] = italicized(base)
      let alt = image.plainText
      out.append(
        NSAttributedString(
          string: alt.isEmpty ? "[image]" : "[\(alt)]",
          attributes: newAttrs))
    default:
      renderInlineChildren(of: markup, into: out, style: style, attrs: attrs)
    }
  }

  // MARK: Font / paragraph helpers

  private static func bolded(_ font: NSFont) -> NSFont {
    NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
  }

  private static func italicized(_ font: NSFont) -> NSFont {
    NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
  }

  private static func paragraphStyle(
    lineSpacing: CGFloat,
    paragraphSpacing: CGFloat,
    firstLineHeadIndent: CGFloat,
    headIndent: CGFloat
  ) -> NSParagraphStyle {
    let p = NSMutableParagraphStyle()
    p.lineSpacing = lineSpacing
    p.paragraphSpacing = paragraphSpacing
    p.firstLineHeadIndent = firstLineHeadIndent
    p.headIndent = headIndent
    return p
  }

  private static func trimTrailingNewlines(_ string: NSMutableAttributedString) {
    while string.length > 0 {
      let last = string.attributedSubstring(from: NSRange(location: string.length - 1, length: 1))
        .string
      if last == "\n" {
        string.deleteCharacters(in: NSRange(location: string.length - 1, length: 1))
      } else {
        break
      }
    }
  }

  // MARK: Plain text fallback

  private static func appendPlainText(_ markup: Markup, into buffer: inout String) {
    switch markup {
    case let text as Text:
      buffer.append(text.string)
    case let code as InlineCode:
      buffer.append(code.code)
    case is SoftBreak:
      buffer.append(" ")
    case is LineBreak:
      buffer.append("\n")
    case let code as CodeBlock:
      buffer.append(code.code)
      buffer.append("\n")
    case is ThematicBreak:
      buffer.append("───\n")
    default:
      for child in markup.children {
        appendPlainText(child, into: &buffer)
      }
      if markup is Paragraph || markup is Heading || markup is BlockQuote
        || markup is ListItem
      {
        buffer.append("\n")
      }
    }
  }
}
