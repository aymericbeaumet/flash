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

  func testHeadlinePopupCarriesTheArticleLinkAndTheNamePopupDoesNot() throws {
    let surface = render(
      "#[popup=feed]#[link=https://aggr.example]aggr#[nolink]#[nopopup] "
        + "#[popup=feed-article]#[link=https://article.example/a]Headline#[nopopup]",
      columns: 40)
    let hits = surface.interactionRects(
      panelFrame: .zero, popupTexts: ["feed": "", "feed-article": ""], popupDocuments: [:])
    let name = try XCTUnwrap(hits.popups.first { $0.name == "feed" })
    let headline = try XCTUnwrap(hits.popups.first { $0.name == "feed-article" })
    XCTAssertEqual(name.link, "https://aggr.example")
    XCTAssertEqual(headline.link, "https://article.example/a")
    XCTAssertGreaterThan(headline.rect.minX, name.rect.maxX)
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

  func testPooledLayersDrawNativeListsFillAndNotchAtCellPositions() {
    for source in [
      "#[align=left,list=on]012345#[list=focus]678#[list=on]9ABCDEF"
        + "#[list=left-marker]<#[list=right-marker]>#[nolist]",
      "LLLL#[align=centre]CC#[align=right]RRRR#[align=notch]AB",
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
          accuracy: 0.01)
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

  func testPillPointSpacingKeepsRightAnchorAndUnrelatedNotch() {
    let right = render("#[align=right,pill]N#[nopill]tail", columns: 40)
    let index = right.visibleRuns.firstIndex { $0.segment.text == "tail" }!
    XCTAssertEqual(
      right.runLayers[index].container.frame.maxX,
      OverlayPanel.statusBarEdgePadding + CGFloat(right.availableColumns) * right.cellWidth,
      accuracy: 0.001)
    XCTAssertEqual(
      right.runLayers[index - 1].container.frame.maxX,
      right.runLayers[index].container.frame.minX, accuracy: 0.001)
    let plain = render("#[align=notch]CENTER", columns: 40)
    let pill = render("#[pill]N#[nopill] tail#[align=notch]CENTER", columns: 40)
    let plainIndex = plain.visibleRuns.firstIndex { $0.segment.text == "CENTER" }!
    let pillIndex = pill.visibleRuns.firstIndex { $0.segment.text == "CENTER" }!
    XCTAssertEqual(plain.runFrames[plainIndex], pill.runFrames[pillIndex])
  }

  func testNotchHidesTheNotchLaneAndClipsCellsOnTheHousing() {
    let notch = CGRect(x: 160, y: 0, width: 45, height: 30)
    let surface = render(
      "#[link=https://example.com]abcdefghijklmnopqrstuvwxyz0123456789"
        + "#[align=centre]HIDDEN#[align=notch]NOTCH#[align=right]RIGHT",
      columns: 50, notch: notch)
    let drawn = surface.visibleRuns.map(\.segment.text).joined()
    XCTAssertFalse(drawn.contains("NOTCH"), drawn)
    XCTAssertFalse(drawn.contains("HIDDEN"), drawn)
    XCTAssertTrue(drawn.contains("RIGHT"), drawn)
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
    let full = surface.visibleRuns.filter(\.segment.cycle).map(\.segment.text).joined()
    XCTAssertTrue(full.contains("…"), full)
    // The two side segments share the bar. A longer right value is cut inside
    // the right segment; it does not take columns from the article, and the
    // same article does not push.
    redraw(surface, source(right: "CPU 10% MEM 40% NET 1.2MiB"), columns: 50)
    let contracted = surface.visibleRuns.filter(\.segment.cycle).map(\.segment.text).joined()
    XCTAssertEqual(contracted, full)
    XCTAssertTrue(text(surface, .right).hasPrefix("…"))
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
    let surface = render("#[shrink]éé", columns: 2)
    XCTAssertEqual(surface.visibleRuns.first?.segment.text, "é")
    redraw(surface, "#[shrink]éé", columns: 1)
    XCTAssertEqual(surface.visibleRuns.first?.segment.text, "…")
    XCTAssertNil(surface.runLayers[0].text.animation(forKey: crossfadeKey))
    XCTAssertNil(surface.runLayers[0].outgoing.animation(forKey: crossfadeKey))
  }

  /// A right segment that gains a leading ellipsis is the same value cut
  /// shorter, so it snaps. The frame stays put because the tail still fills
  /// the segment.
  func testRightSegmentReBudgetSnapsInsteadOfCrossfading() {
    let surface = render("#[align=right]abcdefghij", columns: 10)
    XCTAssertEqual(text(surface, .right), "abcdefghij")
    redraw(surface, "#[align=right]abcdefghijk", columns: 10)
    XCTAssertEqual(text(surface, .right), "…cdefghijk")
    XCTAssertTrue(
      surface.runLayers.allSatisfy {
        $0.text.animation(forKey: crossfadeKey) == nil
          && $0.outgoing.animation(forKey: crossfadeKey) == nil
      })
  }

  func testTruncationEquivalenceIgnoresEllipsisAndTrailingSpaceOnly() {
    XCTAssertTrue(NativeStatusBarSurface.truncationEquivalent("Hello wor…", "Hello world"))
    XCTAssertTrue(NativeStatusBarSurface.truncationEquivalent("Hello world ", "Hello"))
    XCTAssertTrue(NativeStatusBarSurface.truncationEquivalent("", "Hello"))
    XCTAssertTrue(NativeStatusBarSurface.truncationEquivalent("…fghij", "abcdefghij"))
    XCTAssertTrue(NativeStatusBarSurface.truncationEquivalent("…234567890", "AB 1234567890"))
    XCTAssertFalse(NativeStatusBarSurface.truncationEquivalent("first", "other"))
    XCTAssertFalse(NativeStatusBarSurface.truncationEquivalent("Hello…", "Help"))
    XCTAssertFalse(NativeStatusBarSurface.truncationEquivalent(" Hello", "Hello"))
    XCTAssertTrue(StatusRunRenderer.onlyCutMoved("abcdefghij", "…bcdefghij"))
    XCTAssertTrue(StatusRunRenderer.onlyCutMoved("Hello world", "Hello wor…"))
    XCTAssertFalse(StatusRunRenderer.onlyCutMoved("abcdefghij", "xyz"))
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

  /// A full right lane on the 16-inch menu bar starts a fraction of a point
  /// inside a 6pt notch margin. That overlap used to discard the whole first
  /// glyph (the C of Cld). The 4pt default keeps it, still outside the housing.
  func testOnePointLessNotchMarginKeepsTheGlyphBesideTheHousing() throws {
    XCTAssertEqual(Config.StatusBar().notchMargin, 4)
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
    let screenWidth: CGFloat = 1728
    let notch = CGRect(x: 771, y: 0, width: 185, height: 32)
    let padding = OverlayPanel.statusBarEdgePadding
    let columns = Int((screenWidth - padding * 2) / cellWidth)
    let previous = FlashTunables.statusBarNotchMargin
    defer { FlashTunables.statusBarNotchMargin = previous }

    let boundary = (0..<columns).first { column in
      let x = padding + CGFloat(column) * cellWidth
      let overlap = notch.maxX + 6 - x
      return overlap > 0 && overlap < 1
    }
    let column = try XCTUnwrap(
      boundary, "the 16-inch housing no longer clips a cell by under a point")
    let text = "C" + String(repeating: "x", count: columns - column - 1)
    let document = StatusFormatDocument.parse("#[align=right]\(text)")

    func paint(margin: Double) -> NativeStatusBarSurface {
      FlashTunables.statusBarNotchMargin = margin
      let surface = NativeStatusBarSurface()
      surface.render(
        document: document,
        barFrame: CGRect(x: 0, y: 0, width: screenWidth, height: 32),
        screenFrame: CGRect(x: 0, y: 0, width: screenWidth, height: 1117),
        scale: 2, notch: notch, font: font,
        labels: .init(normal: "N", insert: "INSERT", command: "COMMAND"),
        palette: OverlayPanel.normalPalette, modeStyle: .normal, modeText: "N")
      return surface
    }

    let clipped = paint(margin: 6).visibleRuns.map(\.segment.text).joined()
    XCTAssertFalse(clipped.contains("C"), clipped)

    let kept = paint(margin: 4)
    let drawn = kept.visibleRuns.map(\.segment.text).joined()
    XCTAssertTrue(drawn.contains("C"), drawn)
    let index = try XCTUnwrap(kept.visibleRuns.firstIndex { $0.segment.text.contains("C") })
    let runText = kept.visibleRuns[index].segment.text
    let mark = try XCTUnwrap(runText.firstIndex(of: "C"))
    let offset = runText.distance(from: runText.startIndex, to: mark)
    let glyphX = kept.runFrames[index].minX + CGFloat(offset) * kept.cellWidth
    XCTAssertGreaterThanOrEqual(glyphX, notch.maxX)
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

  func testNotchDrawsARecessedNotchOfTheRealHousingWidth() throws {
    let columns = 60
    let notchWidth: CGFloat = 185
    let source =
      String(repeating: "L", count: 40) + "#[align=notch]CENTRE#[align=right]"
      + String(repeating: "R", count: 40)
    let surface = render(source, columns: columns, notchWidth: notchWidth)
    XCTAssertFalse(surface.centreNotch.isHidden)
    let notch = try XCTUnwrap(surface.centreNotch.path).boundingBox
    let bar = surface.backgroundLayer.frame
    let margin = OverlayPanel.statusBarNotchMargin
    let edge = OverlayPanel.statusBarEdgePadding
    XCTAssertEqual(notch.width, notchWidth, accuracy: 0.51)
    XCTAssertEqual(notch.midX, bar.midX, accuracy: 0.51)
    XCTAssertEqual(notch.height, bar.height, accuracy: 0.001)
    let centre = try XCTUnwrap(surface.visibleRuns.firstIndex { $0.segment.text == "CENTRE" })
    XCTAssertTrue(notch.contains(surface.runFrames[centre]))
    let left = try glyphSpan(surface, alignments: [.left, .default])
    let right = try glyphSpan(surface, alignments: [.right])
    XCTAssertEqual(left.minX, edge, accuracy: 0.01)
    // The fixture bar is a fraction over an integral column grid. The right
    // segment ends on that requested edge; the background layer is snapped.
    let requested = surface.cellWidth * CGFloat(columns) + edge * 2 + 0.001
    XCTAssertEqual(right.maxX, requested - edge, accuracy: 0.01)
    let leftGap = notch.minX - left.maxX
    let rightGap = right.minX - notch.maxX
    XCTAssertGreaterThanOrEqual(leftGap, margin - 0.51)
    XCTAssertGreaterThanOrEqual(rightGap, margin - 0.51)
    XCTAssertEqual(leftGap, rightGap, accuracy: 0.51, "the two notch gaps differ")
    for (index, run) in surface.visibleRuns.enumerated()
    where run.segment.alignment != .notch && !run.segment.text.allSatisfy(\.isWhitespace) {
      let frame = surface.runFrames[index]
      XCTAssertTrue(
        frame.maxX <= notch.minX - margin + 0.51 || frame.minX >= notch.maxX + margin - 0.51,
        "run '\(run.segment.text)' frame=\(frame) crowds the notch \(notch)")
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
    // A longer centre label is cut inside the housing. The recess stays the
    // housing width.
    redraw(
      surface,
      source.replacingOccurrences(
        of: "CENTRE", with: "A MUCH LONGER CENTRE LABEL THAT CANNOT FIT THE HOUSING"),
      columns: columns, notchWidth: notchWidth)
    let fixed = try XCTUnwrap(surface.centreNotch.path).boundingBox
    XCTAssertEqual(fixed.width, notch.width, accuracy: 0.001)
    let clipped = surface.visibleRuns.filter { $0.segment.alignment == .notch }
    XCTAssertTrue(clipped.contains { $0.segment.text.hasSuffix("…") })
    let interior =
      notchWidth
      - CGFloat(NativeStatusBarSurface.centreGutterColumns * 2) * surface.cellWidth
    XCTAssertLessThanOrEqual(
      clipped.reduce(0) { $0 + $1.columns },
      Int(floor(interior / surface.cellWidth)))
    // No centre, or a physical notch (which hides the centre): no recess.
    redraw(surface, "LEFT#[align=right]RIGHT", columns: columns, notchWidth: notchWidth)
    XCTAssertTrue(surface.centreNotch.isHidden)
    redraw(
      surface, source, columns: columns, notch: CGRect(x: 200, y: 0, width: 45, height: 30),
      notchWidth: notchWidth)
    XCTAssertTrue(surface.centreNotch.isHidden)
  }

  func testFeedLabelTitleAndDomainSlideAsOneArticle() throws {
    func line(_ title: String, _ domain: String, _ url: String) -> String {
      "#[fg=#EBCB8B]AGGR#[fg=colour245] #[cyc]#[link=\(url)]#[shrink]\(title)"
        + "#[noshrink] (\(domain))#[nolink]#[nocyc]"
    }
    let surface = render(
      line("Hi café", "one.example", "https://aggr.example/1"), columns: 80)
    let articleRuns = surface.visibleRuns.filter(\.segment.cycle)
    XCTAssertEqual(articleRuns.map(\.segment.text), ["Hi café (one.example)"])
    redraw(
      surface, line("A much longer headline", "two.example", "https://aggr.example/2"), columns: 80)
    let article = try XCTUnwrap(
      surface.visibleRuns.enumerated().first {
        $0.element.segment.cycle && $0.element.segment.text.contains("two.example")
      })
    XCTAssertTrue(article.element.segment.text.contains("A much longer headline"))
    XCTAssertEqual(surface.visibleRuns.filter(\.segment.cycle).count, 1)
    let layers = surface.runLayers[article.offset]
    let motion = try XCTUnwrap(layers.text.animation(forKey: cycleKey) as? CAAnimationGroup)
    let paths = (motion.animations ?? []).compactMap { ($0 as? CABasicAnimation)?.keyPath }
    XCTAssertTrue(paths.contains("transform.translation.y"))
    XCTAssertFalse(paths.contains("transform.translation.x"))
    XCTAssertNil(layers.container.animation(forKey: cycleKey))
    let outgoing = (layers.outgoing.string as? NSAttributedString)?.string ?? ""
    XCTAssertTrue(outgoing.contains("Hi café"))
    XCTAssertTrue(outgoing.contains("one.example"))
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

  /// Each segment is cut to its own width. An unmarked right segment starts
  /// with an ellipsis; a shrink span elsewhere does not spend the right
  /// segment's budget.
  func testUnmarkedRightSegmentStartsWithEllipsisInsideItsOwnWidth() {
    let right = "CPU 10% MEM 20% 12:34"
    let columns = 30
    let surface = render(
      "HN #[shrink]" + String(repeating: "a", count: 30) + "#[noshrink]#[align=right]" + right,
      columns: columns)
    XCTAssertTrue(text(surface, .left).hasSuffix("…"))
    XCTAssertTrue(text(surface, .left).hasPrefix("HN a"))
    XCTAssertTrue(text(surface, .right).hasPrefix("…"))
    XCTAssertTrue(text(surface, .right).hasSuffix("12:34"))
    XCTAssertFalse(text(surface, .right).contains(right))
  }

  /// A centred name stays inside the housing. A long one ends with an ellipsis;
  /// the recess keeps the housing width for a short name too.
  func testLongCentredLabelStaysInsideTheHousing() throws {
    let columns = 200
    let housing = housingWidth(columns: 24)
    let label = "Microsoft Visual Studio Code — flash (ab/dev)"
    XCTAssertEqual(label.count, 45)
    func source(_ label: String) -> String {
      "#[pill]N#[nopill] FEED#[align=notch]#[shrink]\(label)#[noshrink]"
        + "#[align=right]CPU 10% 12:34"
    }
    let surface = render(source(label), columns: columns, notchWidth: housing)
    XCTAssertTrue(text(surface, .notch).hasSuffix("…"))
    XCTAssertFalse(text(surface, .notch).contains(label))
    let recess = try XCTUnwrap(surface.centreNotch.path).boundingBox
    XCTAssertEqual(recess.width, housing, accuracy: 0.51)
    let centre = surface.visibleRuns.indices.filter {
      surface.visibleRuns[$0].segment.alignment == .notch
    }.map { surface.runFrames[$0] }.reduce(CGRect.null) { $0.union($1) }
    let gutter = CGFloat(NativeStatusBarSurface.centreGutterColumns) * surface.cellWidth
    XCTAssertGreaterThanOrEqual(centre.minX - recess.minX, gutter - 0.51)
    XCTAssertGreaterThanOrEqual(recess.maxX - centre.maxX, gutter - 0.51)
    XCTAssertEqual(centre.minX - recess.minX, recess.maxX - centre.maxX, accuracy: 0.51)

    redraw(surface, source("Finder"), columns: columns, notchWidth: housing)
    XCTAssertEqual(text(surface, .notch), "Finder")
    XCTAssertEqual(
      try XCTUnwrap(surface.centreNotch.path).boundingBox.width, housing, accuracy: 0.51)
  }

  /// A centred label longer than the housing ends with an ellipsis. Side
  /// segments that fit their own width are not cut to make the centre room.
  func testCentredLabelEndsWithEllipsisWithoutCuttingSideSegments() throws {
    let lane = 20
    let surface = render(
      String(repeating: "L", count: lane) + "#[align=notch]#[shrink]"
        + String(repeating: "c", count: 40) + "#[noshrink]#[align=right]"
        + String(repeating: "R", count: lane),
      columns: 120, notchWidth: housingWidth(columns: 24))
    XCTAssertEqual(text(surface, .left), String(repeating: "L", count: lane))
    XCTAssertEqual(text(surface, .right), String(repeating: "R", count: lane))
    XCTAssertTrue(text(surface, .notch).hasSuffix("…"))
    XCTAssertLessThan(text(surface, .notch).count, 40)
    try assertLanesClearTheRecess(surface)
  }

  /// A centre label that fits the housing stays whole while a side segment's
  /// last shrink span takes that segment's ellipsis.
  func testAFittingCentreStaysIntactWhileTheLaneShrinkIsCut() throws {
    let label = "Finder"
    let surface = render(
      "FEED #[shrink]" + String(repeating: "t", count: 80)
        + "#[noshrink]#[align=notch]\(label)#[align=right]CPU 10%",
      columns: 100, notchWidth: housingWidth(columns: 24))
    XCTAssertEqual(text(surface, .notch), label)
    XCTAssertTrue(text(surface, .left).hasPrefix("FEED t"))
    XCTAssertTrue(text(surface, .left).hasSuffix("…"))
    XCTAssertEqual(text(surface, .right), "CPU 10%")
    try assertLanesClearTheRecess(surface)
  }

  /// Two shrink spans in one segment: only the last one is cut. The other
  /// segment is cut to its own budget, not by whichever span is widest.
  func testOnlyTheLastShrinkInASegmentIsCut() {
    let surface = render(
      "F #[shrink]KEEP#[noshrink] #[shrink]" + String(repeating: "t", count: 80)
        + "#[noshrink] END#[align=notch]#[shrink]"
        + String(repeating: "a", count: 40)
        + "#[noshrink]#[align=right]" + String(repeating: "R", count: 12),
      columns: 140, notchWidth: housingWidth(columns: 24))
    let left = text(surface, .left)
    XCTAssertTrue(left.contains("KEEP"), left)
    XCTAssertTrue(left.hasSuffix("END") || left.contains("… END"), left)
    XCTAssertTrue(left.contains("…"), left)
    XCTAssertFalse(left.contains(String(repeating: "t", count: 80)), left)
    XCTAssertTrue(text(surface, .notch).hasSuffix("…"))
    XCTAssertEqual(text(surface, .right), String(repeating: "R", count: 12))
  }

  /// The absolute centre owns its columns plus a gutter: side lanes with
  /// nothing elastic in them lose characters rather than reaching it.
  func testSideLanesTruncateBeforeReachingTheReservedCentre() throws {
    let columns = 60
    let surface = render(
      String(repeating: "L", count: 40)
        + "#[align=notch]CENTRE"
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
        maxX <= centreFrame.minX || minX >= centreFrame.maxX,
        "run \(text) overlaps the reserved centre")
    }
    XCTAssertTrue(surface.layout.text.contains("CENTRE"))
  }

  /// With nothing marked, the left and the centre lose their ends and the right
  /// loses its head. A centre label inside the housing is kept.
  func testUnmarkedLanesCutAtTheirOwnEdge() {
    let document = StatusFormatDocument.parse(
      "ABCDEFGHIJ#[align=notch]C#[align=right]abcdefghij")
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
      narrow.texts, ["ABCDE…", "C", "…fghij"], "the centre within the housing is kept")
  }

  /// `#[align=centre]` reserves the same housing as `#[align=notch]`.
  func testCentreReservesTheSameHousingAsTheNotch() {
    let geometry = NativeStatusBarSurface.overflowGeometry(
      columns: 40, cellWidth: 8, notchWidth: 185, leftColumns: nil)
    let centre = NativeStatusBarSurface.fitted(
      StatusFormatDocument.parse("LEFT#[align=centre]MID#[align=right]RIGHT"), in: geometry)
    let notch = NativeStatusBarSurface.fitted(
      StatusFormatDocument.parse("LEFT#[align=notch]MID#[align=right]RIGHT"), in: geometry)
    XCTAssertEqual(centre.reserve, notch.reserve)
    XCTAssertEqual(centre.reserve.count, Int(ceil(185 / 8)))
    XCTAssertEqual(centre.document.runs.map(\.text), notch.document.runs.map(\.text))
  }

  /// The centred label and its recess stay at the middle of the bar. A wider
  /// right lane does not move either, and the same holds for `#[align=notch]`.
  func testTheNotchStaysAtTheMiddleWhenTheSidesDiffer() throws {
    let housing: CGFloat = 185
    for alignment in ["centre", "notch"] {
      func draw(_ right: String) -> NativeStatusBarSurface {
        render(
          "LEFT#[align=\(alignment)]APP#[align=right]\(right)",
          columns: 80, notchWidth: housing)
      }
      let balanced = draw("RIGHT")
      let heavy = draw(String(repeating: "R", count: 30))
      let lane: StatusFormatAlignment = alignment == "centre" ? .centre : .notch
      var recesses: [CGRect] = []
      for surface in [balanced, heavy] {
        XCTAssertFalse(surface.centreNotch.isHidden, alignment)
        let recess = try XCTUnwrap(surface.centreNotch.path).boundingBox
        XCTAssertEqual(recess.width, housing, accuracy: 0.51, alignment)
        XCTAssertEqual(
          recess.midX, surface.backgroundLayer.frame.midX, accuracy: 0.51, alignment)
        let label = try glyphSpan(surface, alignments: [lane])
        XCTAssertEqual(label.midX, recess.midX, accuracy: 0.51, alignment)
        XCTAssertEqual(text(surface, lane), "APP", alignment)
        try assertLanesClearTheRecess(surface)
        recesses.append(recess)
      }
      XCTAssertEqual(recesses[0].midX, recesses[1].midX, accuracy: 0.51, alignment)
      XCTAssertEqual(recesses[0].width, recesses[1].width, accuracy: 0.51, alignment)
    }
  }

  /// A bar too narrow for both lanes and the centre gives the centre up rather
  /// than erasing a lane.
  func testNarrowBarDropsTheCentreReservationInsteadOfStarvingALane() {
    let document = StatusFormatDocument.parse("L#[align=notch]CENTRE#[align=right]R")
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

  /// The glyph bounds of the given alignments, ignoring the blank fill.
  private func glyphSpan(
    _ surface: NativeStatusBarSurface, alignments: [StatusFormatAlignment]
  ) throws -> CGRect {
    var span = CGRect.null
    for (index, run) in surface.visibleRuns.enumerated()
    where alignments.contains(run.segment.alignment) {
      let text = run.segment.text
      guard let first = text.firstIndex(where: { !$0.isWhitespace }),
        let last = text.lastIndex(where: { !$0.isWhitespace })
      else { continue }
      let frame = surface.runFrames[index]
      let minX =
        frame.minX + CGFloat(text.distance(from: text.startIndex, to: first)) * surface.cellWidth
      let maxX =
        frame.minX + CGFloat(text.distance(from: text.startIndex, to: last) + 1) * surface.cellWidth
      span = span.union(CGRect(x: minX, y: 0, width: maxX - minX, height: 1))
    }
    return try XCTUnwrap(span.isNull ? nil : span)
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
    let margin = OverlayPanel.statusBarNotchMargin
    for (index, run) in surface.visibleRuns.enumerated()
    where run.segment.alignment != .notch && run.segment.alignment != .centre {
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
    case .hyper: modeText = labels.hyper
    case .visual: modeText = labels.visual
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
    case .hyper: palette = OverlayPanel.hyperPalette
    case .visual: palette = OverlayPanel.visualPalette
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
