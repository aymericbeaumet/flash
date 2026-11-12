import FlashCore
import Foundation

/// The command line's vocabulary and its one resolver.
///
/// A typed `:` line, or the words after `flash` in a terminal, is read in
/// this order: an exact Flash command (`:help show`), a vim ex command at
/// or past its minimum (`:q`, `:tabn`), then each word by its unique prefix
/// among the words available right now (`:ta nex` is `tab next`,
/// `:screensh w` is `screenshot window`). An ambiguous or unknown prefix
/// resolves nothing: the completion list, or the CLI's error, names the
/// candidates. Completion and dispatch share the resolver, so the row the
/// list highlights is what Enter runs. Config files and mappings stay
/// canonical: `URLEventHandler.parse(words:)` knows none of this.
extension NormalModeDispatcher {

  // MARK: - Vim ex commands

  /// What `!` after an ex command's name does.
  enum BangPolicy: Equatable {
    /// `:name!` is not a command.
    case rejected
    /// `:name!` runs the same commands: vim's `!` discards unsaved changes,
    /// and Flash has nothing to discard.
    case accepted
    /// `:name!` runs these instead (`app quit --force`).
    case forces([URLCommand])
  }

  /// What the words after an ex command's name mean.
  enum CommandLineTrailing: Equatable {
    /// Nothing may follow the name.
    case rejected
    /// The words are the help topic (`:h plugins`), matched by unique
    /// prefix among the manual's pages and the plugins' guides, or passed
    /// through when none starts with them.
    case helpTopic
    /// An optional register name the commands take (`:y a`, `:pu +`).
    case register
    /// A tab position selects that tab (`:tabn 3`, `:b 3`); without one the
    /// commands run, or nothing when the position is required.
    case tabIndex(required: Bool)
    /// `+N` or `-N` moves the tab that many places (`:tabm +1`).
    case tabOffset
    /// One key of vim's `ctrl+w` window commands (`:winc l`).
    case windowKey
    /// The keys of a NORMAL mapping, with an optional count and register
    /// (`:norm 3gt`).
    case keys

    /// How the catalog and completion show what follows the name.
    var syntax: String {
      switch self {
      case .rejected: return ""
      case .helpTopic: return " [topic]"
      case .register: return " [x]"
      case .tabIndex(let required): return required ? " N" : " [N]"
      case .tabOffset: return " ±N"
      case .windowKey: return " {c}"
      case .keys: return " {keys}"
      }
    }
  }

  /// vim's `ctrl+w {c}` window commands, for `:winc[md] {c}`; the NORMAL
  /// defaults bind the same keys after `ctrl+w`.
  static let windowCommandWords: [Character: [String]] = [
    "h": ["window", "focus", "--direction=left"],
    "j": ["window", "focus", "--direction=down"],
    "k": ["window", "focus", "--direction=up"],
    "l": ["window", "focus", "--direction=right"],
    "w": ["window", "next"],
    "W": ["window", "previous"],
    "q": ["window", "close"],
    "c": ["window", "close"],
    "n": ["window", "new"],
    "H": ["window", "move", "--position=lefthalf"],
    "J": ["window", "move", "--position=bottomhalf"],
    "K": ["window", "move", "--position=tophalf"],
    "L": ["window", "move", "--position=righthalf"],
    "o": ["window", "move", "--position=maximized"],
    "=": ["window", "move", "--position=centered"],
    "s": ["pane", "split_horizontal"],
    "v": ["pane", "split_vertical"],
  ]

  /// An ex command's name with vim's minimum in brackets: `q[uit]` is
  /// typed as `q`, `qu`, `qui` or `quit`. Case matters (`tabN[ext]` is not
  /// `tabn[ext]`).
  struct CommandLineName: ExpressibleByStringLiteral, Equatable {
    var documented: String
    var full: String
    var minimumLength: Int

    init(stringLiteral value: String) {
      self.init(value)
    }

    init(_ documented: String) {
      self.documented = documented
      var full = ""
      var required = 0
      var optional = false
      for ch in documented {
        switch ch {
        case "[":
          optional = true
        case "]":
          optional = false
        default:
          full.append(ch)
          if !optional { required += 1 }
        }
      }
      self.full = full
      self.minimumLength = required
    }

    func matches(_ body: String) -> Bool {
      body.count >= minimumLength && body.count <= full.count && full.hasPrefix(body)
    }
  }

  /// One vim ex command that is a Flash command: its names with their
  /// minimums, the commands it runs in order (a step whose outcome is
  /// `.failed` stops the rest), its `!` form and what may follow it.
  struct CommandLineSpec: Equatable {
    var names: [CommandLineName]
    var commands: [URLCommand]
    var bangPolicy: BangPolicy = .rejected
    var trailing: CommandLineTrailing = .rejected
    /// Runs a query instead of commands (`:checkh`).
    var query: FlashQuery? = nil

    /// What it runs, as the completion list and the catalog show it:
    /// `tab close`, `app save, then tab close`.
    var description: String {
      if let query { return query.name.description }
      switch trailing {
      case .tabIndex(required: true): return "tab select"
      case .tabOffset: return "tab move_next / tab move_previous"
      case .windowKey: return "the ctrl+w window command"
      case .keys: return "the NORMAL mapping for the keys"
      default: break
      }
      return commands.map { $0.argv.dropFirst().joined(separator: " ") }.joined(
        separator: ", then ")
    }

