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
}

enum AudioDeviceError: LocalizedError {
  case system(OSStatus)
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .system(let status): "CoreAudio error \(status)"
    case .unavailable(let uid): "audio device unavailable: \(uid)"
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
