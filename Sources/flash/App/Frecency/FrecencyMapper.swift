import FlashCore
import Foundation

/// Derive a stable frecency item key from a `Candidate`. App rows
/// prefer bundle id (the most durable handle); web rows canonicalize
/// the URL (lowercased host, stripped `www.`, trimmed trailing `/`)
/// so two captures of the same page collapse to one row.
enum FrecencyMapper {
  static func itemKey(for candidate: Candidate) -> String? {
    if candidate.kind == .app {
      if !candidate.bundleIdentifier.isEmpty {
        return FrecencyKey.app(bundleID: candidate.bundleIdentifier)
      }
      if let path = candidate.url?.standardizedFileURL.path, !path.isEmpty {
        return FrecencyKey.appPath(path)
      }
    }
    if let url = candidate.url?.absoluteString, !url.isEmpty {
      return FrecencyKey.url(canonicalizeURL(url))
    }
    return nil
  }

  static func canonicalizeURL(_ raw: String) -> String {
    guard let url = URL(string: raw) else { return raw }
    var host = url.host?.lowercased() ?? ""
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    let scheme = url.scheme?.lowercased() ?? ""
    var path = url.path
    if path.hasSuffix("/") { path = String(path.dropLast()) }
    let suffix: String
    if let q = url.query, !q.isEmpty { suffix = "?\(q)" } else { suffix = "" }
    if scheme.isEmpty { return "\(host)\(path)\(suffix)" }
    return "\(scheme)://\(host)\(path)\(suffix)"
  }
}