    /// An alias spelled like one of Flash's topics (`di[splay]`) that takes no
    /// words: followed by some, the line is the topic's (`:disp sleep`).
    var yieldsWordsToTopic: Bool {
      trailing == .rejected && names.contains { URLEventHandler.isTopic($0.full) }
    }

    /// `:q[uit]`; the `!` form is listed only where it does something more.
    var helpLine: String {
      let base = names.map { ":\($0.documented)\(trailing.syntax)" }.joined(separator: " / ")
      guard case .forces = bangPolicy else { return base }
      return "\(base) / \(names.map { ":\($0.documented)!" }.joined(separator: " / "))"
    }

    func matches(_ word: String) -> Bool {
      names.contains { $0.matches(word) }
    }
  }

  /// The vim ex commands, with vim's minimums. `:q` is vim's quit (`app
  /// close`): the tab, as vim closes the window it is in; in an app with no
  /// tab to close, the OS window, and the app itself with its last window.
  /// `:clo[se]` is the OS window alone; `:bd[elete]` unloads vim's buffer,
  /// which is the tab here. `:wq` and its spellings save, then run `:q`
  /// only when the save did not fail. `:q!`, `:w!`
  /// and `:wq!` run as without the `!`, which in vim discards changes Flash
  /// never holds; `:qa!` and `:wqa!` force-quit, and `:e!` reverts the
  /// document, after asking. `:h[elp] <topic>` opens a
  /// page of the manual. No name may equal a topic or a plugin command,
  /// except `help`, which runs that topic's only command, and `display`,
  /// vim's `:di` for the registers, which alone shows them and leaves the
  /// words after it to the `display` topic (`:disp sleep`).
  static let commandLineSpecs: [CommandLineSpec] = [
    CommandLineSpec(names: ["q[uit]"], commands: [.appClose], bangPolicy: .accepted),
    CommandLineSpec(
      names: ["qa[ll]", "quita[ll]"], commands: [.quitApp(force: false)],
      bangPolicy: .forces([.quitApp(force: true)])),
    CommandLineSpec(names: ["bd[elete]"], commands: [.tabClose]),
    CommandLineSpec(names: ["clo[se]"], commands: [.windowClose]),
    CommandLineSpec(names: ["w[rite]"], commands: [.save], bangPolicy: .accepted),
    CommandLineSpec(
      names: ["wq", "x[it]", "exi[t]"], commands: [.save, .appClose], bangPolicy: .accepted),
    CommandLineSpec(
      names: ["wqa[ll]", "xa[ll]"], commands: [.saveAndQuit(force: false)],
      bangPolicy: .forces([.saveAndQuit(force: true)])),
    CommandLineSpec(names: ["tabnew", "tabe[dit]"], commands: [.tabNew]),
    CommandLineSpec(names: ["tabc[lose]"], commands: [.tabClose]),
    CommandLineSpec(
      names: ["tabn[ext]"], commands: [.tabNext], trailing: .tabIndex(required: false)),
    CommandLineSpec(names: ["tabp[revious]", "tabN[ext]"], commands: [.tabPrev]),
    CommandLineSpec(names: ["tabfir[st]", "tabr[ewind]"], commands: [.tabFirst]),
    CommandLineSpec(names: ["tabl[ast]"], commands: [.tabLast]),
    CommandLineSpec(names: ["new", "vne[w]"], commands: [.windowNew(private: false)]),
    CommandLineSpec(names: ["sp[lit]"], commands: [.paneSplitHorizontal]),
    CommandLineSpec(names: ["vs[plit]"], commands: [.paneSplitVertical]),
    CommandLineSpec(names: ["u[ndo]"], commands: [.undo]),
    CommandLineSpec(names: ["red[o]"], commands: [.redo]),
    // `:e!` is vim's revert to the file as saved: the app's, after asking.
    CommandLineSpec(
      names: ["e[dit]"], commands: [.documentOpen], bangPolicy: .forces([.documentRevert])),
    CommandLineSpec(names: ["sav[eas]"], commands: [.documentSaveAs]),
    // `:p` and `:pr` print here; `process` is `:proc` and longer.
    CommandLineSpec(names: ["p[rint]", "ha[rdcopy]"], commands: [.print]),
    // vim's options window; its `:hid[e]` hides the buffer, here the app.
    CommandLineSpec(names: ["opt[ions]"], commands: [.appSettings]),
    CommandLineSpec(names: ["hid[e]"], commands: [.appVisibility(.hide)]),
    CommandLineSpec(names: ["h[elp]"], commands: [.showUsage(topic: nil)], trailing: .helpTopic),
    CommandLineSpec(names: ["map"], commands: [.showMappings]),
    CommandLineSpec(names: ["ter[minal]", "sh[ell]"], commands: [.terminalMode(name: nil)]),
    // Buffers are tabs here, as `:bd` already says.
    CommandLineSpec(names: ["bn[ext]"], commands: [.tabNext]),
    CommandLineSpec(names: ["bp[revious]", "bN[ext]"], commands: [.tabPrev]),
    CommandLineSpec(names: ["bf[irst]", "br[ewind]"], commands: [.tabFirst]),
    CommandLineSpec(names: ["bl[ast]"], commands: [.tabLast]),
    CommandLineSpec(names: ["b[uffer]"], commands: [], trailing: .tabIndex(required: true)),
    // `:ls` lists vim's buffers to choose one; the switcher lists every window.
    CommandLineSpec(names: ["ls", "buffers", "files"], commands: [.windowSwitch]),
    CommandLineSpec(names: ["tabm[ove]"], commands: [], trailing: .tabOffset),
    CommandLineSpec(names: ["winc[md]"], commands: [], trailing: .windowKey),
    CommandLineSpec(names: ["up[date]"], commands: [.save]),
    CommandLineSpec(
      names: ["y[ank]"], commands: [.yankSelection(register: nil)], trailing: .register),
    CommandLineSpec(names: ["pu[t]"], commands: [.paste(register: nil)], trailing: .register),
    CommandLineSpec(
      names: ["reg[isters]", "di[splay]"],
      commands: [URLEventHandler.parse(words: ["clipboard", "show"])].compactMap { $0 }),
    CommandLineSpec(names: ["so[urce]"], commands: [.configReload]),
    CommandLineSpec(names: ["ve[rsion]"], commands: [.showAbout]),
    CommandLineSpec(names: ["star[tinsert]"], commands: [.insertMode]),
    CommandLineSpec(names: ["stopi[nsert]"], commands: [.normalMode]),
    CommandLineSpec(names: ["mes[sages]"], commands: [.showLogs]),
    CommandLineSpec(names: ["checkh[ealth]"], commands: [], query: .doctor),
    CommandLineSpec(names: ["norm[al]"], commands: [], trailing: .keys),
  ]

