import Foundation

/// A completion its caller expects on the main queue. The closure is not
/// `Sendable`: it reads and writes its caller's main-queue state. It crosses
/// to that queue inside this box and is called nowhere else.
public struct MainQueueCompletion<Value>: @unchecked Sendable {
  private let body: (Value) -> Void

  public init(_ body: @escaping (Value) -> Void) { self.body = body }

  /// Call the completion on the main queue, on a later turn of it, with the
  /// value `make` builds there.
  public func deliver(_ make: @escaping @Sendable () -> Value) {
    DispatchQueue.main.async { self.body(make()) }
  }
}
