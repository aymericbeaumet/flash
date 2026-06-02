import AppKit
import FlashCore

public final class SafariProvider: BrowserScriptProvider {
    public init() {
        super.init(identifier: "safari", bundleID: "com.apple.Safari", appName: "Safari", priority: 30)
    }

    public override func discover(in context: AppContext, deadline: Date) throws -> [JumpTarget] {
        let source = """
        tell application "Safari"
          set theJS to "\(escapedJavascript())"
          return do JavaScript theJS in current tab of front window
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return [] }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if error != nil { return [] }
        guard let text = descriptor.stringValue else { return [] }
        return targetsFromText(text, in: context)
    }

    private func escapedJavascript() -> String {
        javascript()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func targetsFromText(_ text: String, in context: AppContext) -> [JumpTarget] {
        let frame = context.frontWindowFrame
        var out: [JumpTarget] = []
        var counter = 0
        for line in text.split(separator: "\n") {
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
            counter += 1
            let center = CGPoint(x: rect.midX, y: rect.midY)
            out.append(JumpTarget(
                id: "safari-\(counter)",
                frame: rect,
                role: tag,
                accessibilityLabel: nil,
                activate: { action in
                    BrowserScriptProvider.synthesizeClick(at: center, action: action)
                    return true
                },
                providerID: "safari"
            ))
        }
        return out
    }
}
