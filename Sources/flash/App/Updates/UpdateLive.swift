import AppKit
import Darwin
import Foundation
import Security

extension BuildIdentity {
  /// The running process's signature, read once.
  static let current: BuildIdentity = {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return .notBundled }
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
      SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let dictionary = info as? [String: Any]
    else { return .unsigned }
    return classify(signingInformation: dictionary)
  }()

  /// `kSecCodeSignatureAdhoc`.
  static let adHocFlag: UInt32 = 0x0002

  static func classify(signingInformation info: [String: Any]) -> BuildIdentity {
    guard info[kSecCodeInfoIdentifier as String] is String else { return .unsigned }
    let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    if flags & adHocFlag != 0 { return .adHoc }
    let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
    let leaf = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
    if let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
      leaf?.hasPrefix("Developer ID Application") == true
    {
      return .developerID(team: team)
    }
    return .certificate(leaf ?? "an unknown certificate")
  }
}

/// `GET https://api.github.com/repos/aymericbeaumet/flash/releases/latest`:
/// nothing but the conditional request header and an honest user agent.
struct GitHubReleaseSource: UpdateReleaseSource {
  var version: String

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }()

  func latest(
    etag: String?,
    completion: @escaping (Result<(release: UpdateRelease?, etag: String?), UpdateError>) -> Void
  ) {
    var request = URLRequest(url: UpdateRelease.latestURL)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("Flash/\(version)", forHTTPHeaderField: "User-Agent")
    if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    Self.session.dataTask(with: request) { data, response, error in
      if let error { return completion(.failure(UpdateError(error.localizedDescription))) }
      guard let http = response as? HTTPURLResponse else {
        return completion(.failure(UpdateError("GitHub sent no HTTP answer")))
      }
      let tag = http.value(forHTTPHeaderField: "ETag")
      switch http.statusCode {
      case 200:
        switch UpdateRelease.parse(latest: data ?? Data()) {
        case .success(let release): completion(.success((release, tag)))
        case .failure(let reason): completion(.failure(UpdateError(reason.description)))
        }
      case 304: completion(.success((nil, tag)))
      case 403, 429: completion(.failure(UpdateError("GitHub's rate limit; trying again later")))
      default: completion(.failure(UpdateError("GitHub answered HTTP \(http.statusCode)")))
      }
    }.resume()
  }
}

/// The release asset, over HTTPS, to a file in the staging folder.
struct URLSessionUpdateDownloader: UpdateDownloading {
  var version: String

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 15 * 60
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }()

  func download(
    _ url: URL, to destination: URL, completion: @escaping (Result<Void, UpdateError>) -> Void
  ) {
    guard url.scheme == "https" else {
      return completion(.failure(UpdateError("refusing a download over \(url.scheme ?? "?")")))
    }
    var request = URLRequest(url: url)
    request.setValue("Flash/\(version)", forHTTPHeaderField: "User-Agent")
    Self.session.downloadTask(with: request) { file, response, error in
      if let error { return completion(.failure(UpdateError(error.localizedDescription))) }
      guard let file, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return completion(.failure(UpdateError("the download answered HTTP \(status)")))
      }
      do {
        try FileManager.default.moveItem(at: file, to: destination)
        completion(.success(()))
      } catch {
        completion(.failure(UpdateError("cannot keep the download: \(error)")))
      }
    }.resume()
  }
}

