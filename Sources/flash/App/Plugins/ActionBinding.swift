import ApplicationServices
import CoreGraphics
import FlashCore
import FlashProviders

/// One `action_bindings` value as a manifest declares it: what an app does
/// for a Flash action. A closed union, validated when the manifest loads.
///
/// - `"cmd+t"` — one chord;
/// - `["cmd+k", "cmd+w"]` — chords sent in order;
/// - `{ "menu": ["File", "New Tab"] }` — press that menu-bar item;
/// - `false` — the app has no such action, so nothing happens.
///
/// `tab_select` values may name the tab with `{index}` (`"cmd+{index}"`).
enum ActionBindingSpec: Hashable, Decodable {
  case chords([String])
  case menu([String])
  case unbound

  static let indexPlaceholder = "{index}"

  init(from decoder: Decoder) throws {
    let single = try decoder.singleValueContainer()
    if let flag = try? single.decode(Bool.self) {
      guard !flag else {
        throw Self.malformed(decoder, "true is not a binding; use false for none")
      }
      self = .unbound
    } else if let chord = try? single.decode(String.self) {
      self = .chords([chord])
    } else if let chords = try? single.decode([String].self) {
      self = .chords(chords)
    } else if let object = try? single.decode([String: [String]].self) {
      guard object.count == 1, let path = object["menu"] else {
        throw Self.malformed(decoder, "the only object form is {\"menu\": [titles]}")
      }
      self = .menu(path)
    } else {
      throw Self.malformed(
        decoder, "expected a chord, an array of chords, {\"menu\": [titles]} or false")
    }
  }

  private static func malformed(_ decoder: Decoder, _ message: String) -> Error {
    DecodingError.dataCorrupted(
      DecodingError.Context(codingPath: decoder.codingPath, debugDescription: message))
  }

  /// Why this value is invalid for `action`, or nil when it is valid.
  func validationError(for action: SourceActionName) -> String? {
    let strings: [String]
    switch self {
    case .unbound:
      return nil
    case .chords(let chords):
      guard !chords.isEmpty else { return "an empty chord array" }
      strings = chords
    case .menu(let path):
      guard path.count >= 2 else { return "a menu path needs the menu and the item title" }
      guard !path.contains(where: { $0.trimmed.isEmpty }) else { return "an empty menu title" }
      strings = path
    }
    if action != .tabSelect, strings.contains(where: { $0.contains(Self.indexPlaceholder) }) {
      return "\(Self.indexPlaceholder) outside tab_select"
    }
    if case .chords(let chords) = self {
      for chord in chords where binding(chord, index: 1) == nil {
        return chord.isEmpty ? "an empty chord (use false for none)" : "not a chord: \(chord)"
      }
    }
    return nil
  }

  /// The binding to dispatch; `index` fills `{index}` (tab_select). A chord
  /// that doesn't exist for that index (`cmd+10`) leaves nothing to send.
  func binding(index: Int? = nil) -> ActionBinding {
    switch self {
    case .unbound:
      return .unbound
    case .chords(let chords):
      let parsed = chords.compactMap { binding($0, index: index ?? 1) }
      return parsed.count == chords.count ? .chords(parsed) : .unbound
    case .menu(let path):
      return .menu(path.map { Self.substitute($0, index: index ?? 1) })
    }
  }

  private func binding(_ chord: String, index: Int) -> ParsedHotkey? {
    HotkeySyntax.parse(hotkey: Self.substitute(chord, index: index))
  }

  private static func substitute(_ value: String, index: Int) -> String {
    value.replacingOccurrences(of: indexPlaceholder, with: String(index))
  }

  /// The binding as a user reads it: `cmd+t`, `cmd+k, cmd+w`,
  /// `menu File › New Tab`, `none`.
  var display: String {
    switch self {
    case .chords(let chords): return chords.joined(separator: ", ")
    case .menu(let path): return "menu " + path.joined(separator: " › ")
    case .unbound: return "none"
    }
  }
}