  /// The one word of the grammar outside the command table, resolved like a
  /// topic's name: `doctor` is `resident doctor`.
  static let commandLineBuiltinWords = ["doctor"]

  /// `open <args>` and `flashlight <query>` take the rest of the line as
  /// text.
  static let commandLineArgumentCommands = ["flashlight", "open"]

  // MARK: - Inventory and resolution

  /// The words the command line resolves against, built once per command
  /// session: Flash's topics with their actions, the loaded plugins'
  /// commands with their subcommands, and the help topics.
  struct CommandLineInventory: Equatable {
    /// `topic → actions`, Flash's command table.
    var topics: [String: [String]]
    /// `command → subcommands` of the loaded plugins; `*` marks a wildcard.
    var pluginCommands: [String: [String]]
    /// The manual's pages and the plugins' guides, for `:help <topic>`.
    var helpTopics: [String]

    static func core(
      pluginCommands: [String: [String]] = [:], helpTopics: [String] = []
    ) -> CommandLineInventory {
      var topics: [String: [String]] = [:]
      for name in URLEventHandler.commandNames + FlashQuery.allCases.map(\.name) {
        topics[name.topic, default: []].append(name.action)
      }
      return CommandLineInventory(
        topics: topics, pluginCommands: pluginCommands, helpTopics: helpTopics)
    }

    /// Every word a line may start with, besides the ex commands.
    var firstWords: [String] {
      Array(
        Set(
          topics.keys.filter { !(topics[$0] ?? []).isEmpty }
            + pluginCommands.keys
            + commandLineBuiltinWords
            + commandLineArgumentCommands)
      ).sorted()
    }

    /// The words that may follow `topic`: its actions.
    func actions(of topic: String) -> [String]? {
      guard let actions = topics[topic] else { return nil }
      return actions
    }
  }

  /// A typed word against the words available at its position.
  enum CommandLineWordMatch: Equatable {
    /// The word is one of them: it wins over any longer word it prefixes.
    case exact(String)
    /// Exactly one word starts with it.
    case unique(String)
    /// Two or more words start with it, sorted.
    case ambiguous([String])
    case none

    var word: String? {
      switch self {
      case .exact(let word), .unique(let word): return word
      case .ambiguous, .none: return nil
      }
    }

    var isAmbiguous: Bool {
      if case .ambiguous = self { return true }
      return false
    }
  }

  static func matchCommandLineWord(_ typed: String, among candidates: [String])
    -> CommandLineWordMatch
  {
    if candidates.contains(typed) { return .exact(typed) }
    let matches = Array(Set(candidates.filter { $0.hasPrefix(typed) })).sorted()
    switch matches.count {
    case 0: return .none
    case 1: return .unique(matches[0])
    default: return .ambiguous(matches)
    }
  }

  /// What a `:` line runs.
  enum CommandLineResolution: Equatable {
    /// Flash commands, in order; a step whose outcome is `.failed` stops the rest.
    case commands([URLCommand])
    /// A plugin command with its subcommand and the words after it.
    case plugin(command: String, subcommand: String, args: [String])
    /// `resident status`, `resident doctor` (`doctor`) or `config check`,
    /// with their arguments.
    case query(FlashQuery, arguments: [String: String])
    /// `open <args>`: the words for `/usr/bin/open`, verbatim.
    case open([String])
    /// `flashlight <query>`: the finder, opened on the query.
    case flashlight(String)
    /// `!<command>`: a shell command, its output shown.
    case shell(String)
    /// `norm[al] <keys>`: the NORMAL mapping those keys run, with an
    /// optional `"x` register and count.
    case normalKeys(String)
    /// A word that needs more: a topic without its action, `open` or
    /// `flashlight` without their text. Completion inserts it.
    case incomplete(String)
    /// Two or more words share the typed prefix: nothing runs, the list
    /// shows them.
    case ambiguous([String])
    /// No word starts with the prefix, a `!` or a word where none may be,
    /// or arguments the command rejects.
    case unknown
    case empty
  }

  static func resolveCommandLine(_ raw: String, inventory: CommandLineInventory)
    -> CommandLineResolution
  {
    resolveCommandWords(commandLineWords(raw), inventory: inventory)
  }

