import Foundation

/// Precomputed view of a mode's `[ModeMapping]` for O(1) interpret-time
/// lookup. Built once at config load (or test setup); read on every
/// keystroke.
///
/// - `byKey` for exact-match dispatch.
/// - `nonAtomicPrefixes` answers "does some longer mapping start with
///   this sequence?" without scanning the whole list. Prefixes are
///   generated from canonical key atoms, so typing `t` never stalls
///   waiting for a `tab`-named mapping, and `<space>s` does not stall
///   because `<space><space>` exists.
/// - `modifiedByChord` resolves modified-key chords (`cmd+f`) without
///   re-parsing on every event.
/// - `ordered` preserves the source order for help/mapping listings.
struct CompiledMappings: Equatable {
  struct Chord: Hashable {
    let modifiers: UInt32
    let virtualKey: UInt32
  }

  let ordered: [ModeMapping]
  let byKey: [String: ModeMapping]
  let nonAtomicPrefixes: Set<String>
  let modifiedByChord: [Chord: ModeMapping]

  init(_ mappings: [ModeMapping] = []) {
    self.ordered = mappings
    var byKey: [String: ModeMapping] = [:]
    byKey.reserveCapacity(mappings.count)
    var prefixes: Set<String> = []
    var byChord: [Chord: ModeMapping] = [:]
    for mapping in mappings {
      // First-writer-wins: matches `mappings.first(where:)` semantics
      // when the caller concatenates `all + normal` and `all` should
      // win on key collision.
      if byKey[mapping.key] == nil {
        byKey[mapping.key] = mapping
      }
      let atoms = NormalModeInterpreter.keyAtoms(from: mapping.key)
      if atoms.count == 1,
        mapping.key.contains("+"),
        let parsed = HotkeySyntax.parse(hotkey: mapping.key)
      {
        let chord = Chord(modifiers: parsed.modifiers, virtualKey: parsed.virtualKey)
        if byChord[chord] == nil {
          byChord[chord] = mapping
        }
      }
      // Only multi-atom mapping keys contribute strict prefixes.
      if atoms.count > 1 {
        for end in 1..<atoms.count {
          prefixes.insert(NormalModeInterpreter.encodeKeyAtoms(Array(atoms.prefix(end))))
        }
      }
    }
    self.byKey = byKey
    self.nonAtomicPrefixes = prefixes
    self.modifiedByChord = byChord
  }

  var isEmpty: Bool { ordered.isEmpty }

  func mapping(for key: String) -> ModeMapping? { byKey[key] }

  func hasStrictPrefix(_ sequence: String) -> Bool {
    nonAtomicPrefixes.contains(sequence)
  }

  func chordMapping(modifiers: UInt32, virtualKey: UInt32) -> ModeMapping? {
    modifiedByChord[Chord(modifiers: modifiers, virtualKey: virtualKey)]
  }
}
