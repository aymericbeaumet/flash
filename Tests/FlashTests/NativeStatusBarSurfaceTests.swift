import AppKit
import XCTest

@testable import flash

final class NativeStatusBarSurfaceTests: XCTestCase {
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
    XCTAssertEqual(
      fill.runLayers[0].container.backgroundColor,
      FlashStatusTextColor.nsColor(.defaultBackground).cgColor)
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
    XCTAssertTrue(surface.runLayers[1].text.animation(forKey: kCATransition) is CATransition)
  }

  func testCarouselSlidesUpOnlyOnArticleChangesAndClearsWhenLayerBecomesAMetric() {
    let surface = render("NEWS #[cyc]first#[nocyc] CPU 10%", columns: 40)
    XCTAssertTrue(surface.runLayers.allSatisfy { $0.text.animation(forKey: kCATransition) == nil })
    redraw(surface, "NEWS #[cyc]second#[nocyc] CPU 20%", columns: 40)
    let article = surface.runLayers[1]
    let transition = article.text.animation(forKey: kCATransition) as? CATransition
    XCTAssertEqual(transition?.type, .push)
    XCTAssertEqual(transition?.subtype, .fromBottom)
    XCTAssertEqual(transition?.duration, 0.42)
    XCTAssertNil(surface.runLayers[0].text.animation(forKey: kCATransition))
    XCTAssertNil(surface.runLayers[2].text.animation(forKey: kCATransition))
    article.text.removeAllAnimations()
    article.effect.removeAllAnimations()
    redraw(surface, "NEWS #[cyc]second#[nocyc] CPU 30%", columns: 40)
    XCTAssertNil(article.text.animation(forKey: kCATransition))
    redraw(surface, "NEWS #[cyc]third#[nocyc] CPU 30%", columns: 40)
    XCTAssertNotNil(article.text.animation(forKey: kCATransition))
    redraw(surface, "NEWS #[fg=red]CPU 40%#[default] MEM 50%", columns: 40)
    XCTAssertTrue(surface.runLayers[1] === article)
    XCTAssertNil(article.text.animation(forKey: kCATransition))
    XCTAssertNil(article.effect.animation(forKey: kCATransition))
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
      let transition = surface.runLayers[index].text.animation(forKey: kCATransition) as? CATransition
      XCTAssertEqual(transition?.subtype, .fromBottom, surface.visibleRuns[index].segment.text)
    }
    let starts = cyclic.compactMap {
      surface.runLayers[$0].text.animation(forKey: kCATransition)?.beginTime
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
      XCTAssertNotNil(surface.runLayers[index].text.animation(forKey: kCATransition))
    }
    for index in surface.visibleRuns.indices where !surface.visibleRuns[index].segment.cycle {
      XCTAssertNil(surface.runLayers[index].text.animation(forKey: kCATransition))
    }
    for layer in surface.runLayers {
      layer.text.removeAllAnimations()
      layer.effect.removeAllAnimations()
    }
    redraw(surface, source("other", url: "https://example.com/b", popup: "feed-b"), columns: 60)
    for index in cyclic {
      XCTAssertNotNil(surface.runLayers[index].text.animation(forKey: kCATransition))
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
        XCTAssertNotNil(surface.runLayers[index].text.animation(forKey: kCATransition))
      } else {
        XCTAssertNil(surface.runLayers[index].text.animation(forKey: kCATransition))
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
