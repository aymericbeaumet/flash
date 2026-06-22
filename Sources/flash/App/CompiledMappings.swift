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
/// - `ordered` preserves the source order for help/mapping listings.
struct CompiledMappings: Equatable {
  let ordered: [ModeMapping]
  let byKey: [String: ModeMapping]
  let nonAtomicPrefixes: Set<String>

  init(_ mappings: [ModeMapping] = []) {
    self.ordered = mappings
    var byKey: [String: ModeMapping] = [:]
    byKey.reserveCapacity(mappings.count)
    var prefixes: Set<String> = []
    for mapping in mappings {
      // First-writer-wins: matches `mappings.first(where:)` semantics
      // when the caller concatenates `all + normal` and `all` should
      // win on key collision.
      if byKey[mapping.key] == nil {
        byKey[mapping.key] = mapping
      }
      let atoms = NormalModeInterpreter.keyAtoms(from: mapping.key)
      // Only multi-atom mapping keys contribute strict prefixes.
      if atoms.count > 1 {
        for end in 1..<atoms.count {
          prefixes.insert(NormalModeInterpreter.encodeKeyAtoms(Array(atoms.prefix(end))))
        }
      }
    }
    self.byKey = byKey
    self.nonAtomicPrefixes = prefixes
  }

  var isEmpty: Bool { ordered.isEmpty }

  func mapping(for key: String) -> ModeMapping? { byKey[key] }

  func hasStrictPrefix(_ sequence: String) -> Bool {
    nonAtomicPrefixes.contains(sequence)
  }

}
