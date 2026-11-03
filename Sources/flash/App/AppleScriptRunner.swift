import Carbon
import CoreServices
import Foundation

/// What `osascript -e <source>` would have printed: the human-readable result
/// plus a newline on stdout (nothing when the script returns no value), or
/// exit status 1 with osascript's `<start>:<end>: <phase> error: <message>
/// (<number>)` line on stderr. A missed deadline is status 124, output past
/// the limit 125, and a failure of the scripting machinery itself -1.
struct AppleScriptOutput: Equatable {
  static let timeoutStatus: Int32 = 124
  static let outputLimitStatus: Int32 = 125

  var status: Int32
  var stdout: String
  var stderr: String

  var ok: Bool { status == 0 }

  /// Nil on success, else a short reason for a log line: the status and the
  /// first line of the error.
  var failure: String? {
    guard !ok else { return nil }
    let firstLine = stderr.split(separator: "\n").first.map(String.init) ?? ""
    return "applescript status=\(status) \(firstLine.prefix(180))"
  }

  /// Stdout without osascript's trailing newline; nil when the script failed.
  var resultText: String? {
    ok ? stdout.trimmingCharacters(in: .newlines) : nil
  }
}

/// Runs AppleScript in the resident through the Open Scripting Architecture,
/// as `osascript` does: compile with the AppleScript component, execute, and
/// print the result with `OSADisplay` in human-readable mode, so callers read
/// exactly what `osascript -e` printed — without its fork/exec, which can stall
/// for seconds while macOS's exec policy daemon is busy. Plugin requests use
/// fixed host templates through `PluginHostAppleScript`; plugin processes load
/// no OSA runtime. The OSA calls provide deadline hooks and human-readable
/// output; OSAKit's display value renders source form (quoted strings, braced lists).
/// `tell application` launches a target that is not running; macOS attributes
/// the Automation request to Flash.
///
/// `run` blocks its caller, so it belongs on a background queue, never main
/// or the keyboard path. At most `maxScriptThreads` background workers wait
/// or run. One process-wide execution gate keeps compiler work and runtime
/// teardown from overlapping across component instances. It owns the complete
/// lifetime, including descriptor/script disposal, close and autorelease-pool drain. Admission to
/// both the worker slots and that gate uses the caller's original deadline.
///
/// The caller's timeout is a deadline the script observes: each Apple Event's
/// reply timeout is capped by the time left, an event sent after the deadline
/// fails at once with `errAETimeout`, and the component's active procedure
/// cancels a running script (`userCanceledErr`) once the deadline passes. A
/// late script therefore releases its thread and slot shortly after its caller
/// saw the timeout, instead of holding them for AppleScript's two-minute event
/// default. A wait outside those hooks (an Automation consent prompt left
/// open) keeps the execution gate until it returns; later scripts time out
/// without entering OSA, with the worker cap bounding blocked threads.
enum AppleScriptRunner {
  /// Workers executing OSA or waiting for its single lifetime gate.
  static let maxScriptThreads = 8
  static let stdoutLimit = 4 * 1024 * 1024
  static let stderrLimit = 256 * 1024
  /// osascript runs its scripts on a main thread's 8 MiB stack.
  private static let scriptStackBytes = 8 * 1024 * 1024
  private static let slots = DispatchSemaphore(value: maxScriptThreads)
  private static let executionGate = ScriptExecutionGate()

  /// Run `source` within `timeout` seconds and wait for its output.
  static func run(_ source: String, timeout: TimeInterval) -> AppleScriptOutput {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let control = ScriptControl(timeout: timeout)
    guard slots.wait(timeout: control.deadline) == .success else {
      return timedOut(timeout)
    }
    let result = ScriptResult()
    let thread = Thread {
      defer { slots.signal() }
      result.finish(execute(source, control: control))
    }
    thread.name = "flash-osascript"
    thread.stackSize = scriptStackBytes
    thread.qualityOfService = .userInitiated
    thread.start()
    guard let output = result.wait(until: control.deadline) else {
      // The script stops at its next Apple Event or active-procedure call.
      control.abandon()
      return timedOut(timeout)
    }
    return output
  }

