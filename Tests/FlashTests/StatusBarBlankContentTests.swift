import XCTest

@testable import flash

final class StatusBarBlankContentTests: XCTestCase {
  private let template = FlashStatusBarTemplate(
    template: """
      #[align=left]#[pill]#{flash.mode}#[nopill]#[fg=colour245] · #{flash.plugin.feed.summary}
      #[align=notch]#[popup=active-app]#[shrink]#{flash.focused_app_name}#[noshrink]#[nopopup]
      #[align=right]#{?flash.caffeinate,#[fg=#EBCB8B]AWAKE#[default] ,}
      #[popup=quota]#{flash.plugin.quota.label}#[nopopup]
      #[fg=colour245] · #{flash.plugin.sysinfo.cpu_label} #{flash.plugin.sysinfo.memory_label}
      #[fg=colour245] · #{?flash.caffeinate,,%a %b %-d }#[default]%H:%M
      """)

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
              focusedAppName: app, modeLabel: mode,
              now: Date(timeIntervalSince1970: 1_800_000_000)),
            dynamicValues: [
              "flash.plugin.feed.summary": feed,
              "flash.plugin.quota.label": "#[fg=green]Cld 99% Cdx 100%#[default]",
              "flash.plugin.sysinfo.cpu_label": "CPU 100%",
              "flash.plugin.sysinfo.memory_label": "MEM 99%",
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
      context: .init(focusedAppName: "Microsoft Visual Studio Code", modeLabel: "INSERT"),
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
        template: template, context: .init(focusedAppName: "Firefox", modeLabel: "INSERT"),
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
      document, pillColumns: 10, hideNotch: physicalNotch)
    let notch = (columns / 2 - 12)..<(columns / 2 + 12)
    let fitted = NativeStatusBarSurface.fitted(
      prepared,
      in: NativeStatusBarSurface.overflowGeometry(
        columns: columns, cellWidth: 8, notchWidth: OverlayPanel.defaultNotchWidth,
        leftColumns: physicalNotch ? notch.lowerBound : nil))
    let result = StatusFormatLayout.layout(fitted.document, columns: columns)
    let excluded: Range<CGFloat>?
    if physicalNotch {
      let start = OverlayPanel.statusBarEdgePadding + CGFloat(notch.lowerBound) * 8
      let end = OverlayPanel.statusBarEdgePadding + CGFloat(notch.upperBound) * 8
      excluded = start..<end
    } else {
      excluded = nil
    }
    return NativeStatusBarSurface.visibleRuns(result, cellWidth: 8, excluded: excluded)
  }

  /// An app names itself: its name and bundle identifier are text in the
  /// bar, never a style, a link a click would open, or a click range.
  func testTheFocusedAppNameIsTextNeverAStyleOrALink() {
    let template = FlashStatusBarTemplate(
      template: "#{flash.focused_app_name} #{flash.focused_app_bundle_id}")
    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: .init(
        focusedAppName: "#[link=file:///Applications/Terminal.app,range=user|x]Evil",
        focusedAppBundleID: "com.example.#[fg=red]app", modeLabel: "NORMAL",
        now: Date(timeIntervalSince1970: 1_800_000_000)))
    let runs = model.document.runs
    XCTAssertTrue(runs.allSatisfy { $0.link == nil }, "\(runs)")
    XCTAssertEqual(
      runs.map(\.text).joined(),
      "#[link=file:///Applications/Terminal.app,range=user|x]Evil com.example.#[fg=red]app")
  }
}
