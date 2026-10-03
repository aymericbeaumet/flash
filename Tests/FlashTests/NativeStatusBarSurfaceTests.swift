import AppKit
import XCTest

@testable import flash

final class NativeStatusBarSurfaceTests: XCTestCase {
  private let cycleKey = NativeStatusBarSurface.cycleAnimationKey
  private let crossfadeKey = NativeStatusBarSurface.crossfadeAnimationKey

  func testValueChangingInPlaceCrossfadesWhileMovedRunsSnap() {
    let surface = render("CPU #[fg=yellow]10%#[default] END", columns: 30)
    let value = surface.runLayers[1]
    XCTAssertEqual((value.text.string as? NSAttributedString)?.string, "10%")
    XCTAssertNil(value.text.animation(forKey: crossfadeKey))
    redraw(surface, "CPU #[fg=yellow]11%#[default] END", columns: 30)
    XCTAssertEqual(
      value.text.animation(forKey: crossfadeKey)?.duration,
      NativeStatusBarSurface.crossfadeDuration)
    XCTAssertEqual(
      value.outgoing.animation(forKey: crossfadeKey)?.duration,
      NativeStatusBarSurface.crossfadeDuration)
    XCTAssertLessThanOrEqual(NativeStatusBarSurface.crossfadeDuration, 0.1)
    XCTAssertEqual((value.outgoing.string as? NSAttributedString)?.string, "10%")
    XCTAssertEqual(value.outgoing.opacity, 0)
    XCTAssertNil(surface.runLayers[0].text.animation(forKey: crossfadeKey))
    value.text.removeAllAnimations()
    value.outgoing.removeAllAnimations()
    redraw(surface, "CPUS #[fg=yellow]12%#[default] END", columns: 30)
    XCTAssertEqual((value.text.string as? NSAttributedString)?.string, "12%")
    XCTAssertNil(value.text.animation(forKey: crossfadeKey))
    XCTAssertNil(value.outgoing.animation(forKey: crossfadeKey))
  }

  func testPooledMetricAnimationCannotSurviveIntoModePill() {
    let surface = render("10%", columns: 30)
    redraw(surface, "11%", columns: 30)
    let layers = surface.runLayers[0]
    XCTAssertNotNil(layers.text.animation(forKey: crossfadeKey))
    XCTAssertNotNil(layers.outgoing.animation(forKey: crossfadeKey))

    redraw(surface, "#[pill]NORMAL#[nopill]", columns: 30)

    XCTAssertEqual((layers.text.string as? NSAttributedString)?.string, "NORMAL")
    XCTAssertNil(layers.text.animation(forKey: crossfadeKey))
    XCTAssertNil(layers.outgoing.animation(forKey: crossfadeKey))
    XCTAssertNil(layers.outgoing.string)
  }

  func testLiveModeTextResolvesBeforePillSizingAndPreservesLiteralText() {
    var mode = FlashStatusTextSegment(text: "N", foreground: .red)
    mode.isModeLabel = true
    mode.pill = true
    var literal = mode
    literal.isModeLabel = false
    let document = StatusFormatDocument(runs: [
      mode, FlashStatusTextSegment(text: " N ", foreground: .defaultForeground), literal,
    ])
    let surface = NativeStatusBarSurface()
    redraw(
      surface, document: document, columns: 80,
      labels: .init(normal: "N", insert: "I", command: "C"), style: .insert,
      modeText: "LONG MODE")

    XCTAssertEqual(
      surface.runLayers.prefix(3).map { ($0.text.string as? NSAttributedString)?.string },
      ["LONG MODE", " N ", "N"])
    XCTAssertEqual(surface.runFrames[0].width, CGFloat(9) * 13 * 0.66 + 16, accuracy: 0.001)
    XCTAssertEqual(surface.runFrames[1].minX, surface.runFrames[0].maxX, accuracy: 0.001)
    XCTAssertEqual(document.runs[0].text, "N", "Rendering must not rewrite a published model")
  }

  func testLiveModeTextOutsidePillChangesImmediately() {
    var mode = FlashStatusTextSegment(text: "STALE", foreground: .defaultForeground)
    mode.isModeLabel = true
    let document = StatusFormatDocument(runs: [mode])
    let surface = NativeStatusBarSurface()
    redraw(surface, document: document, columns: 40, modeText: "NORMAL")
    redraw(surface, document: document, columns: 40, style: .insert, modeText: "INSERT")

    let layers = surface.runLayers[0]
    XCTAssertEqual((layers.text.string as? NSAttributedString)?.string, "INSERT")
    XCTAssertNil(layers.text.animation(forKey: crossfadeKey))
    XCTAssertNil(layers.outgoing.animation(forKey: crossfadeKey))
  }

  func testLiveModePillPreservesEmptyPlaceholderAcrossLabelChanges() {
    var mode = FlashStatusTextSegment(text: "", foreground: .defaultForeground)
    mode.isModeLabel = true
    mode.pill = true
    let document = StatusFormatDocument(runs: [mode])
    let surface = NativeStatusBarSurface()
    for (input, expected) in [(" INSERT ", "INSERT"), (" \t ", ""), ("NORMAL", "NORMAL")] {
      redraw(surface, document: document, columns: 40, modeText: input)
      let layers = surface.runLayers[0]
      XCTAssertFalse(layers.pill.isHidden)
      XCTAssertEqual((layers.text.string as? NSAttributedString)?.string, expected)
      XCTAssertNil(layers.text.animationKeys())
      XCTAssertNil(layers.outgoing.animationKeys())
    }
  }

  func testHoverWashUpdatesImmediatelyAndBarDrawsHairlineUnderTransparentRuns() throws {
    let surface = render("A #[fg=red]B#[default] C", columns: 10)
    let first = try XCTUnwrap(surface.visibleRuns.firstIndex { $0.segment.text == "A " })
    let second = try XCTUnwrap(surface.visibleRuns.firstIndex { $0.segment.text == "B" })
    XCTAssertEqual(surface.hoverHighlight.opacity, 0)
    surface.setHoverHighlight(surface.runFrames[first])
    XCTAssertEqual(surface.hoverHighlight.opacity, 1)
    XCTAssertTrue(surface.hoverHighlight.animationKeys()?.isEmpty != false)
    surface.setHoverHighlight(surface.runFrames[second])
    XCTAssertEqual(surface.hoverHighlight.frame.minX, surface.runFrames[second].minX - 5)
    XCTAssertEqual(surface.hoverHighlight.frame.width, surface.runFrames[second].width + 10)
    XCTAssertTrue(surface.hoverHighlight.animationKeys()?.isEmpty != false)
    surface.setHoverHighlight(nil)
    XCTAssertEqual(surface.hoverHighlight.opacity, 0)
    XCTAssertTrue(surface.hoverHighlight.animationKeys()?.isEmpty != false)
    let sublayers = surface.backgroundLayer.sublayers ?? []
    XCTAssertTrue(sublayers.first === surface.hairline)
    XCTAssertTrue(sublayers.dropFirst().first === surface.centreNotch)
    XCTAssertTrue(sublayers.dropFirst(2).first === surface.hoverHighlight)
    XCTAssertTrue(surface.runLayers.allSatisfy { $0.container.backgroundColor == nil })
    XCTAssertEqual(surface.hairline.frame.height, 0.5)
    XCTAssertEqual(surface.backgroundLayer.colors?.count, 2)
  }

