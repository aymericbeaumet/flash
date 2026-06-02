import AppKit
import CoreGraphics
import FlashCore

enum ActionDispatcher {
    static func perform(_ action: JumpAction, on target: JumpTarget) -> Bool {
        if let activate = target.activate {
            if activate(action) { return true }
        }
        return synthesizeClick(at: CGPoint(x: target.frame.midX, y: target.frame.midY), action: action)
    }

    @discardableResult
    static func synthesizeClick(at screenPoint: CGPoint, action: JumpAction) -> Bool {
        // Convert NSScreen (bottom-left origin) to CGEvent (top-left origin of the primary screen).
        let screenH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 1080
        let cgPoint = CGPoint(x: screenPoint.x, y: screenH - screenPoint.y)

        let source = CGEventSource(stateID: .combinedSessionState)
        let savedCursor = CGEvent(source: source)?.location ?? cgPoint
        let button: CGMouseButton = action == .leftClick ? .left : .right
        let downType: CGEventType = action == .leftClick ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = action == .leftClick ? .leftMouseUp : .rightMouseUp

        guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: cgPoint, mouseButton: button),
              let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: cgPoint, mouseButton: button)
        else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        let restore = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: savedCursor, mouseButton: .left)
        restore?.post(tap: .cghidEventTap)
        return true
    }
}
