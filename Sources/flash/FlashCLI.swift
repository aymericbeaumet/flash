import AppKit
import Foundation

// CLI half of the `flash` binary. When the executable is launched with any
// extra argv (`flash mouse target`, `flash ta nex`, `flash q`, …), main
// dispatches here instead of starting `NSApplication`. The words go to the
// running resident over its socket (`IPCClient`, `docs/ipc-protocol.md`)
// and resolve there exactly as the same words typed after `:` do: one
// resolver, one inventory (the focused app's plugin commands included), one
// runner. The reply carries how the run ended, which becomes the exit
// status. Without a resident, the CLI opens the app bundle it lives in and
// waits for the socket (`ResidentConnector`).
//
// This entry point is intentionally narrow: no shell expansion, no
// pass-through to other binaries — anything the grammar does not resolve
// returns non-zero and exits.

enum FlashCLI {
  static let usage = """
    Usage:
      flash [--json] <words ...>   the words you would type after : in Flash

    The same grammar as the command line: a command (flash tab next), a vim
    ex command (flash q, flash tabn), each word by its unique prefix
    (flash ta nex), a plugin command (flash screenshot window), or one of
    open <args>, flashlight <query>, logs, commands and doctor. A leading #
    also copies the output to the clipboard. Scripts should spell commands
    in full: a prefix can become ambiguous when a plugin adds a command.
    Flash starts when it is not running.

    --json prints the reply as one JSON object (status, output, message)
    instead of the output and the message.

    Queries:
      flash resident status [--json]       the resident's state
      flash resident doctor [--json]       check permissions, capture, config, plugins
      flash events watch [--name=<glob,...>] [--count=<n>]
                                           host events as JSON lines, as they happen
      flash config check [--file=path]     validate a config file, even without the resident
      flash config schema                  flash.toml's JSON Schema, for editors
      flash cli completion --shell=zsh     the completion script for zsh, bash or fish
      flash cli manpage                    the flash(1) man page

    Exit status: 0 when it ran, 1 when it failed or found nothing to act on,
    2 when the words name no command or more than one.

    Examples:
      flash mouse target --modifiers=cmd
      flash mode normal
      flash mode terminal --name=btop
      flash app open --name=Firefox
      flash window move --position=lefthalf
      flash alert confirm --prompt='Close it?' --command='tab close'
      flash events watch --name='core:mode.changed,core:focus.changed'
      flash --json resident status --json
      flash help show
      flash open ~/Downloads
    """

  /// A connection to the resident: the socket, or a stub in tests.
  protocol Channel: AnyObject {
    /// Run `words` from `directory` as `:<words>`; how the run ended.
    func request(words: [String], directory: String) throws -> CommandInvocationResult
    /// Stream host events matching `patterns` to `emit`, at most `count`;
    /// the CLI's exit status.
    func watch(patterns: [String], count: Int?, emit: (Data) -> Bool) throws -> Int32
  }

  /// Why no channel opened.
  enum OpenFailure: Error, Equatable {
    /// No resident runs and the CLI did not start one.
    case notRunning
    case failed(String)
  }

  /// How the CLI reaches the resident: the socket, or a stub in tests.
  /// `launching` says whether a resident that is not running may be
  /// started for these words.
  struct Transport {
    var open: (_ launching: Bool) -> Result<any Channel, OpenFailure>

    static let socket = Transport(open: { launching in
      FlashCLI.openSocket(launching: launching)
    })
  }

