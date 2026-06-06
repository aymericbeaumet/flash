import AppKit
import ApplicationServices
import FlashCore
import Foundation

final class SlackSource: FlashSource {
  let identifier = "slack"
  let displayName = "slack"
  let priority = 0
  let capabilities: FlashSourceCapabilities = [.candidates]
  let activationPolicy: FlashSourceActivationPolicy = .bundleIDs(SlackSource.bundleIdentifiers)

  static let bundleIdentifiers: Set<String> = [
    "com.tinyspeck.slackmacgap",
    "com.tinyspeck.slackmacgap.direct",
  ]

  func supports(_ context: AppContext) -> Bool { false }

  func discover(in context: AppContext) throws -> [JumpTarget] {
    []
  }

  func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate] {
    var out: [Candidate] = []
    var seen = Set<String>()
    for app in environment.runningApplications {
      guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier,
        Self.bundleIdentifiers.contains(bundleID)
      else { continue }
      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      let windows = AXCandidateSourceHelpers.elementArrayAttribute(
        axApp, kAXWindowsAttribute as String)
      for window in windows {
        for element in slackChannelElements(in: window) {
          guard let channel = slackChannelName(for: element) else { continue }
          let key = "\(app.processIdentifier)|\(channel)"
          guard seen.insert(key).inserted else { continue }
          out.append(
            Candidate(
              kind: .slackChannel,
              sourceID: identifier,
              source: displayName,
              pid: app.processIdentifier,
              name: channel,
              subtitle: "Slack channel",
              bundleIdentifier: bundleID,
              url: nil,
              tmuxClientTTY: nil,
              tmuxTarget: nil,
              targetElement: element))
        }
      }
    }
    return out
  }

  func resolveCandidate(
    _ item: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    AXCandidateSourceHelpers.resolveAXItem(item, completion: completion)
  }

  private func slackChannelElements(in root: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var queue = [root]
    var index = 0
    while index < queue.count, index < 3_000 {
      let element = queue[index]
      index += 1
      if slackChannelName(for: element) != nil {
        out.append(element)
      }
      queue.append(
        contentsOf: AXCandidateSourceHelpers.elementArrayAttribute(
          element, kAXChildrenAttribute as String))
      queue.append(
        contentsOf: AXCandidateSourceHelpers.elementArrayAttribute(
          element, "AXChildrenInNavigationOrder"))
    }
    return out
  }

  func slackChannelName(for element: AXUIElement) -> String? {
    let values = [
      AXCandidateSourceHelpers.stringAttribute(element, kAXTitleAttribute as String),
      AXCandidateSourceHelpers.stringAttribute(element, kAXDescriptionAttribute as String),
      AXCandidateSourceHelpers.stringAttribute(element, kAXValueAttribute as String),
      AXCandidateSourceHelpers.stringAttribute(element, "AXHelp"),
      AXCandidateSourceHelpers.stringAttribute(element, "AXIdentifier"),
      AXCandidateSourceHelpers.stringAttribute(element, "AXRoleDescription"),
    ].compactMap { $0 }
    for raw in values {
      if let channel = Self.parseChannelName(raw) {
        return channel
      }
    }
    if values.contains(where: { $0.localizedCaseInsensitiveContains("channel") }) {
      for raw in values {
        if let channel = Self.parseBareChannelName(raw) {
          return channel
        }
      }
    }
    return nil
  }

  static func parseChannelName(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let separators = CharacterSet.whitespacesAndNewlines
      .union(CharacterSet(charactersIn: ",:;()[]{}<>|•·"))
    let tokens = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }
    for (index, token) in tokens.enumerated() {
      if token == "#", index + 1 < tokens.count {
        let cleaned = cleanChannelToken(tokens[index + 1])
        if !cleaned.isEmpty { return "#\(cleaned)" }
      }
      guard token.hasPrefix("#") else { continue }
      let cleaned = cleanChannelToken(String(token.dropFirst()))
      if !cleaned.isEmpty { return "#\(cleaned)" }
    }

    let lower = trimmed.lowercased()
    guard lower.contains("channel") else { return nil }
    for token in tokens {
      let cleaned = cleanChannelToken(token)
      guard !cleaned.isEmpty else { continue }
      let lowered = cleaned.lowercased()
      if ["channel", "channels", "public", "private", "unread", "threads", "mentions"].contains(
        lowered)
      {
        continue
      }
      return "#\(cleaned)"
    }
    return nil
  }

  static func parseBareChannelName(_ raw: String) -> String? {
    let cleaned = cleanChannelToken(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !cleaned.isEmpty else { return nil }
    let lowered = cleaned.lowercased()
    guard !["channel", "channels", "public", "private"].contains(lowered) else { return nil }
    guard cleaned.count <= 80 else { return nil }
    return "#\(cleaned)"
  }

  private static func cleanChannelToken(_ raw: String) -> String {
    let allowed = raw.unicodeScalars.filter { scalar in
      CharacterSet.alphanumerics.contains(scalar)
        || scalar == "-" || scalar == "_" || scalar == "."
    }
    return String(String.UnicodeScalarView(allowed))
  }
}