  /// The resolver over words: the CLI's argv, or a `:` line split on
  /// whitespace.
  static func resolveCommandWords(_ words: [String], inventory: CommandLineInventory)
    -> CommandLineResolution
  {
    // A blank CLI word (a quoted variable that is unset) is the extra space
    // the command line skips, never a prefix of every word.
    let words = words.filter { !$0.trimmed.isEmpty }
    guard let first = words.first else { return .empty }
    let rest = Array(words.dropFirst())
    // vim's `:!{cmd}`: the rest of the line is a shell command.
    if first.hasPrefix("!") {
      let command = ([String(first.dropFirst())] + rest).joined(separator: " ").trimmed
      return command.isEmpty ? .incomplete("!") : .shell(command)
    }
    // vim's `:{n}` and `:$`: line n, the last line, of the engaged field.
    if rest.isEmpty, let line = commandLineLineCommand(first) {
      return .commands([line])
    }
    // An exact Flash command wins over everything that shares its first
    // word: `:help show` is the command, `:help plugins` the ex form.
    if let actions = inventory.topics[first], let second = rest.first, actions.contains(second) {
      return coreCommand(first, second, rest.dropFirst())
    }
    // A vim ex command at or past its minimum, case-sensitively. `!`
    // belongs to it alone.
    var name = first
    var bang = false
    if name.hasSuffix("!") {
      bang = true
      name.removeLast()
    }
    if let spec = commandLineSpecs.first(where: { $0.matches(name) }),
      bang || rest.isEmpty || !spec.yieldsWordsToTopic
    {
      return resolve(spec, bang: bang, trailing: rest, inventory: inventory)
    }
    guard !bang else { return .unknown }
    // Each word by its unique prefix at its position.
    switch matchCommandLineWord(first, among: inventory.firstWords) {
    case .none:
      return .unknown
    case .ambiguous(let candidates):
      return .ambiguous(candidates)
    case .exact(let word), .unique(let word):
      if let actions = inventory.topics[word] {
        return resolveTopic(word, actions: actions, rest: rest, inventory: inventory)
      }
      if let subcommands = inventory.pluginCommands[word] {
        return resolvePlugin(word, subcommands: subcommands, rest: rest)
      }
      switch word {
      case "doctor": return query(.doctor, rest[...])
      case "open": return rest.isEmpty ? .incomplete(word) : .open(rest)
      case "flashlight":
        return rest.isEmpty ? .incomplete(word) : .flashlight(rest.joined(separator: " "))
      default: return .incomplete(word)
      }
    }
  }

  private static func resolveTopic(
    _ topic: String, actions: [String], rest: [String], inventory: CommandLineInventory
  ) -> CommandLineResolution {
    guard let second = rest.first else {
      // A topic alone runs the one of its actions that only shows (`:logs`
      // is `logs show`, never `logs write`) or reports (a query); one that
      // changes anything (`display sleep`, `screen lock`) waits for its
      // action, and so does a topic with two that show or report (`:cli`).
      let implied = actions.filter { action in
        if FlashQuery(topic: topic, action: action) != nil { return true }
        guard case .commands(let commands) = coreCommand(topic, action, []) else { return false }
        return commands.allSatisfy(\.impliedByItsTopic)
      }
      if implied.count == 1 {
        let resolution = coreCommand(topic, implied[0], [])
        switch resolution {
        case .commands, .query: return resolution
        default: break
        }
      }
      return .incomplete(topic)
    }
    // A topic with one action takes its arguments right away:
    // `:metrics --name=… --value=…` is `:metrics record --name=… --value=…`.
    if actions.count == 1, second.hasPrefix("--") {
      return coreCommand(topic, actions[0], rest[...])
    }
    switch matchCommandLineWord(second, among: inventory.actions(of: topic) ?? actions) {
    case .none:
      return .unknown
    case .ambiguous(let candidates):
      return .ambiguous(candidates)
    case .exact(let action), .unique(let action):
      return coreCommand(topic, action, rest.dropFirst())
    }
  }

  /// The `cursor` command of vim's `:{n}` (`:42`, `:0` the first line) and
  /// `:$` (the last line); nil for any other word.
  static func commandLineLineCommand(_ word: String) -> URLCommand? {
    if word == "$" { return .cursor(.motion(.lastLine)) }
    guard !word.isEmpty, word.allSatisfy({ $0.isASCII && $0.isNumber }), let line = Int(word)
    else { return nil }
    return .cursor(.line(index: max(line, 1)))
  }

  private static func resolvePlugin(
    _ command: String, subcommands: [String], rest: [String]
  ) -> CommandLineResolution {
    guard let second = rest.first else { return .incomplete(command) }
    let declared = subcommands.filter { !$0.isEmpty && $0 != "*" }
    let args = Array(rest.dropFirst())
    switch matchCommandLineWord(second, among: declared) {
    case .exact(let subcommand), .unique(let subcommand):
      return .plugin(command: command, subcommand: subcommand, args: args)
    case .ambiguous(let candidates):
      return .ambiguous(candidates)
    case .none:
      // A wildcard command takes the words as typed (`:calc 2 + 2`).
      guard subcommands.contains("*") else { return .unknown }
      return .plugin(command: command, subcommand: second, args: args)
    }
  }

