import CoreGraphics

/// Oracle mouse events represent plain clicks, independent of keys held by
/// the person running a fixture. Keep their click count explicit too.
public enum IntegrationMouseEvents {
  @discardableResult
  public static func prepare(_ event: CGEvent, clickCount: Int = 1) -> CGEvent {
    event.flags = []
    event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
    return event
  }

  public static func menuBarRevealPoint(itemFrame: CGRect, screenFrame: CGRect) -> CGPoint {
    CGPoint(
      x: min(max(itemFrame.midX, screenFrame.minX + 1), screenFrame.maxX - 1),
      y: screenFrame.maxY)
  }

  /// A warp alone does not notify application hover/tracking. Follow it
  /// with this move so an auto-hidden native menu bar can reveal.
  public static func movement(
    to point: CGPoint, from origin: CGPoint, source: CGEventSource?
  ) -> CGEvent? {
    guard
      let event = CGEvent(
        mouseEventSource: source, mouseType: .mouseMoved,
        mouseCursorPosition: point, mouseButton: .left)
    else { return nil }
    prepare(event, clickCount: 0)
    event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - origin.x).rounded()))
    event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - origin.y).rounded()))
    return event
  }
}
