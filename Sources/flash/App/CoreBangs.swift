import FlashCore
import Foundation

/// A flashlight bang Flash itself owns: once `!<token> ` is confirmed, the
/// pool becomes `scope`'s rows for the rest of the query, exactly as if the
/// user had typed `@<type>`.
struct CoreBang: Equatable, Sendable {
  let token: String
  let description: String
  let scope: SourceScope
}

/// Core bangs take precedence over every plugin bang, and a plugin declaring
/// one of these tokens fails to load.
enum CoreBangs {
  static let all: [CoreBang] = [FileSearchSource.bang, ClipboardFlashlight.bang]

  static func bang(token: String) -> CoreBang? {
    let token = token.lowercased()
    return all.first { $0.token == token }
  }

  /// Synthetic `!<token>` rows for the bang list, shaped like plugin bangs.
  static var candidates: [Candidate] {
    all.map { bang in
      Candidate(
        kind: CandidateFinder.bangKind,
        sourceID: "bang:core",
        source: "bang",
        title: "!\(bang.token)",
        subtitle: bang.description,
        sourcePayload: bang.token)
    }
  }
}
