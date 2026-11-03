import AppKit
import XCTest

@testable import flash

/// The core audio and now-playing verbs: parsing, the command line, and what
/// `MediaController` decides against a stubbed CoreAudio and player set. No
/// test touches the Mac's real devices, players or event stream.
final class MediaCommandTests: XCTestCase {
  private final class StubDevices: AudioDeviceProviding {
    var devices: [AudioDeviceDirection: [AudioDeviceRecord]] = [:]
    var selected: [(uid: String, direction: AudioDeviceDirection)] = []
    var steps: [Bool] = []
    var muteToggles = 0
    var percent = 50
    var volume = OutputVolume(percent: 44, muted: false)
    var failure: Error?

    func list(direction: AudioDeviceDirection) throws -> [AudioDeviceRecord] {
      if let failure { throw failure }
      return devices[direction] ?? []
    }
    func select(uid: String, direction: AudioDeviceDirection) throws {
      selected.append((uid, direction))
    }
    func stepOutputVolume(up: Bool) throws -> Int {
      if let failure { throw failure }
      steps.append(up)
      percent += up ? 6 : -6
      return percent
    }
    func toggleOutputMute() throws { muteToggles += 1 }
    func outputVolume() throws -> OutputVolume { volume }
  }

  private let outputs = [
    AudioDeviceRecord(uid: "usb-1", name: "USB Audio", isDefault: true),
    AudioDeviceRecord(uid: "usb-2", name: "USB Audio", isDefault: false),
    AudioDeviceRecord(uid: "speakers", name: "Studio Speakers", isDefault: false),
  ]