  private static func resolve(
    _ spec: CommandLineSpec, bang: Bool, trailing: [String], inventory: CommandLineInventory
  ) -> CommandLineResolution {
    let commands: [URLCommand]
    switch (bang, spec.bangPolicy) {
    case (false, _), (true, .accepted): commands = spec.commands
    case (true, .rejected): return .unknown
    case (true, .forces(let forced)): commands = forced
    }
    if let flashQuery = spec.query {
      return trailing.isEmpty ? .query(flashQuery, arguments: [:]) : .unknown
    }
    switch spec.trailing {
    case .rejected:
      return trailing.isEmpty ? .commands(commands) : .unknown
    case .register:
      guard let name = trailing.first else { return .commands(commands) }
      guard trailing.count == 1, name.count == 1, let character = name.first,
        NormalModeInterpreter.isRegisterNameChar(character)
      else { return .unknown }
      return .commands(
        commands.compactMap {
          NormalModeInterpreter.applyingRegister(name, to: .flashCommand($0)).command
        })
    case .tabIndex(let required):
      guard let word = trailing.first else {
        return required ? .incomplete(spec.names[0].full) : .commands(commands)
      }
      guard trailing.count == 1, let index = Int(word), (1...999).contains(index) else {
        return .unknown
      }
      return .commands([.tabSelect(index: index)])
    case .tabOffset:
      guard trailing.count == 1, let word = trailing.first, let sign = word.first,
        sign == "+" || sign == "-", let places = Int(word.dropFirst()), (1...99).contains(places)
      else { return .unknown }
      return .commands(Array(repeating: sign == "+" ? .tabMoveNext : .tabMovePrev, count: places))
    case .windowKey:
      guard trailing.count == 1, let word = trailing.first, word.count == 1,
        let key = word.first, let words = windowCommandWords[key],
        let command = URLEventHandler.parse(words: words)
      else { return .unknown }
      return .commands([command])
    case .keys:
      let keys = trailing.joined(separator: " ")
      return keys.isEmpty ? .incomplete(spec.names[0].full) : .normalKeys(keys)
    case .helpTopic:
      guard !trailing.isEmpty else { return .commands(commands) }
      let typed = trailing.joined(separator: " ")
      guard !typed.hasPrefix("-") else { return .unknown }
      switch matchCommandLineWord(typed, among: inventory.helpTopics) {
      case .exact(let topic), .unique(let topic):
        return .commands([.showUsage(topic: topic)])
      case .ambiguous(let candidates):
        return .ambiguous(candidates)
      case .none:
        return .commands([.showUsage(topic: typed)])
      }
    }
  }

  private static func coreCommand(_ topic: String, _ action: String, _ rest: ArraySlice<String>)
    -> CommandLineResolution
  {
    if let flashQuery = FlashQuery(topic: topic, action: action) {
      return query(flashQuery, rest)
    }
    guard let args = commandLineArguments(rest),
      let command = URLEventHandler.parse(topic: topic, action: action, args: args)
    else { return .unknown }
    return .commands([command])
  }

  private static func query(_ query: FlashQuery, _ rest: ArraySlice<String>)
    -> CommandLineResolution
  {
    guard let arguments = commandLineArguments(rest), query.accepts(arguments) else {
      return .unknown
    }
    return .query(query, arguments: arguments)
  }

  /// The `--name=value` words after an action. A word that is not an
  /// argument continues the value before it, so `--device=Studio Speakers`
  /// keeps the device name whole. Nil when they do not parse.
  static func commandLineArguments(_ words: ArraySlice<String>) -> [String: String]? {
    var arguments: [String] = []
    for word in words {
      if word.hasPrefix("--") || arguments.isEmpty {
        arguments.append(word)
      } else {
        arguments[arguments.count - 1] += " " + word
      }
    }
    return try? CommandArguments.parse(arguments)
  }

  /// The line's words, without the prompt's colon.
  static func commandLineWords(_ raw: String) -> [String] {
    var body = raw.trimmed
    if body.hasPrefix(":") { body.removeFirst() }
    return body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
  }

  /// A Flash command by its exact words, as a mapping or the CLI reads it:
  /// `:tab next`, `:popup quit --name=btop`. Nil for anything else; the
  /// command line itself goes through ``resolveCommandLine(_:inventory:)``.
  static func commandLineCoreCommand(_ raw: String) -> URLCommand? {
    let words = commandLineWords(raw)
    guard words.count >= 2, URLEventHandler.isTopic(words[0]),
      let args = commandLineArguments(words.dropFirst(2))
    else { return nil }
    return URLEventHandler.parse(topic: words[0], action: words[1], args: args)
  }

  /// Runs `commands` in order through `perform`, which reports each step's
  /// outcome; a step that failed, or found no app to act in, stops the rest
  /// (`:wq` closes nothing when the save failed). `completion` gets the step
  /// that ended the run and its outcome.
  static func runCommandSequence<Outcome>(
    _ commands: [URLCommand],
    outcome: @escaping (Outcome) -> NormalModeCommandOutcome,
    perform: @escaping (URLCommand, @escaping (Outcome) -> Void) -> Void,
    completion: @escaping (URLCommand, Outcome) -> Void = { _, _ in }
  ) {
    guard let first = commands.first else { return }
    let rest = Array(commands.dropFirst())
    perform(first) { result in
      guard !rest.isEmpty, commandSequenceContinues(after: outcome(result)) else {
        return completion(first, result)
      }
      runCommandSequence(rest, outcome: outcome, perform: perform, completion: completion)
    }
  }

  static func runCommandSequence(
    _ commands: [URLCommand],
    perform: @escaping (URLCommand, @escaping (NormalModeCommandOutcome) -> Void) -> Void
  ) {
    runCommandSequence(commands, outcome: { $0 }, perform: perform)
  }

  static func commandSequenceContinues(after outcome: NormalModeCommandOutcome) -> Bool {
    switch outcome {
    case .failed, .noTarget: return false
    case .performed, .chordSent, .unavailable, .refused: return true
    }
  }

  // MARK: - Other `:` syntaxes

