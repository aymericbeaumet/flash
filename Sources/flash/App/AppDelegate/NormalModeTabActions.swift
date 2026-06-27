import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore

// Tab- and window-action surface for normal mode: `gN`, `[t`/`]t`, `[m`/`]m`,
// `T`, `t`, `x`, plus the per-bundle fallback keystrokes when no source claims
// the action. Pulled out of NormalModeCoordinator to keep the per-source
// dispatch + fallback policy in one place, separate from mode transitions
// and command-line bookkeeping.

extension AppDelegate {
  func tabSelectInNormalMode(index: Int) {
    let index = normalizedRepeatCount(index)
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for tab_select index=\(index)")
      applyModeOverlay()
      return
    }
    if let key = Self.nativeBrowserTabIndexKey(
      index: index,
      bundleIdentifier: context.bundleIdentifier)
    {
      sendNormalModeKey(key, flags: .maskCommand)
      return
    }
    registry.perform(.tabSelect(index: index), in: context) { [weak self] result in
      guard let self else { return }
      switch result.disposition {
      case .performed:
        if let pid = result.targetPID {
          self.normalModeTargetPID = pid
        }
        self.scheduleNormalModeRecapture()
      case .failed:
        FlashLog.warn(
          "[normal_mode] tab_select failed in claimed source "
            + "bundle=\(context.bundleIdentifier) index=\(index)")
        self.scheduleNormalModeRecapture()
      case .unhandled:
        guard let key = Self.tabIndexKeyCode(index) else {
          FlashLog.debug("[normal_mode] tab_select unsupported index=\(index)")
          self.applyModeOverlay()
          return
        }
        self.sendNormalModeKey(key, flags: .maskCommand)
      }
    }
  }

  func tabNextInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "tab_next",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.perform(.tabNext, in: context, completion: completion)
      },
      fallback: { [weak self] context, count in
        guard let self else { return }
        guard
          let shortcut = Self.tabTraversalFallbackShortcut(
            direction: .forward,
            bundleIdentifier: context.bundleIdentifier)
        else {
          FlashLog.debug(
            "[normal_mode] tab_next unsupported bundle=\(context.bundleIdentifier)")
          self.applyModeOverlay()
          return
        }
        self.sendNormalModeKey(shortcut.key, flags: shortcut.flags, repeatCount: count)
      })
  }

  func tabPrevInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "tab_previous",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.perform(.tabPrev, in: context, completion: completion)
      },
      fallback: { [weak self] context, count in
        guard let self else { return }
        guard
          let shortcut = Self.tabTraversalFallbackShortcut(
            direction: .back,
            bundleIdentifier: context.bundleIdentifier)
        else {
          FlashLog.debug(
            "[normal_mode] tab_previous unsupported bundle=\(context.bundleIdentifier)")
          self.applyModeOverlay()
          return
        }
        self.sendNormalModeKey(shortcut.key, flags: shortcut.flags, repeatCount: count)
      })
  }

  /// Jump to the last tab. Browsers map ⌘9 to "last tab" by convention
  /// (Chrome, Safari, Firefox), so for those bundles the fast path is a
  /// single synthesized ⌘9. Plugin-backed sources expose this through
  /// the `tab_last` source action (the tmux plugin uses `last-window`).
  func tabLastInNormalMode() {
    performTabSourceAction(
      name: "tab_last",
      repeatCount: 1,
      action: { registry, context, completion in
        registry.perform(.tabLast, in: context, completion: completion)
      },
      fallback: { [weak self] context, _ in
        if BrowserTabSources.allBundleIdentifiers.contains(context.bundleIdentifier) {
          self?.sendNormalModeKey(CGKeyCode(kVK_ANSI_9), flags: .maskCommand)
        } else {
          FlashLog.debug(
            "[normal_mode] tab_last unsupported bundle=\(context.bundleIdentifier)")
          self?.applyModeOverlay()
        }
      })
  }

  /// Reorder the focused window's current tab. Tmux runs `swap-window`
  /// across the source action; Firefox honours ⌘⇧Page Up/Down to slide
  /// the active tab inside its strip, so the host falls back to that
  /// chord when the plugin layer doesn't claim the action. Browsers
  /// without a portable shortcut (Safari, Chromium today) get a
  /// `warn`-level log naming the bundle so the user knows the mapping
  /// fired but couldn't reach the app — they can bind their own
  /// shortcut and override `[m`/`]m` in flash.toml.
  func tabMoveInNormalMode(direction: SourceTabDirection, repeatCount: Int) {
    let actionName = direction == .next ? "tab_move_next" : "tab_move_previous"
    performTabSourceAction(
      name: actionName,
      repeatCount: repeatCount,
      action: { registry, context, completion in
        if direction == .next {
          registry.perform(.tabMoveNext, in: context, completion: completion)
        } else {
          registry.perform(.tabMovePrev, in: context, completion: completion)
        }
      },
      fallback: { [weak self] context, count in
        guard let self else { return }
        if Self.bundleSupportsFirefoxStyleTabMove(context.bundleIdentifier) {
          let key: CGKeyCode =
            direction == .next
            ? CGKeyCode(kVK_PageDown) : CGKeyCode(kVK_PageUp)
          self.sendNormalModeKey(
            key, flags: [.maskCommand, .maskShift], repeatCount: count)
          return
        }
        FlashLog.warn(
          "[normal_mode] \(actionName) has no native shortcut on "
            + "bundle=\(context.bundleIdentifier); bind via a tab-mover "
            + "extension or override `[m`/`]m` in flash.toml")
        self.applyModeOverlay()
      })
  }

  /// Bundles whose tab strip honours `⌘⇧Page Up / ⌘⇧Page Down` for
  /// moving the focused tab left / right. Firefox (release +
  /// developer edition) is the canonical example; other Mozilla-based
  /// browsers inherit the same chord.
  private static let firefoxStyleTabMoveBundles: Set<String> = [
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
    "org.mozilla.nightly",
  ]

  static func bundleSupportsFirefoxStyleTabMove(_ bundleID: String) -> Bool {
    firefoxStyleTabMoveBundles.contains(bundleID)
  }

  /// Reopen the most recently closed tab. Cross-browser standard is
  /// ⌘⇧T; the plugin source action gets first refusal (tmux returns
  /// `.unhandled` because there's no concept of a closed tab to reopen)
  /// so the keystroke fallback only runs in non-terminal contexts that
  /// actually honour the chord.
  func tabReopenInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "tab_reopen",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.perform(.tabReopen, in: context, completion: completion)
      },
      fallback: { [weak self] context, count in
        if BrowserTabSources.allBundleIdentifiers.contains(context.bundleIdentifier) {
          self?.sendNormalModeKey(
            CGKeyCode(kVK_ANSI_T),
            flags: [.maskCommand, .maskShift],
            repeatCount: count)
        } else {
          FlashLog.debug(
            "[normal_mode] tab_reopen unsupported bundle=\(context.bundleIdentifier)")
          self?.applyModeOverlay()
        }
      })
  }

  func tabNewInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "tab_new",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.perform(.tabNew, in: context, completion: completion)
      },
      fallback: { [weak self] context, count in
        guard BrowserTabSources.allBundleIdentifiers.contains(context.bundleIdentifier) else {
          FlashLog.debug(
            "[normal_mode] tab_new unsupported bundle=\(context.bundleIdentifier)")
          self?.applyModeOverlay()
          return
        }
        self?.sendNormalModeKey(CGKeyCode(kVK_ANSI_T), flags: .maskCommand, repeatCount: count)
      })
  }

  func reloadInNormalMode(force: Bool, repeatCount: Int) {
    performTabSourceAction(
      name: force ? "app_reload_force" : "app_reload",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.perform(.reload(force: force), in: context, completion: completion)
      },
      fallback: { [weak self] context, count in
        guard
          let shortcut = Self.browserReloadFallbackShortcut(
            force: force,
            bundleIdentifier: context.bundleIdentifier)
        else {
          FlashLog.debug(
            "[normal_mode] app_reload unsupported bundle=\(context.bundleIdentifier)")
          self?.applyModeOverlay()
          return
        }
        self?.sendNormalModeKey(shortcut.key, flags: shortcut.flags, repeatCount: count)
      })
  }

  func archiveInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "resource_archive",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.perform(.archive, in: context, completion: completion)
      },
      fallback: { [weak self] context, _ in
        FlashLog.debug(
          "[normal_mode] resource_archive unsupported bundle=\(context.bundleIdentifier)")
        self?.applyModeOverlay()
      })
  }

  func resourceNavigationInNormalMode(direction: SourceTabDirection, repeatCount: Int) {
    let actionName = direction == .next ? "resource_next" : "resource_previous"
    let action: SourceAction = direction == .next ? .resourceNext : .resourcePrevious
    let fallbackScroll: NormalModeDispatcher.ScrollKind = direction == .next ? .down : .up
    performTabSourceAction(
      name: actionName,
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.perform(action, in: context, completion: completion)
      },
      fallback: { [weak self] _, count in
        self?.scrollNormalMode(fallbackScroll, repeatCount: count)
      })
  }

  func tabCloseInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "tab_close",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.perform(.tabClose, in: context, completion: completion)
      },
      fallback: { [weak self] _, count in
        self?.sendNormalModeKey(CGKeyCode(kVK_ANSI_W), flags: .maskCommand, repeatCount: count)
      })
  }

  /// `window_close` inside a terminal hosting tmux must close the *tmux*
  /// window, not the terminal's OS window — sending ⌘W to e.g. Alacritty
  /// quits the whole terminal, yanking the user out of the app and off
  /// their tmux session. Route through the tmux source action (it picks
  /// the next window in the same session itself) and only fall back to
  /// ⌘W for apps no source claims (browsers, native windows).
  func windowCloseInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "window_close",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.perform(.tabClose, in: context, completion: completion)
      },
      fallback: { [weak self] _, count in
        self?.sendNormalModeKey(CGKeyCode(kVK_ANSI_W), flags: .maskCommand, repeatCount: count)
      })
  }

  static let messagesBundleIdentifiers: Set<String> = [
    "com.apple.MobileSMS",
    "com.apple.Messages",
  ]

  static func browserReloadFallbackShortcut(
    force: Bool,
    bundleIdentifier: String
  ) -> (key: CGKeyCode, flags: CGEventFlags)? {
    guard BrowserTabSources.allBundleIdentifiers.contains(bundleIdentifier) else { return nil }
    if force, BrowserTabSources.safariBundleIdentifiers.contains(bundleIdentifier) {
      return (CGKeyCode(kVK_ANSI_R), [.maskCommand, .maskAlternate])
    }
    return (
      CGKeyCode(kVK_ANSI_R),
      force ? [.maskCommand, .maskShift] : .maskCommand
    )
  }

  func performTabSourceAction(
    name: String,
    repeatCount: Int,
    action:
      @escaping (
        SourceRegistry,
        AppContext,
        @escaping (SourceActionResult) -> Void
      ) -> Void,
    fallback: @escaping (AppContext, Int) -> Void
  ) {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for \(name)")
      applyModeOverlay()
      return
    }
    let count = normalizedRepeatCount(repeatCount)

    func attempt(_ remaining: Int) {
      guard remaining > 0 else {
        scheduleNormalModeRecapture()
        return
      }
      action(registry, context) { [weak self] result in
        guard let self else { return }
        switch result.disposition {
        case .performed:
          if let pid = result.targetPID {
            self.normalModeTargetPID = pid
          }
          attempt(remaining - 1)
        case .failed:
          // A source claimed the action but couldn't complete it. The
          // keystroke fallback must not fire here — see
          // `SourceActionResult.Disposition.failed`.
          FlashLog.warn(
            "[normal_mode] \(name) failed in claimed source bundle=\(context.bundleIdentifier)")
          self.scheduleNormalModeRecapture()
        case .unhandled:
          fallback(context, remaining)
        }
      }
    }

    attempt(count)
  }

  static func nativeBrowserTabIndexKey(index: Int, bundleIdentifier: String) -> CGKeyCode? {
    guard BrowserTabSources.allBundleIdentifiers.contains(bundleIdentifier) else { return nil }
    return tabIndexKeyCode(index)
  }

  static func tabTraversalFallbackShortcut(
    direction: NavigationDirection,
    bundleIdentifier: String
  ) -> (key: CGKeyCode, flags: CGEventFlags)? {
    if messagesBundleIdentifiers.contains(bundleIdentifier) {
      // macOS Sequoia+ rebound conversation traversal in Messages to
      // ⌘⇧]/⌘⇧[, matching the Safari/Notes convention. The earlier
      // Ctrl+Tab pair is no longer registered, which is why `[t`/`]t`
      // stopped switching discussions.
      let key: CGKeyCode =
        direction == .forward
        ? CGKeyCode(kVK_ANSI_RightBracket)
        : CGKeyCode(kVK_ANSI_LeftBracket)
      return (key, [.maskCommand, .maskShift])
    }
    if BrowserTabSources.allBundleIdentifiers.contains(bundleIdentifier) {
      let key: CGKeyCode =
        direction == .forward
        ? CGKeyCode(kVK_ANSI_RightBracket)
        : CGKeyCode(kVK_ANSI_LeftBracket)
      return (key, [.maskCommand, .maskShift])
    }
    return nil
  }

  private static func tabIndexKeyCode(_ index: Int) -> CGKeyCode? {
    switch index {
    case 1: return CGKeyCode(kVK_ANSI_1)
    case 2: return CGKeyCode(kVK_ANSI_2)
    case 3: return CGKeyCode(kVK_ANSI_3)
    case 4: return CGKeyCode(kVK_ANSI_4)
    case 5: return CGKeyCode(kVK_ANSI_5)
    case 6: return CGKeyCode(kVK_ANSI_6)
    case 7: return CGKeyCode(kVK_ANSI_7)
    case 8: return CGKeyCode(kVK_ANSI_8)
    case 9: return CGKeyCode(kVK_ANSI_9)
    default: return nil
    }
  }

}
