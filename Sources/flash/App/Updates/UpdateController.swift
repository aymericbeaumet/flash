import Darwin
import Foundation

struct UpdateError: Error, Equatable, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// GitHub's `releases/latest`. A nil release is `304 Not Modified` for `etag`.
protocol UpdateReleaseSource {
  func latest(
    etag: String?,
    completion: @escaping (Result<(release: UpdateRelease?, etag: String?), UpdateError>) -> Void)
}

protocol UpdateDownloading {
  /// Download `url` to `destination`, replacing nothing (it does not exist).
  func download(
    _ url: URL, to destination: URL, completion: @escaping (Result<Void, UpdateError>) -> Void)
}

protocol UpdateUnpacking {
  /// Extract `archive` into `directory`; the extracted `Flash.app`.
  func unpack(_ archive: URL, into directory: URL) -> Result<URL, UpdateError>
}

protocol UpdateBundleVerifying {
  /// The bundle is `release`, signed so that `identity` may run it in its
  /// place.
  func verify(_ bundle: URL, release: UpdateRelease, identity: BuildIdentity) -> Result<
    Void, UpdateError
  >
}

protocol UpdateInstalling {
  /// Whether the running bundle and its folder can be replaced by this user.
  func canReplace(_ bundle: URL) -> Bool
  /// Swap `staged` and `installed` in one step: `installed` becomes the new
  /// bundle and `staged` holds the old one.
  func swap(_ staged: URL, with installed: URL) -> Result<Void, UpdateError>
  /// Tell Launch Services the bundle changed.
  func register(_ bundle: URL)
  /// Whether `a` and `b` are on one volume, so a swap can be atomic.
  func sameVolume(_ a: URL, _ b: URL) -> Bool
}

/// Checks GitHub for the newest stable release, downloads and verifies it
/// into `Updates/`, and swaps it with the running bundle. In process, on its
/// own serial queue: no helper, installer or daemon (AGENTS.md). Whoever
/// calls `install` relaunches.
final class UpdateController {
  struct Environment {
    var currentVersion: String
    var bundleURL: URL
    var identity: BuildIdentity
    /// `~/Library/Application Support/Flash/Updates`.
    var directory: URL
    var source: any UpdateReleaseSource
    var downloader: any UpdateDownloading
    var unpacker: any UpdateUnpacking
    var verifier: any UpdateBundleVerifying
    var installer: any UpdateInstalling
    var now: () -> Date = Date.init
  }

  static var defaultDirectory: URL {
    let support =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support")
    return support.appendingPathComponent("Flash/Updates", isDirectory: true)
  }

  let environment: Environment
  /// State only, each step short: main reads it synchronously.
  private let queue: DispatchQueue
  /// Unpacking and signature checks, which take seconds, never on `queue`.
  private let workQueue = DispatchQueue(label: "flash.updates.work", qos: .utility)
  /// Queue-confined.
  private var state: UpdateState
  private var checking = false
  private var waiting: [(UpdateCheckReport) -> Void] = []

  init(
    environment: Environment,
    queue: DispatchQueue = DispatchQueue(label: "flash.updates", qos: .userInitiated)
  ) {
    self.environment = environment
    self.queue = queue
    self.state = Self.loadState(in: environment.directory)
  }

  var stateFile: URL { environment.directory.appendingPathComponent("state.json") }

  /// The state as last saved. Tests and the About window.
  var snapshot: UpdateState { queue.sync { state } }

  /// Block until queued work finished. Tests.
  func drain() {
    queue.sync {}
    workQueue.sync {}
    queue.sync {}
  }

  // MARK: Check

  /// Ask GitHub for the newest stable release. With `prepare`, a newer one
  /// this build can install is downloaded and verified too, so it is ready
  /// when it is wanted. Concurrent calls share one check. `completion` runs
  /// on the controller's queue.
  func check(
    mode: UpdateMode, prepare: Bool, completion: @escaping (UpdateCheckReport) -> Void
  ) {
    queue.async { [self] in
      waiting.append(completion)
      guard !checking else { return }
      checking = true
      fetch(etag: state.latest == nil ? nil : state.etag) { [self] result in
        conclude(result, mode: mode, prepare: prepare)
      }
    }
  }

  private func fetch(
    etag: String?,
    completion: @escaping (Result<(release: UpdateRelease?, etag: String?), UpdateError>) -> Void
  ) {
    environment.source.latest(etag: etag) { [self] result in
      queue.async { completion(result) }
    }
  }