  func testHoverWashFitsFeedLabelWithoutItsLinkedSeparatorSpace() throws {
    let archive = "https://aggr.example"
    let surface = render(
      "#[pill]NORMAL#[nopill] · #[link=\(archive),popup=feed,fg=yellow]AGGR"
        + "#[fg=white] #[link=https://article.example]Article#[nolink,nopopup]",
      columns: 50)
    let label = try XCTUnwrap(surface.visibleRuns.firstIndex { $0.segment.text == "AGGR" })
    let link = try XCTUnwrap(
      surface.interactionRects(panelFrame: .zero, popupTexts: [:], popupDocuments: [:])
        .links.first { $0.url.absoluteString == archive })
    XCTAssertEqual(link.rect.minX, surface.runFrames[label].minX, accuracy: 0.001)
    XCTAssertEqual(link.rect.width, surface.cellWidth * 5, accuracy: 0.001)
    surface.setHoverHighlight(link.rect)
    XCTAssertEqual(surface.hoverHighlight.frame.minX, surface.runFrames[label].minX - 5)
    XCTAssertEqual(
      surface.hoverHighlight.frame.maxX, surface.runFrames[label].maxX + 5, accuracy: 0.001)
  }

  /// The user's AI-usage segment, rendered: each link's hint sits at the
  /// centre of its own text (the bounds its hover wash hugs), and the popup
  /// wrapping both adds no hint on the space between them.
  func testStatusHintsTargetEachLinkInAPopupAtItsWashedText() throws {
    let claude = "https://claude.ai/new#settings/usage"
    let codex = "https://chatgpt.com/settings/usage?tab=overview"
    let surface = render(
      "#[popup=ai-usage]#[link=\(claude)]Cld 91%↻6d#[nolink] "
        + "#[link=\(codex)]Cdx 26%↻6d#[nolink]#[nopopup] #[popup=cpu]CPU 3%#[nopopup]",
      columns: 50)
    let hits = surface.interactionRects(
      panelFrame: .zero, popupTexts: ["ai-usage": "usage", "cpu": "CPU"], popupDocuments: [:])
    let popup = try XCTUnwrap(hits.popups.first { $0.name == "ai-usage" })
    XCTAssertEqual(hits.hints.count, 3)
    for (hint, url) in zip(hits.hints.prefix(2), [claude, codex]) {
      let link = try XCTUnwrap(hits.links.first { $0.url.absoluteString == url })
      XCTAssertEqual(hint.action, .click(link.url))
      XCTAssertEqual(hint.popup?.name, "ai-usage")
      surface.setHoverHighlight(link.rect)
      let wash = surface.hoverHighlight.frame.insetBy(
        dx: NativeStatusBarSurface.hoverWashHorizontalPadding, dy: 0)
      XCTAssertEqual(hint.point.x, wash.midX, accuracy: 0.001)
      XCTAssertTrue(link.rect.contains(hint.point))
    }
    let gap = hits.hints[1].rect.minX - hits.hints[0].rect.maxX
    XCTAssertEqual(gap, surface.cellWidth, accuracy: 0.001)
    XCTAssertFalse(
      hits.hints.contains {
        $0.point.x > hits.hints[0].rect.maxX && $0.point.x < hits.hints[1].rect.minX
      })
    XCTAssertNotEqual(hits.hints[0].point.x, popup.rect.midX, accuracy: 1)
    // A popup-only span is still one hint, on its text.
    let cpu = try XCTUnwrap(hits.popups.first { $0.name == "cpu" })
    XCTAssertEqual(hits.hints[2].action, .hover(cpu))
    XCTAssertEqual(hits.hints[2].textBounds, cpu.textBounds)
  }

  func testWideHoverWashRemainsSubtle() {
    let title = String(repeating: "a", count: NativeStatusBarSurface.wideHoverCells + 1)
    let surface = render(title, columns: 40)
    surface.setHoverHighlight(surface.runFrames[0])
    XCTAssertEqual(surface.hoverHighlight.opacity, NativeStatusBarSurface.wideHoverOpacity)
  }

  func testHoverWashTrimsOnlyOuterWhitespaceAndPreservesUnicodeCellGeometry() throws {
    let surface = render("L#[link=https://example.com]  A界 B  #[nolink]R", columns: 20)
    let link = try XCTUnwrap(
      surface.interactionRects(panelFrame: .zero, popupTexts: [:], popupDocuments: [:]).links.first)
    surface.setHoverHighlight(link.rect)
    XCTAssertEqual(
      surface.hoverHighlight.frame.minX, link.rect.minX + 2 * surface.cellWidth - 5,
      accuracy: 0.001)
    XCTAssertEqual(surface.hoverHighlight.frame.width, 5 * surface.cellWidth + 10, accuracy: 0.001)
  }

  func testFirstModelPopulatesPreviouslyEmptySurfaceWithoutFocusOrModeChange() {
    let surface = render("", columns: 40)
    XCTAssertTrue(surface.layout.text.trimmingCharacters(in: .whitespaces).isEmpty)
    redraw(surface, "#[pill]NORMAL#[nopill] Firefox", columns: 40)
    XCTAssertFalse(surface.visibleRuns.isEmpty)
    let pill = surface.runLayers[0]
    XCTAssertEqual((pill.text.string as? NSAttributedString)?.string, "NORMAL")
    XCTAssertEqual(
      pill.pill.colors as? [CGColor],
      [OverlayPanel.normalPalette.bottomCG, OverlayPanel.normalPalette.topCG])
    XCTAssertTrue(pill.container.superlayer === surface.backgroundLayer)
    XCTAssertFalse(pill.container.isHidden)
    XCTAssertFalse(pill.pill.isHidden)
    XCTAssertEqual(pill.pill.borderWidth, 1)
  }

  func testPooledLayersDrawNativeListsFillAndAbsoluteCentreAtCellPositions() {
    for source in [
      "#[align=left,list=on]012345#[list=focus]678#[list=on]9ABCDEF"
        + "#[list=left-marker]<#[list=right-marker]>#[nolist]",
      "LLLL#[align=centre]CC#[align=right]RRRR#[align=absolute-centre]AB",
      "A#[fill=red]",
    ] {
      let surface = render(source, columns: 10)
      let native = StatusFormatLayout.layout(StatusFormatDocument.parse(source), columns: 10)
      XCTAssertEqual(surface.layout, native)
      XCTAssertEqual(surface.visibleRuns.map(\.segment.text).joined(), native.text)
      for (run, layers) in zip(surface.visibleRuns, surface.runLayers) {
        XCTAssertEqual(
          layers.container.frame.minX,
          OverlayPanel.statusBarEdgePadding + CGFloat(run.column) * surface.cellWidth,
          accuracy: 0.001)
        XCTAssertEqual(
          layers.container.frame.width, CGFloat(run.columns) * surface.cellWidth, accuracy: 0.001)
        XCTAssertEqual((layers.text.string as? NSAttributedString)?.string, run.segment.text)
      }
    }
    let fill = render("A#[fill=red]", columns: 10)
    // Default-background cells stay transparent so the bar fill shows through.
    XCTAssertNil(fill.runLayers[0].container.backgroundColor)
    XCTAssertEqual(
      fill.backgroundLayer.backgroundColor, FlashStatusTextColor.nsColor(.palette(1)).cgColor)
  }

