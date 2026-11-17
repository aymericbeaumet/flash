import AppKit
import FlashCore

/// What a media command asks for. Play, pause and skip are the function-row
/// keys (`key system --key=media_play`, `media_next`, `media_previous`); these
/// are the commands that need CoreAudio or a player's scripting.
enum MediaCommand: Hashable {
  case volumeUp
  case volumeDown
  case volumeMute
  /// List the devices (`query == nil`), or make the one whose name or UID is
  /// `query` the default.
  case device(AudioDeviceDirection, query: String?)
  case status

  var name: CommandName {
    switch self {
    case .volumeUp: return CommandName("volume", "up")
    case .volumeDown: return CommandName("volume", "down")
    case .volumeMute: return CommandName("volume", "mute")
    case .device(.input, _): return CommandName("audio", "input")
    case .device(.output, _): return CommandName("audio", "output")
    case .status: return CommandName("media", "status")
    }
  }

  var argTokens: [String] {
    guard case .device(_, let query?) = self else { return [] }
    return ["--device=\(query)"]
  }
}

/// What the resident shows once a media verb finished.
enum MediaOutcome: Equatable {
  /// The volume alert at this percent.
  case volume(Int)
  /// A banner: a device list, the selected device, what is playing.
  case message(String)
  /// Nothing to show.
  case done
  /// The verb did not run; the text says why.
  case failed(String)

  /// What the CLI prints and the command line shows: the alert's or the
  /// banner's text.
  var output: String? {
    switch self {
    case .volume(let percent): return "volume \(min(100, max(0, percent)))%"
    case .message(let text): return text
    case .done: return nil
    case .failed(let reason): return reason
    }
  }

  /// A volume step's alert is the feedback of a change, shown wherever it
  /// ran; an answer shows only when no caller presents it.
  var showsWherever: Bool {
    if case .volume = self { return true }
    return false
  }
}

enum MediaError: LocalizedError, Equatable {
  case deviceNotFound(String)
  case ambiguousDevice(String)

  var errorDescription: String? {
    switch self {
    case .deviceNotFound(let query): return "audio device not found: \(query)"
    case .ambiguousDevice(let query): return "audio device name is ambiguous, use its UID: \(query)"
    }
  }
}

/// A media app `media status` asks what it is playing, through its
/// AppleScript dictionary. Only a player already running is asked, so the
/// verb never launches one.
struct MediaPlayer: Equatable {
  let name: String
  let bundleID: String
  /// Its tracks name an artist; TV and Podcasts episodes do not.
  let hasArtist: Bool

  static let all = [
    MediaPlayer(name: "Spotify", bundleID: "com.spotify.client", hasArtist: true),
    MediaPlayer(name: "Music", bundleID: "com.apple.Music", hasArtist: true),
    MediaPlayer(name: "TV", bundleID: "com.apple.TV", hasArtist: false),
    MediaPlayer(name: "Podcasts", bundleID: "com.apple.podcasts", hasArtist: false),
  ]

  /// The players among the running `bundleIDs`, in `all`'s order.
  static func running(among bundleIDs: Set<String>) -> [MediaPlayer] {
    all.filter { bundleIDs.contains($0.bundleID) }
  }

  /// The player state, then the current track, one per line. A stopped
  /// player has no current track; the `try` keeps that from losing the
  /// state. The timeout bounds every Apple Event the script sends, and the
  /// `is running` check keeps a player that quit since it was listed from
  /// being launched to answer: the script then prints nothing.
  var nowPlayingScript: String {
    let track =
      hasArtist
      ? "name of current track & \" — \" & artist of current track"
      : "name of current track"
    return """
      if application id "\(bundleID)" is not running then return ""
      with timeout of 10 seconds
        tell application id "\(bundleID)"
          set playerState to player state as text
          set trackText to ""
          try
            set trackText to \(track)
          end try
          return playerState & linefeed & trackText
        end tell
      end timeout
      """
  }
}

/// One player's answer to `nowPlayingScript`.
struct MediaNowPlaying: Equatable {
  /// `playing`, `paused` or `stopped`.
  let state: String
  /// Empty when nothing is loaded.
  let track: String

  /// Nil without a state line.
  static func parse(_ output: String) -> MediaNowPlaying? {
    let lines = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    guard let state = lines.first.map({ String($0).trimmed.lowercased() }), !state.isEmpty
    else { return nil }
    return MediaNowPlaying(state: state, track: lines.count > 1 ? String(lines[1]).trimmed : "")
  }
}

