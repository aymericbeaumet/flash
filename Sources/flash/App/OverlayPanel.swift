import AppKit
import QuartzCore
import FlashCore

final class OverlayPanel: NSPanel {
    private let contentLayer = CALayer()
    private var hintLayers: [CALayer] = []
    private var labelLayers: [CATextLayer] = []
    private var hintLayerPool: [CALayer] = []
    private var labelLayerPool: [CATextLayer] = []

    /// One shape layer holds every debug border, drawn as a single CGPath. This
    /// is one GPU draw call regardless of how many targets are visible —
    /// vs. N CALayers which previously caused a perceptible stutter when debug
    /// mode was on with 300+ hints.
    private let debugShapeLayer = CAShapeLayer()
    private var lastTargetLocalRects: [CGRect] = []

    weak var coordinator: OverlayCoordinator?

    var overlayConfig: Config.Overlay = .init()
    var debugConfig: Config.Debug = .init()

    init() {
        let frame = OverlayPanel.unionScreenFrame()
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.acceptsMouseMovedEvents = false
        self.becomesKeyOnlyIfNeeded = false

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = contentLayer
        contentLayer.frame = view.bounds

        debugShapeLayer.fillColor = NSColor.clear.cgColor
        debugShapeLayer.strokeColor = NSColor.systemPink.cgColor
        debugShapeLayer.lineWidth = 1
        debugShapeLayer.isHidden = true
        debugShapeLayer.actions = OverlayPanel.noActions
        contentLayer.addSublayer(debugShapeLayer)

        self.contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func display(hints: [AssignedHint]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
            orderFrontRegardless()
            makeKey()
        }

        let frame = OverlayPanel.unionScreenFrame()
        if self.frame != frame {
            self.setFrame(frame, display: false)
            self.contentView?.frame = NSRect(origin: .zero, size: frame.size)
            contentLayer.frame = contentView?.bounds ?? .zero
        }

        recycleAll()

        let bg = nsColor(fromHex: overlayConfig.hintBG) ?? .systemYellow
        let fg = nsColor(fromHex: overlayConfig.hintFG) ?? .black
        let fontSize = CGFloat(overlayConfig.fontSize)
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        let debugEnabled = debugConfig.showBounds
        if debugEnabled {
            debugShapeLayer.strokeColor = (nsColor(fromHex: debugConfig.boundsFG) ?? NSColor.systemPink).cgColor
            debugShapeLayer.fillColor = (nsColor(fromHex: debugConfig.boundsBG) ?? NSColor.clear).cgColor
        }
        lastTargetLocalRects.removeAll(keepingCapacity: true)
        if debugEnabled {
            lastTargetLocalRects.reserveCapacity(hints.count)
        }

        for hint in hints {
            let local = CGRect(
                x: hint.target.frame.minX - frame.minX,
                y: hint.target.frame.minY - frame.minY,
                width: hint.target.frame.width,
                height: hint.target.frame.height
            )
            if debugEnabled {
                lastTargetLocalRects.append(local)
            }

            let chip = dequeueHintLayer()
            chip.actions = OverlayPanel.noActions
            // The chip pool retains visual state across activations. If the
            // previous overlay was dismissed mid-filter (e.g. by typing the
            // first character of a hint), most chips were `isHidden = true`.
            // Without this reset, the next activation pulls hidden chips out
            // of the pool and the user sees only the debug outlines.
            chip.isHidden = false
            let label = dequeueLabelLayer()
            label.actions = OverlayPanel.noActions
            label.isHidden = false
            label.string = hint.label.uppercased()
            label.fontSize = fontSize
            label.foregroundColor = fg.cgColor
            label.alignmentMode = .center
            label.contentsScale = scale
            label.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

            // Global-screen chip frame (computed via the shared helper so the
            // dispatcher can click at the same point) → translate to the
            // overlay's local coordinate space by subtracting `frame.minX/Y`.
            let chipGlobal = OverlayPanel.chipFrame(for: hint, fontSize: fontSize)
            let approxWidth = chipGlobal.width
            let chipHeight = chipGlobal.height
            chip.frame = CGRect(
                x: chipGlobal.minX - frame.minX,
                y: chipGlobal.minY - frame.minY,
                width: chipGlobal.width,
                height: chipGlobal.height
            )
            chip.backgroundColor = bg.cgColor
            chip.cornerRadius = 4
            chip.borderWidth = 1
            chip.borderColor = NSColor.black.withAlphaComponent(0.4).cgColor

            label.frame = CGRect(x: 0, y: (chipHeight - fontSize - 2) / 2, width: approxWidth, height: fontSize + 2)
            chip.addSublayer(label)

            contentLayer.addSublayer(chip)
            hintLayers.append(chip)
            labelLayers.append(label)
        }

        if debugEnabled {
            rebuildDebugPath(visibleIndices: nil)
            debugShapeLayer.isHidden = false
            contentLayer.insertSublayer(debugShapeLayer, at: 0)
        } else {
            debugShapeLayer.isHidden = true
            debugShapeLayer.path = nil
        }
    }