  /// The reply timeout, in ticks (1/60 s), for an Apple Event sent with
  /// `remaining` seconds left: AppleScript's own timeout (`requested`;
  /// negative means its default or none) capped by the deadline.
  static func clampTicks(_ requested: Int32, remaining: TimeInterval) -> Int {
    let cap = Int(min(max(remaining, 0) * 60, Double(Int32.max)).rounded(.down)) + 1
    return requested < 0 ? cap : min(cap, Int(requested))
  }

  private static func timedOut(_ timeout: TimeInterval) -> AppleScriptOutput {
    AppleScriptOutput(
      status: AppleScriptOutput.timeoutStatus, stdout: "",
      stderr: "applescript timed out timeout_ms=\(Int((timeout * 1000).rounded()))")
  }

  private static func internalFailure(_ diagnostic: String) -> AppleScriptOutput {
    AppleScriptOutput(status: -1, stdout: "", stderr: diagnostic)
  }

  /// Compile, execute and display `source` on the calling thread, observing
  /// `control`'s deadline. Internal: tests drive the deadline hooks directly.
  static func execute(_ source: String, control: ScriptControl) -> AppleScriptOutput {
    executionGate.perform(control: control) {
      executeExclusively(source, control: control)
    } ?? timedOut(control.timeout)
  }

  private static func executeExclusively(_ source: String, control: ScriptControl)
    -> AppleScriptOutput
  {
    guard let api = ComponentAPI.shared else {
      return internalFailure("applescript could not load the component manager")
    }
    guard let instance = api.openDefault(OSType(kOSAComponentType), OSType(typeAppleScript))
    else { return internalFailure("applescript could not open the AppleScript component") }
    defer { _ = api.close(instance) }
    // `control` outlives `instance`, which closes first and takes both
    // procedures with it.
    let refcon = Unmanaged.passUnretained(control).toOpaque()
    _ = OSASetActiveProc(instance, activeProc, refcon)
    _ = OSASetSendProc(instance, sendProc, refcon)

    var sourceDesc = AEDesc()
    let created = source.utf8CString.withUnsafeBufferPointer { bytes in
      AECreateDesc(DescType(typeUTF8Text), bytes.baseAddress, bytes.count - 1, &sourceDesc)
    }
    guard created == noErr else {
      return internalFailure("applescript could not create the source descriptor")
    }
    defer { AEDisposeDesc(&sourceDesc) }

    var script = OSAID(kOSANullScript)
    let status = OSACompile(instance, &sourceDesc, Int32(kOSAModeNull), &script)
    defer { dispose(script, in: instance) }
    switch status {
    case noErr: return runCompiled(script, in: instance)
    case OSAError(errOSAScriptError): return errorOutput(instance, phase: "syntax")
    default: return internalFailure("applescript compile failed status=\(status)")
    }
  }

  private static func runCompiled(_ script: OSAID, in instance: OSAComponentInstance)
    -> AppleScriptOutput
  {
    var result = OSAID(kOSANullScript)
    let status = OSAExecute(
      instance, script, OSAID(kOSANullScript), Int32(kOSAModeNull), &result)
    defer { dispose(result, in: instance) }
    switch status {
    case noErr where result == OSAID(kOSANullScript):
      return AppleScriptOutput(status: 0, stdout: "", stderr: "")
    case noErr: return display(result, in: instance)
    case OSAError(errOSAScriptError): return errorOutput(instance, phase: "execution")
    default: return internalFailure("applescript execute failed status=\(status)")
    }
  }

