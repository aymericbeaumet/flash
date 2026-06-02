import AppKit
import QuartzCore
import FlashCore

final class OverlayPanel: NSPanel {
    private let contentLayer = CALayer()
    private var hintLayers: [CAGradientLayer] = []
    private var labelLayers: [CATextLayer] = []
    private var hintLayerPool: [CAGradientLayer] = []
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

    // Fallback border colour when the configured `hint_border` is malformed.
    private static let fallbackBorderCGColor = NSColor.black.withAlphaComponent(0.4).cgColor

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

    /// Allocate `count` chip+label layers and stash them in the pools. Called
    /// once at app launch to keep the first-activation layer allocation cost
    /// off the hot path.
    func warmPool(count: Int) {
        hintLayerPool.reserveCapacity(count)
        labelLayerPool.reserveCapacity(count)
        for _ in 0..<count {
            hintLayerPool.append(makeChipLayer())
            labelLayerPool.append(makeLabelLayer())
        }
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

        let bgTop = nsColor(fromHex: overlayConfig.hintBGTop) ?? .systemYellow
        let bgBottom = nsColor(fromHex: overlayConfig.hintBGBottom) ?? bgTop
        let fg = nsColor(fromHex: overlayConfig.hintFG) ?? .black
        let border = nsColor(fromHex: overlayConfig.hintBorder)
        let fontSize = CGFloat(overlayConfig.fontSize)
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        // Hoisted out of the per-chip loop: every value below is identical
        // for every chip in this activation (HintAssigner guarantees uniform
        // label length, the colors come from config not from the hint, and
        // the font instance never changes mid-render). Previously every one
        // of these was recomputed N times — at N=200 that's 200 NSFont
        // allocations, 200 NSColor allocations, 200 CGColor accesses.
        let gradientColors: [CGColor] = [bgBottom.cgColor, bgTop.cgColor]
        let fgCG = fg.cgColor
        let borderCG = border?.cgColor ?? OverlayPanel.fallbackBorderCGColor
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let labelLen = hints.first?.display.count ?? 1
        let approxWidth = Self.chipWidth(forLabelLength: labelLen, fontSize: fontSize)
        let chipHeight = Self.chipHeight(forFontSize: fontSize)
        let labelFrame = CGRect(x: 0, y: (chipHeight - fontSize - 2) / 2, width: approxWidth, height: fontSize + 2)

        let debugEnabled = debugConfig.showBounds
        if debugEnabled {
            debugShapeLayer.strokeColor = (nsColor(fromHex: debugConfig.boundsFG) ?? NSColor.systemPink).cgColor
            debugShapeLayer.fillColor = (nsColor(fromHex: debugConfig.boundsBG) ?? NSColor.clear).cgColor
        }
        lastTargetLocalRects.removeAll(keepingCapacity: true)
        if debugEnabled {
            lastTargetLocalRects.reserveCapacity(hints.count)
        }

        // Build sublayers off-tree, then batch-attach with a single
        // assignment to `contentLayer.sublayers`. The previous approach
        // (N `addSublayer` calls) was N tree mutations on the host layer,
        // each of which triggers AppKit's needs-display bookkeeping.
        var newSublayers: [CALayer] = []
        newSublayers.reserveCapacity(hints.count + 1)
        if debugEnabled {
            newSublayers.append(debugShapeLayer)
        }

        hintLayers.reserveCapacity(hints.count)
        labelLayers.reserveCapacity(hints.count)

        for hint in hints {
            let targetFrame = hint.target.frame
            let local = CGRect(
                x: targetFrame.minX - frame.minX,
                y: targetFrame.minY - frame.minY,
                width: targetFrame.width,
                height: targetFrame.height
            )
            if debugEnabled {
                lastTargetLocalRects.append(local)
            }

            let chip = dequeueHintLayer()
            // The chip pool retains visual state across activations. If the
            // previous overlay was dismissed mid-filter (e.g. by typing the
            // first character of a hint), most chips were `isHidden = true`.
            // Without this reset, the next activation pulls hidden chips out
            // of the pool and the user sees only the debug outlines.
            chip.isHidden = false
            let label = dequeueLabelLayer()
            label.isHidden = false
            label.string = hint.display
            label.fontSize = fontSize
            label.foregroundColor = fgCG
            label.contentsScale = scale
            label.font = font
            label.frame = labelFrame

            let chipGlobal = Self.chipFrame(
                target: targetFrame,
                width: approxWidth,
                height: chipHeight
            )
            chip.frame = CGRect(
                x: chipGlobal.minX - frame.minX,
                y: chipGlobal.minY - frame.minY,
                width: chipGlobal.width,
                height: chipGlobal.height
            )
            chip.colors = gradientColors
            chip.borderColor = borderCG

            chip.sublayers = [label]
            newSublayers.append(chip)
            hintLayers.append(chip)
            labelLayers.append(label)
        }

        contentLayer.sublayers = newSublayers
        if debugEnabled {
            rebuildDebugPath(visibleIndices: nil)
            debugShapeLayer.isHidden = false
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
        chip.frame = CGRect(x: centerX - approxWidth / 2, y: centerY - chipHeight / 2, width: approxWidth, height: chipHeight)
        let bannerTop = nsColor(fromHex: overlayConfig.hintBGTop) ?? .systemYellow
        let bannerBottom = nsColor(fromHex: overlayConfig.hintBGBottom) ?? bannerTop
        chip.colors = [bannerBottom.cgColor, bannerTop.cgColor]
        chip.cornerRadius = 6
        chip.borderColor = nsColor(fromHex: overlayConfig.hintBorder)?.cgColor ?? OverlayPanel.fallbackBorderCGColor
        let textHeight = lineHeight * CGFloat(lines.count)
        label.frame = CGRect(x: 8, y: (chipHeight - textHeight) / 2, width: approxWidth - 16, height: textHeight)
        chip.sublayers = [label]
        contentLayer.sublayers = [chip]
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
            let matches = hint.display.hasPrefix(upper)
            chip.isHidden = !matches
            if matches { visible.insert(idx) }
        }
        if debugConfig.showBounds {
            rebuildDebugPath(visibleIndices: visible)
        }
        CATransaction.commit()
    }

