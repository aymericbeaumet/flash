import Foundation

/// Watches the OS application directories and fires `onChange` (debounced)
/// whenever a bundle is added, removed, or renamed directly inside one of
/// them. Backed by one `DispatchSource`/kqueue per directory — the same
/// mechanism the config hot-reload watcher uses (see ConfigReload.swift):
/// a directory fd opened `O_EVTONLY` fires `.write` when its direct
/// entries change.
///
/// kqueue is not recursive: an app installed into a nested subfolder that
/// is not itself a watched root won't fire. That's an accepted gap — the
/// standard install locations (`/Applications`, `~/Applications`, and the
/// system roots) are watched directly and cover normal drag-install and
/// installer-package flows, which land the bundle as a direct child.
///
/// All callbacks are delivered on a private serial queue, so `onChange`
/// must be safe to run off the main thread.
final class ApplicationDirectoryWatcher {
  private let queue = DispatchQueue(label: "com.flash.app.application-watcher")
  private let debounceMs: Int
  private let onChange: () -> Void
  private var sources: [DispatchSourceFileSystemObject] = []
  /// `.normal`: an installed app should be searchable by the time the user
  /// opens the flashlight, but nothing on screen waits on the rescan.
  private lazy var pending = PollDeadline("core:app_directories", priority: .normal, on: queue)

  /// - Parameters:
  ///   - paths: directories to watch. Non-existent paths are skipped.
  ///   - debounce: coalescing window — an installer that touches a root
  ///     several times in quick succession triggers a single rescan.
  ///   - onChange: invoked on the watcher's serial queue after the
  ///     debounce window elapses.
  init(
    paths: [String],
    debounceMs: Int = 300,
    onChange: @escaping () -> Void
  ) {
    self.debounceMs = debounceMs
    self.onChange = onChange
    for path in paths {
      attach(path: path)
    }
  }

  deinit {
    for source in sources { source.cancel() }
  }

  private func attach(path: String) {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .delete, .rename],
      queue: queue)
    source.setEventHandler { [weak self] in
      self?.scheduleChange()
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    sources.append(source)
  }

  /// Debounce on the serial queue: each event re-arms one deadline on the
  /// shared clock, so a burst collapses to one `onChange`.
  private func scheduleChange() {
    pending.arm(afterMs: debounceMs) { [weak self] in self?.onChange() }
  }
}
