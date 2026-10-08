import Foundation

/// What to do when macOS secure input stays on after the password field is
/// gone. Another process has to disable its own hold; Flash can only ask it
/// to (blur a browser field, or activate the app so it resigns). A field the
/// user is actually typing in is left alone.
enum SecureInputRelease {
  struct Holder: Equatable {
    var pid: pid_t
    var bundleID: String?
  }

  struct Focus: Equatable {
    var role: String?
    var subrole: String?
  }

  struct Snapshot: Equatable {
    var enabled: Bool
    var holders: [Holder]
    var frontmostPID: pid_t?
    var frontmostBundleID: String?
    var focused: Focus
    var runningBundleIDs: [String]
    var ownPID: pid_t
  }

  enum Kind: Equatable, CustomStringConvertible {
    /// Blur the focused element in each window. No activation. If the flag
    /// stays on, the driver then uses `addressBar`.
    case chromium
    /// The browser's Open Location shortcut, after that browser is frontmost.
    case addressBar
    /// Bring the app forward, then return to where the user was, so a
    /// background password manager drops a hold it took while inactive.
    case activate

    var description: String {
      switch self {
      case .chromium: "chromium"
      case .addressBar: "address_bar"
      case .activate: "activate"
      }
    }
  }

  struct Request: Equatable {
    var bundleID: String
    var kind: Kind
    /// App to restore after a release that had to take focus. Nil when the
    /// holder is already the frontmost app, or the front app has no bundle id.
    var returnTo: String?
    /// The user is in this app. The first sample can be the moment a password
    /// field took focus and has not published its role yet, so the machine
    /// waits for a second stuck sample before touching it.
    var frontmost: Bool
  }

  enum Decision: Equatable {
    case idle
    case legitimate
    case release([Request])
  }

  /// Chromium-family browsers whose AppleScript dictionary can blur the
  /// focused DOM node without activating the app.
  static let chromiumBundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.google.Chrome.beta",
    "com.google.Chrome.canary",
    "com.google.Chrome.dev",
    "com.brave.Browser",
    "com.brave.Browser.beta",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.Beta",
    "company.thebrowser.Browser",
    "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera",
    "com.operasoftware.OperaGX",
    "org.chromium.Chromium",
  ]

  /// Browsers that release a stuck hold when the address bar takes focus.
  static let addressBarBundleIDs: Set<String> = [
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
    "org.mozilla.nightly",
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
  ]

  /// Never activated. `com.apple.finder` is the app a frontmost holder is
  /// resigned through, so it cannot also be a release target.
  static let refusedBundleIDs: Set<String> = [
    "com.flash.app",
    "com.apple.finder",
    "com.apple.loginwindow",
    "com.apple.SecurityAgent",
    "com.apple.dock",
    "com.apple.SystemUIServer",
    "com.apple.controlcenter",
    "com.apple.notificationcenterui",
    "com.apple.WindowManager",
    "com.apple.TextInputMenuAgent",
    "com.apple.CharacterPaletteIM",
    "com.apple.Spotlight",
  ]

  static let finderBundleID = "com.apple.finder"

  /// Open Location. Sent only after the target browser is the frontmost app.
  static let addressBarScript = """
    tell application "System Events" to keystroke "l" using command down
    """

  static func decide(_ snapshot: Snapshot) -> Decision {
    guard snapshot.enabled else { return .idle }
    if isSecureField(snapshot.focused) { return .legitimate }
    if isTextEntry(snapshot.focused.role), !hasBackgroundHolder(snapshot) {
      return .legitimate
    }

    var requests: [Request] = []
    var seen = Set<String>()
    func append(_ bundleID: String, kind: Kind) {
      guard seen.insert(bundleID).inserted else { return }
      let front = bundleID == snapshot.frontmostBundleID
      requests.append(
        Request(
          bundleID: bundleID, kind: kind,
          returnTo: front ? nil : snapshot.frontmostBundleID, frontmost: front))
    }

    let holders = snapshot.holders.filter { $0.pid > 0 && $0.pid != snapshot.ownPID }
    let ordered =
      holders.filter { $0.pid != snapshot.frontmostPID }
      + holders.filter { $0.pid == snapshot.frontmostPID }
    for holder in ordered {
      guard let bundleID = holder.bundleID, let kind = kind(of: bundleID) else { continue }
      append(bundleID, kind: kind)
    }
    // The registry sometimes names loginwindow, or names nobody, while a
    // browser still holds the enable. Blurring a Chromium window does not
    // activate it. Activating some other running app would, so that stays
    // limited to a holder the registry actually named.
    if requests.isEmpty {
      for bundleID in snapshot.runningBundleIDs where chromiumBundleIDs.contains(bundleID) {
        append(bundleID, kind: .chromium)
      }
    }
    return .release(requests)
  }

  /// Nil when `bundleID` must not be interpolated into AppleScript.
  static func chromiumBlurScript(bundleID: String) -> String? {
    guard chromiumBundleIDs.contains(bundleID), isBundleID(bundleID) else { return nil }
    let blur = "if (document.activeElement) document.activeElement.blur()"
    return """
      tell application id "\(bundleID)"
        set n to count of windows
        if n is 0 then return
        if n > 8 then set n to 8
        repeat with i from 1 to n
          try
            tell active tab of window (i as integer) to execute javascript "\(blur)"
          end try
        end repeat
      end tell
      """
  }

  static func isBundleID(_ bundleID: String) -> Bool {
    guard let first = bundleID.utf8.first,
      (first >= 65 && first <= 90) || (first >= 97 && first <= 122)
    else { return false }
    return bundleID.utf8.allSatisfy { byte in
      (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
        || byte == 46 || byte == 45
    }
  }

  private static func kind(of bundleID: String) -> Kind? {
    if refusedBundleIDs.contains(bundleID) || !isBundleID(bundleID) { return nil }
    if chromiumBundleIDs.contains(bundleID) { return .chromium }
    if addressBarBundleIDs.contains(bundleID) { return .addressBar }
    return .activate
  }

  private static func isSecureField(_ focus: Focus) -> Bool {
    focus.role == "AXSecureTextField" || focus.subrole == "AXSecureTextField"
  }

  private static func isTextEntry(_ role: String?) -> Bool {
    switch role {
    case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
      return true
    default:
      return false
    }
  }

  /// A different app than the one in front holds secure input and is one
  /// Flash is willing to ask. A text field in front is then not the password.
  private static func hasBackgroundHolder(_ snapshot: Snapshot) -> Bool {
    snapshot.holders.contains { holder in
      holder.pid > 0 && holder.pid != snapshot.ownPID && holder.pid != snapshot.frontmostPID
        && holder.bundleID.flatMap(kind(of:)) != nil
    }
  }
}