    private func rebuildDebugPath(visibleIndices: Set<Int>?) {
        let path = CGMutablePath()
        for (idx, rect) in lastTargetLocalRects.enumerated() {
            if let visibleIndices, !visibleIndices.contains(idx) { continue }
            path.addRect(rect)
        }
        debugShapeLayer.path = path
    }

    static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
        "transform": NSNull(), "contents": NSNull(), "hidden": NSNull(),
        "opacity": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull(),
        "borderWidth": NSNull(), "borderColor": NSNull(),
        "onOrderIn": NSNull(), "onOrderOut": NSNull(), "sublayers": NSNull(),
    ]

    func hide() {
        orderOut(nil)
        recycleAll()
    }

    /// Show a transient banner centered on the focused screen. Multi-line strings (with
    /// `\n`) are rendered as wrapped text. Used to signal edge cases (no targets,
    /// Accessibility denied) — staying within the "transparent hint overlay only" UI rule.
    func displayBanner(_ text: String, durationMs: Int = 700) {
        bannerToken &+= 1
        let myToken = bannerToken

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
            orderFrontRegardless()
        }

        let frame = OverlayPanel.unionScreenFrame()
        if self.frame != frame {
            self.setFrame(frame, display: false)
            self.contentView?.frame = NSRect(origin: .zero, size: frame.size)
            contentLayer.frame = contentView?.bounds ?? .zero
        }
        recycleAll()

        let fontSize = max(CGFloat(overlayConfig.fontSize), 16)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let longestLine = lines.map(\.count).max() ?? text.count

        let label = dequeueLabelLayer()
        label.actions = OverlayPanel.noActions
        label.string = text
        label.fontSize = fontSize
        label.foregroundColor = (nsColor(fromHex: overlayConfig.hintFG) ?? .black).cgColor
        label.alignmentMode = .center
        label.isWrapped = true
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        label.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

        let lineHeight = fontSize + 6
        let approxWidth = CGFloat(longestLine) * fontSize * 0.62 + 40
        let chipHeight = lineHeight * CGFloat(lines.count) + 16
        let centerX: CGFloat
        let centerY: CGFloat
        if let main = NSScreen.main {
            centerX = main.frame.midX - frame.minX
            centerY = main.frame.midY - frame.minY
        } else {
            centerX = (contentView?.bounds.midX ?? 0)
            centerY = (contentView?.bounds.midY ?? 0)
        }

        let chip = dequeueHintLayer()
        chip.actions = OverlayPanel.noActions
        chip.frame = CGRect(x: centerX - approxWidth / 2, y: centerY - chipHeight / 2, width: approxWidth, height: chipHeight)
        chip.backgroundColor = (nsColor(fromHex: overlayConfig.hintBG) ?? .systemYellow).cgColor
        chip.cornerRadius = 6
        chip.borderWidth = 1
        chip.borderColor = NSColor.black.withAlphaComponent(0.4).cgColor
        let textHeight = lineHeight * CGFloat(lines.count)
        label.frame = CGRect(x: 8, y: (chipHeight - textHeight) / 2, width: approxWidth - 16, height: textHeight)
        chip.addSublayer(label)
        contentLayer.addSublayer(chip)
        hintLayers.append(chip)
        labelLayers.append(label)

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(durationMs)) { [weak self] in
            // Only hide if a newer banner hasn't replaced us — otherwise we'd hide it early.
            guard let self, self.bannerToken == myToken else { return }
            self.hide()
        }
    }

    private var bannerToken: UInt64 = 0

    func filter(prefix: String, hints: [AssignedHint]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let upper = prefix.uppercased()
        var visible = Set<Int>()
        for (idx, hint) in hints.enumerated() {
            guard idx < hintLayers.count else { break }
            let chip = hintLayers[idx]
            let matches = hint.label.uppercased().hasPrefix(upper)
            chip.isHidden = !matches
            if matches { visible.insert(idx) }
        }
        if debugConfig.showBounds {
            rebuildDebugPath(visibleIndices: visible)
        }
        CATransaction.commit()
    }

    private func recycleAll() {
        for chip in hintLayers {
            chip.removeFromSuperlayer()
            for sub in chip.sublayers ?? [] { sub.removeFromSuperlayer() }
            hintLayerPool.append(chip)
        }
        labelLayerPool.append(contentsOf: labelLayers)
        hintLayers.removeAll(keepingCapacity: true)
        labelLayers.removeAll(keepingCapacity: true)
        debugShapeLayer.path = nil
        debugShapeLayer.isHidden = true
        lastTargetLocalRects.removeAll(keepingCapacity: true)
    }

    private func dequeueHintLayer() -> CALayer {
        if let last = hintLayerPool.popLast() { return last }
        return CALayer()
    }

    private func dequeueLabelLayer() -> CATextLayer {
        if let last = labelLayerPool.popLast() { return last }
        return CATextLayer()
    }

    /// The chip's bounding rect in global NSScreen coordinates for a given hint
    /// and font size. The renderer in `display(hints:)` and the dispatcher both
    /// call this so the click point we synthesize is identical to where the
    /// chip is drawn — never the AX rect's geometric centre, which can be
    /// hundreds of pixels away for a long row.
    static func chipFrame(for hint: AssignedHint, fontSize: CGFloat) -> CGRect {
        let approxWidth = max(18, CGFloat(hint.label.count) * fontSize * 0.7 + 10)
        let chipHeight = fontSize + 8
        return CGRect(
            x: hint.target.frame.minX,
            y: hint.target.frame.maxY - chipHeight,
            width: approxWidth,
            height: chipHeight
        )
    }

    static func unionScreenFrame() -> NSRect {
        var u: NSRect = .null
        for s in NSScreen.screens { u = u.union(s.frame) }
        if u.isNull, let main = NSScreen.main { return main.frame }
        return u
    }

    private func nsColor(fromHex hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt64(s, radix: 16) else { return nil }
        switch s.count {
        case 6:
            let r = CGFloat((v >> 16) & 0xff) / 255
            let g = CGFloat((v >> 8) & 0xff) / 255
            let b = CGFloat(v & 0xff) / 255
            return NSColor(red: r, green: g, blue: b, alpha: 1)
        case 8:
            let r = CGFloat((v >> 24) & 0xff) / 255
            let g = CGFloat((v >> 16) & 0xff) / 255
            let b = CGFloat((v >> 8) & 0xff) / 255
            let a = CGFloat(v & 0xff) / 255
            return NSColor(red: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }
}

protocol OverlayCoordinator: AnyObject {
    func overlayDidCancel()
    func overlayDidCommit(prefix: String)
    func overlayDidUpdatePrefix(_ prefix: String)
}
