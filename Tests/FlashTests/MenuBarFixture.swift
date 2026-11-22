import ApplicationServices
import Foundation

@testable import flash

/// A menu bar that exists only in the test: its elements are application
/// elements of pids nothing runs under, and every read and press is
/// answered here. No test built on it reads or presses a real app's menu.
final class MenuBarFixture {
  struct Node {
    var role: String?
    var title: String?
    /// Nil: the element does not say.
    var enabled: Bool?
    var children: [pid_t] = []
  }

  /// The pid the fixture's app runs under, and its `AXMenuBar` element.
  let owner: pid_t
  let bar: pid_t
  private let lock = NSLock()
  private var nodes: [pid_t: Node] = [:]
  private var readLog: [pid_t] = []
  private var pressLog: [(element: pid_t, action: String)] = []
  private var pressStatus = AXError.success

  init(owner: pid_t = 4_242, bar: pid_t = 900_000) {
    self.owner = owner
    self.bar = bar
  }

  func set(
    _ id: pid_t, _ role: String?, _ title: String? = nil, enabled: Bool? = true,
    _ children: [pid_t] = []
  ) {
    lock.lock()
    nodes[id] = Node(role: role, title: title, enabled: enabled, children: children)
    lock.unlock()
  }

  /// Elements read so far, in order.
  var reads: [pid_t] {
    lock.lock()
    defer { lock.unlock() }
    return readLog
  }

  /// Elements pressed so far, in order, with the action each was sent.
  var presses: [(element: pid_t, action: String)] {
    lock.lock()
    defer { lock.unlock() }
    return pressLog
  }

  /// What the next presses answer.
  func answerPresses(with status: AXError) {
    lock.lock()
    pressStatus = status
    lock.unlock()
  }

  func element(_ id: pid_t) -> AXUIElement { AXUIElementCreateApplication(id) }

  private static func id(of element: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return pid
  }

  /// A broker whose menu-bar snapshots walk this fixture. `owner` answers
  /// which app owns the bar, the fixture's own by default; `roots` is where
  /// a window snapshot starts, the application element by default.
  func broker(
    owner: (() -> pid_t?)? = nil, hasMenuBar: Bool = true,
    roots: @escaping (AXUIElement) -> [AXUIElement] = { [$0] }
  ) -> AXBroker {
    let pid = self.owner
    return AXBroker(
      roots: roots,
      menuBarOwner: owner ?? { pid },
      menuBar: { [self] _ in hasMenuBar ? element(bar) : nil },
      readAttributes: { [self] element, names in read(element, names) },
      performAction: { [self] element, action in press(element, action) })
  }

  private func read(_ element: AXUIElement, _ names: [String]) -> (AXError, CFArray?) {
    let id = Self.id(of: element)
    lock.lock()
    readLog.append(id)
    let node = nodes[id] ?? Node()
    lock.unlock()
    let values: [Any] = names.map { name in
      if name == kAXRoleAttribute as String { return node.role ?? NSNull() }
      if name == kAXTitleAttribute as String { return node.title ?? NSNull() }
      if name == kAXEnabledAttribute as String {
        return node.enabled.map { $0 ? kCFBooleanTrue as Any : kCFBooleanFalse as Any } ?? NSNull()
      }
      if name == kAXChildrenAttribute as String { return node.children.map(self.element) }
      return NSNull()
    }
    return (.success, values as CFArray)
  }

  private func press(_ element: AXUIElement, _ action: String) -> AXError {
    lock.lock()
    defer { lock.unlock() }
    pressLog.append((Self.id(of: element), action))
    return pressStatus
  }
}
