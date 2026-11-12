import AppKit

/// The resident's socket (`IPCServer`): `flash <words>` from a terminal, a
/// script or a hotkey daemon arrives here and runs exactly as `:<words>`,
/// through the command line's one runner; `flash events watch` subscribes
/// to the host events `emitHostEvent` fans out.
extension AppDelegate {
  func startIPCServer() {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    let server = IPCServer(
      endpoint: .standard, serverName: "Flash \(version) (\(build))",
      runner: { [weak self] invocation, arrivedAt, completion in
        guard let self else { return completion(.failed("Flash is quitting")) }
        // An activation dates from the request's arrival (`[latency] hints_visible`).
        Trace.triggered(at: arrivedAt) {
          Trace.ensure(.cli) {
            self.runInvocation(invocation, surface: .cli, completion: completion)
          }
        }
      },
      subscriptions: { [weak self] connection, events, done in
        self?.ipcEvents.setSubscription(connection, events: events)
        done()
      })
    ipcEvents.deliver = { [weak server] frame, key, connections in
      server?.deliver(frame, coalescingKey: key, to: connections)
    }
    ipcEvents.subscribersDidChange = { [weak self] in self?.reconcileHostEventSources() }
    do {
      try server.start()
      ipcServer = server
    } catch {
      FlashLog.error("[ipc] listen_failed", fields: ["reason": "\(error)"])
    }
  }

  func stopIPCServer() {
    ipcServer?.stop()
    ipcServer = nil
    ipcEvents.deliver = nil
  }
}