  /// Whether completing `name` leaves the line open for an argument it
  /// requires (`app open --name=`). The others run on `<CR>`; `<tab>` still
  /// inserts them for optional arguments (`popup quit --name=btop`).
  static func commandAwaitsArguments(_ name: CommandName) -> Bool {
    URLEventHandler.requiresArguments(name)
  }

  /// Recognize the flashlight command only after its separating whitespace has
  /// been typed. Bare `:flashlight` still belongs to top-level command
  /// completion because the command is not syntactically committed yet.
  static func commandLineCandidateQuery(_ raw: String) -> String? {
    commandLineQuery(raw, name: "flashlight")
  }

  /// True when the command buffer is just the `:` prompt (plus any leading or
  /// trailing whitespace) with no command typed yet.
  static func commandLineBodyIsEmpty(_ raw: String) -> Bool {
    var body = raw.trimmingCharacters(in: .newlines)
    body.removeLeadingWhitespace()
    if body.hasPrefix(":") {
      body.removeFirst()
    }
    return body.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// Which surface an up/down (or ctrl+p / ctrl+n) move drives in the `:` bar.
  enum CommandLineMoveTarget: Equatable {
    case candidates
    case completions
    case history
  }

  /// Decide what up/down (and ctrl+p / ctrl+n) navigate in the command bar.
  ///
  /// History recall wins whenever there is nothing to pick from a list: an
  /// empty command body (bare `:`), or an in-progress recall — so the user can
  /// keep cycling even though a recalled entry looks like a command or a
  /// flashlight query. Otherwise the flashlight candidate list or the
  /// command-completion list keeps the arrows, exactly as before.
  static func commandLineMoveTarget(
    bodyIsEmpty: Bool,
    isRecalling: Bool,
    hasCandidateQuery: Bool,
    hasCompletions: Bool
  ) -> CommandLineMoveTarget {
    if isRecalling || bodyIsEmpty {
      return .history
    }
    if hasCandidateQuery {
      return .candidates
    }
    if hasCompletions {
      return .completions
    }
    return .history
  }

  /// At the top of a suggestion list (candidate finder or command completions),
  /// one more "up" (`delta < 0` with the selection already at index 0, or with
  /// no row highlighted) crosses over into command history instead of
  /// clamping; stepping back down walks out of history and returns to the
  /// list. Any other move stays in the list.
  static func commandLineListTopEntersHistory(delta: Int, selectedIndex: Int) -> Bool {
    delta < 0 && selectedIndex <= 0
  }

  struct CandidateFinderQuery: Equatable {
    /// `@<type>` narrows the pool to the rows of that resource type
    /// (`ResourceTypes`); nil when the user didn't type one. A token that is
    /// no type name (`@emojis`) is kept as a type that matches nothing.
    var scope: SourceScope?
    /// The residual search text (every non-selector token, space-joined).
    var text: String
  }

  /// Parse `@<type>` narrowing from the live query. At most one `@<type>`
  /// token is honoured — the first one. Every other token is kept as literal
  /// search text.
  ///
  /// Examples:
  ///   "@tabs gmail"  → scope=.type("tabs"),   text="gmail"
  ///   "@Emojis "     → scope=.type("emojis"), text=""
  ///   "gmail"        → scope=nil,             text="gmail"
  ///   "@"            → scope=nil,             text="@"
  static func candidateFinderQuery(_ query: String) -> CandidateFinderQuery {
    var scope: SourceScope?
    var words: [Substring] = []
    for token in query.split(whereSeparator: { $0.isWhitespace }) {
      guard token.hasPrefix("@"), scope == nil else {
        words.append(token)
        continue
      }
      let body = token.dropFirst(1)
      if body.isEmpty {
        words.append(token)
        continue
      }
      scope = .type(body.lowercased())
    }
    return CandidateFinderQuery(scope: scope, text: words.joined(separator: " "))
  }

  private static func commandLineQuery(
    _ raw: String,
    name: String
  ) -> String? {
    var body = raw.trimmingCharacters(in: .newlines)
    body.removeLeadingWhitespace()
    if body.hasPrefix(":") {
      body.removeFirst()
      body.removeLeadingWhitespace()
    }

    guard body.count > name.count else { return nil }
    let nameEnd = body.index(body.startIndex, offsetBy: name.count)
    guard body[..<nameEnd].lowercased() == name else { return nil }
    guard body[nameEnd].isWhitespace else { return nil }
    let restStart = body.index(after: nameEnd)
    // Preserve trailing whitespace: it's the signal `parseBangState`
    // uses to lock onto a bang. We only strip leading whitespace
    // between `flashlight` and the user's query, plus newlines (the
    // command-line buffer should never carry one, but Foundation's
    // string editing can leak them through paste).
    var query = String(body[restStart...])
    query = String(query.drop(while: { $0 == " " || $0 == "\t" }))
    // Preserve a leading `=` marker. It is calculator-owned syntax, not a
    // generic flashlight-query rewrite; evaluator plugins can claim it
    // explicitly while ordinary catalog matching still sees the marker.
    query = query.replacingOccurrences(of: "\n", with: "")
    return query
  }

  /// Detect the `#` output-capture modifier. A `#` immediately after the
  /// `:` prompt (`:#aws whoami`) or at the very head (`#aws whoami`) means
  /// "run the command and put its stdout on the clipboard". Returns the
  /// raw with the `#` stripped (the leading `:` preserved so downstream
  /// parsers are unaffected) plus whether the modifier was present.
  static func commandLineClipboardModifier(_ raw: String) -> (raw: String, capture: Bool) {
    let trimmed = raw.trimmed
    var hadColon = false
    var body = trimmed
    if body.hasPrefix(":") {
      hadColon = true
      body.removeFirst()
      body = body.drop(while: { $0.isWhitespace }).description
    }
    guard body.hasPrefix("#") else { return (raw, false) }
    body.removeFirst()
    body = body.drop(while: { $0.isWhitespace }).description
    return ((hadColon ? ":" : "") + body, true)
  }

  // MARK: - Catalog

  static let builtinCatalog: [(name: String, description: String)] = [
    ("doctor", "Check permissions, key capture, config, hotkeys and plugins"),
    ("open", "Forward args to /usr/bin/open"),
    ("flashlight", "Fuzzy finder across apps, tabs, and plugins"),
  ]

  /// Flat catalog of every ex command, command-line builtin and Flash
  /// command (`:<topic> <action>`), tagged `source = "core"`. The HTTP
  /// inspector merges this with each plugin's declared commands to list every
  /// command and where it comes from.
  static func coreCommandCatalog() -> [[String: Any]] {
    var result: [[String: Any]] = []
    for spec in commandLineSpecs {
      guard let primary = spec.names.first else { continue }
      result.append([
        "name": ":\(primary.full)",
        "syntax": spec.helpLine,
        "aliases": spec.names.map { ":\($0.documented)" },
        "description": spec.description,
        "source": "core",
        "source_kind": "core",
      ])
    }
    for (name, description) in builtinCatalog {
      let syntax = commandLineArgumentCommands.contains(name) ? ":\(name) <args>" : ":\(name)"
      result.append([
        "name": ":\(name)",
        "syntax": syntax,
        "aliases": [":\(name)"],
        "description": description,
        "source": "core",
        "source_kind": "core",
      ])
    }
    for name in URLEventHandler.commandNames {
      result.append([
        "name": ":\(name)",
        "syntax": URLEventHandler.syntax(for: name, prefix: ":") ?? ":\(name)",
        "aliases": [String](),
        "description": URLEventHandler.summary(of: name) ?? "",
        "source": "core",
        "source_kind": "core",
      ])
    }
    for query in FlashQuery.allCases {
      let options = query.options.map { " " + $0.syntax }.joined()
      result.append([
        "name": ":\(query.name)",
        "syntax": ":\(query.name)\(options)",
        "aliases": [String](),
        "description": query.summary,
        "source": "core",
        "source_kind": "core",
      ])
    }
    return result
  }

  // MARK: - Completion

  /// A single completion candidate offered for a command or sub-command.
  ///
  /// Every candidate has a **value** (`insertion`) and a **label**
  /// (`label`). The label is purely cosmetic — it is what the user sees
  /// in the suggestion list and never affects behaviour. The value is
  /// what actually lands in the command-line buffer. When a candidate
  /// has no distinct label, set `label == insertion` so the value shows
  /// through.
  ///
  /// Selection semantics, uniform across built-in and plugin candidates:
  /// - `<tab>` inserts the candidate's value without sending the command
  ///   (the user can keep typing args).
  /// - `<CR>` inserts the candidate's value, then either leaves the line
  ///   open or submits according to `kind`.
  ///
  /// `kind` only governs what `<CR>` does once the value is inserted:
  /// `acceptsArgs` leaves the line open for arguments, while `terminal`
  /// and `pluginSubcommand` submit immediately.
  struct CommandLineCompletion: Equatable {
    enum Kind: Equatable {
      case terminal
      case acceptsArgs
      case pluginSubcommand
    }
    /// Cosmetic text shown in the suggestion list.
    var label: String
    /// The value inserted into the command line on `<tab>`/`<CR>`.
    var insertion: String
    var kind: Kind
    /// What an ex command runs, shown beside its name.
    var detail: String? = nil
  }

  /// The list for one typed line. `selectedLabel` is the label the typed
  /// query selects — an exact word, a unique prefix, or an ex command at
  /// or past its minimum — ranked first and highlighted, so Enter runs what
  /// the list shows; nil when the query selects none. With `ambiguous`,
  /// two or more labels share the query as a prefix: no row is
  /// highlighted and Enter runs nothing.
  struct CommandLineCompletionContext: Equatable {
    var prefix: String
    var query: String
    var items: [CommandLineCompletion]
    var selectedLabel: String?
    var ambiguous: Bool
  }

  /// The convenience form: an inventory from ordered plugin commands and
  /// their subcommands.
  static func commandLineCompletions(
    _ raw: String,
    pluginCommands: [String],
    pluginSubcommands: [String: [String]],
    helpTopics: [String] = []
  ) -> CommandLineCompletionContext? {
    var commands: [String: [String]] = [:]
    for command in pluginCommands {
      commands[command.lowercased()] = pluginSubcommands[command] ?? []
    }
    for (command, subcommands) in pluginSubcommands where commands[command.lowercased()] == nil {
      commands[command.lowercased()] = subcommands
    }
    return commandLineCompletions(
      raw, inventory: .core(pluginCommands: commands, helpTopics: helpTopics))
  }

  static func commandLineCompletions(_ raw: String, inventory: CommandLineInventory)
    -> CommandLineCompletionContext?
  {
    var body = raw
    body.removeLeadingWhitespace()
    guard body.hasPrefix(":") else { return nil }
    body.removeFirst()

    if body.first(where: { $0.isWhitespace }) == nil {
      let query = body
      let top = topLevelCompletions(inventory: inventory)
      var items = top.items
      if !query.isEmpty {
        let foldedQuery = query.folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: .current)
        items = zip(top.items, top.foldedLabels).compactMap { item, folded in
          folded.hasPrefix(foldedQuery) ? item : nil
        }
      }
      let selection = firstWordSelection(query, inventory: inventory)
      return CommandLineCompletionContext(
        prefix: ":", query: query, items: items,
        selectedLabel: selection.word, ambiguous: selection.isAmbiguous)
    }

    let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let first = String(parts[0])
    let rest = String(parts[1])
    guard rest.first(where: { $0.isWhitespace }) == nil else { return nil }

    // The first word resolves as dispatch resolves it: an ex command
    // (only `h[elp]` takes a word, the help topics), a topic's actions, a
    // plugin's declared subcommands.
    if let spec = commandLineSpecs.first(where: { $0.matches(first) }) {
      guard spec.trailing == .helpTopic else { return nil }
      let topics = inventory.helpTopics.sorted()
      let items = topics.map { topic in
        CommandLineCompletion(label: topic, insertion: topic, kind: .pluginSubcommand)
      }
      return context(
        prefix: ":help ", query: rest, items: items,
        match: matchCommandLineWord(rest, among: topics))
    }
    guard let word = matchCommandLineWord(first, among: inventory.firstWords).word else {
      return nil
    }
    if let actions = inventory.topics[word] {
      let words = actions.sorted()
      let items = words.map { action in
        let name = CommandName(word, action)
        return commandAwaitsArguments(name)
          ? CommandLineCompletion(label: action, insertion: "\(action) ", kind: .acceptsArgs)
          : CommandLineCompletion(label: action, insertion: action, kind: .pluginSubcommand)
      }
      return context(
        prefix: ":\(word) ", query: rest, items: items,
        match: matchCommandLineWord(rest, among: words))
    }
    if let subcommands = inventory.pluginCommands[word] {
      let declared = subcommands.filter { !$0.isEmpty && $0 != "*" }
      guard !declared.isEmpty else { return nil }
      let items = declared.map { name in
        CommandLineCompletion(label: name, insertion: name, kind: .pluginSubcommand)
      }
      return context(
        prefix: ":\(word) ", query: rest, items: items,
        match: matchCommandLineWord(rest, among: declared))
    }
    return nil
  }

