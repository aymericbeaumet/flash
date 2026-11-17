import Foundation

/// One connection's protocol state, pure: the server feeds it frames and
/// performs the actions it returns. `hello` must come first and name
/// `IPCProtocol.version`; afterwards a connection runs at most
/// `maxInFlightRequests` requests at once, each under a distinct `id`, and
/// replaces its subscription with every `subscribe`.
struct IPCSession {
  enum Phase: Equatable {
    case awaitingHello
    case ready
    case closed
  }

  enum Action: Equatable {
    /// Write this frame.
    case send(Data)
    /// Close once the frames before it are written (best effort).
    case close
    /// Run `invocation` and answer `id` with its result.
    case run(id: String, invocation: CommandInvocation)
    /// Replace the subscription with `events` (concrete names; empty
    /// unsubscribes), then answer `id` with `subscribed`.
    case subscribe(id: String, events: [String])
  }

  let welcome: Data
  let maxInFlightRequests: Int
  private(set) var phase = Phase.awaitingHello
  private(set) var inFlight: Set<String> = []
  /// The client's own name from `hello`, for the log.
  private(set) var client: String?

  init(welcome: Data, maxInFlightRequests: Int = IPCProtocol.maxInFlightRequests) {
    self.welcome = welcome
    self.maxInFlightRequests = maxInFlightRequests
  }

  mutating func receive(_ output: IPCFrameReader.Output) -> [Action] {
    guard phase != .closed else { return [] }
    switch output {
    case .tooLarge:
      return fail(IPCProtocol.Rejection(code: .frameTooLarge, message: "a line is too long"))
    case .frame(let frame):
      return receive(frame)
    }
  }

  private mutating func receive(_ frame: Data) -> [Action] {
    let message: IPCProtocol.ClientMessage
    switch IPCProtocol.decodeClientMessage(frame) {
    case .failure(let rejection):
      if phase == .awaitingHello, rejection.id != nil {
        return fail(handshakeRequired)
      }
      return rejection.code.closesConnection
        ? fail(rejection) : [.send(IPCProtocol.errorFrame(rejection))]
    case .success(let decoded):
      message = decoded
    }
    switch (phase, message) {
    case (.awaitingHello, .hello(let version, let client)):
      guard version == IPCProtocol.version else {
        return fail(
          IPCProtocol.Rejection(
            code: .protocolMismatch,
            message: "this resident speaks protocol \(IPCProtocol.version), not \(version)"))
      }
      phase = .ready
      self.client = client
      return [.send(welcome)]
    case (.awaitingHello, _), (.ready, .hello):
      return fail(handshakeRequired)
    case (.ready, .request(let id, let words, let cwd)):
      if inFlight.contains(id) {
        return [reject(.invalidRequest, "request \(id) is already running", id: id)]
      }
      guard inFlight.count < maxInFlightRequests else {
        return [
          reject(
            .tooManyRequests, "\(maxInFlightRequests) requests are already running", id: id)
        ]
      }
      inFlight.insert(id)
      return [.run(id: id, invocation: CommandInvocation(words: words, workingDirectory: cwd))]
    case (.ready, .subscribe(let id, let patterns)):
      switch IPCProtocol.resolveSubscription(patterns) {
      case .failure(var rejection):
        rejection.id = id
        return [.send(IPCProtocol.errorFrame(rejection))]
      case .success(let events):
        return [.subscribe(id: id, events: events)]
      }
    case (.closed, _):
      return []
    }
  }

  /// A request's result went out: its `id` may be used again.
  mutating func finished(id: String) {
    inFlight.remove(id)
  }

  /// The handshake deadline passed: close unless `hello` arrived.
  mutating func handshakeExpired() -> [Action] {
    guard phase == .awaitingHello else { return [] }
    return fail(
      IPCProtocol.Rejection(code: .handshakeTimeout, message: "no hello in time"))
  }

  /// End the session with `rejection`, whatever its phase.
  mutating func fail(_ rejection: IPCProtocol.Rejection) -> [Action] {
    guard phase != .closed else { return [] }
    phase = .closed
    return [.send(IPCProtocol.errorFrame(rejection)), .close]
  }

  private var handshakeRequired: IPCProtocol.Rejection {
    IPCProtocol.Rejection(
      code: .handshakeRequired,
      message: "say hello once, first, with protocol \(IPCProtocol.version)")
  }

  private func reject(_ code: IPCProtocol.ErrorCode, _ message: String, id: String) -> Action {
    .send(IPCProtocol.errorFrame(code, message, id: id))
  }
}
