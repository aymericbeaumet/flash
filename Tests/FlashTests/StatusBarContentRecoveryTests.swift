import AppKit
import QuartzCore
import XCTest

@testable import flash

final class StatusBarContentRecoveryTests: XCTestCase {
  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  func testPopulatedEmptyPopulatedRestoresAllPooledGlyphs() throws {
    let surface = NativeStatusBarSurface()
    draw(surface)
    let initialText = try readableText(surface)
    let initialFrames = surface.runFrames
    let initialLayers = surface.runLayers
    XCTAssertTrue(initialText.contains("Firefox"))
    XCTAssertTrue(initialText.contains("CPU 10%"))

    for _ in 0..<3 {
      draw(surface, source: "")
      XCTAssertTrue(try readableText(surface).trimmingCharacters(in: .whitespaces).isEmpty)
      XCTAssertTrue(
        surface.runLayers.dropFirst(surface.visibleRuns.count).allSatisfy {
          $0.container.isHidden && $0.previous == nil
        })

      draw(surface)
      XCTAssertEqual(try readableText(surface), initialText)
      XCTAssertEqual(surface.runFrames, initialFrames)
      XCTAssertTrue(zip(surface.runLayers, initialLayers).allSatisfy { $0 === $1 })
    }
  }

  func testZeroWidthThenRestoredScreenRecoversHiddenPoolWithoutModeChange() throws {
    let surface = NativeStatusBarSurface()
    draw(surface)
    let initialText = try readableText(surface)

    draw(surface, width: OverlayPanel.statusBarEdgePadding * 2)
    XCTAssertEqual(surface.availableColumns, 0)
    XCTAssertTrue(surface.visibleRuns.isEmpty)
    XCTAssertTrue(surface.runLayers.allSatisfy { $0.container.isHidden })

    draw(surface)
    XCTAssertEqual(try readableText(surface), initialText)
  }

  func testScaleAndNotchTransitionsRestoreAllThreeLanes() throws {
    let surface = NativeStatusBarSurface()
    draw(surface)
    let initialText = try readableText(surface)
    let initialFrames = surface.runFrames

    for scale in [CGFloat(1), 2, 1, 2] {
      draw(
        surface, scale: scale,
        notch: CGRect(x: 630, y: 875, width: 180, height: 25))
      let notchedText = try readableText(surface)
      XCTAssertTrue(notchedText.contains("INSERT"))
      XCTAssertTrue(notchedText.contains("CPU 10%"))
      XCTAssertFalse(notchedText.contains("Firefox"))

      draw(surface, width: 1_920, scale: scale)
      XCTAssertTrue(try readableText(surface).contains("Firefox"))
      XCTAssertTrue(
        surface.runLayers.prefix(surface.visibleRuns.count).allSatisfy {
          $0.text.contentsScale == scale && $0.effect.contentsScale == scale
        })
    }

    draw(surface)
    XCTAssertEqual(try readableText(surface), initialText)
    XCTAssertEqual(surface.runFrames, initialFrames)
  }

  func testModeAndAnimatedFeedChangesNeverHideUnrelatedText() throws {
    let surface = NativeStatusBarSurface()
    let modes: [(OverlayModeBadgeStyle, String)] = [
      (.passthrough, "INSERT"), (.normal, "NORMAL"), (.command, "COMMAND"),
      (.terminal, "TERMINAL"), (.passthrough, "INSERT"),
    ]
    for (style, label) in modes {
      for tick in 0..<3 {
        draw(surface, source: source(label: label, tick: tick), style: style)
        let text = try readableText(surface)
        XCTAssertTrue(text.contains(label))
        XCTAssertTrue(text.contains("Firefox"))
        XCTAssertTrue(text.contains("CPU \(10 + tick)%"))
        XCTAssertTrue(text.contains("Story \(tick)"))
        XCTAssertTrue(
          surface.runLayers.prefix(surface.visibleRuns.count).allSatisfy {
            $0.text.opacity == 1 && $0.effect.opacity == 1 && $0.outgoing.opacity == 0
          })
      }
    }
  }

  func testReattachingUnchangedAnimatedSurfacePreservesReadableLayers() throws {
    let root = CALayer()
    root.actions = OverlayPanel.noActions
    let surface = NativeStatusBarSurface()
    root.addSublayer(surface.backgroundLayer)
    draw(surface)
    draw(surface, source: source(tick: 1))
    let initialText = try readableText(surface)
    let initialLayers = surface.runLayers
    XCTAssertTrue(
      surface.runLayers.contains {
        $0.text.animation(forKey: NativeStatusBarSurface.cycleAnimationKey) != nil
      })

    for _ in 0..<3 {
      root.sublayers = nil
      XCTAssertNil(surface.backgroundLayer.superlayer)
      XCTAssertEqual(try readableText(surface), initialText)
      root.sublayers = [surface.backgroundLayer]
      draw(surface, source: source(tick: 1))
      XCTAssertEqual(try readableText(surface), initialText)
      XCTAssertTrue(zip(surface.runLayers, initialLayers).allSatisfy { $0 === $1 })
      for (run, layers) in zip(surface.visibleRuns, surface.runLayers)
      where run.segment.blink || run.segment.breathing {
        XCTAssertNotNil(layers.effect.animation(forKey: "flashEffect"))
      }
    }
  }

