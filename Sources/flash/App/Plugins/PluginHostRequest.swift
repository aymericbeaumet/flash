import CoreGraphics
import FlashCore
import Foundation

/// One plugin→host RPC, decoded from its wire params before anything runs.
/// Every method takes a closed set of params (`docs/schema/plugin/host.*`):
/// a key the method does not define, or a value of the wrong type, refuses
/// the call. `host.applescript` keeps its params as sent, because
/// `PluginAppleScriptOperation` closes them per operation.
enum PluginHostRequest {
  case ping
  case normalModeTarget
  case activate(pid: pid_t)
  /// `intervalMs` is as sent; the host clamps it when it posts.
  case postKeys(pid: pid_t, chords: [Chord], intervalMs: Int?)
  /// `text` is the URL as the plugin wrote it, which the allowlist reads.
  case fetch(url: URL, text: String)
  case wifiInfo(requestAuthorization: Bool)
  case open(OpenTarget)
  case appleScript([String: Any])
  case audio(Audio)
  case systemAction(HostSystemAction)
  /// `pid` is above 1: launchd, the caller's own group and every group are
  /// refused when the request is decoded.
  case processSignal(pid: pid_t, signal: HostProcessSignal)
  case ax(AX)

  typealias Chord = (key: CGKeyCode, flags: CGEventFlags)

  enum OpenTarget: Equatable {
    /// An absolute URL of any scheme but `file`.
    case url(URL)
    case app(bundleID: String)
  }

  /// One `host.audio_devices` operation (`protocol.json` `audio_devices`).
  enum Audio: Equatable {
    case list(AudioDeviceDirection)
    case select(AudioDeviceDirection, uid: String)
    /// Never zero, at most `maxVolumeTicks` either way.
    case stepVolume(ticks: Int)
    case toggleMute
    case volume

    /// The operation names, in contract order, each with the params it
    /// takes besides `operation`.
    static let operations: [(name: String, params: Set<String>)] = [
      ("list", ["direction"]), ("select", ["direction", "uid"]), ("step_volume", ["ticks"]),
      ("toggle_mute", []), ("volume", []),
    ]
  }

  /// The most ticks one `step_volume` moves: the whole scale.
  static let maxVolumeTicks = CoreAudioDevices.volumeTicks

  /// The Accessibility broker's calls. Handles are the broker's own.
  enum AX: Equatable {
    /// An empty `follow` and an absent `maxNodes` take the broker's defaults.
    case snapshot(
      pid: pid_t, follow: [String], collect: [String], pruneRoles: Set<String>, maxNodes: Int?)
    /// An absent `action` presses.
    case perform(handle: UInt64, action: String?)
    case set(handle: UInt64, attribute: String, value: Bool)
    case selectChild(parent: UInt64, child: UInt64)
  }

  /// The methods of `protocol.json` `plugin_to_host_rpcs`.
  enum Method: String, CaseIterable {
    case ping = "host.ping"
    case fetch = "host.fetch"
    case wifiInfo = "host.wifi_info"
    case appleScript = "host.applescript"
    case audioDevices = "host.audio_devices"
    case systemAction = "host.system_action"
    case processSignal = "host.process_signal"
    case normalModeTarget = "host.normal_mode_target"
    case activate = "host.activate"
    case open = "host.open"
    case postKeys = "host.post_keys"
    case axSnapshot = "host.ax_snapshot"
    case axPerform = "host.ax_perform"
    case axSet = "host.ax_set"
    case axSelectChild = "host.ax_select_child"

    /// The manifest capability a plugin holds to call it; `host.ping` is
    /// open to every plugin.
    var capability: PluginCapability? {
      switch self {
      case .ping: return nil
      case .fetch: return .networkFetch
      case .wifiInfo: return .wifiInfo
      case .appleScript: return .appleEvents
      case .audioDevices: return .audioDevices
      case .systemAction: return .systemActions
      case .processSignal: return .processSignal
      case .normalModeTarget, .activate: return .appControl
      case .open: return .open
      case .postKeys, .axSnapshot, .axPerform, .axSet, .axSelectChild: return .accessibility
      }
    }

