import AppKit
import FlashCore
import Foundation

extension AppDelegate {
  /// Handle the resident clipboard history commands without a plugin RPC:
  /// `show`, `delete`, `pin` and `unpin`. A failure's output, when there is
  /// one, says why.
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
      guard let id = Self.clipboardEntryID(args) else {
        completion(false, nil)
        return true
      }
      clipboardHistoryStore.delete(id: id) { deleted in completion(deleted, nil) }
      return true
    case "pin", "unpin":
      guard let id = Self.clipboardEntryID(args) else {
        completion(false, nil)
        return true
      }
      clipboardHistoryStore.setPinned(id: id, subcommand.lowercased() == "pin") { result in
        switch result {
        case .changed, .unchanged: completion(true, nil)
        case .full(let capacity): completion(false, Self.clipboardPinsFullMessage(capacity))
        case .missing, .failed: completion(false, nil)
        }
      }
      return true
    default: return false
    }
  }

  private static func clipboardEntryID(_ args: [String]) -> String? {
    guard args.count == 1 else { return nil }
    let id = args[0].hasPrefix("id=") ? String(args[0].dropFirst(3)) : args[0]
    return ClipboardCapture.isEntryID(id) ? id : nil
  }

  static func clipboardPinsFullMessage(_ capacity: Int) -> String {
    "Pins may fill \(capacity - 1) of the \(capacity) clipboard history entries: "
      + "unpin one, or raise [clipboard] history_size"
  }

  /// `clipboard restore --id=<id> [--paste] [--plain]`: put a history entry
  /// back on the clipboard, then, with `paste`, run the focused app's own
  /// `clipboard paste`. `plain` keeps only its text. False when no entry has
  /// this id or nothing could be written.
  func restoreClipboardEntry(
    id: String, paste: Bool, plain: Bool, completion: @escaping (Bool) -> Void
  ) {
    clipboardHistoryStore.payload(id: id) { [weak self] payload in
      guard let self, let payload, ClipboardRestore.write(payload, plain: plain) else {
        completion(false)
        return
      }
      guard paste else { return completion(true) }
      self.performMappedCommand(.clipboardPaste) { outcome in
        completion(outcome == .performed || outcome == .chordSent)
      }
    }
  }

  /// A clipboard row chosen in the flashlight. The command line closes and
  /// gives the keyboard back to the app it covered (`targetPID`); a history
  /// entry is then put on the clipboard and pasted there with the app's own
  /// `clipboard paste`, and a register borrows the clipboard for that paste,
  /// as `register paste` does.
  /// `.copy` only fills the clipboard. Neither changes the mode.
  func deliverClipboardRow(
    _ row: Candidate, _ delivery: ClipboardRowDelivery, targetPID: pid_t?
  ) {
    let payload = row.sourcePayload ?? ""
    if row.kind == ClipboardFlashlight.registerKind {
      let text = registers.read(register: payload) ?? ""
      switch delivery {
      case .copy:
        if !text.isEmpty { NormalModeDispatcher.copy(text) }
        returnToCommandTarget(targetPID) { _, _ in }
      case .paste, .pastePlain:
        guard !text.isEmpty else { return returnToCommandTarget(targetPID) { _, _ in } }
        returnToCommandTarget(targetPID) { [weak self] pid, target in
          guard let self, let giveBack = self.borrowPasteboard(for: text) else { return }
          self.pasteFromClipboard(into: target, pid: pid)
          giveBack()
        }
      }
      return
    }
    let store = clipboardHistoryStore
    guard delivery.pastes else {
      store.payload(id: payload) { entry in
        if let entry { ClipboardRestore.write(entry, plain: false) }
      }
      returnToCommandTarget(targetPID) { _, _ in }
      return
    }
    returnToCommandTarget(targetPID) { [weak self] pid, target in
      store.payload(id: payload) { entry in
        guard let self, let entry, !target.isTerminated, target.isActive,
          ClipboardRestore.write(entry, plain: delivery.plain)
        else { return }
        self.pasteFromClipboard(into: target, pid: pid)
      }
    }
  }

  /// Command-P on a selected clipboard history row: pin it, or unpin it.
  /// The rows refresh when the store publishes the change.
  func togglePinOfSelectedClipboardRow() -> Bool {
    guard NormalModeDispatcher.commandLineCandidateQuery(overlay.commandLineText) != nil,
      finder.matches.indices.contains(finder.selectedIndex)
    else { return false }
    let row = finder.matches[finder.selectedIndex].candidate
    guard row.sourceID == ClipboardFlashlight.sourceID, row.kind == ClipboardFlashlight.entryKind,
      let id = row.sourcePayload
    else { return false }
    let pin = row.source != ClipboardFlashlight.pinnedLabel
    finder.followedRow = (
      id, pin ? ClipboardFlashlight.pinnedLabel : ClipboardFlashlight.historyLabel
    )
    clipboardHistoryStore.setPinned(id: id, pin) { [weak self] result in
      guard case .full(let capacity) = result else { return }
      self?.finder.followedRow = nil
      let message = Self.clipboardPinsFullMessage(capacity)
      FlashLog.info(
        "[clipboard] pin_refused", fields: ["capacity": "\(capacity)"], source: "core:Command")
      self?.overlay.displayAlert(.message(message, style: .error))
    }
    return true
  }
}
