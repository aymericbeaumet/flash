import AppKit

/// A paste that borrows the clipboard. The user's copy is captured, the text
/// to paste goes on the pasteboard marked transient (nspasteboard.org's
/// `TransientType`, which clipboard managers and Flash's own history skip),
/// the app pastes it with its own paste command, and the copy goes back once
/// the app has had time to read the pasteboard. A copy made in between wins.
struct PasteboardSnapshot {
  static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
  /// How long an app gets to read a pasteboard its paste command asked for.
  /// Apps read it while handling the paste key; this leaves a wide margin.
  static let returnDelayMs = 400

  /// Each item's data, type by type, in the pasteboard's order: the first
  /// type is the copy's preferred one.
  let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

  static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
    PasteboardSnapshot(
      items: (pasteboard.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
      })
  }

  /// Put the captured copy back, marked transient so a history that already
  /// recorded it does not record it again.
  @discardableResult
  func restore(to pasteboard: NSPasteboard) -> Bool {
    pasteboard.clearContents()
    let objects = items.filter { !$0.isEmpty }.map { entries -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for entry in entries { item.setData(entry.data, forType: entry.type) }
      return item
    }
    guard let first = objects.first else { return true }
    if !first.types.contains(Self.transientType) {
      first.setData(Data(), forType: Self.transientType)
    }
    return pasteboard.writeObjects(objects)
  }

  /// Put `text` on the pasteboard for one paste, marked transient.
  @discardableResult
  static func lend(_ text: String, to pasteboard: NSPasteboard) -> Bool {
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    item.setData(Data(), forType: transientType)
    return pasteboard.writeObjects([item])
  }
}
