import Foundation

/// A host surface that can ask plugins for ephemeral candidates derived from
/// the user's current input. Query evaluators are distinct from ordinary
/// candidate sources: their results belong only to one exact query and must
/// never be appended to the session's frozen candidate snapshot.
public enum QueryEvaluationSurface: String, Codable, Hashable, Sendable {
  case flashlight
}

public struct QueryEvaluationRequest: Sendable {
  public let surface: QueryEvaluationSurface
  public let scope: CandidateScope
  public let text: String
  /// Literal marker ownership. When present, the host routes the request only
  /// to evaluators that declared the same marker; nil is the additive lane.
  public let exclusivePrefix: String?

  public init(
    surface: QueryEvaluationSurface,
    scope: CandidateScope,
    text: String,
    exclusivePrefix: String? = nil
  ) {
    self.surface = surface
    self.scope = scope
    self.text = text
    self.exclusivePrefix = exclusivePrefix
  }
}

/// A pure, warm-state query processor. Implementations may parse and compute
/// from `request.text`, but must not perform filesystem, subprocess, or network
/// I/O on this path. Any external state must be prepared before evaluation.
public protocol FlashQueryEvaluator: AnyObject {
  var queryEvaluatorIdentifier: String { get }
  /// Static arbitration order for additive answers. This is provider-level
  /// policy, not a per-result confidence score.
  var queryEvaluationPriority: Int { get }
  var queryEvaluationSurfaces: Set<QueryEvaluationSurface> { get }
  var queryEvaluationPrefixes: Set<String> { get }

  func evaluateQuery(
    _ request: QueryEvaluationRequest,
    in environment: FlashSourceEnvironment,
    completion: @escaping ([Candidate]) -> Void
  )
}

public extension FlashQueryEvaluator {
  var queryEvaluationPrefixes: Set<String> { [] }
}
