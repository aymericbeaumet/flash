import Foundation
import Network

final class DebugServer {
  let hostPort: String
  private let stateProvider: () -> [String: Any]
  private let queue = DispatchQueue(label: "flash.debug_server", qos: .utility)
  private var listener: NWListener?
  private var logSinkID: UUID?
  private var logs: [[String: Any]] = []
  private var eventConnections: [UUID: NWConnection] = [:]
  private let maxLogs = 2_000

  init(hostPort: String, stateProvider: @escaping () -> [String: Any]) {
    self.hostPort = hostPort
    self.stateProvider = stateProvider
  }

  func start() {
    guard let endpoint = Self.parse(hostPort: hostPort) else {
      FlashLog.warn("[debug] invalid http_host \(hostPort)")
      return
    }
    do {
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: endpoint.host, port: endpoint.port)
      let listener = try NWListener(using: parameters)
      listener.newConnectionHandler = { [weak self] connection in
        self?.handle(connection)
      }
      listener.stateUpdateHandler = { state in
        if case .failed(let error) = state {
          FlashLog.warn("[debug] server failed \(error)")
        }
      }
      listener.start(queue: queue)
      self.listener = listener
      logSinkID = FlashLog.addSink { [weak self] record in
        self?.append(record)
      }
      FlashLog.info("[debug] server listening http://\(hostPort)")
    } catch {
      FlashLog.warn("[debug] could not start server \(hostPort): \(error)")
    }
  }

  func stop() {
    if let logSinkID {
      FlashLog.removeSink(logSinkID)
    }
    logSinkID = nil
    listener?.cancel()
    listener = nil
    for connection in eventConnections.values {
      connection.cancel()
    }
    eventConnections.removeAll()
  }

  func broadcastState() {
    queue.async { [weak self] in
      guard let self else { return }
      self.broadcast(event: "state", object: self.stateProvider())
    }
  }

  private func append(_ record: FlashLog.Record) {
    queue.async { [weak self] in
      guard let self else { return }
      let object = record.jsonObject
      self.logs.append(object)
      if self.logs.count > self.maxLogs {
        self.logs.removeFirst(self.logs.count - self.maxLogs)
      }
      self.broadcast(event: "log", object: object)
    }
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
      guard let self else {
        connection.cancel()
        return
      }
      guard let data, let request = String(data: data, encoding: .utf8) else {
        connection.cancel()
        return
      }
      let path = Self.requestPath(request)
      switch path {
      case "/":
        self.sendHTML(connection)
      case "/state":
        self.sendJSON(self.stateProvider(), connection: connection)
      case "/logs":
        self.sendJSON(["logs": self.logs], connection: connection)
      case "/events":
        self.startEvents(connection)
      default:
        self.sendText("not found", status: "404 Not Found", connection: connection)
      }
    }
  }

  private func sendHTML(_ connection: NWConnection) {
    send(
      Self.response(
        body: Self.pageHTML,
        contentType: "text/html; charset=utf-8"),
      connection: connection,
      close: true)
  }

  private func sendJSON(_ object: Any, connection: NWConnection) {
    let body = Self.jsonString(object)
    send(
      Self.response(body: body, contentType: "application/json; charset=utf-8"),
      connection: connection,
      close: true)
  }

  private func sendText(_ text: String, status: String, connection: NWConnection) {
    send(
      Self.response(body: text, status: status, contentType: "text/plain; charset=utf-8"),
      connection: connection,
      close: true)
  }

  private func startEvents(_ connection: NWConnection) {
    let id = UUID()
    eventConnections[id] = connection
    let headers = """
      HTTP/1.1 200 OK\r
      Content-Type: text/event-stream\r
      Cache-Control: no-cache\r
      Connection: keep-alive\r
      \r
      """
    send(headers, connection: connection, close: false)
    sendEvent("state", object: stateProvider(), connection: connection)
    sendEvent("logs", object: ["logs": logs], connection: connection)
    connection.stateUpdateHandler = { [weak self] state in
      if case .cancelled = state {
        self?.queue.async {
          self?.eventConnections.removeValue(forKey: id)
        }
      }
    }
  }

  private func broadcast(event: String, object: Any) {
    for connection in eventConnections.values {
      sendEvent(event, object: object, connection: connection)
    }
  }

  private func sendEvent(_ event: String, object: Any, connection: NWConnection) {
    let payload = "event: \(event)\ndata: \(Self.jsonString(object))\n\n"
    send(payload, connection: connection, close: false)
  }

  private func send(_ text: String, connection: NWConnection, close: Bool) {
    connection.send(content: text.data(using: .utf8), completion: .contentProcessed { _ in
      if close {
        connection.cancel()
      }
    })
  }

  private static func response(
    body: String,
    status: String = "200 OK",
    contentType: String
  ) -> String {
    let length = body.data(using: .utf8)?.count ?? 0
    return """
      HTTP/1.1 \(status)\r
      Content-Type: \(contentType)\r
      Content-Length: \(length)\r
      Cache-Control: no-cache\r
      \r
      \(body)
      """
  }

  private static func requestPath(_ request: String) -> String {
    let first = request.split(separator: "\n", maxSplits: 1).first ?? ""
    let parts = first.split(separator: " ")
    guard parts.count >= 2 else { return "/" }
    return String(parts[1].split(separator: "?", maxSplits: 1).first ?? "/")
  }

  private static func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
  }

  private static func parse(hostPort: String) -> (host: NWEndpoint.Host, port: NWEndpoint.Port)? {
    let trimmed = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
    let hostRaw: String
    let portRaw: String
    if trimmed.hasPrefix("[::1]:") {
      hostRaw = "::1"
      portRaw = String(trimmed.dropFirst("[::1]:".count))
    } else {
      let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { return nil }
      hostRaw = parts[0]
      portRaw = parts[1]
    }
    guard ["localhost", "127.0.0.1", "::1"].contains(hostRaw),
      let portInt = UInt16(portRaw),
      let port = NWEndpoint.Port(rawValue: portInt)
    else { return nil }
    return (NWEndpoint.Host(hostRaw), port)
  }

  private static let pageHTML = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Flash Debug</title>
      <style>
        * { box-sizing: border-box; }
        body { margin: 0; font: 12px/1.35 ui-monospace, SFMono-Regular, Menlo, monospace; background: #101214; color: #e7edf3; }
        header { height: 36px; display: flex; align-items: center; gap: 16px; padding: 0 12px; border-bottom: 1px solid #303841; background: #171b20; }
        main { height: calc(100vh - 36px); display: grid; grid-template-columns: 1.1fr 1fr 1.4fr; grid-template-rows: 1fr 1fr; gap: 1px; background: #303841; }
        section { min-height: 0; overflow: auto; background: #101214; padding: 10px; }
        h2 { margin: 0 0 8px; font-size: 12px; color: #8bd3ff; }
        pre { margin: 0; white-space: pre-wrap; word-break: break-word; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 3px 6px; border-bottom: 1px solid #232a31; text-align: left; vertical-align: top; }
        th { color: #8bd3ff; position: sticky; top: 0; background: #101214; }
        .logs { grid-column: 3; grid-row: 1 / span 2; }
        .log { border-bottom: 1px solid #232a31; padding: 3px 0; }
        .warn,.error,.fatal { color: #ffb4a8; }
        .debug,.trace { color: #aeb8c2; }
      </style>
    </head>
    <body>
      <header><strong>Flash Debug</strong><span id="summary"></span></header>
      <main>
        <section><h2>State</h2><pre id="state">{}</pre></section>
        <section><h2>Resolved Config</h2><pre id="config">{}</pre></section>
        <section><h2>Plugins</h2><table><thead><tr><th>ID</th><th>State</th><th>PID</th><th>HB</th><th>Snap</th><th>Actions</th><th>Error</th></tr></thead><tbody id="plugins"></tbody></table></section>
        <section><h2>Recent Events</h2><pre id="events"></pre></section>
        <section class="logs"><h2>Logs</h2><div id="logs"></div></section>
      </main>
      <script>
        const stateEl = document.getElementById('state');
        const configEl = document.getElementById('config');
        const pluginsEl = document.getElementById('plugins');
        const logsEl = document.getElementById('logs');
        const eventsEl = document.getElementById('events');
        const summaryEl = document.getElementById('summary');
        let logs = [];
        function renderState(s) {
          stateEl.textContent = JSON.stringify({mode:s.mode, focused_app:s.focused_app, overlay:s.overlay}, null, 2);
          configEl.textContent = JSON.stringify(s.config || {}, null, 2);
          const plugins = s.plugins || [];
          pluginsEl.innerHTML = plugins.map(p => `<tr><td>${p.id} ${p.version}</td><td>${p.state}</td><td>${p.pid ?? '-'}</td><td>${p.heartbeat_age_ms ?? '-'}</td><td>${p.target_count}t/${p.candidate_count}c</td><td>${p.action_count}</td><td>${p.last_error ?? ''}</td></tr>`).join('');
          summaryEl.textContent = `${plugins.length} plugins`;
        }
        function renderLogs() {
          logsEl.innerHTML = logs.slice(-700).reverse().map(l => `<div class="log ${l.level}">[${l.level}] ${l.source}: ${l.message}</div>`).join('');
        }
        fetch('/state').then(r => r.json()).then(renderState);
        fetch('/logs').then(r => r.json()).then(v => { logs = v.logs || []; renderLogs(); });
        const es = new EventSource('/events');
        es.addEventListener('state', e => { const s = JSON.parse(e.data); renderState(s); eventsEl.textContent = new Date().toISOString() + ' state\\n' + eventsEl.textContent; });
        es.addEventListener('log', e => { logs.push(JSON.parse(e.data)); renderLogs(); });
        es.addEventListener('logs', e => { logs = JSON.parse(e.data).logs || []; renderLogs(); });
      </script>
    </body>
    </html>
    """
}