    /// Every param the method defines. `host.applescript` has none here: its
    /// operation decides them.
    fileprivate var params: Set<String>? {
      switch self {
      case .ping, .normalModeTarget: return []
      case .fetch: return ["url"]
      case .wifiInfo: return ["request_authorization"]
      case .appleScript: return nil
      case .audioDevices: return ["operation", "direction", "uid", "ticks"]
      case .systemAction: return ["action"]
      case .processSignal: return ["pid", "signal"]
      case .activate: return ["pid"]
      case .open: return ["url", "bundle_id"]
      case .postKeys: return ["pid", "keys", "interval_ms"]
      case .axSnapshot: return ["pid", "follow", "collect", "max_nodes", "prune_roles"]
      case .axPerform: return ["handle", "action"]
      case .axSet: return ["handle", "attribute", "value"]
      case .axSelectChild: return ["parent", "child"]
      }
    }
  }

  /// Why a call is refused: the `error` of its `ok: false` reply.
  struct Refusal: Error, Equatable {
    let message: String
  }

  private static let chordKeys: Set<String> = ["key_code", "modifiers"]
  private static let modifiers: [String: CGEventFlags] = [
    "command": .maskCommand,
    "control": .maskControl,
    "option": .maskAlternate,
    "shift": .maskShift,
  ]
  static let maxChords = 32

  init(_ method: Method, params: [String: Any]) throws(Refusal) {
    let malformed = Refusal(message: "invalid \(method.rawValue) params")
    if let defined = method.params, !params.keys.allSatisfy(defined.contains) { throw malformed }
    /// An optional list of strings: absent is empty, anything else refuses.
    func strings(_ key: String) throws(Refusal) -> [String] {
      guard let raw = params[key] else { return [] }
      guard let list = raw as? [String] else { throw malformed }
      return list
    }
    func handle(_ key: String) -> UInt64? {
      PluginJSON.integer(params[key]).flatMap { UInt64(exactly: $0) }
    }
    switch method {
    case .ping:
      self = .ping
    case .normalModeTarget:
      self = .normalModeTarget
    case .appleScript:
      self = .appleScript(params)
    case .audioDevices:
      self = .audio(try Self.audio(params, malformed: malformed))
    case .systemAction:
      guard let name = params["action"] as? String, let action = HostSystemAction(rawValue: name)
      else { throw Refusal(message: "host.system_action requires a supported action") }
      self = .systemAction(action)
    case .processSignal:
      guard let pid = PluginJSON.pid(params["pid"]), pid > 1,
        let name = params["signal"] as? String, let signal = HostProcessSignal(rawValue: name)
      else {
        throw Refusal(message: "host.process_signal requires a pid above 1 and a supported signal")
      }
      self = .processSignal(pid: pid, signal: signal)
    case .activate:
      guard let pid = PluginJSON.pid(params["pid"]) else {
        throw Refusal(message: "host.activate requires pid")
      }
      self = .activate(pid: pid)
    case .fetch:
      guard let text = params["url"] as? String, let url = URLParsing.url(text),
        url.scheme == "https"
      else { throw Refusal(message: "host.fetch requires a valid https url param") }
      self = .fetch(url: url, text: text)
    case .wifiInfo:
      guard let flag = PluginJSON.boolean(params["request_authorization"]) else {
        throw Refusal(message: "host.wifi_info requires a boolean request_authorization param")
      }
      self = .wifiInfo(requestAuthorization: flag)
    case .open:
      self = .open(try Self.openTarget(params))
    case .postKeys:
      self = try Self.postKeys(params, malformed: malformed)
    case .axSnapshot:
      guard let pid = PluginJSON.pid(params["pid"]) else {
        throw Refusal(message: "host.ax_snapshot requires pid")
      }
      let maxNodes = PluginJSON.integer(params["max_nodes"])
      guard params["max_nodes"] == nil || maxNodes != nil else {
        throw Refusal(message: "invalid snapshot scalar params")
      }
      self = .ax(
        .snapshot(
          pid: pid, follow: try strings("follow"), collect: try strings("collect"),
          pruneRoles: Set(try strings("prune_roles")), maxNodes: maxNodes))
    case .axPerform:
      guard let handle = handle("handle") else {
        throw Refusal(message: "host.ax_perform requires handle")
      }
      let action = params["action"] as? String
      guard params["action"] == nil || action != nil else { throw malformed }
      self = .ax(.perform(handle: handle, action: action))
    case .axSet:
      guard let handle = handle("handle"), let attribute = params["attribute"] as? String else {
        throw Refusal(message: "host.ax_set requires handle and attribute")
      }
      guard let value = PluginJSON.boolean(params["value"]) else {
        throw Refusal(message: "host.ax_set value must be a bool")
      }
      self = .ax(.set(handle: handle, attribute: attribute, value: value))
    case .axSelectChild:
      guard let parent = handle("parent"), let child = handle("child") else {
        throw Refusal(message: "host.ax_select_child requires parent and child")
      }
      self = .ax(.selectChild(parent: parent, child: child))
    }
  }