  func testTransientRecycleAndCachedReattachmentPreserveNativeGlyphs() throws {
    let panel = OverlayPanel()
    let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    let visible = CGRect(x: 0, y: 0, width: 1_440, height: 875)
    let snapshot = OverlayPanel.makeScreenSnapshot(
      screens: [(scale: 2, frame: screen, visibleFrame: visible, notch: nil)],
      nativeStatusBarFallbackHeight: 25)
    panel.modeBadgeStyle = .passthrough
    panel.modeBadgeText = "INSERT"
    panel.statusBarModel = FlashStatusBarModel(
      appText: "", modeText: "", rightText: "",
      document: StatusFormatDocument.parse(source()))
    // Configure while hidden, then exercise the same cache-hit append used
    // after transient teardown without ordering any test window on screen.
    panel.configureModeBadge(panelFrame: screen, screenSnapshot: snapshot)
    panel.modeBadgeVisible = true
    let stamp = OverlayPanel.ModeBadgeLayoutStamp(
      text: panel.modeBadgeText, style: panel.modeBadgeStyle, visible: true,
      panelFrame: screen, layoutRevision: panel.statusBarLayoutRevision,
      screenRevision: OverlayPanel.screenSnapshotRevision)
    panel.lastModeBadgeLayoutStamp = stamp
    let surface = panel.primaryStatusBarSurface
    let initialText = try readableText(surface)
    let initialLayers = surface.runLayers

    for _ in 0..<3 {
      let chip = panel.makeChipLayer()
      let label = CATextLayer()
      chip.sublayers = [label]
      panel.hintLayers = [chip]
      panel.labelLayers = [label]
      panel.contentLayer.sublayers = [chip, panel.modeBadgeLayer]
      panel.recycleAll()
      XCTAssertNil(panel.modeBadgeLayer.superlayer)
      XCTAssertNil(chip.sublayers)
      XCTAssertEqual(try readableText(surface), initialText)

      var restored: [CALayer] = []
      panel.appendModeBadgeLayerIfNeeded(to: &restored, panelFrame: screen)
      panel.contentLayer.sublayers = restored
      XCTAssertEqual(panel.lastModeBadgeLayoutStamp, stamp)
      XCTAssertTrue(panel.modeBadgeLayer.superlayer === panel.contentLayer)
      XCTAssertEqual(try readableText(surface), initialText)
      XCTAssertTrue(zip(surface.runLayers, initialLayers).allSatisfy { $0 === $1 })
      XCTAssertFalse(panel.isVisible)
    }
    panel.modeBadgeVisible = false
  }

  func testTransientRecyclePreservesNativeEditorBackingLayers() throws {
    let panel = OverlayPanel()
    let view = try XCTUnwrap(panel.contentView)
    panel.commandTextField.wantsLayer = true
    panel.configureCommandTextField(
      promptFrame: CGRect(x: 100, y: 450, width: 600, height: 38),
      font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium), fontSize: 14)
    defer { panel.hideCommandTextField() }
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    CATransaction.flush()

