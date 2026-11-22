import Foundation

@testable import flash

/// CoreAudio for the tests: the conformance corpus's two devices per
/// direction, the output at 38% and not muted. Nothing here reaches the
/// Mac's audio server.
final class AudioDeviceStub: AudioDeviceProviding {
  var devices: [AudioDeviceDirection: [AudioDeviceRecord]] = {
    let pair = [
      AudioDeviceRecord(uid: "built-in", name: "MacBook Pro Speakers", isDefault: true),
      AudioDeviceRecord(uid: "usb-1", name: "USB Audio", isDefault: false),
    ]
    return [.input: pair, .output: pair]
  }()
  var scalar: Float32 = 0.375
  var muted = false
  /// Thrown by every call while set.
  var failure: Error?
  /// Each call that reached CoreAudio's place, in order.
  private(set) var calls: [String] = []

  private func record(_ call: String) throws {
    if let failure { throw failure }
    calls.append(call)
  }

  func list(direction: AudioDeviceDirection) throws -> [AudioDeviceRecord] {
    try record("list \(direction.rawValue)")
    return devices[direction] ?? []
  }

  func select(uid: String, direction: AudioDeviceDirection) throws {
    try record("select \(direction.rawValue) \(uid)")
    guard let listed = devices[direction], listed.contains(where: { $0.uid == uid }) else {
      throw AudioDeviceError.unavailable(uid)
    }
    devices[direction] = listed.map {
      AudioDeviceRecord(uid: $0.uid, name: $0.name, isDefault: $0.uid == uid)
    }
  }

  func stepOutputVolume(ticks: Int) throws -> Int {
    try record("step \(ticks)")
    scalar = CoreAudioDevices.nativeVolume(scalar, ticks: ticks)
    muted = false
    return CoreAudioDevices.volumePercent(scalar)
  }

  func toggleOutputMute() throws -> Bool {
    try record("mute")
    muted.toggle()
    return muted
  }

  func outputVolume() throws -> OutputVolume {
    try record("volume")
    return OutputVolume(percent: CoreAudioDevices.volumePercent(scalar), muted: muted)
  }
}
