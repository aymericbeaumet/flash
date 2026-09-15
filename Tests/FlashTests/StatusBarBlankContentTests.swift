import XCTest

@testable import flash

final class StatusBarBlankContentTests: XCTestCase {
  private let template = FlashStatusBarTemplate(
    template:
      "#[align=left]#{E:@left}#[align=absolute-centre]#{E:@centre}#[align=right]#{T:@right}",
    options: [
      "@left": """
      #[pill]#{flash.mode}#[nopill]#[fg=colour245] · #{flash.plugin.feed.summary}
      """,
      "@centre": """
      #[popup=active-app]#{=/23/…:flash.active_app_name}#[nopopup]
      """,
      "@right": """
      #{?flash.plugin.caffeinate.state,#[fg=#EBCB8B]AWAKE#[default] ,}
      #[popup=quota]#{flash.plugin.quota.label}#[nopopup]
      #[fg=colour245] · #{flash.plugin.cpu.label} #{flash.plugin.memory.label}
      #[fg=colour245] · #{?flash.plugin.caffeinate.state,,%a %b %-d }#[default]%H:%M
      """,
    ])

  func testDynamicOverflowAndNotchReservationsKeepVisibleModeText() {
    let feeds = [
      "",
      "HN Loading…",
      feed(title: "A short article"),
      feed(title: String(repeating: "A long dynamic article title ", count: 60)),
      feed(title: String(repeating: "👩‍💻 🇫🇷 新しい記事 ", count: 60)),
    ]
    for mode in ["INSERT", "NORMAL", "COMMAND", "TERMINAL"] {
      for app in ["Firefox", "Ghostty", "Microsoft Visual Studio Code"] {
        for (feedIndex, feed) in feeds.enumerated() {
          let model = FlashStatusBarTemplateEngine.render(
            template: template,
            context: .init(
              activeAppName: app, modeLabel: mode,
              now: Date(timeIntervalSince1970: 1_800_000_000)),
            dynamicValues: [
              "flash.plugin.feed.summary": feed,
              "flash.plugin.quota.label": "#[fg=green]Cld 99% Cdx 100%#[default]",
              "flash.plugin.cpu.label": "CPU 100%",
              "flash.plugin.memory.label": "MEM 99%",
            ])
          XCTAssertFalse(model.document.runs.contains { $0.text.contains("\n") })
          for columns in [90, 128, 180, 260] {
            for physicalNotch in [false, true] {
              let visible = layout(
                model.document, columns: columns, physicalNotch: physicalNotch)
              let modeText = visible.filter { $0.segment.pill }.map(\.segment.text).joined()
              XCTAssertEqual(
                modeText.trimmingCharacters(in: .whitespaces), mode,
                "mode=\(mode), app=\(app), feed=\(feedIndex), columns=\(columns), notch=\(physicalNotch)"
              )
              XCTAssertTrue(
                visible.contains { run in
                  !run.segment.hidden
                    && !run.segment.text.trimmingCharacters(in: .whitespaces).isEmpty
                })
              XCTAssertTrue(visible.allSatisfy { $0.columns > 0 })
            }
          }
        }
      }
    }
  }

  func testNarrowVirtualCenterSlotDoesNotBlankNonemptyContent() {
    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: .init(activeAppName: "Microsoft Visual Studio Code", modeLabel: "INSERT"),
      dynamicValues: [
        "flash.plugin.feed.summary": feed(title: String(repeating: "Overflow ", count: 100))
      ])
    for columns in [16, 20, 24, 32, 40, 60] {
      let visible = layout(model.document, columns: columns, physicalNotch: false)
      XCTAssertFalse(
        visible.map(\.segment.text).joined().trimmingCharacters(in: .whitespaces).isEmpty,
        "all text disappeared at \(columns) columns")
    }
  }

  func testRichPluginStylesCannotRetroactivelyHideTheModeLabel() {
    for markup in [
      "#[hidden]Hidden feed",
      "#[blink]Blinking feed",
      "#[breathing]Breathing feed",
      "#[fg=default,bg=default,reverse]Reverse feed",
      "#[fg=not-a-color]Malformed feed style",
    ] {
      let model = FlashStatusBarTemplateEngine.render(
        template: template, context: .init(activeAppName: "Firefox", modeLabel: "INSERT"),
        dynamicValues: ["flash.plugin.feed.summary": markup])
      let pill = layout(model.document, columns: 128, physicalNotch: false).filter {
        $0.segment.pill
      }
      XCTAssertEqual(
        pill.map(\.segment.text).joined().trimmingCharacters(in: .whitespaces), "INSERT")
      XCTAssertTrue(
        pill.allSatisfy {
          !$0.segment.hidden && !$0.segment.blink && !$0.segment.breathing
        })
    }
  }

  private func feed(title: String) -> String {
    "#[fg=#D8DEE9]HN#[fg=colour245] #[cyc]#[link=https://example.com/article]"
      + "#[shrink]\(title)#[noshrink]#[nolink] (example.com) "
      + "#[fg=#88C0D0]↗#[fg=colour245]#[nocyc]"
  }

  private func layout(
    _ document: StatusFormatDocument, columns: Int, physicalNotch: Bool
  ) -> [StatusFormatLayout.PositionedRun] {
    let prepared = NativeStatusBarSurface.preparedDocument(
      document, pillColumns: 10, hideCentre: physicalNotch)
    let reserve =
      physicalNotch
      ? (columns / 2 - 12)..<(columns / 2 + 12)
      : NativeStatusBarSurface.centreReservation(prepared, columns: columns)
    let shrunk = NativeStatusBarSurface.shrinkingDocument(
      prepared, columns: columns, reserve: reserve)
    let clamped = NativeStatusBarSurface.clampedLanes(shrunk, columns: columns, reserve: reserve)
    let result = StatusFormatLayout.layout(clamped, columns: columns)
    let excluded: Range<CGFloat>?
    if physicalNotch {
      let start = OverlayPanel.statusBarEdgePadding + CGFloat(reserve.lowerBound) * 8
      let end = OverlayPanel.statusBarEdgePadding + CGFloat(reserve.upperBound) * 8
      excluded = start..<end
    } else {
      excluded = nil
    }
    return NativeStatusBarSurface.visibleRuns(result, cellWidth: 8, excluded: excluded)
  }
}