    let editorLayer = try XCTUnwrap(panel.commandTextField.layer)
    let editorParent = try XCTUnwrap(editorLayer.superlayer)
    panel.recycleAll()
    XCTAssertTrue(editorLayer.superlayer === editorParent)
    XCTAssertTrue(editorParent.sublayers?.contains { $0 === editorLayer } == true)
  }

  func testDrawingSurfaceResizesWithThePanelWithoutContainingNativeSubviews() throws {
    let panel = OverlayPanel()
    let container = try XCTUnwrap(panel.contentView)
    let drawingView = try XCTUnwrap(
      container.subviews.first { $0.layer === panel.contentLayer })
    XCTAssertTrue(drawingView.subviews.isEmpty)
    XCTAssertTrue(panel.commandTextField.superview === container)
    XCTAssertFalse(container.layer === panel.contentLayer)
    XCTAssertNil(panel.contentLayer.delegate)

    for frame in [
      CGRect(x: 0, y: 0, width: 1_440, height: 900),
      CGRect(x: -1_920, y: 0, width: 3_360, height: 1_080),
      CGRect(x: 0, y: -900, width: 1_920, height: 1_980),
    ] {
      panel.applyPanelFrame(frame)
      container.layoutSubtreeIfNeeded()
      XCTAssertEqual(drawingView.frame, container.bounds)
      XCTAssertEqual(panel.contentLayer.frame, drawingView.bounds)
      XCTAssertTrue(drawingView.layer === panel.contentLayer)
    }
  }

  func testNativeCommandEditorShowHideAndLayoutPreserveStatusGlyphs() throws {
    let panel = OverlayPanel()
    let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    panel.applyPanelFrame(screen)
    let surface = panel.primaryStatusBarSurface
    draw(surface)
    panel.contentLayer.sublayers = [panel.modeBadgeLayer]
    let initialText = try readableText(surface)
    let initialLayers = surface.runLayers
    let view = try XCTUnwrap(panel.contentView)
    let initialInputMode = panel.inputMode
    defer {
      panel.hideCommandTextField()
      panel.inputMode = initialInputMode
    }

    for iteration in 0..<3 {
      panel.inputMode = .commandLine
      panel.configureCommandTextField(
        promptFrame: CGRect(x: 100, y: 450, width: 600, height: 38),
        font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium), fontSize: 14)
      XCTAssertTrue(panel.makeFirstResponder(panel.commandTextField))
      panel.setCommandTextFieldText(":entry \(iteration)", cursorIndex: 8)
      let editor = try XCTUnwrap(panel.commandTextField.currentEditor() as? NSTextView)
      XCTAssertTrue(editor.isFieldEditor)
      XCTAssertTrue(editor.isDescendant(of: view))
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
      CATransaction.flush()
      XCTAssertEqual(try readableText(surface), initialText)
      XCTAssertTrue(panel.modeBadgeLayer.superlayer === panel.contentLayer)

      panel.contentLayer.sublayers = [panel.modeBadgeLayer, panel.commandPromptLayer]
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
      CATransaction.flush()
      XCTAssertEqual(try readableText(surface), initialText)

      panel.hideCommandTextField()
      panel.inputMode = initialInputMode
      panel.recycleAll()
      panel.contentLayer.sublayers = [panel.modeBadgeLayer]
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
      CATransaction.flush()
      XCTAssertEqual(try readableText(surface), initialText)
      XCTAssertTrue(panel.modeBadgeLayer.superlayer === panel.contentLayer)
      XCTAssertTrue(zip(surface.runLayers, initialLayers).allSatisfy { $0 === $1 })
      XCTAssertFalse(panel.isVisible)
    }
  }

  private func source(label: String = "INSERT", tick: Int = 0) -> String {
    "#[align=left,pill]\(label)#[nopill,default] NEWS "
      + "#[cyc,fg=yellow]Story \(tick)#[nocyc,default] "
      + "#[breathing]SYNC#[nobreathing] "
      + "#[align=absolute-centre]Firefox"
      + "#[align=right]CPU \(10 + tick)% #[blink]ONLINE#[noblink] 12:3\(tick)"
  }

  private func draw(
    _ surface: NativeStatusBarSurface, source: String? = nil, width: CGFloat = 1_440,
    scale: CGFloat = 2, notch: CGRect? = nil, style: OverlayModeBadgeStyle = .passthrough
  ) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let palette: OverlayPanel.ModeBadgePalette
    switch style {
    case .passthrough: palette = OverlayPanel.passthroughPalette
    case .normal: palette = OverlayPanel.normalPalette
    case .command: palette = OverlayPanel.commandPaletteValue
    case .terminal: palette = OverlayPanel.terminalPalette
    }
    surface.render(
      document: StatusFormatDocument.parse(source ?? self.source()),
      barFrame: CGRect(x: 0, y: 875, width: width, height: 25),
      screenFrame: CGRect(x: 0, y: 0, width: width, height: 900),
      scale: scale, notch: notch,
      font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
      labels: .init(), palette: palette, modeStyle: style, minimumCentreWidth: 192)
  }

  private func readableText(
    _ surface: NativeStatusBarSurface, file: StaticString = #filePath, line: UInt = #line
  ) throws -> String {
    XCTAssertFalse(surface.backgroundLayer.isHidden, file: file, line: line)
    XCTAssertEqual(surface.backgroundLayer.opacity, 1, file: file, line: line)
    var text = ""
    for (run, layers) in zip(surface.visibleRuns, surface.runLayers) {
      let glyphLayer = run.segment.blink || run.segment.breathing ? layers.effect : layers.text
      let attributed = try XCTUnwrap(
        glyphLayer.string as? NSAttributedString, file: file, line: line)
      text += attributed.string
      guard !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        continue
      }
      XCTAssertFalse(layers.container.isHidden, file: file, line: line)
      XCTAssertFalse(glyphLayer.isHidden, file: file, line: line)
      XCTAssertEqual(layers.container.opacity, 1, file: file, line: line)
      XCTAssertEqual(glyphLayer.opacity, 1, file: file, line: line)
      XCTAssertTrue(layers.container.superlayer === surface.backgroundLayer, file: file, line: line)
      XCTAssertTrue(glyphLayer.superlayer === layers.container, file: file, line: line)
      XCTAssertTrue(glyphLayer.frame.intersects(layers.container.bounds), file: file, line: line)
      XCTAssertTrue(
        layers.container.frame.intersects(surface.backgroundLayer.bounds), file: file, line: line)
      attributed.enumerateAttribute(
        .foregroundColor, in: NSRange(location: 0, length: attributed.length)
      ) { value, _, _ in
        XCTAssertGreaterThan((value as? NSColor)?.alphaComponent ?? 0, 0, file: file, line: line)
      }
      attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) {
        value, _, _ in
        XCTAssertGreaterThan((value as? NSFont)?.pointSize ?? 0, 0, file: file, line: line)
      }
    }
    return text
  }
}