  private static func context(
    prefix: String, query: String, items: [CommandLineCompletion], match: CommandLineWordMatch
  ) -> CommandLineCompletionContext {
    CommandLineCompletionContext(
      prefix: prefix, query: query, items: items,
      selectedLabel: match.word, ambiguous: match.isAmbiguous)
  }

  /// What a first word selects in the top-level list: the ex command it
  /// spells (at or past its minimum), else the unique word it prefixes.
  /// An ex command's name below its minimum is no prefix match, so `:ex`
  /// selects nothing, and the empty prompt is every word at once.
  private static func firstWordSelection(_ query: String, inventory: CommandLineInventory)
    -> CommandLineWordMatch
  {
    guard !query.isEmpty else { return .ambiguous(inventory.firstWords) }
    for spec in commandLineSpecs {
      if let name = spec.names.first(where: { $0.matches(query) }) { return .exact(name.full) }
    }
    return matchCommandLineWord(query, among: inventory.firstWords)
  }

  /// The `:` completion list with each label folded for prefix matching,
  /// built once per inventory: the list is static for a session, and every
  /// keystroke on the command line filters it.
  private struct TopLevelCompletions {
    var inventory: CommandLineInventory
    var items: [CommandLineCompletion]
    var foldedLabels: [String]
  }
  private static let topLevelCompletionsLock = NSLock()
  private static var topLevelCompletionsCache: TopLevelCompletions?