  /// The result as osascript prints it: human-readable, then a newline.
  private static func display(_ result: OSAID, in instance: OSAComponentInstance)
    -> AppleScriptOutput
  {
    var text = AEDesc()
    defer { AEDisposeDesc(&text) }
    let status = OSADisplay(
      instance, result, DescType(typeUTF8Text), Int32(kOSAModeDisplayForHumans), &text)
    guard status == noErr else {
      return internalFailure("applescript display failed status=\(status)")
    }
    switch Self.text(of: &text, limit: stdoutLimit) {
    case .text(let value): return AppleScriptOutput(status: 0, stdout: value + "\n", stderr: "")
    case .unreadable: return internalFailure("applescript could not read the result text")
    case .tooLarge:
      return AppleScriptOutput(
        status: AppleScriptOutput.outputLimitStatus, stdout: "",
        stderr: "applescript stdout exceeded limit_bytes=\(stdoutLimit)")
    }
  }

  /// osascript's error line: `<start>:<end>: <phase> error: <message>
  /// (<number>)`, without the range when the error has none (`0:0`).
  private static func errorOutput(_ instance: OSAComponentInstance, phase: String)
    -> AppleScriptOutput
  {
    let number =
      scriptError(instance, selector: OSType(kOSAErrorNumber), type: DescType(typeSInt32)) {
        (desc: inout AEDesc) -> Int32? in
        var value: Int32 = 0
        return AEGetDescData(&desc, &value, MemoryLayout<Int32>.size) == noErr ? value : nil
      } ?? 0
    let message =
      scriptError(instance, selector: OSType(kOSAErrorMessage), type: DescType(typeUTF8Text)) {
        (desc: inout AEDesc) -> String? in
        guard case .text(let value) = text(of: &desc, limit: stderrLimit) else { return nil }
        return value
      } ?? ""
    let range = scriptError(
      instance, selector: OSType(kOSAErrorRange), type: DescType(typeOSAErrorRange)
    ) { (desc: inout AEDesc) -> (start: Int32, end: Int32)? in
      guard let start = int32Field(of: &desc, key: AEKeyword(keyOSASourceStart)),
        let end = int32Field(of: &desc, key: AEKeyword(keyOSASourceEnd))
      else { return nil }
      return (start, end)
    }
    let prefix = range.map { $0.start == 0 && $0.end == 0 ? "" : "\($0.start):\($0.end): " } ?? ""
    return AppleScriptOutput(
      status: 1, stdout: "", stderr: "\(prefix)\(phase) error: \(message) (\(number))\n")
  }

  private static func scriptError<T>(
    _ instance: OSAComponentInstance, selector: OSType, type: DescType,
    read: (inout AEDesc) -> T?
  ) -> T? {
    var desc = AEDesc()
    defer { AEDisposeDesc(&desc) }
    guard OSAScriptError(instance, selector, type, &desc) == noErr else { return nil }
    return read(&desc)
  }

  private static func int32Field(of record: inout AEDesc, key: AEKeyword) -> Int32? {
    var actualType = DescType(0)
    var value: Int32 = 0
    var actualSize = 0
    let status = AEGetParamPtr(
      &record, key, DescType(typeSInt32), &actualType, &value, MemoryLayout<Int32>.size,
      &actualSize)
    return status == noErr ? value : nil
  }

  private enum DescText {
    case text(String)
    case unreadable
    case tooLarge
  }

  /// The descriptor's bytes as UTF-8 text, coercing other types.
  private static func text(of desc: inout AEDesc, limit: Int) -> DescText {
    guard desc.descriptorType == DescType(typeUTF8Text) else {
      var coerced = AEDesc()
      defer { AEDisposeDesc(&coerced) }
      guard AECoerceDesc(&desc, DescType(typeUTF8Text), &coerced) == noErr else {
        return .unreadable
      }
      return text(of: &coerced, limit: limit)
    }
    let size = AEGetDescDataSize(&desc)
    guard size <= limit else { return .tooLarge }
    guard size > 0 else { return .text("") }
    var bytes = [UInt8](repeating: 0, count: size)
    guard AEGetDescData(&desc, &bytes, size) == noErr else { return .unreadable }
    return .text(String(decoding: bytes, as: UTF8.self))
  }

  private static func dispose(_ id: OSAID, in instance: OSAComponentInstance) {
    if id != OSAID(kOSANullScript) { _ = OSADispose(instance, id) }
  }
}