  static func run(args: [String], transport: Transport = .socket) -> Int32 {
    var args = args
    let asJSON = args.first == "--json"
    if asJSON { args.removeFirst() }
    guard !args.isEmpty else {
      FileHandle.standardError.write(Data((usage + "\n").utf8))
      return 2
    }
    if args == ["-h"] || args == ["--help"] {
      print(usage)
      return 0
    }
    let directory = FileManager.default.currentDirectoryPath
    let invocation = CommandInvocation(words: args, workingDirectory: directory)
    // Resolved here too: `config check` spelled out runs without asking the
    // resident (its first word is exact, so the resident would read it the
    // same), and without a resident the words still get their diagnosis.
    let inventory = NormalModeDispatcher.CommandLineInventory.core()
    let local = NormalModeDispatcher.resolveCommandWords(invocation.words, inventory: inventory)
    if case .query(let query, let arguments) = local, query.runsInCLI,
      invocation.words.first == query.name.topic
    {
      return finish(runLocally(query, arguments), asJSON: asJSON)
    }
    let menu = preparedMenuWords(
      args, directory: directory, inventory: inventory, readStdin: readPipedStandardInput)
    defer { if let file = menu.temporaryFile { try? FileManager.default.removeItem(at: file) } }
    let channel: any Channel
    switch transport.open(startsResident(local, words: invocation.words, inventory: inventory)) {
    case .success(let opened):
      channel = opened
    case .failure(.notRunning):
      if case .query(let query, let arguments) = local, query.runsInCLI {
        return finish(runLocally(query, arguments), asJSON: asJSON)
      }
      if let rejection = local.rejection(of: invocation.words, inventory: inventory) {
        return finish(.rejected(rejection), asJSON: asJSON)
      }
      return finish(.failed("Flash is not running"), asJSON: asJSON)
    case .failure(.failed(let reason)):
      return finish(.failed(reason), asJSON: asJSON)
    }
    do {
      if case .query(.eventsWatch, let arguments) = local,
        invocation.words.first == FlashQuery.eventsWatch.name.topic
      {
        return try watch(channel, arguments)
      }
      let result = try channel.request(words: menu.words, directory: directory)
      if result.status == .local, let name = result.query, let query = FlashQuery(name: name) {
        if query == .eventsWatch { return try watch(channel, result.arguments ?? [:]) }
        if query.runsInCLI {
          return finish(runLocally(query, result.arguments ?? [:]), asJSON: asJSON)
        }
      }
      return finish(result, asJSON: asJSON)
    } catch {
      return finish(.failed("\(error)"), asJSON: asJSON)
    }
  }

  /// Whether these words may start a resident that is not running. Not
  /// to quit it, and not for words Flash's own topics reject: no plugin can
  /// make them valid, so the CLI says why without starting anything.
  static func startsResident(
    _ local: NormalModeDispatcher.CommandLineResolution, words: [String],
    inventory: NormalModeDispatcher.CommandLineInventory
  ) -> Bool {
    if case .commands(let commands) = local, commands == [.quit] { return false }
    if let first = words.first, URLEventHandler.isTopic(first),
      local.rejection(of: words, inventory: inventory) != nil
    {
      return false
    }
    return true
  }