    private func recycleAll() {
        // Batch detach: one assignment to `sublayers` instead of N
        // removeFromSuperlayer calls. The debugShapeLayer is re-added by
        // display(hints:) if debug is enabled, so detaching it here too is
        // safe — it's not retained anywhere else.
        contentLayer.sublayers = nil
        for chip in hintLayers {
            // Each chip has exactly one sublayer (its label). Wipe so the
            // chip is clean when next dequeued from the pool.
            chip.sublayers = nil
            hintLayerPool.append(chip)
        }
        labelLayerPool.append(contentsOf: labelLayers)
        hintLayers.removeAll(keepingCapacity: true)
        labelLayers.removeAll(keepingCapacity: true)
        debugShapeLayer.path = nil
        debugShapeLayer.isHidden = true
        lastTargetLocalRects.removeAll(keepingCapacity: true)
    }

    private func makeChipLayer() -> CAGradientLayer {
        let l = CAGradientLayer()
        // Static styling that never changes after creation — set once at
        // pool-fill time so the per-chip render loop only touches frame +
        // colors.
        l.cornerRadius = 3
        l.borderWidth = 1
        l.actions = OverlayPanel.noActions
        return l
    }

    private func makeLabelLayer() -> CATextLayer {
        let l = CATextLayer()
        l.alignmentMode = .center
        l.actions = OverlayPanel.noActions
        return l
    }

    private func dequeueHintLayer() -> CAGradientLayer {
        if let last = hintLayerPool.popLast() { return last }
        return makeChipLayer()
    }

    private func dequeueLabelLayer() -> CATextLayer {
        if let last = labelLayerPool.popLast() { return last }
        return makeLabelLayer()
    }

    /// Chip's bounding rect in global NSScreen coordinates, for a target
    /// rect + uniform chip size.
    ///
    /// Centring is gated on height first:
    ///  - If the target's height is under 130 % of the chip height, the
    ///    chip is centred vertically on the target's midpoint.
    ///  - Horizontal centring additionally requires the target's width to
    ///    be under 130 % of the chip width.
    ///  - Otherwise the chip anchors to the target's top-left corner.
    static func chipFrame(target: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        let centerY = target.height < height * 1.3
        let centerX = centerY && target.width < width * 1.3
        let x = centerX ? target.midX - width / 2 : target.minX
        let y = centerY ? target.midY - height / 2 : target.maxY - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Convenience overload. Used by `commit` (`hint.target.frame` is the
    /// only thing it knows) to derive the click point — the renderer
    /// inside `display(hints:)` calls the `(target:width:height:)` form
    /// directly so it can reuse the per-render uniform chip size.
    static func chipFrame(for hint: AssignedHint, fontSize: CGFloat) -> CGRect {
        let width = chipWidth(forLabelLength: hint.display.count, fontSize: fontSize)
        let height = chipHeight(forFontSize: fontSize)
        return chipFrame(target: hint.target.frame, width: width, height: height)
    }

    /// Centralised chip-dimension formulas so the renderer in
    /// `display(hints:)` and the click-point computation in `commit`
    /// never drift out of sync.
    static func chipWidth(forLabelLength labelLen: Int, fontSize: CGFloat) -> CGFloat {
        max(14, CGFloat(labelLen) * fontSize * 0.6 + 6)
    }

    static func chipHeight(forFontSize fontSize: CGFloat) -> CGFloat {
        fontSize + 4
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
