import AppKit
import Carbon.HIToolbox
import Foundation

/// `--bench=N` for the integration oracles: drive the installed resident
/// through N hint activations on a fixture the oracle already launched, for
/// `Scripts/benchmark-hints.sh`. Each run brings the fixture forward, posts
/// the trigger, waits for `/state` to show a finished hint layout, dismisses
/// it and waits for it to go. Flash logs `[latency] hints_visible` for every
/// activation; the script reads those lines from its log between the
/// `bench measure_start_ms=` / `bench measure_end_ms=` markers this prints.
public struct ResidentHintBenchmark {
  public enum Trigger: String {
    /// `f` posted at the HID level in NORMAL (origin=key).
    case key
    /// `flash mouse_target` (origin=cli).
    case cli
  }

  public enum Failure: Error, CustomStringConvertible {
    case invalidArgument(String)
    case notNormal(String)
    case command(String)
    case state(String)
    case timedOut(String)

    public var description: String {
      switch self {
      case .invalidArgument(let argument): return "invalid benchmark argument \(argument)"
      case .notNormal(let mode):
        return "Flash is in \(mode) after enter_normal_mode; bind an all-mode leave_mode or "
          + "enter_normal_mode mapping to enable NORMAL, or pass --trigger=cli"
      case .command(let message): return "flash command failed: \(message)"
      case .state(let message): return "Flash debug state unavailable: \(message)"
      case .timedOut(let what): return "timed out waiting for \(what)"
      }
    }
  }

  public var runs: Int
  public var trigger: Trigger
  /// Unmeasured activations first: a cold walk and prepared-model warm-up.
  public var warmup = 2
  public var flashCLIPath = "\(NSHomeDirectory())/.local/bin/flash"
  public var stateURL = URL(string: "http://127.0.0.1:4242/state")!

  public init(runs: Int, trigger: Trigger) {
    self.runs = runs
    self.trigger = trigger
  }

  /// `--bench=N` and `--bench-trigger=key|cli` from an oracle's argv; nil
  /// runs when `--bench` is absent. Throws on a malformed value.
  public static func parse(_ arguments: [String]) throws -> ResidentHintBenchmark? {
    var runs: Int?
    var trigger = Trigger.key
    for argument in arguments {
      if argument.hasPrefix("--bench=") {
        guard let value = Int(argument.dropFirst("--bench=".count)), value > 0 else {
          throw Failure.invalidArgument(argument)
        }
        runs = value
      } else if argument.hasPrefix("--bench-trigger=") {
        guard let value = Trigger(rawValue: String(argument.dropFirst("--bench-trigger=".count)))
        else { throw Failure.invalidArgument(argument) }
        trigger = value
      }
    }
    return runs.map { ResidentHintBenchmark(runs: $0, trigger: trigger) }
  }

  /// Whether an argument belongs to the benchmark (so oracles can skip it).
  public static func owns(_ argument: String) -> Bool {
    argument.hasPrefix("--bench=") || argument.hasPrefix("--bench-trigger=")
  }

  /// A finished hint layout: the walk is done and hints are up.
  public static func hintsVisible(_ state: [String: Any]) -> Bool {
    state["activation_in_flight"] as? Bool == false
      && !((state["hints"] as? [Any]) ?? []).isEmpty
  }

  public static func hintsDismissed(_ state: [String: Any]) -> Bool {
    state["activation_in_flight"] as? Bool == false
      && ((state["hints"] as? [Any]) ?? []).isEmpty
  }

  /// Run the loop. `activate` brings the fixture forward; `log` prints a
  /// progress line. Returns the number of measured runs.
  @discardableResult
  public func run(activate: () -> Void, log: (String) -> Void) throws -> Int {
    if trigger == .key {
      try flash("enter_normal_mode")
      let mode = try fetchState()["mode"] as? String ?? "unknown"
      guard mode == "normal" else { throw Failure.notNormal(mode) }
    }
    var measured = 0
    for index in 0..<(warmup + runs) {
      if index == warmup {
        log("bench measure_start_ms=\(Self.nowMs())")
      }
      activate()
      Thread.sleep(forTimeInterval: 0.2)
      try fire()
      // `/state` is built on Flash's main thread: the first poll waits out a
      // typical activation so polling does not slow the one being measured.
      let state = try waitForState(
        "hints", timeout: 8, firstPollAfter: 0.3, until: Self.hintsVisible)
      let count = (state["hints"] as? [Any])?.count ?? 0
      try flash("hints_dismiss")
      _ = try waitForState("dismissal", timeout: 4, until: Self.hintsDismissed)
      if index >= warmup {
        measured += 1
        log("bench run \(measured)/\(runs) hints=\(count)")
      }
      // Let the prepared model settle as it would between real activations.
      Thread.sleep(forTimeInterval: 0.4)
    }
    log("bench measure_end_ms=\(Self.nowMs())")
    return measured
  }

  private func fire() throws {
    switch trigger {
    case .cli:
      try flash("mouse_target")
    case .key:
      let source = CGEventSource(stateID: .hidSystemState)
      CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_F), keyDown: true)?
        .post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.02)
      CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_F), keyDown: false)?
        .post(tap: .cghidEventTap)
    }
  }

  private func flash(_ verb: String) throws {
    guard FileManager.default.isExecutableFile(atPath: flashCLIPath) else {
      throw Failure.command("\(flashCLIPath) is not executable")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: flashCLIPath)
    process.arguments = [verb]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let output =
        String(
          data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      throw Failure.command("\(verb) exited \(process.terminationStatus): \(output)")
    }
  }

  private func waitForState(
    _ what: String, timeout: TimeInterval, firstPollAfter delay: TimeInterval = 0,
    until done: ([String: Any]) -> Bool
  ) throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeout)
    Thread.sleep(forTimeInterval: delay)
    while Date() < deadline {
      let state = try fetchState()
      if done(state) { return state }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw Failure.timedOut(what)
  }

  private func fetchState() throws -> [String: Any] {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<[String: Any], Failure> = .failure(.state("no response"))
    URLSession.shared.dataTask(with: stateURL) { data, _, error in
      if let error {
        result = .failure(.state(String(describing: error)))
      } else if let data,
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      {
        result = .success(object)
      } else {
        result = .failure(.state("invalid JSON from \(stateURL)"))
      }
      semaphore.signal()
    }.resume()
    guard semaphore.wait(timeout: .now() + 2) == .success else {
      throw Failure.state("no reply from \(stateURL)")
    }
    return try result.get()
  }

  private static func nowMs() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded())
  }
}