  /// `events watch`: each event line as the resident sent it, flushed as
  /// it arrives; a reader that goes away (`| head -1`) ends it quietly.
  private static func watch(_ channel: any Channel, _ arguments: [String: String]) throws -> Int32 {
    let patterns = FlashQuery.eventPatterns(arguments["name"])
    let count = arguments["count"].flatMap(Int.init)
    return try channel.watch(patterns: patterns, count: count) { line in
      var bytes = line
      bytes.append(0x0A)
      return bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
          let written = Darwin.write(STDOUT_FILENO, raw.baseAddress! + offset, raw.count - offset)
          if written < 0 {
            if errno == EINTR { continue }
            return false
          }
          offset += written
        }
        return true
      }
    }
  }

  /// The socket, starting the resident when `launching` allows it.
  private static func openSocket(launching: Bool) -> Result<any Channel, OpenFailure> {
    let endpoint = IPCEndpoint.standard
    let bundle: () -> URL? = {
      let url = appBundle.bundleURL
      return url.pathExtension == "app" ? url : nil
    }
    let outcome = ResidentConnector.connect(
      launching: launching, seams: ResidentConnector.live(endpoint, bundle: bundle))
    switch outcome {
    case .connected(let client):
      do {
        _ = try client.hello(client: "flash-cli \(cliVersion)")
      } catch {
        return .failure(.failed("\(error)"))
      }
      return .success(SocketChannel(client: client))
    case .notRunning:
      return .failure(.notRunning)
    case .launchFailed(let reason):
      return .failure(.failed("could not start Flash: \(reason)"))
    case .didNotStart(let seconds):
      return .failure(
        .failed(
          "Flash did not answer on \(endpoint.socketPath) within \(Int(seconds)) s of starting"))
    case .notAnswering(let seconds):
      return .failure(
        .failed(
          "Flash is running but did not answer on \(endpoint.socketPath) within \(Int(seconds)) s: "
            + "quit and reopen it"))
    case .failed(let reason):
      return .failure(.failed(reason))
    }
  }

  private static var cliVersion: String {
    appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
  }

  /// The socket as a `Channel`.
  private final class SocketChannel: Channel {
    let client: IPCClient

    init(client: IPCClient) {
      self.client = client
    }

    func request(words: [String], directory: String) throws -> CommandInvocationResult {
      try client.request(words: words, directory: directory)
    }

    func watch(patterns: [String], count: Int?, emit: (Data) -> Bool) throws -> Int32 {
      try client.watch(events: patterns, count: count, emit: emit)
    }
  }

  /// `menu choose` reads its items from a file the resident opens: a relative
  /// `--file` resolves in this shell's directory, and without `--file` piped
  /// standard input is saved to a private temporary file, deleted once the
  /// resident answers. Every other command's words pass through untouched.
  static func preparedMenuWords(
    _ args: [String], directory: String,
    inventory: NormalModeDispatcher.CommandLineInventory,
    readStdin: () -> Data?
  ) -> (words: [String], temporaryFile: URL?) {
    let fileIndex = args.firstIndex { $0.hasPrefix("--file=") }
    let probe = fileIndex == nil ? args + ["--file=/"] : args
    guard
      case .commands(let commands) = NormalModeDispatcher.resolveCommandWords(
        probe, inventory: inventory),
      commands.count == 1, case .menuChoose = commands[0]
    else { return (args, nil) }
    if let fileIndex {
      let path = String(args[fileIndex].dropFirst("--file=".count))
      guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return (args, nil) }
      var words = args
      words[fileIndex] = "--file=" + (directory as NSString).appendingPathComponent(path)
      return (words, nil)
    }
    guard let data = readStdin() else { return (args, nil) }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-menu-\(UUID().uuidString).txt")
    guard
      FileManager.default.createFile(
        atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { return (args, nil) }
    return (args + ["--file=\(url.path)"], url)
  }

  /// Standard input when it is a pipe or a file, never a terminal.
  private static func readPipedStandardInput() -> Data? {
    guard isatty(STDIN_FILENO) == 0 else { return nil }
    return FileHandle.standardInput.readDataToEndOfFile()
  }

  /// Print a result: its output on stdout and its message on stderr, or,
  /// with `--json`, the result as one JSON object on stdout. The exit
  /// status is the same either way.
  static func finish(_ result: CommandInvocationResult, asJSON: Bool = false) -> Int32 {
    if asJSON {
      print(String(decoding: result.json, as: UTF8.self))
      return result.exitCode
    }
    if let output = result.output { print(output, terminator: output.hasSuffix("\n") ? "" : "\n") }
    if let message = result.message {
      FileHandle.standardError.write(Data("flash: \(message)\n".utf8))
    }
    return result.exitCode
  }

  /// A query answered from files, in this process.
  static func runLocally(_ query: FlashQuery, _ arguments: [String: String])
    -> CommandInvocationResult
  {
    switch query {
    case .configSchema:
      guard let defaults = ConfigLoader.embeddedDefaultLayer(in: appBundle)?.text else {
        return .failed("this build has no config.default.toml to describe")
      }
      return .succeeded(ConfigSchema.json(defaults: defaults))
    case .configCheck:
      return runConfigCheck(arguments)
    case .completion:
      guard let shell = arguments["shell"].flatMap(CLIReference.Shell.init(rawValue:)) else {
        return .failed("--shell must be zsh, bash or fish")
      }
      return .succeeded(CLIReference.completion(for: shell))
    case .manPage:
      return .succeeded(CLIReference.manPage())
    case .status, .doctor, .eventsWatch:
      return .failed("\(query.name) needs the resident")
    }
  }

  /// `config check`, in this process: the default config path and a
  /// relative `--file` read from this shell's environment and directory.
  /// Exit 1 for problems, 2 for a file it cannot read.
  private static func runConfigCheck(_ arguments: [String: String]) -> CommandInvocationResult {
    let url =
      arguments["file"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
      ?? ConfigLoader.resolvePath(environment: ProcessInfo.processInfo.environment)
    let check = ConfigCheck.run(
      fileURL: url.resolvingSymlinksInPath(),
      text: (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) },
      defaultLayer: ConfigLoader.embeddedDefaultLayer(in: appBundle))
    let output = check.lines.isEmpty ? nil : check.lines.joined(separator: "\n")
    switch check.exitCode {
    case 0: return .succeeded(output)
    case 1: return CommandInvocationResult(status: .failed, output: output)
    default: return CommandInvocationResult(status: .rejected, output: output)
    }
  }

  /// The app bundle this executable lives in. Run through the
  /// `~/.local/bin/flash` symlink, `Bundle.main` is the symlink's directory,
  /// so the bundle is found from the executable's resolved path.
  static var appBundle: Bundle {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
      return .main
    }
    return appBundle(containing: executable) ?? .main
  }

  /// `…/Flash.app` for `…/Flash.app/Contents/MacOS/flash`; nil outside a bundle.
  static func appBundle(containing executable: URL) -> Bundle? {
    let macOS = executable.deletingLastPathComponent()
    let contents = macOS.deletingLastPathComponent()
    let app = contents.deletingLastPathComponent()
    guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
      app.pathExtension == "app"
    else { return nil }
    return Bundle(url: app)
  }
}
