import AppKit

/// Puts one clipboard history entry back on a pasteboard, in the formats it
/// was copied with, or as plain text. Every write carries
/// ``ClipboardMonitor/restoredEntryType`` with the entry's id, so the watcher
/// moves the entry to the front instead of recording a second copy.
enum ClipboardRestore {
  /// The pasteboard type the history's image MIME types are written as.
  static func pasteboardType(forMime mime: String) -> NSPasteboard.PasteboardType? {
    switch mime {
    case "image/png": return .png
    case "image/jpeg": return NSPasteboard.PasteboardType("public.jpeg")
    case "image/gif": return NSPasteboard.PasteboardType("com.compuserve.gif")
    case "image/webp": return NSPasteboard.PasteboardType("org.webmproject.webp")
    default: return nil
    }
  }

  /// The pasteboard items for `payload`. `plain` keeps only the entry's
  /// text; an entry without text (a bare image) is written whole either way.
  /// Empty when the payload has nothing to write.
  static func items(for payload: ClipboardEntryPayload, plain: Bool) -> [NSPasteboardItem] {
    let first = NSPasteboardItem()
    var items = [first]
    let hasText = !payload.text.isEmpty
    if !(plain && hasText) {
      switch payload.kind {
      case "files":
        let urls = payload.files.map { URL(fileURLWithPath: $0).absoluteString }
        guard let head = urls.first else { return [] }
        first.setString(head, forType: .fileURL)
        for url in urls.dropFirst() {
          let item = NSPasteboardItem()
          item.setString(url, forType: .fileURL)
          items.append(item)
        }
      case "image":
        guard let image = payload.image, let mime = payload.mime,
          let type = pasteboardType(forMime: mime)
        else { return [] }
        first.setData(image, forType: type)
      case "html":
        if let html = payload.html, !html.isEmpty { first.setString(html, forType: .html) }
      default:
        break
      }
    }
    if hasText { first.setString(payload.text, forType: .string) }
    guard !first.types.isEmpty else { return [] }
    first.setData(Data(payload.id.utf8), forType: ClipboardMonitor.restoredEntryType)
    return items
  }

  /// Replace `pasteboard`'s contents with `payload`. False when there was
  /// nothing to write or the pasteboard refused it; the contents are then
  /// left alone.
  @discardableResult
  static func write(
    _ payload: ClipboardEntryPayload, plain: Bool, to pasteboard: NSPasteboard = .general
  ) -> Bool {
    let items = items(for: payload, plain: plain)
    guard !items.isEmpty else { return false }
    pasteboard.clearContents()
    return pasteboard.writeObjects(items)
  }
}
