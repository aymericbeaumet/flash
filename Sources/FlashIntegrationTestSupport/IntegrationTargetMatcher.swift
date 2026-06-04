import CoreGraphics
import FlashCore
import Foundation

public struct ExpectedRect: Codable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var cgRect: CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }
}

public struct ExpectedIntegrationTarget: Codable, Sendable {
  public let id: String
  public let label: String
  public let role: String?
  public let rect: ExpectedRect?

  public init(id: String, label: String, role: String? = nil, rect: ExpectedRect? = nil) {
    self.id = id
    self.label = label
    self.role = role
    self.rect = rect
  }
}

public struct IntegrationTargetMatch: Sendable {
  public let expected: ExpectedIntegrationTarget
  public let actual: JumpTarget
}

public struct IntegrationTargetDiff: Sendable {
  public let matches: [IntegrationTargetMatch]
  public let missing: [ExpectedIntegrationTarget]
  public let unexpected: [JumpTarget]

  public var hasFailures: Bool { !missing.isEmpty || !unexpected.isEmpty }
}

public enum IntegrationTargetMatcher {
  public static func classify(
    expected: [ExpectedIntegrationTarget],
    actual: [JumpTarget],
    allowedUnexpectedLabels: Set<String> = [],
    ignoreUnlabeledUnexpected: Bool = false
  ) -> IntegrationTargetDiff {
    var unmatched = Array(actual.enumerated())
    var matches: [IntegrationTargetMatch] = []
    var missing: [ExpectedIntegrationTarget] = []

    for exp in expected {
      guard
        let foundIndex = unmatched.firstIndex(where: { _, target in
          targetMatches(expected: exp, actual: target)
        })
      else {
        missing.append(exp)
        continue
      }
      let (_, target) = unmatched.remove(at: foundIndex)
      matches.append(IntegrationTargetMatch(expected: exp, actual: target))
    }

    let unexpected = unmatched.map(\.element).filter { target in
      guard let label = normalized(target.accessibilityLabel) else { return true }
      return !allowedUnexpectedLabels.contains(label)
    }.filter { target in
      !(ignoreUnlabeledUnexpected && normalized(target.accessibilityLabel) == nil)
    }

    return IntegrationTargetDiff(matches: matches, missing: missing, unexpected: unexpected)
  }

  public static func targetMatches(
    expected: ExpectedIntegrationTarget,
    actual: JumpTarget
  ) -> Bool {
    guard normalized(actual.accessibilityLabel) == normalized(expected.label) else {
      return false
    }
    if let expectedRole = expected.role, actual.role != expectedRole {
      return false
    }
    if let expectedRect = expected.rect?.cgRect {
      let distance = centroidDistance(expectedRect, actual.frame)
      let iou = iouRatio(expectedRect, actual.frame)
      return distance <= 16 || iou >= 0.45
    }
    return true
  }

  public static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return cleaned.isEmpty ? nil : cleaned
  }

  private static func centroidDistance(_ a: CGRect, _ b: CGRect) -> Double {
    let dx = Double(a.midX - b.midX)
    let dy = Double(a.midY - b.midY)
    return (dx * dx + dy * dy).squareRoot()
  }

  private static func iouRatio(_ a: CGRect, _ b: CGRect) -> Double {
    let inter = a.intersection(b)
    if inter.isNull || inter.isEmpty { return 0 }
    let interArea = Double(inter.width * inter.height)
    let union = Double(a.width * a.height + b.width * b.height) - interArea
    return union > 0 ? interArea / union : 0
  }
}