/// `/usr/bin/ditto -x -k`, which keeps the bundle's symlinks, permissions
/// and extended attributes as `ditto -c -k --keepParent` packed them.
struct DittoUpdateUnpacker: UpdateUnpacking {
  func unpack(_ archive: URL, into directory: URL) -> Result<URL, UpdateError> {
    // Bounds this one extraction of a ~35 MB archive.
    let result = BoundedCommand.run(
      ["/usr/bin/ditto", "-x", "-k", archive.path, directory.path],
      environment: ProcessInfo.processInfo.environment, timeout: 120, capture: .none)
    if let failure = result.launchFailure {
      return .failure(UpdateError("ditto did not start: \(failure)"))
    }
    guard !result.timedOut else { return .failure(UpdateError("unpacking timed out")) }
    guard result.status == 0 else {
      return .failure(UpdateError("ditto failed with status \(result.status ?? -1)"))
    }
    let apps =
      ((try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "app" }
    guard apps.count == 1, let app = apps.first, app.lastPathComponent == "Flash.app" else {
      return .failure(UpdateError("the archive holds no single Flash.app"))
    }
    return .success(app)
  }
}

/// The new bundle is Flash, the release's version, and validly signed, deep
/// and strict. A Developer ID build also requires the new bundle to satisfy
/// its own designated requirement: the same team, so macOS keeps Flash's
/// permissions and nobody else's build is installed.
struct CodeSignatureUpdateVerifier: UpdateBundleVerifying {
  func verify(_ bundle: URL, release: UpdateRelease, identity: BuildIdentity) -> Result<
    Void, UpdateError
  > {
    let plist = bundle.appendingPathComponent("Contents/Info.plist")
    guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else {
      return .failure(UpdateError("the bundle has no Info.plist"))
    }
    guard info["CFBundleIdentifier"] as? String == "com.flash.app" else {
      return .failure(UpdateError("the bundle is not com.flash.app"))
    }
    guard info["CFBundleShortVersionString"] as? String == release.version else {
      return .failure(UpdateError("the bundle is not version \(release.version)"))
    }
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else { return .failure(UpdateError("the bundle's signature cannot be read")) }
    guard let requirement = Self.requirement(for: identity) else {
      return .failure(UpdateError("this build's signing requirement cannot be read"))
    }
    let flags = SecCSFlags(
      rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    var error: Unmanaged<CFError>?
    let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, &error)
    guard status == errSecSuccess else {
      let reason = error?.takeRetainedValue().localizedDescription ?? "status \(status)"
      return .failure(UpdateError("the bundle's signature does not hold: \(reason)"))
    }
    return .success(())
  }

  /// The running app's designated requirement for a Developer ID build;
  /// otherwise only the identifier, since an ad-hoc signature is pinned to
  /// its own binary.
  private static func requirement(for identity: BuildIdentity) -> SecRequirement? {
    if case .developerID = identity {
      var code: SecCode?
      var running: SecStaticCode?
      var requirement: SecRequirement?
      guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
        SecCodeCopyStaticCode(code, [], &running) == errSecSuccess, let running,
        SecCodeCopyDesignatedRequirement(running, [], &requirement) == errSecSuccess
      else { return nil }
      return requirement
    }
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        "identifier \"com.flash.app\"" as CFString, [], &requirement) == errSecSuccess
    else { return nil }
    return requirement
  }
}

/// One `renamex_np(RENAME_SWAP)`: the running bundle's path holds the new
/// version at once, and the old bundle stays intact where the new one was,
/// so an interrupted install leaves one complete Flash or the other.
struct BundleSwapInstaller: UpdateInstalling {
  func canReplace(_ bundle: URL) -> Bool {
    access(bundle.path, W_OK) == 0
      && access(bundle.deletingLastPathComponent().path, W_OK) == 0
  }

  func swap(_ staged: URL, with installed: URL) -> Result<Void, UpdateError> {
    guard renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
      return .failure(
        UpdateError("the bundles could not be swapped: \(String(cString: strerror(errno)))"))
    }
    return .success(())
  }

  func register(_ bundle: URL) {
    _ = LSRegisterURL(bundle as CFURL, true)
  }

  func sameVolume(_ a: URL, _ b: URL) -> Bool {
    var first = stat()
    var second = stat()
    try? FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    guard stat(a.path, &first) == 0, stat(b.path, &second) == 0 else { return false }
    return first.st_dev == second.st_dev
  }
}

extension UpdateController {
  /// The resident's updater over GitHub, the real bundle and Updates/.
  static func live() -> UpdateController {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    return UpdateController(
      environment: Environment(
        currentVersion: version, bundleURL: Bundle.main.bundleURL, identity: .current,
        directory: defaultDirectory, source: GitHubReleaseSource(version: version),
        downloader: URLSessionUpdateDownloader(version: version),
        unpacker: DittoUpdateUnpacker(), verifier: CodeSignatureUpdateVerifier(),
        installer: BundleSwapInstaller()))
  }
}

/// Start the installed bundle as a new process that waits for this one to
/// let go of the resident lock, then quit: one resident at every moment.
enum UpdateRelaunch {
  /// The variable the new process reads in `main.swift`.
  static let waitVariable = "FLASH_UPDATE_RELAUNCH_PID"

  static func relaunch(_ bundle: URL, completion: @escaping (Error?) -> Void) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.environment = [waitVariable: String(getpid())]
    NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
      DispatchQueue.main.async { completion(error) }
    }
  }
}
