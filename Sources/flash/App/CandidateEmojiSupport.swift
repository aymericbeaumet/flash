import AppKit
import FlashCore

enum CandidateEmojiSupport {
  private static let emojiFontCoverage =
    NSFont(name: "Apple Color Emoji", size: 16)?.coveredCharacterSet

  static func candidateCanRenderInCommandBar(_ candidate: Candidate) -> Bool {
    guard candidate.kind == CandidateFinder.emojiKind else { return true }
    let glyph =
      candidate.sourcePayload?.trimmed
      ?? candidate.title.split(separator: " ", maxSplits: 1).first.map(String.init)
      ?? ""
    guard !glyph.isEmpty, glyphContainsEmojiScalar(glyph), let coverage = emojiFontCoverage
    else { return true }

    for scalar in glyph.unicodeScalars where !isSequenceGlue(scalar) {
      if isKeycapBase(scalar), glyph.unicodeScalars.contains(UnicodeScalar(0x20E3)!) {
        continue
      }
      guard coverage.contains(scalar) else { return false }
    }
    return true
  }

  static func applyEmojiFont(
    to attributed: NSMutableAttributedString,
    line: String,
    fontSize: CGFloat
  ) {
    guard let emojiFont = emojiFont(forCandidateFontSize: fontSize) else {
      return
    }

    var index = line.startIndex
    while index < line.endIndex {
      let next = line.index(after: index)
      let cluster = String(line[index..<next])
      if emojiClusterIsRenderable(cluster) {
        attributed.addAttribute(.font, value: emojiFont, range: NSRange(index..<next, in: line))
      }
      index = next
    }
  }

  static func emojiFont(forCandidateFontSize fontSize: CGFloat) -> NSFont? {
    NSFont(name: "Apple Color Emoji", size: max(8, fontSize - 4))
  }

  static func emojiClusterIsRenderable(_ cluster: String) -> Bool {
    guard glyphContainsEmojiScalar(cluster), let coverage = emojiFontCoverage else {
      return false
    }
    for scalar in cluster.unicodeScalars where !isSequenceGlue(scalar) {
      if isKeycapBase(scalar), cluster.unicodeScalars.contains(UnicodeScalar(0x20E3)!) {
        continue
      }
      guard coverage.contains(scalar) else { return false }
    }
    return true
  }

  private static func glyphContainsEmojiScalar(_ glyph: String) -> Bool {
    glyph.unicodeScalars.contains(where: requiresEmojiFont(_:))
  }

  private static func requiresEmojiFont(_ scalar: UnicodeScalar) -> Bool {
    !isSequenceGlue(scalar) && !isKeycapBase(scalar)
      && (scalar.value >= 0x2600 || scalar.value == 0x00A9 || scalar.value == 0x00AE)
  }

  private static func isSequenceGlue(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0xFE0E || scalar.value == 0xFE0F || scalar.value == 0x200D
      || scalar.value == 0x20E3
      || (0xE0020...0xE007F).contains(scalar.value)
  }

  private static func isKeycapBase(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0x23 || scalar.value == 0x2A || (0x30...0x39).contains(scalar.value)
  }
}