  private func conclude(
    _ result: Result<(release: UpdateRelease?, etag: String?), UpdateError>,
    mode: UpdateMode, prepare: Bool
  ) {
    let release: UpdateRelease
    switch result {
    case .failure(let error):
      return finish(report(.failed(error.description), mode: mode))
    case .success(let answer):
      guard let fresh = answer.release ?? state.latest else {
        return finish(report(.failed("GitHub sent no release"), mode: mode))
      }
      release = fresh
      state.latest = fresh
      if let etag = answer.etag { state.etag = etag }
      state.checkedAt = environment.now()
      save()
    }
    guard let current = SemanticVersion(environment.currentVersion),
      let latest = release.semanticVersion
    else {
      return finish(
        report(.failed("version \(environment.currentVersion) is not comparable"), mode: mode))
    }
    guard latest > current else {
      discardStaged()
      return finish(report(.upToDate, mode: mode))
    }
    if isStaged(release) { return finish(report(.ready(release), mode: mode)) }
    // Only a build a release can replace downloads one.
    guard prepare, environment.identity.checksAutomatically else {
      return finish(report(.available(release), mode: mode))
    }
    stage(release) { [self] outcome in
      switch outcome {
      case .success: finish(report(.ready(release), mode: mode))
      case .failure(let error):
        FlashLog.error("[updates] staging \(release.version) failed: \(error)")
        finish(
          report(.failed("Flash \(release.version) could not be prepared: \(error)"), mode: mode))
      }
    }
  }

  private func report(_ status: UpdateCheckReport.Status, mode: UpdateMode) -> UpdateCheckReport {
    UpdateCheckReport(
      current: environment.currentVersion, status: status, identity: environment.identity,
      mode: mode)
  }

  private func finish(_ report: UpdateCheckReport) {
    checking = false
    let callbacks = waiting
    waiting.removeAll()
    for callback in callbacks { callback(report) }
  }

  // MARK: Stage

  /// Where `version` is unpacked: under `Updates/` when that is on the
  /// running bundle's volume, so the swap is one rename; beside the bundle,
  /// hidden, when it is not.
  func stagingDirectory(for version: String) -> URL {
    let folder = environment.bundleURL.deletingLastPathComponent()
    if environment.installer.sameVolume(environment.directory, folder) {
      return environment.directory.appendingPathComponent(version, isDirectory: true)
    }
    return folder.appendingPathComponent(".Flash-\(version).update", isDirectory: true)
  }

  func stagedBundle(for version: String) -> URL {
    stagingDirectory(for: version).appendingPathComponent("Flash.app", isDirectory: true)
  }

  private func isStaged(_ release: UpdateRelease) -> Bool {
    state.staged == release.version
      && FileManager.default.fileExists(atPath: stagedBundle(for: release.version).path)
  }

