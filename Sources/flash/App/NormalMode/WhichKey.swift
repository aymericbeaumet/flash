import Foundation

/// The which-key palette: after a NORMAL prefix pause, the keys that can
/// follow it and what each runs. Pure over the interpreter state and compiled mappings.
enum WhichKey {
  struct Entry: Equatable {
    /// The next key, spelled as the mappings page spells keys.
    let key: String
    /// What it runs: the command's words, or how many longer mappings
    /// continue through it.
    let title: String
  }

  /// The accepted continuations of `pending`, configured commands first,
  /// then built-in selectors, with each next key appearing once.
  static func entries(
    after pending: String, in mappings: CompiledMappings,
    literal: Bool = false, includeRoot: Bool = false
  ) -> [Entry] {
    let prefix = literal ? pending : NormalModeInterpreter.continuationMappingPrefix(pending)
    let builtIns =
      literal ? [] : NormalModeInterpreter.builtInContinuations(after: pending, in: mappings)
    guard includeRoot || prefix?.isEmpty == false || !builtIns.isEmpty else { return [] }
    var exact: [String: MappingCommand] = [:]
    var deeper: [String: Int] = [:]
    if let prefix {
      let prefixAtoms = prefix.isEmpty ? [] : NormalModeInterpreter.keyAtoms(from: prefix)
      for mapping in mappings.ordered where mappings.mapping(for: mapping.key) == mapping {
        let atoms = NormalModeInterpreter.keyAtoms(from: mapping.key)
        guard atoms.count > prefixAtoms.count, Array(atoms.prefix(prefixAtoms.count)) == prefixAtoms
        else { continue }
        let next = atoms[prefixAtoms.count]
        if !literal, NormalModeInterpreter.mappingAtomIsIntercepted(next, after: pending) {
          continue
        }
        if atoms.count == prefixAtoms.count + 1 {
          exact[next] =
            literal
            ? mapping.action
            : NormalModeInterpreter.continuationAction(
              mapping.action, after: pending, sequence: mapping.key)
        } else {
          deeper[next, default: 0] += 1
        }
      }
    }
    let configuredKeys = Set(exact.keys).union(deeper.keys)
    let configured = configuredKeys.map { atom in
      let shown = NormalModeDispatcher.displayMappingKey(atom)
      if let action = exact[atom] { return Entry(key: shown, title: title(of: action)) }
      return Entry(key: shown, title: "+\(deeper[atom] ?? 0) more")
    }
    let implicit = builtIns.filter { !configuredKeys.contains($0.key) }.map {
      Entry(
        key: $0.key,
        title: $0.action.map(title(of:)) ?? "register " + $0.key)
    }
    // Keep the user's specific commands ahead of generic slot selectors.
    return configured.sorted(by: keyOrder) + implicit.sorted(by: keyOrder)
  }

  private static func keyOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
    let left = lhs.key.lowercased()
    let right = rhs.key.lowercased()
    return left == right ? lhs.key > rhs.key : left < right
  }

  /// A row as the palette draws it: the whole sequence on the chip, with
  /// what is already typed faded as a hint chip fades its typed letters.
  struct Row: Equatable {
    let label: String
    let title: String
  }

  /// What `pending` shows as already typed: its register and count as
  /// typed, then the prefix keys spelled as the mappings page spells them.
  /// Empty when no prefix is pending, a count alone included.
  static func typed(_ pending: String) -> String {
    NormalModeInterpreter.pendingDisplay(pending)
  }

  /// The palette for `pending`: what is typed, and one row per next key
  /// whose chip starts with it, so the user sees exactly where they are.
  static func rows(
    after pending: String, in mappings: CompiledMappings,
    literal: Bool = false, includeRoot: Bool = false
  ) -> (typed: String, entries: [Row]) {
    let typed =
      literal
      ? NormalModeDispatcher.displayMappingKey(pending)
      : includeRoot && NormalModeInterpreter.pendingPrefix(pending).isEmpty
        ? NormalModeInterpreter.pendingLead(pending) : typed(pending)
    return (
      typed,
      entries(after: pending, in: mappings, literal: literal, includeRoot: includeRoot)
        .map { Row(label: typed + $0.key, title: $0.title) }
    )
  }

  /// A command as its words (`tab next`), a script as its argv.
  static func title(of action: MappingCommand) -> String {
    switch action {
    case .flashCommand: return action.argv.dropFirst().joined(separator: " ")
    case .shellCommand(let argv): return argv.joined(separator: " ")
    }
  }
}