  func testExplicitModePillReservesConfiguredWidthAndPlainLeftTextRemainsPlain() {
    let normal = render("#[pill]N#[nopill] tail", columns: 40)
    let command = render("#[pill]COMMAND#[nopill] tail", columns: 40)
    XCTAssertEqual(normal.visibleRuns.first?.columns, command.visibleRuns.first?.columns)
    XCTAssertEqual(normal.runLayers.first?.pill.isHidden, false)
    let plain = render("N tail", columns: 40)
    XCTAssertTrue(plain.runLayers.allSatisfy { $0.pill.isHidden })
    XCTAssertEqual(plain.layout.text.trimmingCharacters(in: .whitespaces), "N tail")
  }

  func testModePillKeepsLegacyPointWidthCenteredLabelAndRetinaOutline() {
    let labels = Config.Mode.Labels(normal: "NORMAL", insert: "INSERT", command: "COMMAND")
    let expectedWidth = CGFloat(7) * 13 * 0.66 + 16
    for (label, style) in [
      ("NORMAL", OverlayModeBadgeStyle.normal), ("INSERT", .insert), ("TERMINAL", .normal),
    ] {
      let surface = NativeStatusBarSurface()
      redraw(surface, "#[pill]\(label)#[nopill] tail", columns: 40, labels: labels, style: style)
      let pill = surface.runLayers[0]
      XCTAssertEqual(pill.container.frame.width, expectedWidth, accuracy: 0.001)
      XCTAssertEqual(pill.pill.frame.width, expectedWidth, accuracy: 0.001)
      XCTAssertEqual(pill.pill.cornerRadius, 4)
      XCTAssertEqual(pill.pill.contentsScale, 2)
      XCTAssertEqual(pill.pill.borderWidth, style == .normal ? 1 : 0)
      XCTAssertEqual(pill.text.alignmentMode, .center)
      XCTAssertEqual((pill.text.string as? NSAttributedString)?.string, label)
      XCTAssertEqual(pill.text.frame.midX, expectedWidth / 2, accuracy: 0.001)
      XCTAssertEqual(
        surface.runLayers[1].container.frame.minX,
        OverlayPanel.statusBarEdgePadding + expectedWidth, accuracy: 0.001)
    }
  }

  func testPillInteractionBoundsUseTheSamePointSpacingAsDrawnText() {
    let surface = render("#[pill]N#[nopill,link=https://example.com]tail", columns: 40)
    let link = surface.interactionRects(panelFrame: .zero, popupTexts: [:], popupDocuments: [:])
      .links[0]
    XCTAssertEqual(link.rect.minX, surface.runLayers[1].container.frame.minX, accuracy: 0.001)
    XCTAssertEqual(link.rect.minX, surface.runLayers[0].container.frame.maxX, accuracy: 0.001)
  }

  func testPillOnlyRemovesLayoutPaddingAndKeepsConfiguredLabelSpaces() {
    let surface = render("#[pill] N #[nopill]", columns: 40)
    XCTAssertEqual((surface.runLayers[0].text.string as? NSAttributedString)?.string, " N ")
  }

  func testPillPointSpacingKeepsRightAnchorAndUnrelatedAbsoluteCentre() {
    let right = render("#[align=right,pill]N#[nopill]tail", columns: 40)
    let index = right.visibleRuns.firstIndex { $0.segment.text == "tail" }!
    XCTAssertEqual(
      right.runLayers[index].container.frame.maxX,
      OverlayPanel.statusBarEdgePadding + CGFloat(right.availableColumns) * right.cellWidth,
      accuracy: 0.001)
    XCTAssertEqual(
      right.runLayers[index - 1].container.frame.maxX,
      right.runLayers[index].container.frame.minX, accuracy: 0.001)
    let plain = render("#[align=absolute-centre]CENTER", columns: 40)
    let pill = render("#[pill]N#[nopill] tail#[align=absolute-centre]CENTER", columns: 40)
    let plainIndex = plain.visibleRuns.firstIndex { $0.segment.text == "CENTER" }!
    let pillIndex = pill.visibleRuns.firstIndex { $0.segment.text == "CENTER" }!
    XCTAssertEqual(plain.runFrames[plainIndex], pill.runFrames[pillIndex])
  }

  func testNotchHidesCentreAndClipsBothDrawnCellsAndInteractionRects() {
    let notch = CGRect(x: 160, y: 0, width: 45, height: 30)
    let surface = render(
      "#[link=https://example.com]abcdefghijklmnopqrstuvwxyz0123456789"
        + "#[align=centre]HIDDEN#[align=right]RIGHT", columns: 50, notch: notch)
    XCTAssertFalse(surface.visibleRuns.map(\.segment.text).joined().contains("HIDDEN"))
    let excluded = notch.insetBy(dx: -OverlayPanel.statusBarNotchMargin, dy: -100)
    for run in surface.runLayers.prefix(surface.visibleRuns.count) {
      XCTAssertFalse(run.container.frame.intersects(excluded))
    }
    let hits = surface.interactionRects(panelFrame: .zero, popupTexts: [:], popupDocuments: [:])
    XCTAssertFalse(hits.links.isEmpty)
    XCTAssertTrue(hits.links.allSatisfy { !$0.rect.intersects(excluded) })
  }

  func testOnlyClosedNativeRangesCreateActionsAndExplicitLinksHavePriority() {
    let source =
      "#[range=user|closed]a#[bold]b#[norange]"
      + "#[link=https://example.com,range=user|unclosed]c"
    let surface = render(source, columns: 20)
    let links = surface.interactionRects(panelFrame: .zero, popupTexts: [:], popupDocuments: [:])
      .links
    XCTAssertEqual(links.first?.url.absoluteString, "https://example.com")
    XCTAssertTrue(
      links.contains { $0.url == FlashStatusBarRenderer.rangeActionURL(name: "closed") })
    XCTAssertFalse(
      links.contains { $0.url == FlashStatusBarRenderer.rangeActionURL(name: "unclosed") })
    let closed = links.filter { $0.url == FlashStatusBarRenderer.rangeActionURL(name: "closed") }
    XCTAssertEqual(closed.count, 1)
    XCTAssertEqual(
      closed.first?.rect.width ?? 0,
      surface.cellWidth * CGFloat(surface.layout.ranges[0].columns.count), accuracy: 0.001)
  }

