import AppKit
import CoreGraphics
import FlashCore
import Vision

public final class VisionProvider: JumpProvider {
    public let identifier = "vision"
    public let priority = 5
    public let enabledBundles: Set<String>

    private var lastImageHash: Int?
    private var lastResults: [JumpTarget] = []

    public init(enabledBundles: [String]) {
        self.enabledBundles = Set(enabledBundles)
    }

    public func supports(_ context: AppContext) -> Bool {
        guard enabledBundles.contains(context.bundleIdentifier) else { return false }
        // Don't claim to support unless Screen Recording is already granted —
        // otherwise our first AX walk would trigger a TCC prompt mid-jump.
        // Users opt in by granting Screen Recording in System Settings.
        return CGPreflightScreenCaptureAccess()
    }

    public func discover(in context: AppContext, deadline: Date) throws -> [JumpTarget] {
        guard CGPreflightScreenCaptureAccess() else { return [] }
        let frame = context.frontWindowFrame
        guard frame.width > 0, frame.height > 0 else { return [] }

        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var targetWindowID: CGWindowID = 0
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == context.processID,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { continue }
            targetWindowID = windowID
            break
        }
        if targetWindowID == 0 { return [] }

        let imageOpt = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            targetWindowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
        guard let image = imageOpt else { return [] }

        let hash = imageHash(image)
        if hash == lastImageHash { return lastResults }

        var detected: [JumpTarget] = []
        let request = VNRecognizeTextRequest { _, _ in }
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observations = request.results else { return [] }

        let imageW = CGFloat(image.width)
        let imageH = CGFloat(image.height)
        let scaleX = frame.width / imageW
        let scaleY = frame.height / imageH

        var counter = 0
        for obs in observations {
            let box = obs.boundingBox
            let px = box.minX * imageW
            let py = (1 - box.maxY) * imageH
            let pw = box.width * imageW
            let ph = box.height * imageH
            if pw < 6 || ph < 6 { continue }

            let rect = CGRect(
                x: frame.minX + px * scaleX,
                y: frame.minY + py * scaleY,
                width: pw * scaleX,
                height: ph * scaleY
            )
            counter += 1
            let center = CGPoint(x: rect.midX, y: rect.midY)
            detected.append(JumpTarget(
                id: "vis-\(counter)",
                frame: rect,
                role: "AXStaticText",
                accessibilityLabel: obs.topCandidates(1).first?.string,
                activate: { action in
                    Self.synthesizeClick(at: center, action: action)
                    return true
                },
                providerID: "vision"
            ))
        }

        lastImageHash = hash
        lastResults = detected
        return detected
    }

    private func imageHash(_ image: CGImage) -> Int {
        var hasher = Hasher()
        hasher.combine(image.width)
        hasher.combine(image.height)
        hasher.combine(image.bytesPerRow)
        if let data = image.dataProvider?.data {
            let length = CFDataGetLength(data)
            let ptr = CFDataGetBytePtr(data)
            let stride = max(1, length / 64)
            var i = 0
            while i < length {
                hasher.combine(ptr?[i] ?? 0)
                i += stride
            }
        }
        return hasher.finalize()
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
