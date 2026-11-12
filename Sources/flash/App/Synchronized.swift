import Foundation

/// A stored value one thread sets while others read it: a tunable applied
/// from the configuration, or a test seam a test overrides while a plugin's
/// queue reads it. Each read and write takes a lock, so neither ever sees a
/// torn value or races the other.
@propertyWrapper
final class Synchronized<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(wrappedValue: Value) {
    value = wrappedValue
  }

  var wrappedValue: Value {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}
