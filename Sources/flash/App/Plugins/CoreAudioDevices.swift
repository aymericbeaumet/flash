import AudioToolbox
import CoreAudio
import Foundation

enum AudioDeviceDirection: String {
  case input
  case output

  var scope: AudioObjectPropertyScope {
    switch self {
    case .input: kAudioObjectPropertyScopeInput
    case .output: kAudioObjectPropertyScopeOutput
    }
  }

  var defaultSelector: AudioObjectPropertySelector {
    switch self {
    case .input: kAudioHardwarePropertyDefaultInputDevice
    case .output: kAudioHardwarePropertyDefaultOutputDevice
    }
  }
}

struct AudioDeviceRecord {
  let uid: String
  let name: String
  let isDefault: Bool
}

protocol AudioDeviceProviding {
  func list(direction: AudioDeviceDirection) throws -> [AudioDeviceRecord]
  func select(uid: String, direction: AudioDeviceDirection) throws
  /// Move the default output one macOS volume-key tick in the sign of
  /// `deltaPercent` and clear mute. Returns the percent the bezel would show.
  func adjustOutputVolume(deltaPercent: Int) throws -> Int
  func toggleOutputMute() throws
}

enum AudioDeviceError: LocalizedError {
  case system(OSStatus)
  case unavailable(String)
  case unsupported(String)

  var errorDescription: String? {
    switch self {
    case .system(let status): "CoreAudio error \(status)"
    case .unavailable(let uid): "audio device unavailable: \(uid)"
    case .unsupported(let what): "audio device does not support \(what)"
    }
  }
}

struct CoreAudioDevices: AudioDeviceProviding {
  private let systemObject = AudioObjectID(kAudioObjectSystemObject)

  func list(direction: AudioDeviceDirection) throws -> [AudioDeviceRecord] {
    let defaultID = try defaultDeviceID(direction: direction)
    return try deviceIDs().compactMap { id in
      guard supports(id, direction: direction) else { return nil }
      return AudioDeviceRecord(
        uid: try stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
        name: try stringProperty(id, selector: kAudioObjectPropertyName),
        isDefault: id == defaultID)
    }
    .sorted {
      let comparison = $0.name.localizedStandardCompare($1.name)
      return comparison == .orderedSame ? $0.uid < $1.uid : comparison == .orderedAscending
    }
  }

