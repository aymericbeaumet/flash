import Foundation

extension AppDelegate {
  /// Handle the two resident clipboard history commands without a plugin RPC.
  func performClipboardHistoryCommand(
    subcommand: String, args: [String],
    completion: @escaping (_ ok: Bool, _ output: String?) -> Void
  ) -> Bool {
    switch subcommand.lowercased() {
    case "show":
      let offset: Int
      switch args {
      case []: offset = 0
      case _ where args.count == 1:
        let arg = args[0]
        guard let raw = arg.lowercased().hasPrefix("offset=") ? String(arg.dropFirst(7)) : nil,
          !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
          let parsed = Int(raw), (0...ClipboardHistoryStore.maxCapacity).contains(parsed)
        else {
          completion(false, nil)
          return true
        }
        offset = parsed
      default:
        completion(false, nil)
        return true
      }
      clipboardHistoryStore.page(offset: offset) { page in
        guard let page, let data = try? JSONEncoder().encode(page),
          let json = String(data: data, encoding: .utf8)
        else {
          completion(false, nil)
          return
        }
        completion(true, json)
      }
      return true
    case "delete":
      guard args.count == 1 else {
        completion(false, nil)
        return true
      }
      let id = args[0].hasPrefix("id=") ? String(args[0].dropFirst(3)) : args[0]
      guard ClipboardCapture.isEntryID(id) else {
        completion(false, nil)
        return true
      }
      clipboardHistoryStore.delete(id: id) { deleted in completion(deleted, nil) }
      return true
    default: return false
    }
  }
}