  func testRepeatedRenderKeepsPooledLayersAndAnimationPhaseWhileCyclesTransition() {
    let surface = render(
      "#[blink,overline,curly-underscore]X#[noblink,nounderscore,nooverline,cyc]one", columns: 20)
    let first = surface.runLayers[0]
    let animation = first.effect.animation(forKey: "flashEffect")
    XCTAssertNotNil(animation)
    XCTAssertFalse(first.overline.isHidden)
    XCTAssertNotNil(first.curlyUnderline.path)
    redraw(
      surface, "#[blink,overline,curly-underscore]X#[noblink,nounderscore,nooverline,cyc]two",
      columns: 20)
    XCTAssertTrue(surface.runLayers[0] === first)
    XCTAssertEqual(first.effect.animation(forKey: "flashEffect")?.beginTime, animation?.beginTime)
    XCTAssertTrue(surface.runLayers[1].text.animation(forKey: cycleKey) is CAAnimationGroup)
  }

  func testCarouselSlidesUpOnlyOnArticleChangesAndClearsWhenLayerBecomesAMetric() {
    let surface = render("NEWS #[cyc]first#[nocyc] CPU 10%", columns: 40)
    XCTAssertTrue(surface.runLayers.allSatisfy { $0.text.animation(forKey: cycleKey) == nil })
    redraw(surface, "NEWS #[cyc]second#[nocyc] CPU 20%", columns: 40)
    let article = surface.runLayers[1]
    let incoming = article.text.animation(forKey: cycleKey) as? CAAnimationGroup
    let rise = incoming?.animations?.compactMap { $0 as? CABasicAnimation }
    XCTAssertEqual(rise?.map(\.keyPath), ["opacity", "transform.translation.y"])
    XCTAssertEqual(incoming?.duration, NativeStatusBarSurface.cycleTransitionDuration)
    let lineHeight = article.container.frame.height
    // The new line rises the full bar height from below while fading in ...
    XCTAssertEqual(rise?[1].fromValue as? CGFloat, -lineHeight)
    XCTAssertEqual(rise?[1].toValue as? CGFloat, 0)
    XCTAssertEqual(rise?[0].fromValue as? CGFloat, 0)
    XCTAssertEqual(rise?[0].toValue as? CGFloat, 1)
    // ... and the old line is pushed the same distance up while fading out,
    // in lockstep.
    let leaving = article.outgoing.animation(forKey: cycleKey) as? CAAnimationGroup
    let push = leaving?.animations?.compactMap { $0 as? CABasicAnimation }
    XCTAssertEqual(push?[1].fromValue as? CGFloat, 0)
    XCTAssertEqual(push?[1].toValue as? CGFloat, lineHeight)
    XCTAssertEqual(push?[0].fromValue as? CGFloat, 1)
    XCTAssertEqual(push?[0].toValue as? CGFloat, 0)
    XCTAssertEqual(leaving?.duration, incoming?.duration)
    XCTAssertEqual(leaving?.beginTime, incoming?.beginTime)
    XCTAssertEqual((article.outgoing.string as? NSAttributedString)?.string, "first")
    XCTAssertEqual(article.outgoing.opacity, 0)
    XCTAssertNil(surface.runLayers[0].text.animation(forKey: cycleKey))
    XCTAssertNil(surface.runLayers[2].text.animation(forKey: cycleKey))
    article.text.removeAllAnimations()
    article.effect.removeAllAnimations()
    redraw(surface, "NEWS #[cyc]second#[nocyc] CPU 30%", columns: 40)
    XCTAssertNil(article.text.animation(forKey: cycleKey))
    redraw(surface, "NEWS #[cyc]third#[nocyc] CPU 30%", columns: 40)
    XCTAssertNotNil(article.text.animation(forKey: cycleKey))
    redraw(surface, "NEWS #[fg=red]CPU 40%#[default] MEM 50%", columns: 40)
    XCTAssertTrue(surface.runLayers[1] === article)
    XCTAssertNil(article.text.animation(forKey: cycleKey))
    XCTAssertNil(article.effect.animation(forKey: cycleKey))
  }

  func testCarouselMovesUnchangedArrowAndDomainWithTheChangedArticle() {
    func source(
      _ title: String, url: String = "https://example.com/a", popup: String = "feed-a"
    ) -> String {
      "NEWS #[cyc,popup=\(popup),link=\(url)]\(title)#[nolink] #[fg=yellow]example.com "
        + "#[link=\(url)]↗#[nolink,nocyc,nopopup,default] CPU 10%"
    }
    let surface = render(source("first"), columns: 60)
    redraw(surface, source("other"), columns: 60)
    let cyclic = surface.visibleRuns.indices.filter { surface.visibleRuns[$0].segment.cycle }
    XCTAssertGreaterThan(cyclic.count, 2)
    for index in cyclic {
      XCTAssertNotNil(
        surface.runLayers[index].text.animation(forKey: cycleKey),
        surface.visibleRuns[index].segment.text)
    }
    let starts = cyclic.compactMap {
      surface.runLayers[$0].text.animation(forKey: cycleKey)?.beginTime
    }
    XCTAssertEqual(Set(starts).count, 1)
    for layer in surface.runLayers {
      layer.text.removeAllAnimations()
      layer.effect.removeAllAnimations()
    }
    redraw(surface, source("other"), columns: 60)
    XCTAssertTrue(surface.runLayers.allSatisfy { $0.text.animationKeys()?.isEmpty != false })
    redraw(surface, source("other", url: "https://example.com/b"), columns: 60)
    for index in cyclic {
      XCTAssertNotNil(surface.runLayers[index].text.animation(forKey: cycleKey))
    }
    for index in surface.visibleRuns.indices where !surface.visibleRuns[index].segment.cycle {
      XCTAssertNil(surface.runLayers[index].text.animation(forKey: cycleKey))
    }
    for layer in surface.runLayers {
      layer.text.removeAllAnimations()
      layer.effect.removeAllAnimations()
    }
    redraw(surface, source("other", url: "https://example.com/b", popup: "feed-b"), columns: 60)
    for index in cyclic {
      XCTAssertNotNil(surface.runLayers[index].text.animation(forKey: cycleKey))
    }
    redraw(surface, "NEWS #[fg=red]CPU 40%#[default] MEM 50%", columns: 60)
    XCTAssertTrue(surface.runLayers.allSatisfy { $0.text.animationKeys()?.isEmpty != false })
    XCTAssertTrue(surface.runLayers.allSatisfy { $0.effect.animationKeys()?.isEmpty != false })
  }

