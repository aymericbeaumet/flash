/// A Flash command's name: `flash <topic> <action>`, both one word of
/// `[a-z][a-z0-9_]*`. The topic is what the command acts on, the action what
/// happens to it. Plugin commands share the shape and the topic namespace.
public struct CommandName: Hashable, Comparable, Sendable, CustomStringConvertible {
  public let topic: String
  public let action: String

  public init(_ topic: String, _ action: String) {
    self.topic = topic
    self.action = action
  }

  /// `"tab next"`; nil unless exactly two well-formed words.
  public init?(_ text: String) {
    let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard words.count == 2, Self.isWord(words[0]), Self.isWord(words[1]) else { return nil }
    self.init(words[0], words[1])
  }

  public var description: String { "\(topic) \(action)" }

  public static func < (lhs: CommandName, rhs: CommandName) -> Bool {
    (lhs.topic, lhs.action) < (rhs.topic, rhs.action)
  }

  /// One lowercase ASCII letter, then lowercase letters, digits and `_`.
  public static func isWord(_ word: String) -> Bool {
    guard let first = word.utf8.first, (97...122).contains(first) else { return false }
    return word.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
  }
}