  private static func topLevelCompletions(inventory: CommandLineInventory) -> TopLevelCompletions {
    topLevelCompletionsLock.lock()
    defer { topLevelCompletionsLock.unlock() }
    if let cached = topLevelCompletionsCache, cached.inventory == inventory {
      return cached
    }
    let items = buildTopLevelCompletions(inventory: inventory)
    let built = TopLevelCompletions(
      inventory: inventory, items: items,
      foldedLabels: items.map {
        $0.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      })
    topLevelCompletionsCache = built
    return built
  }

  private static func buildTopLevelCompletions(inventory: CommandLineInventory)
    -> [CommandLineCompletion]
  {
    var items: [CommandLineCompletion] = []
    var seen = Set<String>()
    // Every spelling of an ex command, with what it runs.
    for spec in commandLineSpecs {
      for name in spec.names where seen.insert(name.full).inserted {
        let takesWords =
          spec.trailing != .rejected && spec.trailing != .register
          && spec.trailing != .tabIndex(required: false)
        items.append(
          CommandLineCompletion(
            label: name.full, insertion: takesWords ? "\(name.full) " : name.full,
            kind: takesWords ? .acceptsArgs : .terminal, detail: spec.description))
      }
    }
    for word in commandLineBuiltinWords where seen.insert(word).inserted {
      items.append(CommandLineCompletion(label: word, insertion: word, kind: .terminal))
    }
    for word in commandLineArgumentCommands where seen.insert(word).inserted {
      items.append(CommandLineCompletion(label: word, insertion: "\(word) ", kind: .acceptsArgs))
    }
    // Flash topics complete to `topic `, then their actions; so do plugin commands.
    for word in inventory.firstWords where seen.insert(word).inserted {
      items.append(CommandLineCompletion(label: word, insertion: "\(word) ", kind: .acceptsArgs))
    }
    items.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    return items
  }
}