  func testCommandsParseAndRoundTripTheirArguments() {
    let cases: [(String, URLCommand)] = [
      ("volume up", .media(.volumeUp)),
      ("volume down", .media(.volumeDown)),
      ("volume mute", .media(.volumeMute)),
      ("audio input", .media(.device(.input, query: nil))),
      ("audio output", .media(.device(.output, query: nil))),
      ("audio output --device=speakers", .media(.device(.output, query: "speakers"))),
      ("media status", .media(.status)),
    ]
    for (text, command) in cases {
      let words = text.split(separator: " ").map(String.init)
      XCTAssertEqual(parseMappingCommand(argv: ["flash"] + words), .flashCommand(command), text)
      XCTAssertEqual(command.diagnosticDescription, "flash " + text)
    }
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "audio", "input", "--device=Studio Microphone"]),
      .flashCommand(.media(.device(.input, query: "Studio Microphone"))))
    for invalid in [
      ["volume", "up", "--steps=2"], ["audio", "output", "--device="],
      ["audio", "output", "--device= "], ["audio", "input", "--name=Mic"],
      ["media", "status", "--json"],
    ] {
      XCTAssertNil(parseMappingCommand(argv: ["flash"] + invalid), "\(invalid)")
    }
  }

  /// The plugin's words are gone, with no alias: playback is the
  /// function-row keys, everything else a core command.
  func testRetiredMediaPluginWordsAreRejected() {
    for argv in [
      ["flash", "media", "volumedown"], ["flash", "media", "output", "USB"],
      ["flash", "media", "toggle"], ["flash", "media_play"], ["flash", "media_toggle"],
      ["flash", "media_next"],
    ] {
      XCTAssertNil(parseMappingCommand(argv: argv), "\(argv)")
    }
    XCTAssertFalse(PluginRepository.declaresCommand("media"))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "key", "system", "--key=media_play"]),
      .flashCommand(.systemKey(.mediaPlay)))
  }

  func testCommandLineRunsTheCommandsAndKeepsDeviceNamesWhole() {
    let cases: [(String, URLCommand)] = [
      (":volume up", .media(.volumeUp)),
      (":media status", .media(.status)),
      (":audio output", .media(.device(.output, query: nil))),
      (
        ":audio output --device=Studio Speakers",
        .media(.device(.output, query: "Studio Speakers"))
      ),
      (":key system --key=media_next", .systemKey(.mediaNext)),
      (":popup quit --name=btop", .popupQuit(name: "btop")),
    ]
    for (text, command) in cases {
      XCTAssertEqual(NormalModeDispatcher.commandLineCoreCommand(text), command, text)
    }
    for invalid in [
      ":audio output Studio", ":volume up now", ":audio output --device=",
      ":media volumedown", ":key system",
    ] {
      XCTAssertNil(NormalModeDispatcher.commandLineCoreCommand(invalid), invalid)
    }
  }

  func testCommandLineCompletesTheCommands() throws {
    let topic = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":vol", pluginCommands: [], pluginSubcommands: [:]))
    XCTAssertEqual(
      topic.items, [.init(label: "volume", insertion: "volume ", kind: .acceptsArgs)])
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":volume ", pluginCommands: [], pluginSubcommands: [:]))
    XCTAssertEqual(context.items.map(\.label), ["down", "mute", "up"])
    XCTAssertTrue(context.items.allSatisfy { $0.kind == .pluginSubcommand })
    let key = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":key sy", pluginCommands: [], pluginSubcommands: [:]))
    XCTAssertTrue(
      key.items.contains(.init(label: "system", insertion: "system ", kind: .acceptsArgs)),
      "a required --key keeps the line open")
    let catalog = NormalModeDispatcher.coreCommandCatalog().compactMap { $0["name"] as? String }
    XCTAssertTrue(catalog.contains(":audio output"))
    XCTAssertTrue(catalog.contains(":caffeinate toggle"))
  }

  func testVolumeStepsShowThePercentAndFollowTheCount() {
    let devices = StubDevices()
    let controller = MediaController(
      devices: devices, runningBundleIDs: { [] }, runScript: { _ in nil })
    XCTAssertEqual(controller.outcome(of: .volumeUp), .volume(56))
    XCTAssertEqual(controller.outcome(of: .volumeDown, repeatCount: 3), .volume(38))
    XCTAssertEqual(devices.steps, [true, false, false, false])
    XCTAssertEqual(controller.outcome(of: .volumeMute), .done)
    XCTAssertEqual(devices.muteToggles, 1)
    devices.failure = AudioDeviceError.unsupported("output volume")
    XCTAssertEqual(
      controller.outcome(of: .volumeUp), .failed("audio device does not support output volume"))
  }

  func testDevicesListAndSelectByUIDOrUniqueName() {
    let devices = StubDevices()
    devices.devices[.output] = outputs
    let controller = MediaController(
      devices: devices, runningBundleIDs: { [] }, runScript: { _ in nil })
    XCTAssertEqual(
      controller.outcome(of: .device(.output, query: nil)),
      .message("* USB Audio [usb-1]\n  USB Audio [usb-2]\n  Studio Speakers [speakers]"))
    XCTAssertEqual(
      controller.outcome(of: .device(.input, query: nil)), .message("no audio input devices"))
    XCTAssertEqual(
      controller.outcome(of: .device(.output, query: "Studio Speakers")),
      .message("output device: Studio Speakers"))
    XCTAssertEqual(
      controller.outcome(of: .device(.output, query: "usb-2")),
      .message("output device: USB Audio"))
    XCTAssertEqual(devices.selected.map(\.uid), ["speakers", "usb-2"])
    XCTAssertEqual(devices.selected.map(\.direction), [.output, .output])
    XCTAssertEqual(
      controller.outcome(of: .device(.output, query: "USB Audio")),
      .failed(MediaError.ambiguousDevice("USB Audio").localizedDescription))
    XCTAssertEqual(
      controller.outcome(of: .device(.output, query: "missing")),
      .failed("audio device not found: missing"))
    XCTAssertEqual(devices.selected.count, 2, "a failed match selects nothing")
  }

  /// Only a running player is asked, so `media status` never launches one.
  func testStatusAsksOnlyRunningPlayersAndReportsTheVolume() {
    let devices = StubDevices()
    devices.volume = OutputVolume(percent: 31, muted: true)
    var asked: [String] = []
    let controller = MediaController(
      devices: devices,
      runningBundleIDs: { ["com.apple.Music", "com.spotify.client", "com.apple.Safari"] },
      runScript: { script in
        asked.append(script)
        return script.contains("com.spotify.client")
          ? "playing\nOne More Time — Daft Punk" : "paused\n"
      })
    XCTAssertEqual(
      controller.outcome(of: .status),
      .message("Spotify [playing]: One More Time — Daft Punk\nMusic [paused]\nvolume 31% (muted)"))
    XCTAssertEqual(asked.count, 2)
    XCTAssertTrue(asked[0].contains("tell application id \"com.spotify.client\""))
    XCTAssertTrue(asked[0].contains("artist of current track"))
    XCTAssertTrue(asked.allSatisfy { $0.contains("with timeout of 10 seconds") })

    let idle = MediaController(
      devices: devices, runningBundleIDs: { ["com.apple.TV"] }, runScript: { _ in nil })
    XCTAssertEqual(
      idle.outcome(of: .status), .message("TV [unknown]\nvolume 31% (muted)"))
    XCTAssertFalse(MediaPlayer.all[2].nowPlayingScript.contains("artist"))
    let none = MediaController(
      devices: devices, runningBundleIDs: { [] },
      runScript: { _ in
        XCTFail()
        return nil
      })
    XCTAssertEqual(
      none.outcome(of: .status), .message("no media app is running\nvolume 31% (muted)"))
  }

  func testNowPlayingReplyParses() {
    XCTAssertEqual(
      MediaNowPlaying.parse("Playing\nTrack — Artist"),
      MediaNowPlaying(state: "playing", track: "Track — Artist"))
    XCTAssertEqual(
      MediaNowPlaying.parse("stopped\n"), MediaNowPlaying(state: "stopped", track: ""))
    XCTAssertEqual(MediaNowPlaying.parse("paused"), MediaNowPlaying(state: "paused", track: ""))
    XCTAssertNil(MediaNowPlaying.parse(""))
    XCTAssertNil(MediaNowPlaying.parse("\nTrack"))
  }

  /// One step is one macOS volume-key tick: 16 between silence and full,
  /// drawn as the bezel's rounded percent.
  func testVolumeStepsLandOnTheBezelTicks() {
    let bezel = [0, 6, 13, 19, 25, 31, 38, 44, 50, 56, 63, 69, 75, 81, 88, 94, 100]
    for (index, percent) in bezel.enumerated() {
      XCTAssertEqual(CoreAudioDevices.volumePercent(Float(index) / 16), percent, "tick \(index)")
    }
    var up = Float(0)
    for percent in bezel.dropFirst() {
      up = CoreAudioDevices.nativeVolume(up, direction: 1)
      XCTAssertEqual(CoreAudioDevices.volumePercent(up), percent)
    }
    XCTAssertEqual(CoreAudioDevices.nativeVolume(1, direction: 1), 1, accuracy: 0.0001)
    var down = Float(1)
    for percent in bezel.dropLast().reversed() {
      down = CoreAudioDevices.nativeVolume(down, direction: -1)
      XCTAssertEqual(CoreAudioDevices.volumePercent(down), percent)
    }
    XCTAssertEqual(CoreAudioDevices.nativeVolume(0, direction: -1), 0, accuracy: 0.0001)
    XCTAssertEqual(
      CoreAudioDevices.volumePercent(CoreAudioDevices.nativeVolume(0.40, direction: 1)), 44)
    XCTAssertEqual(
      CoreAudioDevices.volumePercent(CoreAudioDevices.nativeVolume(0.40, direction: -1)), 38)
  }

  /// Play/pause is the keyboard's own NX_KEYTYPE_PLAY, posted as a key down
  /// and a key up.
  func testMediaKeysPostADownUpPairThroughTheSeam() throws {
    let original = SystemKeyboard.eventPoster
    defer { SystemKeyboard.eventPoster = original }
    var posted: [CGEvent] = []
    SystemKeyboard.eventPoster = { posted.append($0) }
    SystemKeyboard.perform(.mediaPlay)
    XCTAssertEqual(posted.count, 2, "one NX_KEYDOWN + one NX_KEYUP")
    let data = try posted.map { try XCTUnwrap(NSEvent(cgEvent: $0)).data1 }
    XCTAssertEqual(data.map { $0 >> 16 }, [16, 16])
    XCTAssertEqual(data.map { ($0 >> 8) & 0xFF }, [0x0A, 0x0B])
  }

  /// What `flash volume up`, `flash audio output` and `flash media status`
  /// print: the same text the alert or banner shows, so a script reads the
  /// answer. A volume step still shows its alert wherever it runs; a list,
  /// a selection or what is playing shows only when a mapping ran it.
  func testEveryAnswerIsTheCommandsOutput() {
    XCTAssertEqual(MediaOutcome.volume(40).output, "volume 40%")
    XCTAssertEqual(
      MediaOutcome.message("Output: Studio Speakers").output, "Output: Studio Speakers")
    XCTAssertNil(MediaOutcome.done.output)
    XCTAssertEqual(MediaOutcome.failed("no output device").output, "no output device")
    XCTAssertTrue(MediaOutcome.volume(40).showsWherever)
    XCTAssertFalse(MediaOutcome.message("Output: Studio Speakers").showsWherever)
  }
}