  func testCarouselReBudgetByAnotherLaneDoesNotPushTheSameArticle() {
    func source(right: String, url: String = "https://example.com/a") -> String {
      "NEWS #[cyc,link=\(url),popup=feed]#[shrink]a long article title that overflows the lane"
        + "#[noshrink]#[nolink] (example.com) #[link=\(url)]↗#[nolink,nocyc,nopopup]"
        + "#[align=right]\(right)"
    }
    let surface = render(source(right: "CPU 9%"), columns: 50)
    let cyclic = surface.visibleRuns.indices.filter { surface.visibleRuns[$0].segment.cycle }
    XCTAssertGreaterThan(cyclic.count, 1)
    let full = surface.visibleRuns[cyclic[0]].segment.text
    // The right lane grows: the elastic title contracts and the row's tail
    // gives way, but it is the same article — no vertical push.
    redraw(surface, source(right: "CPU 10% MEM 40% NET 1.2MiB"), columns: 50)
    let contracted = surface.visibleRuns.filter(\.segment.cycle).map(\.segment.text).joined()
    XCTAssertNotEqual(contracted, full)
    XCTAssertTrue(contracted.contains("…"))
    XCTAssertTrue(surface.runLayers.allSatisfy { $0.text.animation(forKey: cycleKey) == nil })
    // A new article still pushes.
    redraw(
      surface, source(right: "CPU 10% MEM 40% NET 1.2MiB", url: "https://example.com/b"),
      columns: 50)
    let animated = surface.visibleRuns.indices.filter {
      surface.visibleRuns[$0].segment.cycle
        && surface.runLayers[$0].text.animation(forKey: cycleKey) != nil
    }
    XCTAssertFalse(animated.isEmpty)
  }

  /// Moving an overflow cut onto a one-cell glyph swaps it for the ellipsis
  /// in the same cell: a re-budget, not a new value, so it snaps.
  func testCutLandingOnAGlyphSnapsInsteadOfCrossfading() {
    let surface = render("#[shrink]éé#[noshrink]#[align=right]RRRR", columns: 6)
    XCTAssertEqual(surface.visibleRuns.first?.segment.text, "é")
    redraw(surface, "#[shrink]éé#[noshrink]#[align=right]RRRRR", columns: 6)
    XCTAssertEqual(surface.visibleRuns.first?.segment.text, "…")
    XCTAssertNil(surface.runLayers[0].text.animation(forKey: crossfadeKey))
    XCTAssertNil(surface.runLayers[0].outgoing.animation(forKey: crossfadeKey))
  }

  func testTruncationEquivalenceIgnoresEllipsisAndTrailingSpaceOnly() {
    XCTAssertTrue(NativeStatusBarSurface.truncationEquivalent("Hello wor…", "Hello world"))
    XCTAssertTrue(NativeStatusBarSurface.truncationEquivalent("Hello world ", "Hello"))
    XCTAssertTrue(NativeStatusBarSurface.truncationEquivalent("", "Hello"))
    XCTAssertFalse(NativeStatusBarSurface.truncationEquivalent("first", "other"))
    XCTAssertFalse(NativeStatusBarSurface.truncationEquivalent("Hello…", "Help"))
  }

