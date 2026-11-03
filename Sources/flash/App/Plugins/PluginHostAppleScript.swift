import FlashCore
import Foundation

enum PluginHostAppleScript {
  private static let queue = DispatchQueue(
    label: "flash.plugin.applescript", qos: .userInitiated, attributes: .concurrent)
  private static let slotsLock = NSLock()
  private static var slotsByPlugin: [String: DispatchSemaphore] = [:]

  private static func slots(for pluginID: String) -> DispatchSemaphore {
    slotsLock.lock()
    defer { slotsLock.unlock() }
    if let slots = slotsByPlugin[pluginID] { return slots }
    let slots = DispatchSemaphore(value: PluginProtocol.appleScriptConcurrency)
    slotsByPlugin[pluginID] = slots
    return slots
  }

  static func handle(
    _ params: [String: Any], targets: [String], pluginID: String,
    scope: PluginHostRequestScope,
    runner: @escaping (String, TimeInterval) -> AppleScriptOutput = AppleScriptRunner.run,
    reply: @escaping ([String: Any]) -> Void
  ) {
    var timeoutMs = PluginProtocol.appleScriptDefaultTimeoutMs
    if let raw = params["timeout_ms"] {
      guard let requested = PluginJSON.integer(raw), requested >= 1,
        requested <= PluginProtocol.appleScriptMaxTimeoutMs
      else {
        reply([
          "ok": false,
          "error":
            "host.applescript timeout_ms must be an integer 1-\(PluginProtocol.appleScriptMaxTimeoutMs)",
        ])
        return
      }
      timeoutMs = requested
    }
    let script: String
    switch PluginAppleScriptOperation.script(params, targets: targets) {
    case .success(let value): script = value
    case .failure(let refusal):
      reply(["ok": false, "error": refusal.message])
      return
    }
    guard script.utf8.count <= PluginProtocol.maxAppleScriptScriptBytes else {
      reply(["ok": false, "error": "operation exceeds the host.applescript source cap"])
      return
    }
    let startedAt = DispatchTime.now()
    let deadline = startedAt + .milliseconds(timeoutMs)
    let timedOut: [String: Any] = [
      "ok": false, "error": "applescript timed out timeout_ms=\(timeoutMs)",
      "status": Int(AppleScriptOutput.timeoutStatus),
    ]
    queue.async {
      let slots = slots(for: pluginID)
      guard slots.wait(timeout: deadline) == .success else {
        if scope.isCurrent() { reply(timedOut) }
        return
      }
      guard scope.isCurrent() else {
        slots.signal()
        return
      }
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline.uptimeNanoseconds else {
        slots.signal()
        reply(timedOut)
        return
      }
      let remaining =
        deadline.uptimeNanoseconds > now
        ? Double(deadline.uptimeNanoseconds - now) / 1_000_000_000 : 0.001
      let output = runner(script, remaining)
      slots.signal()
      guard scope.isCurrent() else { return }
      let elapsedMs = Int(
        Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
      reply(result(of: output, timedOut: timedOut, pluginID: pluginID, elapsedMs: elapsedMs))
    }
  }

  private static func result(
    of output: AppleScriptOutput, timedOut: [String: Any], pluginID: String, elapsedMs: Int
  ) -> [String: Any] {
    let oversized: [String: Any] = [
      "ok": false,
      "error":
        "result exceeds the \(PluginProtocol.maxAppleScriptResultBytes) byte host.applescript cap",
      "status": Int(AppleScriptOutput.outputLimitStatus),
    ]
    if output.ok {
      var bytes = Array(output.stdout.utf8)
      if bytes.last == 0x0A { bytes.removeLast() }
      guard bytes.count <= PluginProtocol.maxAppleScriptResultBytes else {
        FlashLog.debug(
          "[plugin] host.applescript result oversized bytes=\(bytes.count) elapsed_ms=\(elapsedMs)",
          fields: ["plugin": pluginID, "bytes": "\(bytes.count)", "elapsed_ms": "\(elapsedMs)"])
        return oversized
      }
      FlashLog.debug(
        "[plugin] host.applescript ok elapsed_ms=\(elapsedMs)",
        fields: ["plugin": pluginID, "bytes": "\(bytes.count)", "elapsed_ms": "\(elapsedMs)"])
      return ["ok": true, "result": String(decoding: bytes, as: UTF8.self)]
    }
    switch output.status {
    case AppleScriptOutput.timeoutStatus:
      FlashLog.debug(
        "[plugin] host.applescript timed out elapsed_ms=\(elapsedMs)",
        fields: ["plugin": pluginID, "elapsed_ms": "\(elapsedMs)"])
      return timedOut
    case AppleScriptOutput.outputLimitStatus:
      return oversized
    default:
      let line =
        output.stderr.split(separator: "\n").first.map { String($0).trimmed } ?? ""
      let code = AppleScriptOutput.errorNumber(in: line).map(String.init) ?? ""
      // Content-free: the status and the error number name the failure
      // (-1743 not authorized, -600 not running) without the message.
      FlashLog.debug(
        "[plugin] host.applescript failed status=\(output.status) error_code=\(code)"
          + " elapsed_ms=\(elapsedMs)",
        fields: [
          "plugin": pluginID, "status": "\(output.status)", "error_code": code,
          "elapsed_ms": "\(elapsedMs)",
        ])
      return [
        "ok": false, "error": line.isEmpty ? "applescript failed" : line,
        "status": Int(output.status),
      ]
    }
  }
}

extension AppleScriptOutput {
  /// The number osascript's error line ends with: `… (-1743)`.
  static func errorNumber(in line: String) -> Int? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return nil }
    return Int(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
  }
}
