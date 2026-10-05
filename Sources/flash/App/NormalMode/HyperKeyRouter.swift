import AppKit

/// One key while HYPER is held.
///
/// Hyper mappings win. A key that does not match one can still complete a
/// NORMAL `<leader>` sequence (`<leader>s` while space is held), but it is
/// never re-read as an ordinary NORMAL command — an unmapped hyper key is
/// swallowed, the same way NORMAL swallows keys it does not know.
enum HyperKeyRouter {
  struct Result: Equatable {
    var hyperPending: String
    var leaderFallbackPending: String?
    var transition: NormalModeTransition
  }

  static func route(
    hyperPending: String,
    leaderFallbackPending: String?,
    leaderAtom: String,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String?,
    charactersIgnoringModifiers: String?,
    hyperMappings: CompiledMappings,
    normalMappings: CompiledMappings
  ) -> Result {
    // A leader sequence already in progress keeps going when this key extends
    // it. Anything else drops that sequence and is read fresh: the interpreter's
    // "drop the prefix and try the key as a NORMAL command" path must not run
    // while the leader is held.
    if let leaderFallbackPending,
      continues(
        pending: leaderFallbackPending,
        keyCode: keyCode,
        modifierFlags: modifierFlags,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        mappings: normalMappings)
    {
      let transition = interpret(
        pending: leaderFallbackPending,
        keyCode: keyCode,
        modifierFlags: modifierFlags,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        mappings: normalMappings)
      return Result(
        hyperPending: "",
        leaderFallbackPending: parked(transition),
        transition: transition)
    }

    let hyper = interpret(
      pending: hyperPending,
      keyCode: keyCode,
      modifierFlags: modifierFlags,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers,
      mappings: hyperMappings)
    if hyper.action != nil || !hyper.pending.isEmpty {
      return Result(
        hyperPending: hyper.pending, leaderFallbackPending: nil, transition: hyper)
    }

    guard
      continues(
        pending: leaderAtom,
        keyCode: keyCode,
        modifierFlags: modifierFlags,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        mappings: normalMappings)
    else {
      return Result(hyperPending: "", leaderFallbackPending: nil, transition: .consume)
    }
    let leader = interpret(
      pending: leaderAtom,
      keyCode: keyCode,
      modifierFlags: modifierFlags,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers,
      mappings: normalMappings)
    return Result(
      hyperPending: "",
      leaderFallbackPending: parked(leader),
      transition: leader)
  }

  /// True when some atom of this key extends `pending` to a mapping or a
  /// longer mapped sequence. Checked before `interpret` so a miss cannot fall
  /// through into an unrelated NORMAL command.
  private static func continues(
    pending: String,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String?,
    charactersIgnoringModifiers: String?,
    mappings: CompiledMappings
  ) -> Bool {
    NormalModeInterpreter.eventKeyAtoms(
      keyCode: keyCode,
      modifierFlags: modifierFlags,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers
    ).contains { atom in
      let sequence = NormalModeInterpreter.appendKeyAtom(pending, atom)
      return mappings.mapping(for: sequence) != nil || mappings.hasStrictPrefix(sequence)
    }
  }

  /// A pending sequence stays parked. An action or a consumed key does not.
  private static func parked(_ transition: NormalModeTransition) -> String? {
    guard transition.action == nil, !transition.pending.isEmpty else { return nil }
    return transition.pending
  }

  private static func interpret(
    pending: String,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String?,
    charactersIgnoringModifiers: String?,
    mappings: CompiledMappings
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending,
      keyCode: keyCode,
      modifierFlags: modifierFlags,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers,
      mappings: mappings)
  }
}
