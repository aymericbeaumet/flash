import AppKit
import FlashCore

open class BrowserScriptProvider: JumpProvider {
    public let identifier: String
    public let priority: Int
    public let bundleID: String
    private let appName: String
    private var compiled: NSAppleScript?

    public init(identifier: String, bundleID: String, appName: String, priority: Int = 20) {
        self.identifier = identifier
        self.bundleID = bundleID
        self.appName = appName
        self.priority = priority
    }

    open func supports(_ context: AppContext) -> Bool {
        context.bundleIdentifier == bundleID
    }

    open func discover(in context: AppContext, deadline: Date) throws -> [JumpTarget] {
        let script = compiled ?? makeScript()
        compiled = script
        var error: NSDictionary?
        let descriptor = script?.executeAndReturnError(&error)
        if error != nil { return [] }
        guard let desc = descriptor else { return [] }
        guard let text = desc.stringValue else { return [] }

        let frame = context.frontWindowFrame
        var out: [JumpTarget] = []
        let lines = text.split(separator: "\n")
        var counter = 0
        for line in lines {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 5,
                  let x = Double(parts[0]), let y = Double(parts[1]),
                  let w = Double(parts[2]), let h = Double(parts[3])
            else { continue }
            let tag = String(parts[4])
            let viewportX = frame.minX + CGFloat(x)
            let viewportY = frame.maxY - CGFloat(y) - CGFloat(h)
            let rect = CGRect(x: viewportX, y: viewportY, width: CGFloat(w), height: CGFloat(h))
            if rect.width < 6 || rect.height < 6 { continue }
            let clipped = rect.intersection(frame)
            if clipped.isNull { continue }
            counter += 1
            let center = CGPoint(x: rect.midX, y: rect.midY)
            out.append(JumpTarget(
                id: "\(identifier)-\(counter)",
                frame: rect,
                role: tag,
                accessibilityLabel: nil,
                activate: { action in
                    Self.synthesizeClick(at: center, action: action)
                    return true
                },
                providerID: identifier
            ))
        }
        return out
    }

    open func javascript() -> String {
        """
        (function(){
          var out=[];
          var sel='a[href], button, input, select, textarea, [role=button], [role=link], [onclick], [tabindex]:not([tabindex="-1"])';
          var els=document.querySelectorAll(sel);
          for (var i=0;i<els.length;i++){
            var r=els[i].getBoundingClientRect();
            if (r.width<6||r.height<6) continue;
            if (r.bottom<0||r.right<0||r.top>window.innerHeight||r.left>window.innerWidth) continue;
            var s=window.getComputedStyle(els[i]);
            if (s.visibility==='hidden'||s.display==='none') continue;
            out.push(Math.round(r.left)+'|'+Math.round(r.top)+'|'+Math.round(r.width)+'|'+Math.round(r.height)+'|'+els[i].tagName.toLowerCase());
          }
          return out.join('\\n');
        })();
        """
    }

    private func makeScript() -> NSAppleScript? {
        let js = javascript()
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"\(appName)\" to tell active tab of front window to execute javascript \"\(escaped)\""
        return NSAppleScript(source: source)
    }

    static func synthesizeClick(at point: CGPoint, action: JumpAction) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let button: CGMouseButton = action == .leftClick ? .left : .right
        let downType: CGEventType = action == .leftClick ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = action == .leftClick ? .leftMouseUp : .rightMouseUp
        let savedCursor = CGEvent(source: source)?.location ?? point
        let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button)
        let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        let restore = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: savedCursor, mouseButton: .left)
        restore?.post(tap: .cghidEventTap)
    }
}