  /// Download, check the digest GitHub published, unpack, check the bundle.
  private func stage(
    _ release: UpdateRelease, completion: @escaping (Result<Void, UpdateError>) -> Void
  ) {
    let directory = stagingDirectory(for: release.version)
    let files = FileManager.default
    let archive = directory.appendingPathComponent(release.assetName)
    workQueue.async { [self] in
      try? files.removeItem(at: directory)
      do {
        try files.createDirectory(at: environment.directory, withIntermediateDirectories: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
      } catch {
        let failure = UpdateError("cannot create \(directory.path): \(error)")
        return queue.async { completion(.failure(failure)) }
      }
      FlashLog.info("[updates] downloading \(release.assetName)")
      download(release, to: archive, in: directory, completion: completion)
    }
  }

  private func download(
    _ release: UpdateRelease, to archive: URL, in directory: URL,
    completion: @escaping (Result<Void, UpdateError>) -> Void
  ) {
    let files = FileManager.default
    environment.downloader.download(release.downloadURL, to: archive) { [self] result in
      workQueue.async { [self] in
        let outcome = result.flatMap { _ in
          verifyAndUnpack(release, archive: archive, into: directory)
        }
        try? files.removeItem(at: archive)
        queue.async { [self] in
          switch outcome {
          case .success:
            state.staged = release.version
            save()
            FlashLog.info("[updates] staged \(release.version)")
            completion(.success(()))
          case .failure(let error):
            workQueue.async { try? files.removeItem(at: directory) }
            completion(.failure(error))
          }
        }
      }
    }
  }

  private func verifyAndUnpack(_ release: UpdateRelease, archive: URL, into directory: URL)
    -> Result<Void, UpdateError>
  {
    guard let digest = UpdateRelease.sha256(of: archive) else {
      return .failure(UpdateError("the download cannot be read"))
    }
    guard digest == release.sha256 else {
      return .failure(
        UpdateError("the download's SHA-256 is \(digest), GitHub published \(release.sha256)"))
    }
    return environment.unpacker.unpack(archive, into: directory).flatMap { bundle in
      guard bundle.standardizedFileURL == stagedBundle(for: release.version).standardizedFileURL
      else { return .failure(UpdateError("the archive holds no Flash.app")) }
      return environment.verifier.verify(bundle, release: release, identity: environment.identity)
    }
  }

  private func discardStaged() {
    guard let staged = state.staged else { return }
    let directory = stagingDirectory(for: staged)
    workQueue.async { try? FileManager.default.removeItem(at: directory) }
    state.staged = nil
    save()
  }

  // MARK: Install

  /// The release staged and still newer than this build, when there is one.
  var stagedRelease: UpdateRelease? {
    queue.sync { stagedReleaseLocked }
  }

  private var stagedReleaseLocked: UpdateRelease? {
    guard let release = state.latest, isStaged(release),
      let current = SemanticVersion(environment.currentVersion),
      let version = release.semanticVersion, version > current
    else { return nil }
    return release
  }

  /// Swap the staged release with the running bundle, after checking it
  /// once more. On success the bundle at `bundleURL` is the new version and
  /// the old one waits under `Updates/` until the new one has started.
  func install() -> Result<UpdateRelease, UpdateError> {
    queue.sync { installLocked() }
  }

  private func installLocked() -> Result<UpdateRelease, UpdateError> {
    if case .never(let reason) = environment.identity.installability {
      return .failure(UpdateError(reason))
    }
    guard let release = stagedReleaseLocked else {
      return .failure(UpdateError("no update is downloaded"))
    }
    let bundle = environment.bundleURL
    guard environment.installer.canReplace(bundle) else {
      return .failure(
        UpdateError(
          "\(bundle.path) cannot be replaced by this user; update with "
            + "brew upgrade --cask flash, or download the release"))
    }
    let staged = stagedBundle(for: release.version)
    if case .failure(let error) = environment.verifier.verify(
      staged, release: release, identity: environment.identity)
    {
      discardStaged()
      return .failure(error)
    }
    state.installed = release.version
    save()
    if case .failure(let error) = environment.installer.swap(staged, with: bundle) {
      state.installed = nil
      save()
      return .failure(error)
    }
    state.staged = nil
    save()
    environment.installer.register(bundle)
    FlashLog.info("[updates] installed \(release.version) at \(bundle.path)")
    return .success(release)
  }

  // MARK: Launch

  /// Once the resident settled: drop what earlier updates left (the bundle
  /// a swap replaced, an abandoned download) and keep only a staged release
  /// still newer than this build. Returns the version this launch was just
  /// updated to, once.
  func settle(completion: @escaping (String?) -> Void) {
    queue.async { [self] in
      let keep = stagedReleaseLocked.map { stagingDirectory(for: $0.version).lastPathComponent }
      if keep == nil, state.staged != nil {
        state.staged = nil
      }
      let entries =
        (try? FileManager.default.contentsOfDirectory(
          at: environment.directory, includingPropertiesForKeys: nil)) ?? []
      var leftovers = entries.filter {
        $0.lastPathComponent != "state.json" && $0.lastPathComponent != keep
      }
      // A staging folder beside the bundle, on another volume.
      let folder = environment.bundleURL.deletingLastPathComponent()
      let siblings =
        (try? FileManager.default.contentsOfDirectory(
          at: folder, includingPropertiesForKeys: nil)) ?? []
      leftovers += siblings.filter {
        $0.lastPathComponent.hasPrefix(".Flash-") && $0.pathExtension == "update"
          && $0.lastPathComponent != keep
      }
      // A replaced bundle is large: delete it off the state queue.
      workQueue.async {
        for entry in leftovers { try? FileManager.default.removeItem(at: entry) }
      }
      var greeting: String?
      if let installed = state.installed {
        if installed == environment.currentVersion { greeting = installed }
        state.installed = nil
      }
      save()
      completion(greeting)
    }
  }

  /// Record that `version` was announced; false when it already was.
  func markAnnounced(_ version: String) -> Bool {
    queue.sync {
      guard state.announced != version else { return false }
      state.announced = version
      save()
      return true
    }
  }

  // MARK: State

  private static func loadState(in directory: URL) -> UpdateState {
    let file = directory.appendingPathComponent("state.json")
    guard let data = try? Data(contentsOf: file),
      let state = try? JSONDecoder().decode(UpdateState.self, from: data)
    else { return UpdateState() }
    return state
  }

  private func save() {
    do {
      try FileManager.default.createDirectory(
        at: environment.directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      try encoder.encode(state).write(to: stateFile, options: .atomic)
    } catch {
      FlashLog.warn("[updates] state not saved: \(error)")
    }
  }
}