/// One stuck episode. A release of only the frontmost app waits for a second
/// sample, so the tick where a password field has just taken focus — and has
/// not published a secure role yet — does not blur it. A background holder is
/// asked immediately. After that attempt, a frontmost hold still in the list
/// gets its own two samples. The flag dropping starts a new episode.
struct SecureInputFixMachine: Equatable {
  private enum Stage: Equatable {
    case ready
    case didBackground
    case done
  }

  private var stage = Stage.ready
  private var frontmostSamples = 0

  enum Outcome: Equatable {
    case wait
    case perform([SecureInputRelease.Request])
  }

  mutating func consider(_ decision: SecureInputRelease.Decision) -> Outcome {
    switch decision {
    case .idle:
      noteCleared()
      return .wait
    case .legitimate:
      frontmostSamples = 0
      return .wait
    case .release(let requests):
      return considerRelease(requests)
    }
  }

  mutating func noteCleared() {
    stage = .ready
    frontmostSamples = 0
  }

  private mutating func considerRelease(
    _ requests: [SecureInputRelease.Request]
  ) -> Outcome {
    switch stage {
    case .done:
      return .wait
    case .ready:
      if requests.isEmpty {
        stage = .done
        return .wait
      }
      let background = requests.filter { !$0.frontmost }
      if !background.isEmpty {
        stage = requests.contains(where: \.frontmost) ? .didBackground : .done
        frontmostSamples = 0
        return .perform(background)
      }
      return takeFrontmost(requests)
    case .didBackground:
      let foreground = requests.filter(\.frontmost)
      guard !foreground.isEmpty else {
        stage = .done
        return .wait
      }
      return takeFrontmost(foreground)
    }
  }

  private mutating func takeFrontmost(
    _ requests: [SecureInputRelease.Request]
  ) -> Outcome {
    frontmostSamples += 1
    guard frontmostSamples >= 2 else { return .wait }
    stage = .done
    frontmostSamples = 0
    return .perform(requests)
  }
}