/// A binding resolved for one dispatch.
enum ActionBinding: Hashable {
  case chords([ParsedHotkey])
  case menu([String])
  case unbound
}

/// One chord to post: a virtual key and its modifier flags.
struct ActionChord: Equatable {
  let key: CGKeyCode
  let flags: CGEventFlags

  init(key: CGKeyCode, flags: CGEventFlags) {
    self.key = key
    self.flags = flags
  }

  init(_ hotkey: ParsedHotkey) {
    self.init(key: hotkey.keyCode, flags: hotkey.eventFlags)
  }
}

/// Presses a menu-bar item of an app by its title path. AX IPC: never on the
/// main thread.
protocol MenuPathPresser {
  func press(_ path: [String], pid: pid_t) -> Bool
}

/// What the host does with a resolved binding, and the one place that runs a
/// menu press. Chords are posted by `AppDelegate.postNormalModeChords`.
enum ActionBindingDispatch: Equatable {
  case sendChords([ActionChord])
  case pressMenu([String])
  /// A terminal would type one of the chords as text.
  case refused
  /// The app has no such action.
  case unavailable

  /// `typesText` is the terminal rule for the receiving app: a sequence one
  /// chord of which would become stray terminal text is refused whole. A
  /// menu press types nothing, so it is never refused.
  static func plan(
    _ binding: ActionBinding, typesText: (CGKeyCode, CGEventFlags) -> Bool
  ) -> ActionBindingDispatch {
    switch binding {
    case .unbound:
      return .unavailable
    case .menu(let path):
      return .pressMenu(path)
    case .chords(let hotkeys):
      let chords = hotkeys.map(ActionChord.init)
      guard !chords.contains(where: { typesText($0.key, $0.flags) }) else { return .refused }
      return .sendChords(chords)
    }
  }

  /// Presses `path` in `pid` `repeatCount` times on `queue`; `completion`
  /// runs on main with whether every press succeeded. A failed press ends the
  /// run: the app has no such item now (renamed, disabled, another language).
  static func pressMenu(
    _ path: [String],
    pid: pid_t,
    repeatCount: Int,
    presser: MenuPathPresser,
    queue: DispatchQueue,
    completion: @escaping (Bool) -> Void
  ) {
    queue.async {
      var ok = true
      for _ in 0..<max(1, repeatCount) where ok {
        ok = presser.press(path, pid: pid)
      }
      DispatchQueue.main.async { completion(ok) }
    }
  }
}

/// Walks the app's menu bar by title — the bar item, then each nested menu's
/// item — and presses the last one when it is enabled.
struct AXMenuPathPresser: MenuPathPresser {
  func press(_ path: [String], pid: pid_t) -> Bool {
    guard let barTitle = path.first else { return false }
    let app = AXApp.make(pid: pid)
    guard
      var element = MenuBarSource.menuBarItems(of: app).first(where: {
        Self.title(of: $0) == barTitle
      })
    else { return false }
    for title in path.dropFirst() {
      // A bar item or submenu item holds one AXMenu whose children are items.
      let items = AXAttribute.children(element).flatMap { child in
        Self.role(of: child) == kAXMenuRole as String ? AXAttribute.children(child) : [child]
      }
      guard let item = items.first(where: { Self.title(of: $0) == title }) else { return false }
      element = item
    }
    guard Self.isEnabled(element) else { return false }
    return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
  }

  private static func title(of element: AXUIElement) -> String? {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &raw) == .success
    else { return nil }
    return (raw as? String)?.trimmingCharacters(in: .whitespaces)
  }

  private static func role(of element: AXUIElement) -> String? {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw) == .success
    else { return nil }
    return raw as? String
  }

  private static func isEnabled(_ element: AXUIElement) -> Bool {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &raw) == .success
    else { return true }
    return (raw as? Bool) ?? true
  }
}