  func select(uid: String, direction: AudioDeviceDirection) throws {
    guard !uid.isEmpty else { throw AudioDeviceError.unavailable(uid) }
    let id = try deviceIDs().first { candidate in
      supports(candidate, direction: direction)
        && (try? stringProperty(candidate, selector: kAudioDevicePropertyDeviceUID)) == uid
    }
    guard var id else { throw AudioDeviceError.unavailable(uid) }
    var address = AudioObjectPropertyAddress(
      mSelector: direction.defaultSelector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectSetPropertyData(
      systemObject, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
    guard status == noErr else { throw AudioDeviceError.system(status) }
  }

  /// macOS volume keys use 16 ticks from silence to full. The bezel percent
  /// is the tick rounded to the nearest whole number: 0, 6, 13, …, 94, 100.
  static let volumeTicks = 16

  /// The next tick in `direction` (positive up, negative down). A scalar
  /// between ticks lands on the neighbouring tick, not a sixteenth past it.
  /// The ends stay at 0 and 1.
  static func nativeVolume(_ current: Float32, direction: Int) -> Float32 {
    let ticks = Double(volumeTicks)
    let scaled = Double(current) * ticks
    let index: Int
    if direction > 0 {
      let at = Int((scaled + 1e-6).rounded(.down))
      let onTick = abs(scaled - Double(at)) < 1e-4
      index = min(volumeTicks, onTick ? at + 1 : Int((scaled - 1e-6).rounded(.up)))
    } else if direction < 0 {
      let at = Int((scaled - 1e-6).rounded(.up))
      let onTick = abs(scaled - Double(at)) < 1e-4
      index = max(0, onTick ? at - 1 : Int((scaled + 1e-6).rounded(.down)))
    } else {
      index = min(volumeTicks, max(0, Int(scaled.rounded())))
    }
    return Float32(Double(index) / ticks)
  }

  /// The percent macOS draws for a scalar on that scale.
  static func volumePercent(_ scalar: Float32) -> Int {
    Int((Double(scalar) * 100).rounded())
  }

  @discardableResult
  func adjustOutputVolume(deltaPercent: Int) throws -> Int {
    let id = try defaultDeviceID(direction: .output)
    let address = try outputVolumeAddress(id)
    let next = Self.nativeVolume(try floatProperty(id, address), direction: deltaPercent)
    try setFloatProperty(id, address, next)
    let mute = muteAddress
    if hasProperty(id, mute) {
      try setUInt32Property(id, mute, 0)
    }
    return Self.volumePercent(next)
  }

  func toggleOutputMute() throws {
    let id = try defaultDeviceID(direction: .output)
    let mute = muteAddress
    guard hasProperty(id, mute) else { throw AudioDeviceError.unsupported("mute") }
    try setUInt32Property(id, mute, try uint32Property(id, mute) == 0 ? 1 : 0)
  }

  private var muteAddress: AudioObjectPropertyAddress {
    outputAddress(kAudioDevicePropertyMute)
  }

  private func outputVolumeAddress(_ id: AudioObjectID) throws -> AudioObjectPropertyAddress {
    let virtual = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    if hasProperty(id, virtual) { return virtual }
    let scalar = outputAddress(kAudioDevicePropertyVolumeScalar)
    guard hasProperty(id, scalar) else { throw AudioDeviceError.unsupported("output volume") }
    return scalar
  }

  private func outputAddress(
    _ selector: AudioObjectPropertySelector
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
  }

  private func hasProperty(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
    var address = address
    return AudioObjectHasProperty(id, &address)
  }

  private func floatProperty(
    _ id: AudioObjectID, _ address: AudioObjectPropertyAddress
  ) throws -> Float32 {
    var address = address
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    guard status == noErr else { throw AudioDeviceError.system(status) }
    return value
  }

  private func setFloatProperty(
    _ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: Float32
  ) throws {
    var address = address
    var value = value
    let status = AudioObjectSetPropertyData(
      id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    guard status == noErr else { throw AudioDeviceError.system(status) }
  }

  private func uint32Property(
    _ id: AudioObjectID, _ address: AudioObjectPropertyAddress
  ) throws -> UInt32 {
    var address = address
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    guard status == noErr else { throw AudioDeviceError.system(status) }
    return value
  }

  private func setUInt32Property(
    _ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: UInt32
  ) throws {
    var address = address
    var value = value
    let status = AudioObjectSetPropertyData(
      id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    guard status == noErr else { throw AudioDeviceError.system(status) }
  }

  private func deviceIDs() throws -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
    guard status == noErr else { throw AudioDeviceError.system(status) }
    var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &devices)
    guard status == noErr else { throw AudioDeviceError.system(status) }
    return devices
  }

  private func defaultDeviceID(direction: AudioDeviceDirection) throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
      mSelector: direction.defaultSelector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id)
    guard status == noErr else { throw AudioDeviceError.system(status) }
    return id
  }

  private func supports(_ id: AudioObjectID, direction: AudioDeviceDirection) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: direction.scope,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
  }

  private func stringProperty(
    _ id: AudioObjectID, selector: AudioObjectPropertySelector
  ) throws -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var rawValue: UnsafeRawPointer?
    var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    let status = withUnsafeMutablePointer(to: &rawValue) { pointer in
      AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { throw AudioDeviceError.system(status) }
    guard let rawValue else { return "" }
    return Unmanaged<CFString>.fromOpaque(rawValue).takeRetainedValue() as String
  }
}
