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
    XCTAssertNotNil(value.text.animation(forKey: crossfadeKey))
    XCTAssertNotNil(value.outgoing.animation(forKey: crossfadeKey))
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

  func testHoverWashFollowsSegmentsAndBarDrawsHairlineUnderTransparentRuns() {
    let surface = render("A #[fg=red]B#[default] C", columns: 10)
    let key = NativeStatusBarSurface.hoverAnimationKey
    XCTAssertEqual(surface.hoverHighlight.opacity, 0)
    surface.setHoverHighlight(CGRect(x: 20, y: 0, width: 30, height: 26))
    XCTAssertEqual(surface.hoverHighlight.opacity, 1)
    XCTAssertEqual(surface.hoverHighlight.frame.minX, 16)
    XCTAssertEqual(surface.hoverHighlight.frame.width, 38)
    XCTAssertNotNil(surface.hoverHighlight.animation(forKey: key))
    surface.setHoverHighlight(nil)
    XCTAssertEqual(surface.hoverHighlight.opacity, 0)
    let sublayers = surface.backgroundLayer.sublayers ?? []
    XCTAssertTrue(sublayers.first === surface.hairline)
    XCTAssertTrue(sublayers.dropFirst().first === surface.hoverHighlight)
    XCTAssertTrue(surface.runLayers.allSatisfy { $0.container.backgroundColor == nil })
    XCTAssertEqual(surface.hairline.frame.height, 0.5)
    XCTAssertEqual(surface.backgroundLayer.colors?.count, 2)
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
    let lineHeight = article.text.frame.height
    // The new line rises a full line height from below while fading in ...
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

  func testShrinkExtensionPreservesFixedSuffixBeforeNativeTrimming() {
    let surface = render("HN #[shrink]abcdefghijklmnopqrstuvwxyz#[noshrink] END", columns: 14)
    XCTAssertEqual(surface.layout.text, "HN abcdef… END")
    let native = render("abcdefghijklmnopqrstuvwxyz END", columns: 14)
    XCTAssertEqual(native.layout.text, "abcdefghijklmn")
  }

  private func render(_ source: String, columns: Int, notch: CGRect? = nil)
    -> NativeStatusBarSurface
  {
    let surface = NativeStatusBarSurface()
    redraw(surface, source, columns: columns, notch: notch)
    return surface
  }

  private func redraw(
    _ surface: NativeStatusBarSurface, _ source: String, columns: Int, notch: CGRect? = nil,
    labels: Config.Mode.Labels = .init(normal: "N", insert: "INSERT", command: "COMMAND"),
    style: OverlayModeBadgeStyle = .normal
  ) {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let width =
      ("M" as NSString).size(withAttributes: [.font: font]).width * CGFloat(columns)
      + OverlayPanel.statusBarEdgePadding * 2 + 0.001
    surface.render(
      document: StatusFormatDocument.parse(source),
      barFrame: CGRect(x: 0, y: 0, width: width, height: 26),
      screenFrame: CGRect(x: 0, y: 0, width: width, height: 900),
      scale: 2, notch: notch, font: font,
      labels: labels,
      palette: style == .insert ? OverlayPanel.insertPalette : OverlayPanel.normalPalette,
      modeStyle: style)
  }
}