  func testDrawnNotchTracesTheHousingOutline() {
    // The housing is widest flush with the top edge, flares inward through
    // the top corners rather than meeting the bezel square, runs straight
    // down its sides, and rounds its two bottom corners.
    let rect = CGRect(x: 100, y: 0, width: 185, height: 30)
    let path = NativeStatusBarSurface.centreNotchPath(in: rect, height: rect.height)
    let fillet = NativeStatusBarSurface.notchTopFilletRadius
    let radius = NativeStatusBarSurface.notchCornerRadius
    XCTAssertEqual(path.boundingBox.minX, rect.minX, accuracy: 0.001)
    XCTAssertEqual(path.boundingBox.maxX, rect.maxX, accuracy: 0.001)
    XCTAssertEqual(path.boundingBox.height, rect.height, accuracy: 0.001)

    // Full width along the top edge ...
    XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.height - 0.5)))
    // ... narrowing through the top corners, so the extreme corner is cut.
    XCTAssertFalse(path.contains(CGPoint(x: rect.minX + 0.5, y: rect.height - 0.5)))
    XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 0.5, y: rect.height - 0.5)))

    // Straight sides below the fillets, inset by exactly the fillet.
    let side = rect.height - fillet - 1
    XCTAssertTrue(path.contains(CGPoint(x: rect.minX + fillet + 0.5, y: side)))
    XCTAssertFalse(path.contains(CGPoint(x: rect.minX + fillet - 0.5, y: side)))
    XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - fillet - 0.5, y: side)))
    XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - fillet + 0.5, y: side)))
    XCTAssertTrue(path.contains(CGPoint(x: rect.minX + fillet + 0.5, y: radius + 1)))

    // Both bottom corners are rounded away, the edge between them solid.
    XCTAssertFalse(path.contains(CGPoint(x: rect.minX + fillet + 0.5, y: 0.5)))
    XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - fillet - 0.5, y: 0.5)))
    XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: 0.5)))

    // A squat bar degrades to a rounded stub, never an inverted or
    // self-intersecting path.
    let squat = NativeStatusBarSurface.centreNotchPath(
      in: CGRect(x: 0, y: 0, width: 12, height: 4), height: 4)
    XCTAssertEqual(squat.boundingBox.width, 12, accuracy: 0.001)
    XCTAssertEqual(squat.boundingBox.height, 4, accuracy: 0.001)
  }

  func testDrawnAndRealNotchesReserveTheSameClearance() {
    // A drawn recess is the real housing's width, so the lanes have to clear
    // it by the housing's margin too — otherwise the bar would lay out
    // differently on a notched Mac and on an external display.
    let previous = FlashTunables.statusBarNotchMargin
    defer { FlashTunables.statusBarNotchMargin = previous }
    for margin in [0.0, 6.0, 14.0] {
      FlashTunables.statusBarNotchMargin = margin
      for cellWidth in [6, 8.05, 13] as [CGFloat] {
        let columns = NativeStatusBarSurface.centreMarginColumns(cellWidth: cellWidth)
        let points = CGFloat(columns) * cellWidth
        // Never less than a real notch reserves ...
        XCTAssertGreaterThanOrEqual(points, OverlayPanel.statusBarNotchMargin)
        // ... and rounded up to whole cells by at most one, so the lanes
        // never lose a meaningful slice to the gap.
        XCTAssertLessThan(points, OverlayPanel.statusBarNotchMargin + cellWidth)
      }
    }
    // A degenerate cell width cannot produce an infinite margin.
    XCTAssertEqual(NativeStatusBarSurface.centreMarginColumns(cellWidth: 0), 0)
  }

  func testAbsoluteCentreDrawsARecessedNotchOfTheRealHousingWidth() throws {
    let columns = 60
    let notchWidth: CGFloat = 185
    let source =
      String(repeating: "L", count: 40) + "#[align=absolute-centre]CENTRE#[align=right]"
      + String(repeating: "R", count: 40)
    let surface = render(source, columns: columns, notchWidth: notchWidth)
    XCTAssertFalse(surface.centreNotch.isHidden)
    let notch = try XCTUnwrap(surface.centreNotch.path).boundingBox
    let notchColumns = Int(ceil(notchWidth / surface.cellWidth))
    let reserve = StatusBarOverflow.reserve(
      centre: 6,
      in: NativeStatusBarSurface.overflowGeometry(
        columns: columns, cellWidth: surface.cellWidth, notchWidth: notchWidth, leftColumns: nil))
    XCTAssertEqual(reserve.count, notchColumns)
    XCTAssertEqual(notch.width, CGFloat(notchColumns) * surface.cellWidth, accuracy: 0.51)
    XCTAssertEqual(
      notch.minX, surface.runFrames[0].minX + CGFloat(reserve.lowerBound) * surface.cellWidth,
      accuracy: 0.51)
    XCTAssertEqual(notch.height, surface.backgroundLayer.frame.height, accuracy: 0.001)
    let centre = try XCTUnwrap(surface.visibleRuns.firstIndex { $0.segment.text == "CENTRE" })
    XCTAssertTrue(notch.contains(surface.runFrames[centre]))
    for (index, run) in surface.visibleRuns.enumerated()
    where index != centre && !run.segment.text.allSatisfy(\.isWhitespace) {
      let frame = surface.runFrames[index]
      // The recess is snapped to the pixel grid, so allow half a device pixel.
      let margin =
        CGFloat(NativeStatusBarSurface.centreMarginColumns(cellWidth: surface.cellWidth))
        * surface.cellWidth
      XCTAssertTrue(
        frame.maxX <= notch.minX - margin + 0.51 || frame.minX >= notch.maxX + margin - 0.51,
        "run '\(run.segment.text)' col=\(run.column)+\(run.columns) frame=\(frame) "
          + "crowds the notch \(notch) reserve=\(reserve)")
    }
    XCTAssertEqual(
      surface.centreNotch.fillColor,
      OverlayPanel.sunken(OverlayPanel.nordPolarNight0, by: OverlayPanel.statusBarNotchSink).cgColor
    )
    // The recess sits under the hover wash and the run containers.
    let sublayers = try XCTUnwrap(surface.backgroundLayer.sublayers)
    let notchIndex = try XCTUnwrap(sublayers.firstIndex { $0 === surface.centreNotch })
    let washIndex = try XCTUnwrap(sublayers.firstIndex { $0 === surface.hoverHighlight })
    XCTAssertLessThan(notchIndex, washIndex)
    XCTAssertTrue(
      sublayers.suffix(from: washIndex + 1).allSatisfy { layer in
        surface.runLayers.contains { $0.container === layer }
      })
    // The recess is at least the housing. A longer centre could widen it, but
    // these lanes need every column: once the centre is the longest section
    // it gives way with the lanes, down to the housing's interior and no
    // further, where it is clipped with an ellipsis.
    redraw(
      surface,
      source.replacingOccurrences(
        of: "CENTRE", with: "A MUCH LONGER CENTRE LABEL THAT CANNOT FIT THE HOUSING"),
      columns: columns, notchWidth: notchWidth)
    let fixed = try XCTUnwrap(surface.centreNotch.path).boundingBox
    XCTAssertEqual(fixed.width, notch.width, accuracy: 0.001)
    let clipped = surface.visibleRuns.filter { $0.segment.alignment == .absoluteCentre }
    XCTAssertTrue(clipped.contains { $0.segment.text.hasSuffix("…") })
    XCTAssertLessThanOrEqual(
      clipped.reduce(0) { $0 + $1.columns },
      notchColumns - NativeStatusBarSurface.centreGutterColumns * 2)
    // No centre, or a physical notch (which hides the centre): no recess.
    redraw(surface, "LEFT#[align=right]RIGHT", columns: columns, notchWidth: notchWidth)
    XCTAssertTrue(surface.centreNotch.isHidden)
    redraw(
      surface, source, columns: columns, notch: CGRect(x: 200, y: 0, width: 45, height: 30),
      notchWidth: notchWidth)
    XCTAssertTrue(surface.centreNotch.isHidden)
  }

  func testIndependentCarouselGroupsDoNotAnimateEachOther() {
    let surface = render("A #[cyc]one#[nocyc] B #[cyc]two#[nocyc]", columns: 40)
    redraw(surface, "A #[cyc]new#[nocyc] B #[cyc]two#[nocyc]", columns: 40)
    for (index, run) in surface.visibleRuns.enumerated() {
      if run.segment.text == "new" {
        XCTAssertNotNil(surface.runLayers[index].text.animation(forKey: cycleKey))
      } else {
        XCTAssertNil(surface.runLayers[index].text.animation(forKey: cycleKey))
      }
    }
  }

  func testUnicodeClustersKeepFollowingGlyphAndHitAtNativeCellColumn() {
    let surface = render("#[link=https://example.com]👩‍💻🇫🇷A", columns: 20)
    let ascii = surface.visibleRuns.first { $0.segment.text == "A" }
    XCTAssertNotNil(ascii)
    let index = surface.visibleRuns.firstIndex { $0.segment.text == "A" }!
    XCTAssertEqual(
      surface.runLayers[index].container.frame.minX,
      OverlayPanel.statusBarEdgePadding + CGFloat(ascii!.column) * surface.cellWidth,
      accuracy: 0.001)
    let unicode = surface.visibleRuns.filter {
      !$0.segment.text.unicodeScalars.allSatisfy(\.isASCII)
    }
    XCTAssertFalse(unicode.isEmpty)
    XCTAssertEqual(unicode.map(\.segment.text).joined(), "👩‍💻🇫🇷")
  }

  func testShrinkSpanGivesWayBeforeTheSectionTail() {
    let surface = render("HN #[shrink]abcdefghijklmnopqrstuvwxyz#[noshrink] END", columns: 14)
    XCTAssertEqual(surface.layout.text, "HN abcdef… END")
    // Unmarked text used to fall to tmux's silent clip ("abcdefghijklmn");
    // a section with no `#[shrink]` span now loses its own tail with an
    // ellipsis, the default truncation point.
    let unmarked = render("abcdefghijklmnopqrstuvwxyz END", columns: 14)
    XCTAssertEqual(unmarked.layout.text, "abcdefghijklm…")
  }

  /// A right lane with nothing marked loses its tail (the clock goes before
  /// the CPU), and only once every `#[shrink]` span elsewhere is exhausted.
  func testUnmarkedRightLaneLosesItsTailOnlyAfterMarkedSpansAreExhausted() {
    let right = "CPU 10% MEM 20% 12:34"
    XCTAssertEqual(
      render(
        "HN #[shrink]" + String(repeating: "a", count: 30) + "#[noshrink]#[align=right]" + right,
        columns: 30
      ).layout.text,
      "HN aaaaa…" + right, "the marked title gives way while the right lane fits")
    XCTAssertEqual(
      render(
        "HN #[shrink]" + String(repeating: "a", count: 30) + "#[noshrink]#[align=right]" + right,
        columns: 20
      ).layout.text,
      "HN …CPU 10% MEM 20%…")

    // With a drawn recess the centred span narrows to the housing first; the
    // right lane's tail goes only after that.
    let housing = 24
    let columns = 80
    let longRight = "CPU 10% · MEM 20% · NET 1.2k · Wed 12:34"
    let surface = render(
      "N#[align=absolute-centre]#[shrink]" + String(repeating: "c", count: 30)
        + "#[noshrink]#[align=right]" + longRight,
      columns: columns, notchWidth: housingWidth(columns: housing))
    let margin = NativeStatusBarSurface.centreMarginColumns(cellWidth: surface.cellWidth)
    let interior = housing - NativeStatusBarSurface.centreGutterColumns * 2
    XCTAssertEqual(
      text(surface, .absoluteCentre), String(repeating: "c", count: interior - 1) + "…")
    let rightBudget = (columns - housing + 1) / 2 - margin
    XCTAssertEqual(text(surface, .right), String(longRight.prefix(rightBudget - 1)) + "…")
    XCTAssertEqual(
      try XCTUnwrap(surface.centreNotch.path).boundingBox.width,
      CGFloat(housing) * surface.cellWidth, accuracy: 0.51)
  }

  /// A long centred name uses the columns the lanes leave free, with no
  /// fixed `#{=/N/…:}` width in the template, and the recess widens to hold
  /// it; a short name keeps the housing's width.
  func testLongCentredLabelUsesFreeColumnsAndWidensTheRecess() throws {
    let columns = 200
    let housing = 24
    let label = "Microsoft Visual Studio Code — flash (ab/dev)"
    XCTAssertEqual(label.count, 45)
    func source(_ label: String) -> String {
      "#[pill]N#[nopill] FEED#[align=absolute-centre]#[shrink]\(label)#[noshrink]"
        + "#[align=right]CPU 10% 12:34"
    }
    let surface = render(
      source(label), columns: columns, notchWidth: housingWidth(columns: housing))
    XCTAssertEqual(text(surface, .absoluteCentre), label)
    let recess = try XCTUnwrap(surface.centreNotch.path).boundingBox
    let gutter = NativeStatusBarSurface.centreGutterColumns
    XCTAssertEqual(recess.width, CGFloat(45 + gutter * 2) * surface.cellWidth, accuracy: 0.51)
    let centre = surface.visibleRuns.indices.filter {
      surface.visibleRuns[$0].segment.alignment == .absoluteCentre
    }.map { surface.runFrames[$0] }.reduce(CGRect.null) { $0.union($1) }
    XCTAssertEqual(centre.minX - recess.minX, CGFloat(gutter) * surface.cellWidth, accuracy: 0.51)
    XCTAssertEqual(recess.maxX - centre.maxX, CGFloat(gutter) * surface.cellWidth, accuracy: 0.51)

    redraw(
      surface, source("Finder"), columns: columns, notchWidth: housingWidth(columns: housing))
    XCTAssertEqual(text(surface, .absoluteCentre), "Finder")
    XCTAssertEqual(
      try XCTUnwrap(surface.centreNotch.path).boundingBox.width,
      CGFloat(housing) * surface.cellWidth, accuracy: 0.51)
  }

  /// A centred `#[shrink]` label contracts (with an ellipsis) before either
  /// side lane's unmarked text loses a character.
  func testCentredShrinkLabelContractsBeforeASideLaneIsCut() throws {
    let columns = 100
    let lane = 30
    let surface = render(
      String(repeating: "L", count: lane) + "#[align=absolute-centre]#[shrink]"
        + String(repeating: "c", count: 40) + "#[noshrink]#[align=right]"
        + String(repeating: "R", count: lane),
      columns: columns, notchWidth: housingWidth(columns: 24))
    XCTAssertEqual(text(surface, .left), String(repeating: "L", count: lane))
    XCTAssertEqual(text(surface, .right), String(repeating: "R", count: lane))
    let margin = NativeStatusBarSurface.centreMarginColumns(cellWidth: surface.cellWidth)
    let centre = columns - 2 * (lane + margin) - NativeStatusBarSurface.centreGutterColumns * 2
    XCTAssertEqual(
      text(surface, .absoluteCentre), String(repeating: "c", count: centre - 1) + "…")
    try assertLanesClearTheRecess(surface)
  }

  /// Unmarked centred text is fixed while a lane's `#[shrink]` group can
  /// still give way.
  func testUnmarkedCentreStaysIntactWhileALaneGroupCanContract() throws {
    let label = "Unmarked centred application"
    let surface = render(
      "FEED #[shrink]" + String(repeating: "t", count: 80)
        + "#[noshrink]#[align=absolute-centre]\(label)#[align=right]CPU 10%",
      columns: 100, notchWidth: housingWidth(columns: 24))
    XCTAssertEqual(text(surface, .absoluteCentre), label)
    XCTAssertTrue(text(surface, .left).hasPrefix("FEED t"))
    XCTAssertTrue(text(surface, .left).hasSuffix("…"))
    XCTAssertEqual(text(surface, .right), "CPU 10%")
    try assertLanesClearTheRecess(surface)
  }

  /// The widest marked span gives way first, whichever section it is in;
  /// level spans then alternate in template order.
  func testLongestShrinkGroupContractsFirstAcrossCentreAndLane() {
    let surface = render(
      "F #[shrink]" + String(repeating: "t", count: 50)
        + "#[noshrink]#[align=absolute-centre]#[shrink]" + String(repeating: "a", count: 30)
        + "#[noshrink]#[align=right]" + String(repeating: "R", count: 20),
      columns: 90, notchWidth: housingWidth(columns: 24))
    XCTAssertEqual(
      NativeStatusBarSurface.centreMarginColumns(cellWidth: surface.cellWidth), 1)
    XCTAssertEqual(text(surface, .left), "F " + String(repeating: "t", count: 25) + "…")
    XCTAssertEqual(text(surface, .absoluteCentre), String(repeating: "a", count: 26) + "…")
    XCTAssertEqual(text(surface, .right), String(repeating: "R", count: 20))
  }

  /// The absolute centre owns its columns plus a gutter: side lanes with
  /// nothing elastic in them lose characters rather than reaching it.
  func testSideLanesTruncateBeforeReachingTheReservedCentre() throws {
    let columns = 60
    let surface = render(
      String(repeating: "L", count: 40)
        + "#[align=absolute-centre]CENTRE"
        + "#[align=right]" + String(repeating: "R", count: 40),
      columns: columns)
    let reserve = StatusBarOverflow.reserve(
      centre: 6,
      in: NativeStatusBarSurface.overflowGeometry(
        columns: columns, cellWidth: surface.cellWidth, notchWidth: 0, leftColumns: nil))
    XCTAssertEqual(reserve.count, 6 + NativeStatusBarSurface.centreGutterColumns * 2)
    let centre = try XCTUnwrap(surface.visibleRuns.firstIndex { $0.segment.text == "CENTRE" })
    let centreFrame = surface.runFrames[centre]
    for (index, run) in surface.visibleRuns.enumerated() where index != centre {
      let frame = surface.runFrames[index]
      XCTAssertTrue(
        frame.maxX <= centreFrame.minX || frame.minX >= centreFrame.maxX,
        "run \(run.segment.text) overlaps the reserved centre")
    }
    XCTAssertTrue(surface.layout.text.contains("CENTRE"))
  }

  /// With nothing marked, every section loses its own tail: the right lane
  /// used to lose its head ("…fghij") to keep the end away from the centre,
  /// and the default truncation point is now the end of each section.
  func testUnmarkedLanesLoseTheirOwnTail() {
    let document = StatusFormatDocument.parse(
      "ABCDEFGHIJ#[align=absolute-centre]C#[align=right]abcdefghij")
    func fitted(columns: Int) -> (texts: [String], reserve: Range<Int>) {
      let fitted = NativeStatusBarSurface.fitted(
        document,
        in: .init(
          columns: columns, housingColumns: 8, gutterColumns: 2, marginColumns: 0,
          minimumLaneColumns: 6))
      return (fitted.document.runs.filter { !$0.isStyleBoundary }.map(\.text), fitted.reserve)
    }
    let wide = fitted(columns: 30)
    XCTAssertEqual(wide.reserve, 11..<19)
    XCTAssertEqual(
      wide.texts, ["ABCDEFGHIJ", "C", "abcdefghij"], "lanes within budget are untouched")
    let narrow = fitted(columns: 20)
    XCTAssertEqual(narrow.reserve, 6..<14)
    XCTAssertEqual(
      narrow.texts, ["ABCDE…", "C", "abcde…"], "the centre within the housing is kept")
  }

  /// A template without an absolute centre reserves nothing.
  func testNoAbsoluteCentreReservesNothing() {
    let document = StatusFormatDocument.parse("LEFT#[align=centre]MID#[align=right]RIGHT")
    let fitted = NativeStatusBarSurface.fitted(
      document,
      in: NativeStatusBarSurface.overflowGeometry(
        columns: 40, cellWidth: 8, notchWidth: 185, leftColumns: nil))
    XCTAssertTrue(fitted.reserve.isEmpty)
    XCTAssertEqual(fitted.document.runs.map(\.text), document.runs.map(\.text))
  }

  /// A bar too narrow for both lanes and the centre gives the centre up rather
  /// than erasing a lane.
  func testNarrowBarDropsTheCentreReservationInsteadOfStarvingALane() {
    let document = StatusFormatDocument.parse("L#[align=absolute-centre]CENTRE#[align=right]R")
    func reserve(columns: Int) -> Range<Int> {
      NativeStatusBarSurface.fitted(
        document,
        in: NativeStatusBarSurface.overflowGeometry(
          columns: columns, cellWidth: 8, notchWidth: 0, leftColumns: nil)
      ).reserve
    }
    XCTAssertTrue(reserve(columns: 16).isEmpty)
    XCTAssertFalse(reserve(columns: 60).isEmpty)
  }

  private var cellWidth: CGFloat {
    ("M" as NSString).size(withAttributes: [
      .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    ]).width
  }

  /// A housing that occupies exactly `columns` cells of the test font.
  private func housingWidth(columns: Int) -> CGFloat {
    (CGFloat(columns) - 0.5) * cellWidth
  }

  /// The drawn text of one lane; the left lane includes the default one, and
  /// the blank fill (which carries the default alignment) is trimmed away.
  private func text(_ surface: NativeStatusBarSurface, _ alignment: StatusFormatAlignment)
    -> String
  {
    surface.visibleRuns.filter {
      $0.segment.alignment == alignment
        || (alignment == .left && $0.segment.alignment == .default)
    }.map(\.segment.text).joined().trimmingCharacters(in: .whitespaces)
  }

  /// Every side-lane glyph ends at least the notch margin short of the recess.
  private func assertLanesClearTheRecess(
    _ surface: NativeStatusBarSurface, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let recess = try XCTUnwrap(surface.centreNotch.path, file: file, line: line).boundingBox
    let margin =
      CGFloat(NativeStatusBarSurface.centreMarginColumns(cellWidth: surface.cellWidth))
      * surface.cellWidth
    for (index, run) in surface.visibleRuns.enumerated()
    where run.segment.alignment != .absoluteCentre {
      let text = run.segment.text
      guard let first = text.firstIndex(where: { !$0.isWhitespace }),
        let last = text.lastIndex(where: { !$0.isWhitespace })
      else { continue }
      let frame = surface.runFrames[index]
      let minX =
        frame.minX + CGFloat(text.distance(from: text.startIndex, to: first)) * surface.cellWidth
      let maxX =
        frame.minX + CGFloat(text.distance(from: text.startIndex, to: last) + 1) * surface.cellWidth
      XCTAssertTrue(
        maxX <= recess.minX - margin + 0.51 || minX >= recess.maxX + margin - 0.51,
        "'\(text)' spans \(minX)..<\(maxX) and crowds the recess \(recess)", file: file, line: line)
    }
  }

  private func render(
    _ source: String, columns: Int, notch: CGRect? = nil, notchWidth: CGFloat = 0
  ) -> NativeStatusBarSurface {
    let surface = NativeStatusBarSurface()
    redraw(surface, source, columns: columns, notch: notch, notchWidth: notchWidth)
    return surface
  }

  private func redraw(
    _ surface: NativeStatusBarSurface, _ source: String, columns: Int, notch: CGRect? = nil,
    notchWidth: CGFloat = 0,
    labels: Config.Mode.Labels = .init(normal: "N", insert: "INSERT", command: "COMMAND"),
    style: OverlayModeBadgeStyle = .normal
  ) {
    let modeText: String
    switch style {
    case .normal: modeText = labels.normal
    case .insert: modeText = labels.insert
    case .command: modeText = labels.command
    }
    redraw(
      surface, document: StatusFormatDocument.parse(source), columns: columns, notch: notch,
      notchWidth: notchWidth, labels: labels, style: style, modeText: modeText)
  }

  private func redraw(
    _ surface: NativeStatusBarSurface, document: StatusFormatDocument, columns: Int,
    notch: CGRect? = nil, notchWidth: CGFloat = 0,
    labels: Config.Mode.Labels = .init(normal: "N", insert: "INSERT", command: "COMMAND"),
    style: OverlayModeBadgeStyle = .normal, modeText: String
  ) {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let width =
      ("M" as NSString).size(withAttributes: [.font: font]).width * CGFloat(columns)
      + OverlayPanel.statusBarEdgePadding * 2 + 0.001
    let palette: OverlayPanel.ModeBadgePalette
    switch style {
    case .normal: palette = OverlayPanel.normalPalette
    case .insert: palette = OverlayPanel.insertPalette
    case .command: palette = OverlayPanel.commandPaletteValue
    }
    surface.render(
      document: document,
      barFrame: CGRect(x: 0, y: 0, width: width, height: 26),
      screenFrame: CGRect(x: 0, y: 0, width: width, height: 900),
      scale: 2, notch: notch, font: font,
      labels: labels,
      palette: palette, modeStyle: style, modeText: modeText, notchWidth: notchWidth)
  }
}
