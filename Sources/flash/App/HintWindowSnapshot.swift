import CoreGraphics

struct HintWindowSnapshot: Equatable {
  let number: CGWindowID
  let layer: Int
  let frame: CGRect

  static func current(
    pid: pid_t, primaryHeight: CGFloat, windowNumber: CGWindowID? = nil
  ) -> Self? {
    guard let info = WindowSnapshot.windowList() else { return nil }
    return resolve(info, pid: pid, primaryHeight: primaryHeight, windowNumber: windowNumber)
  }

  static func resolve(
    _ info: [[String: Any]], pid: pid_t, primaryHeight: CGFloat, windowNumber: CGWindowID? = nil
  ) -> Self? {
    let entries = WindowSnapshot.entries(from: info, primaryH: primaryHeight)
    let layerZero = entries.filter { $0.pid == pid && $0.layer == 0 }.map(\.nsBounds)
    let active = entries.first(where: {
      $0.pid == pid && WindowSnapshot.isInteractionSurfaceLayer($0.layer)
        && !($0.layer == 0
          && WindowSnapshot.isAnchoredCard($0.nsBounds, amongLayer0App: layerZero))
    })
    for raw in info {
      guard raw[kCGWindowOwnerPID as String] as? pid_t == pid,
        let number = raw[kCGWindowNumber as String] as? CGWindowID,
        let bounds = raw[kCGWindowBounds as String] as? [String: Any],
        let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { continue }
      let frame = CGRect(
        x: cgFrame.minX, y: primaryHeight - cgFrame.maxY,
        width: cgFrame.width, height: cgFrame.height)
      let matches = windowNumber.map { $0 == number } ?? (frame == active?.nsBounds)
      if matches, frame.width > 0, frame.height > 0 {
        return Self(number: number, layer: raw[kCGWindowLayer as String] as? Int ?? 0, frame: frame)
      }
    }
    return nil
  }
}
