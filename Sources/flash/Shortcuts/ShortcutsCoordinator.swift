import AppKit
import Foundation

/// Glue between config discovery, Carbon hotkey registration, and
/// the running-apps cache.
///
/// Lookup chain (first existing wins):
///   1. `$XDG_CONFIG_HOME/skhd/skhdrc`
///   2. `$HOME/.config/skhd/skhdrc`
///   3. `$HOME/.skhdrc`
///
/// Live reload watches ALL three locations even when the file is
/// absent — creating a higher-precedence file later swaps in
/// automatically. Watching uses parent-dir observers when the file
/// itself doesn't exist (DispatchSource needs an open file
/// descriptor), and reverts to file watchers once the file appears.
final class ShortcutsCoordinator {

  private let cache = AppActivationCache()
  private let hotkeys = HotKeyManager()
  private var fileSources: [DispatchSourceFileSystemObject] = []
  private var loadedPath: String?
  private let reloadDebounce = DispatchQueue(label: "flash.shortcuts.reload")
  private var reloadPending: DispatchWorkItem?

  func start() {
    cache.start()
    reload()
    installWatchers()
  }

  func stop() {
    hotkeys.unregisterAll()
    cache.stop()
    teardownWatchers()
  }

  // MARK: - Path resolution

  /// Resolved in lookup order. Paths that don't currently exist are
  /// still returned — the watcher set watches their parent dirs so
  /// creation triggers a reload.
  static var candidatePaths: [String] {
    let env = ProcessInfo.processInfo.environment
    let home = NSHomeDirectory()
    var paths: [String] = []
    if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
      paths.append((xdg as NSString).expandingTildeInPath + "/skhd/skhdrc")
    }
    paths.append("\(home)/.config/skhd/skhdrc")
    paths.append("\(home)/.skhdrc")
    return paths
  }

  private func firstExistingPath() -> String? {
    let fm = FileManager.default
    return Self.candidatePaths.first { fm.fileExists(atPath: $0) }
  }

  // MARK: - Load

  func reload() {
    hotkeys.unregisterAll()
    guard let path = firstExistingPath(),
      let text = try? String(contentsOfFile: path, encoding: .utf8)
    else {
      loadedPath = nil
      return
    }
    loadedPath = path
    let rules = SKHDParser.parse(text)
    for rule in rules {
      switch rule.action {
      case .launchApp(let target):
        let ok = hotkeys.register(
          modifiers: rule.modifiers, virtualKey: rule.virtualKey
        ) { [weak cache] in
          cache?.activate(target: target)
        }
        if !ok {
          FlashLog.write(
            "[shortcuts] could not register: \(rule.source) "
              + "(another app may already own this hotkey)")
        }
      case .unknown:
        // Silently skip — keeps the parser permissive enough that
        // the same skhdrc can drive a real skhd daemon alongside us
        // for commands we don't implement.
        continue
      }
    }
  }

  // MARK: - Watch

  /// Watch BOTH the file (if present) and its parent dir (always),
  /// for each candidate. File watcher catches edits; dir watcher
  /// catches create/rename/delete — which is how we notice a
  /// higher-precedence config getting promoted into existence.
  private func installWatchers() {
    teardownWatchers()
    var watchedDirs = Set<String>()
    for path in Self.candidatePaths {
      addFileWatcherIfExists(path: path)
      let dir = (path as NSString).deletingLastPathComponent
      if watchedDirs.insert(dir).inserted {
        addDirWatcher(path: dir)
      }
    }
  }

  private func teardownWatchers() {
    for s in fileSources { s.cancel() }
    fileSources.removeAll()
  }

  private func addFileWatcherIfExists(path: String) {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend],
      queue: .main)
    src.setEventHandler { [weak self] in self?.scheduleReload() }
    src.setCancelHandler { close(fd) }
    src.resume()
    fileSources.append(src)
  }

  private func addDirWatcher(path: String) {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
      // Dir doesn't exist (e.g. ~/.config/skhd/ when user hasn't
      // created it yet). Skip — the user will likely create the
      // path via a `mkdir -p` before editing, at which point a
      // re-`start()` (next app launch) would pick it up. Watching a
      // nonexistent dir would require watching the parent recursively,
      // which is overkill for this corner.
      return
    }
    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .delete, .rename],
      queue: .main)
    src.setEventHandler { [weak self] in self?.scheduleReload() }
    src.setCancelHandler { close(fd) }
    src.resume()
    fileSources.append(src)
  }

  /// Debounce reloads — editors often write through several syscalls
  /// (truncate + write or rename-into-place), each firing the source,
  /// and we don't want to re-register hotkeys mid-write.
  private func scheduleReload() {
    reloadPending?.cancel()
    let item = DispatchWorkItem { [weak self] in
      DispatchQueue.main.async {
        self?.installWatchers()  // re-discover (paths may have shifted)
        self?.reload()
      }
    }
    reloadPending = item
    reloadDebounce.asyncAfter(deadline: .now() + 0.15, execute: item)
  }
}
