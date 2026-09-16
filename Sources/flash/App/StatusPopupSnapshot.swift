import Foundation

/// A pager reads this private file; the existing status collectors remain the
/// only owners of the data. File work never runs on a pointer or keyboard event.
final class StatusPopupSnapshot {
  private static let queue = DispatchQueue(label: "com.flash.popup-files", qos: .utility)
  private let fileQueue: DispatchQueue
  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("flash-popup-\(UUID().uuidString)", isDirectory: true)
  var fileURL: URL { directory.appendingPathComponent("details.txt") }
  var data: Data
  var allowsRefresh = true
  private var writtenData: Data?
  private var closed = false
  private enum WriteKind: Equatable { case hover, explicit }
  private struct PendingWrite {
    var bytes: Data
    var kind: WriteKind
    var completion: (Result<Bool, Error>) -> Void
  }
  private var pendingWrites: [PendingWrite] = []
  private var writeInFlight = false
  private var freezeCompletions: [(Bool) -> Void] = []
  private var repaintBeforeFocus = false

  init(data: Data, fileQueue: DispatchQueue? = nil) {
    self.data = data
    self.fileQueue = fileQueue ?? Self.queue
  }

  func publish(completion: @escaping (Result<Bool, Error>) -> Void) {
    guard !closed, allowsRefresh else { return }
    // A hover only needs the latest queued value. Dropped publications never
    // run their callbacks, which could otherwise start less before its file exists.
    pendingWrites.removeAll { $0.kind == .hover }
    pendingWrites.append(PendingWrite(bytes: data, kind: .hover, completion: completion))
    startNextWrite()
  }

  func freeze(completion: @escaping (Bool) -> Void) {
    guard !closed else { return }
    allowsRefresh = false
    pendingWrites.removeAll { $0.kind == .hover }
    guard writeInFlight else {
      completion(false)
      return
    }
    freezeCompletions.append(completion)
  }

  func write(completion: @escaping (Result<Bool, Error>) -> Void) {
    guard !closed else { return }
    pendingWrites.append(PendingWrite(bytes: data, kind: .explicit, completion: completion))
    startNextWrite()
  }

  /// Scheduling stays on main. Only one file operation can be active, so a
  /// freeze can discard waiting hover writes and await that operation without
  /// blocking input on file I/O or a lock.
  private func startNextWrite() {
    guard !closed, !writeInFlight, !pendingWrites.isEmpty else { return }
    writeInFlight = true
    let request = pendingWrites.removeFirst()
    let bytes = request.bytes
    let directory = directory
    let file = fileURL
    fileQueue.async { [self] in
      let result: Result<Bool, Error>
      var replacesExistingFile = false
      do {
        if writtenData == bytes {
          result = .success(false)
        } else {
          try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          // Keep the inode: less retains its open descriptor across repaints.
          try bytes.write(to: file)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
          replacesExistingFile = writtenData != nil
          writtenData = bytes
          result = .success(true)
        }
      } catch {
        result = .failure(error)
      }
      let repaint = replacesExistingFile
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.closed else { return }
        self.writeInFlight = false
        if !self.freezeCompletions.isEmpty {
          self.repaintBeforeFocus = self.repaintBeforeFocus || repaint
        }
        request.completion(result)
        guard !self.closed else { return }
        self.startNextWrite()
        guard !self.writeInFlight else { return }
        let completions = self.freezeCompletions
        let repaint = self.repaintBeforeFocus
        self.freezeCompletions.removeAll()
        self.repaintBeforeFocus = false
        for completion in completions { completion(repaint) }
      }
    }
  }

  func close() {
    guard !closed else { return }
    closed = true
    pendingWrites.removeAll()
    freezeCompletions.removeAll()
    let directory = directory
    fileQueue.async { try? FileManager.default.removeItem(at: directory) }
  }

  deinit { close() }
}