  /// `host.audio_devices`: a known operation with exactly its own params.
  private static func audio(
    _ params: [String: Any], malformed: Refusal
  ) throws(Refusal) -> Audio {
    guard let name = params["operation"] as? String,
      let operation = Audio.operations.first(where: { $0.name == name })
    else { throw Refusal(message: "host.audio_devices requires a supported operation") }
    guard Set(params.keys).isSubset(of: operation.params.union(["operation"])) else {
      throw malformed
    }
    func direction() throws(Refusal) -> AudioDeviceDirection {
      guard let raw = params["direction"] as? String,
        let direction = AudioDeviceDirection(rawValue: raw)
      else {
        throw Refusal(message: "host.audio_devices requires an input or output direction")
      }
      return direction
    }
    switch name {
    case "list":
      return .list(try direction())
    case "select":
      let direction = try direction()
      guard let uid = params["uid"] as? String, !uid.isEmpty else {
        throw Refusal(message: "host.audio_devices select requires a non-empty uid")
      }
      return .select(direction, uid: uid)
    case "step_volume":
      guard let ticks = PluginJSON.integer(params["ticks"]), ticks != 0,
        abs(ticks) <= maxVolumeTicks
      else {
        throw Refusal(
          message:
            "host.audio_devices step_volume requires non-zero ticks from "
            + "-\(maxVolumeTicks) to \(maxVolumeTicks)")
      }
      return .stepVolume(ticks: ticks)
    case "toggle_mute":
      return .toggleMute
    default:
      return .volume
    }
  }

  /// `host.open` names one thing: a URL or an app.
  private static func openTarget(_ params: [String: Any]) throws(Refusal) -> OpenTarget {
    let missing = Refusal(message: "host.open requires url or bundle_id")
    guard params.count == 1 else { throw missing }
    if let bundleID = params["bundle_id"] as? String { return .app(bundleID: bundleID) }
    guard let text = params["url"] as? String, let url = URLParsing.url(text), url.scheme != nil
    else { throw missing }
    // Never a local file: a sandboxed plugin could write a `.command`, a
    // script or an app into its data directory, and LaunchServices would run
    // it outside the sandbox.
    guard url.scheme?.lowercased() != "file" else {
      throw Refusal(message: "host.open does not open local files")
    }
    return .url(url)
  }

  /// `host.post_keys`: 1 to 32 chords, each a key code under at least one
  /// modifier, so the call can never type text into the target.
  private static func postKeys(
    _ params: [String: Any], malformed: Refusal
  ) throws(Refusal) -> PluginHostRequest {
    let interval = PluginJSON.integer(params["interval_ms"])
    guard params["interval_ms"] == nil || interval != nil else {
      throw Refusal(message: "host.post_keys requires an integer interval_ms")
    }
    guard let pid = PluginJSON.pid(params["pid"]), let steps = params["keys"] as? [[String: Any]],
      !steps.isEmpty, steps.count <= maxChords
    else { throw Refusal(message: "host.post_keys requires pid and 1-\(maxChords) keys") }
    var chords: [Chord] = []
    for step in steps {
      guard step.keys.allSatisfy(chordKeys.contains) else { throw malformed }
      guard let code = PluginJSON.integer(step["key_code"]), code >= 0, code < 0x80,
        let names = step["modifiers"] as? [String], !names.isEmpty
      else { throw Refusal(message: "each key needs key_code and non-empty modifiers") }
      var flags: CGEventFlags = []
      for name in names {
        guard let flag = modifiers[name] else {
          throw Refusal(message: "unknown modifier: \(name)")
        }
        flags.insert(flag)
      }
      chords.append((key: CGKeyCode(code), flags: flags))
    }
    return .postKeys(pid: pid, chords: chords, intervalMs: interval)
  }
}
