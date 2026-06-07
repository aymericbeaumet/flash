import Foundation
import Network

final class DebugServer {
  let hostPort: String
  private(set) var listeningPort: UInt16?
  private let stateProvider: () -> [String: Any]
  private let queue = DispatchQueue(label: "flash.debug_server", qos: .utility)
  private var listener: NWListener?
  private var logSinkID: UUID?
  private var stateTimer: DispatchSourceTimer?
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
      let listener = try NWListener(using: .tcp, on: endpoint.port)
      listener.newConnectionHandler = { [weak self] connection in
        self?.handle(connection)
      }
      listener.stateUpdateHandler = { [weak self] state in
        if case .ready = state {
          let port = listener.port?.rawValue
          self?.listeningPort = port
          FlashLog.info("[debug] server listening http://\(endpoint.host):\(port ?? 0)")
        }
        if case .failed(let error) = state {
          FlashLog.warn("[debug] server failed \(error)")
        }
      }
      listener.start(queue: queue)
      self.listener = listener
      startStateTimer()
      logSinkID = FlashLog.addSink { [weak self] record in
        self?.append(record)
      }
    } catch {
      FlashLog.warn("[debug] could not start server \(hostPort): \(error)")
    }
  }

  func stop() {
    if let logSinkID {
      FlashLog.removeSink(logSinkID)
    }
    logSinkID = nil
    stateTimer?.cancel()
    stateTimer = nil
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

  private func startStateTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(150))
    timer.setEventHandler { [weak self] in
      guard let self, !self.eventConnections.isEmpty else { return }
      self.broadcast(event: "state", object: self.stateProvider())
    }
    stateTimer = timer
    timer.resume()
  }

  private func handle(_ connection: NWConnection) {
    guard Self.isLoopback(endpoint: connection.endpoint) else {
      connection.cancel()
      return
    }
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

  static func parse(hostPort: String) -> (host: String, port: NWEndpoint.Port)? {
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
    return (hostRaw, port)
  }

  static func isLoopback(endpoint: NWEndpoint) -> Bool {
    guard case .hostPort(let host, _) = endpoint else { return false }
    switch host {
    case .name(let name, _):
      return name == "localhost"
    case .ipv4(let address):
      return address.rawValue.first == 127
    case .ipv6(let address):
      return address == IPv6Address("::1")
    default:
      return false
    }
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
        header { height: 36px; display: flex; align-items: center; padding: 0 12px; border-bottom: 1px solid #303841; background: #171b20; }
        main { height: calc(100vh - 36px); display: grid; grid-template-rows: minmax(0, 1fr) minmax(0, 1fr); gap: 1px; background: #303841; }
        .info-grid { min-height: 0; display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 1px; background: #303841; }
        section { min-height: 0; overflow: auto; background: #101214; padding: 10px; }
        h2 { margin: 0 0 8px; font-size: 12px; color: #8bd3ff; letter-spacing: 0; }
        pre { margin: 0; white-space: pre-wrap; word-break: break-word; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 3px 6px; border-bottom: 1px solid #232a31; text-align: left; vertical-align: top; }
        th { color: #8bd3ff; position: sticky; top: 0; background: #101214; }
        .logs { min-height: 0; display: grid; grid-template-rows: auto minmax(0, 1fr); padding: 0; }
        .log-toolbar { display: flex; align-items: center; gap: 8px; padding: 8px 10px; border-bottom: 1px solid #232a31; background: #101214; }
        .log-toolbar h2 { margin: 0 8px 0 0; }
        input, select { height: 24px; border: 1px solid #34414d; background: #171b20; color: #e7edf3; font: inherit; padding: 2px 7px; border-radius: 4px; }
        input { width: min(520px, 42vw); }
        .count { color: #aeb8c2; margin-left: auto; }
        #logs { overflow: auto; padding: 0 10px 10px; }
        #logTopPad, #logBottomPad { height: 0; }
        .log { height: 24px; display: grid; grid-template-columns: 180px 68px minmax(210px, 0.45fr) minmax(320px, 1fr); gap: 8px; align-items: center; border-bottom: 1px solid #232a31; padding: 2px 0; }
        .timestamp { color: #93a1ad; white-space: nowrap; }
        .source { color: #8bd3ff; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .message { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .level { display: inline-block; width: 56px; text-align: center; border-radius: 4px; padding: 1px 5px; font-weight: 700; text-transform: uppercase; }
        .level-trace { color: #9aa4ad; background: #20262d; }
        .level-debug { color: #c2ccd6; background: #26313b; }
        .level-info { color: #10222d; background: #8bd3ff; }
        .level-warn { color: #2d2200; background: #ffd166; }
        .level-error { color: #fff3f2; background: #d9574f; }
        .level-fatal { color: #fff7fb; background: #b21e59; }
      </style>
    </head>
    <body>
      <header><strong>Flash Debug</strong></header>
      <main>
        <div class="info-grid">
          <section><h2>Current State</h2><pre id="state">{}</pre></section>
          <section><h2>Resolved Config</h2><pre id="config">{}</pre></section>
          <section><h2 id="pluginsTitle">Loaded Plugins</h2><table><thead><tr><th>ID</th><th>State</th><th>PID</th><th>HB</th><th>Snap</th><th>Actions</th><th>Source</th><th>Error</th></tr></thead><tbody id="plugins"></tbody></table></section>
        </div>
        <section class="logs">
          <div class="log-toolbar">
            <h2>Logs</h2>
            <input id="logSearch" type="search" placeholder="search message, source, fields">
            <select id="logLevel">
              <option value="">all levels</option>
              <option value="trace">trace</option>
              <option value="debug">debug</option>
              <option value="info">info</option>
              <option value="warn">warn</option>
              <option value="error">error</option>
              <option value="fatal">fatal</option>
            </select>
            <span class="count" id="logCount">0 logs</span>
          </div>
          <div id="logs"><div id="logTopPad"></div><div id="logRows"></div><div id="logBottomPad"></div></div>
        </section>
      </main>
      <script>
        const stateEl = document.getElementById('state');
        const configEl = document.getElementById('config');
        const pluginsEl = document.getElementById('plugins');
        const pluginsTitleEl = document.getElementById('pluginsTitle');
        const logsEl = document.getElementById('logs');
        const logRowsEl = document.getElementById('logRows');
        const logTopPadEl = document.getElementById('logTopPad');
        const logBottomPadEl = document.getElementById('logBottomPad');
        const logSearchEl = document.getElementById('logSearch');
        const logLevelEl = document.getElementById('logLevel');
        const logCountEl = document.getElementById('logCount');
        let logs = [];
        let filteredLogs = [];
        let scrollRenderScheduled = false;
        const rowHeight = 24;
        const overscan = 40;
        function escapeHTML(value) {
          return String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
        }
        function timestamp(ms) {
          if (!ms) return '-';
          const d = new Date(ms);
          const pad = (n, w = 2) => String(n).padStart(w, '0');
          return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`;
        }
        function renderState(s) {
          stateEl.textContent = JSON.stringify({mode:s.mode, focused_app:s.focused_app, overlay:s.overlay}, null, 2);
          configEl.textContent = JSON.stringify(s.config || {}, null, 2);
          const plugins = s.plugins || [];
          pluginsTitleEl.textContent = `Loaded Plugins (${plugins.length})`;
          pluginsEl.innerHTML = plugins.map(p => `<tr><td>${escapeHTML(p.id)} ${escapeHTML(p.version)}</td><td>${escapeHTML(p.state)}</td><td>${escapeHTML(p.pid ?? '-')}</td><td>${escapeHTML(p.heartbeat_age_ms ?? '-')}</td><td>${escapeHTML(p.target_count)}t/${escapeHTML(p.candidate_count)}c</td><td>${escapeHTML(p.action_count)}</td><td>${escapeHTML(p.origin ?? '-')}</td><td>${escapeHTML(p.last_error ?? '')}</td></tr>`).join('');
        }
        function logSearchText(l) {
          return `${l.level || ''} ${l.source || ''} ${l.message || ''} ${JSON.stringify(l.fields || {})}`.toLowerCase();
        }
        function renderVisibleLogs() {
          const viewportHeight = logsEl.clientHeight || rowHeight;
          const totalHeight = filteredLogs.length * rowHeight;
          const start = Math.max(0, Math.floor(logsEl.scrollTop / rowHeight) - overscan);
          const visibleCount = Math.ceil(viewportHeight / rowHeight) + overscan * 2;
          const end = Math.min(filteredLogs.length, start + visibleCount);
          let topPad = start * rowHeight;
          if (totalHeight < viewportHeight) {
            topPad += viewportHeight - totalHeight;
          }
          logTopPadEl.style.height = `${topPad}px`;
          logBottomPadEl.style.height = `${Math.max(0, filteredLogs.length - end) * rowHeight}px`;
          logRowsEl.innerHTML = filteredLogs.slice(start, end).map(l => {
            const fields = l.fields && Object.keys(l.fields).length ? ` ${JSON.stringify(l.fields)}` : '';
            const message = (l.message || '') + fields;
            return `<div class="log"><span class="timestamp">${escapeHTML(timestamp(l.time_unix_ms))}</span><span class="level level-${escapeHTML(l.level || 'info')}">${escapeHTML(l.level || 'info')}</span><span class="source" title="${escapeHTML(l.source || '-')}">${escapeHTML(l.source || '-')}</span><span class="message" title="${escapeHTML(message)}">${escapeHTML(message)}</span></div>`;
          }).join('');
          logCountEl.textContent = `${filteredLogs.length}/${logs.length} logs`;
        }
        function renderLogs(options = {}) {
          const wasAtBottom = logsEl.scrollTop + logsEl.clientHeight >= logsEl.scrollHeight - rowHeight;
          const q = logSearchEl.value.trim().toLowerCase();
          const level = logLevelEl.value;
          filteredLogs = logs.filter(l => (!level || l.level === level) && (!q || logSearchText(l).includes(q)));
          if (options.forceBottom || wasAtBottom || q || level) {
            logsEl.scrollTop = filteredLogs.length * rowHeight;
          }
          renderVisibleLogs();
        }
        fetch('/state').then(r => r.json()).then(renderState);
        fetch('/logs').then(r => r.json()).then(v => { logs = v.logs || []; renderLogs({forceBottom: true}); });
        logSearchEl.addEventListener('input', () => renderLogs({forceBottom: true}));
        logLevelEl.addEventListener('change', () => renderLogs({forceBottom: true}));
        logsEl.addEventListener('scroll', () => {
          if (scrollRenderScheduled) return;
          scrollRenderScheduled = true;
          requestAnimationFrame(() => {
            scrollRenderScheduled = false;
            renderVisibleLogs();
          });
        });
        const es = new EventSource('/events');
        es.addEventListener('state', e => { renderState(JSON.parse(e.data)); });
        es.addEventListener('log', e => { logs.push(JSON.parse(e.data)); renderLogs(); });
        es.addEventListener('logs', e => { logs = JSON.parse(e.data).logs || []; renderLogs({forceBottom: true}); });
      </script>
    </body>
    </html>
    """
}