/// One complete OSA lifetime, including teardown, before another may begin.
final class ScriptExecutionGate {
  private let permit = DispatchSemaphore(value: 1)

  func perform<T>(control: ScriptControl, _ body: () -> T) -> T? {
    guard permit.wait(timeout: control.deadline) == .success else { return nil }
    defer { permit.signal() }
    guard control.remaining() != nil else { return nil }
    return autoreleasepool(invoking: body)
  }
}

/// The deadline one script observes from its thread, and whether its caller
/// has gone.
final class ScriptControl {
  let timeout: TimeInterval
  let deadline: DispatchTime
  private let lock = NSLock()
  private var abandoned = false

  init(timeout: TimeInterval) {
    self.timeout = timeout
    let seconds = max(0, min(timeout, 365 * 24 * 3600))
    deadline = .now() + seconds
  }

  func abandon() {
    lock.lock()
    abandoned = true
    lock.unlock()
  }

  /// Seconds left for the script; nil once the deadline passed or the
  /// caller is gone.
  func remaining() -> TimeInterval? {
    lock.lock()
    let gone = abandoned
    lock.unlock()
    let now = DispatchTime.now().uptimeNanoseconds
    guard !gone, deadline.uptimeNanoseconds > now else { return nil }
    return TimeInterval(deadline.uptimeNanoseconds - now) / 1_000_000_000
  }
}

/// One script's output, handed from its thread to the waiting caller.
private final class ScriptResult {
  private let lock = NSLock()
  private let done = DispatchSemaphore(value: 0)
  private var output: AppleScriptOutput?

  func finish(_ output: AppleScriptOutput) {
    lock.lock()
    self.output = output
    lock.unlock()
    done.signal()
  }

  func wait(until deadline: DispatchTime) -> AppleScriptOutput? {
    guard done.wait(timeout: deadline) == .success else { return nil }
    lock.lock()
    defer { lock.unlock() }
    return output
  }
}

/// An AppleScript component instance (Components.h's `ComponentInstance`).
typealias OSAComponentInstance = UnsafeMutablePointer<CoreServices.ComponentInstanceRecord>

/// The Component Manager calls Swift does not import, resolved once from
/// CoreServices, which stays loaded for the life of the process.
private struct ComponentAPI {
  typealias OpenDefault = @convention(c) (OSType, OSType) -> OSAComponentInstance?
  typealias Close = @convention(c) (OSAComponentInstance?) -> OSErr

  let openDefault: OpenDefault
  let close: Close

  static let shared: ComponentAPI? = {
    guard
      let handle = dlopen(
        "/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY),
      let open = dlsym(handle, "OpenDefaultComponent"),
      let close = dlsym(handle, "CloseComponent")
    else { return nil }
    return ComponentAPI(
      openDefault: unsafeBitCast(open, to: OpenDefault.self),
      close: unsafeBitCast(close, to: Close.self))
  }()
}

/// Active procedure: AppleScript calls it periodically while a script runs;
/// an error return cancels the script.
private let activeProc: OSAActiveUPP = { refcon in
  guard let refcon else { return OSErr(userCanceledErr) }
  let control = Unmanaged<ScriptControl>.fromOpaque(refcon).takeUnretainedValue()
  return control.remaining() == nil ? OSErr(userCanceledErr) : OSErr(noErr)
}

/// Send procedure: every Apple Event the script sends, its reply timeout
/// capped by the script's deadline.
private let sendProc: OSASendUPP = { event, reply, sendMode, _, timeoutTicks, _, _, refcon in
  guard let refcon else { return OSErr(errAETimeout) }
  let control = Unmanaged<ScriptControl>.fromOpaque(refcon).takeUnretainedValue()
  guard let remaining = control.remaining() else { return OSErr(errAETimeout) }
  let status = AESendMessage(
    event, reply, sendMode,
    AppleScriptRunner.clampTicks(timeoutTicks, remaining: remaining))
  return OSErr(exactly: status) ?? OSErr(errAEEventFailed)
}