/// The text the media verbs show. Pure, so the wording is tested without a
/// player or an audio device.
enum MediaReport {
  /// `media status`: one line per running player, then the output volume.
  static func status(
    players: [(player: MediaPlayer, nowPlaying: MediaNowPlaying?)], volume: OutputVolume?
  ) -> String {
    var lines = players.map { entry -> String in
      let line = "\(entry.player.name) [\(entry.nowPlaying?.state ?? "unknown")]"
      guard let track = entry.nowPlaying?.track, !track.isEmpty else { return line }
      return "\(line): \(track)"
    }
    if lines.isEmpty { lines.append("no media app is running") }
    if let volume {
      lines.append("volume \(volume.percent)%" + (volume.muted ? " (muted)" : ""))
    }
    return lines.joined(separator: "\n")
  }

  /// `audio input` / `audio output` without a device: the default marked `*`.
  static func devices(_ devices: [AudioDeviceRecord], direction: AudioDeviceDirection) -> String {
    guard !devices.isEmpty else { return "no audio \(direction.rawValue) devices" }
    return devices.map { "\($0.isDefault ? "* " : "  ")\($0.name) [\($0.uid)]" }
      .joined(separator: "\n")
  }

  /// The device `query` names: its UID, which is unique, or a name only one
  /// device has.
  static func device(
    matching query: String, in devices: [AudioDeviceRecord]
  ) -> Result<AudioDeviceRecord, MediaError> {
    if let device = devices.first(where: { $0.uid == query }) { return .success(device) }
    let named = devices.filter { $0.name == query }
    switch named.count {
    case 0: return .failure(.deviceNotFound(query))
    case 1: return .success(named[0])
    default: return .failure(.ambiguousDevice(query))
    }
  }
}

/// Runs the media verbs off the main thread. CoreAudio calls are synchronous
/// audio-server requests, and the now-playing Apple Events can wait on a
/// player or an Automation prompt, so each has its own serial queue: neither
/// holds the keyboard path, and a pending prompt does not hold the volume.
final class MediaController {
  private let audioQueue = DispatchQueue(label: "flash.media.audio", qos: .userInitiated)
  private let statusQueue = DispatchQueue(label: "flash.media.status", qos: .userInitiated)
  private let devices: any AudioDeviceProviding
  private let runningBundleIDs: () -> Set<String>
  private let runScript: (String) -> String?

  init(
    devices: any AudioDeviceProviding = CoreAudioDevices(),
    runningBundleIDs: @escaping () -> Set<String> = MediaController.runningBundleIDs,
    runScript: @escaping (String) -> String? = MediaController.runNowPlayingScript
  ) {
    self.devices = devices
    self.runningBundleIDs = runningBundleIDs
    self.runScript = runScript
  }

  /// Run `command` and hand its outcome to `completion` on main. A NORMAL
  /// count steps the volume that many ticks; other verbs run once.
  func perform(
    _ command: MediaCommand, repeatCount: Int = 1,
    completion: @escaping (MediaOutcome) -> Void
  ) {
    let queue = command == .status ? statusQueue : audioQueue
    queue.async { [self] in
      let outcome = outcome(of: command, repeatCount: repeatCount)
      DispatchQueue.main.async { completion(outcome) }
    }
  }

  /// Synchronous: CoreAudio and the players' scripting. Never on main.
  func outcome(of command: MediaCommand, repeatCount: Int = 1) -> MediaOutcome {
    do {
      switch command {
      case .volumeUp, .volumeDown:
        var percent = 0
        for _ in 0..<max(1, repeatCount) {
          percent = try devices.stepOutputVolume(up: command == .volumeUp)
        }
        return .volume(percent)
      case .volumeMute:
        try devices.toggleOutputMute()
        return .done
      case .device(let direction, nil):
        return .message(
          MediaReport.devices(try devices.list(direction: direction), direction: direction))
      case .device(let direction, let query?):
        let device = try MediaReport.device(
          matching: query, in: try devices.list(direction: direction)
        ).get()
        try devices.select(uid: device.uid, direction: direction)
        return .message("\(direction.rawValue) device: \(device.name)")
      case .status:
        let players = MediaPlayer.running(among: runningBundleIDs()).map { player in
          (
            player: player,
            nowPlaying: runScript(player.nowPlayingScript).flatMap(MediaNowPlaying.parse)
          )
        }
        return .message(MediaReport.status(players: players, volume: try? devices.outputVolume()))
      }
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// The script bounds each Apple Event to 10 seconds; this bounds the whole
  /// script a little later.
  static let nowPlayingTimeout: TimeInterval = 15

  /// A player's answer, without the trailing newline; nil when the script
  /// failed. In process, on the status queue.
  static func runNowPlayingScript(_ source: String) -> String? {
    let output = AppleScriptRunner.run(source, timeout: nowPlayingTimeout)
    if let failure = output.failure {
      FlashLog.warn("[media] \(failure)", source: "core:Media")
    }
    return output.resultText
  }

  /// The running apps' bundle IDs. `NSRunningApplication` reads are
  /// thread-safe, so this runs on the status queue.
  static func runningBundleIDs() -> Set<String> {
    Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
  }
}
