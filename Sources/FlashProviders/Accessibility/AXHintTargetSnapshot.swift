import CoreGraphics
import FlashCore

/// Properties captured with the walk distinguish a retained AX object from a
/// reused row/link object whose action now belongs to different content.
struct AXHintTargetSnapshot {
  var role: String
  var subrole: String?
  var title: String?
  var description: String?
  var value: String?
  var url: String?
  var enabled: Bool
  var hidden: Bool
  var frame: CGRect

  func resolvedClickPoint(preferred point: CGPoint, current: Self) -> CGPoint? {
    guard role == current.role, subrole == current.subrole,
      title == current.title, description == current.description,
      value == current.value, url == current.url,
      enabled == current.enabled, !current.hidden
    else { return nil }
    return JumpTarget.relocatedClickPoint(point, from: frame, to: current.frame)
  }
}
