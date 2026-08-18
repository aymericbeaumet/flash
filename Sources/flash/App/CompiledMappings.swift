import CoreGraphics
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
  private let physicalAtomsBySignature: [UInt64: Set<String>]

  init(_ mappings: [ModeMapping] = []) {
    self.ordered = mappings
    var byKey: [String: ModeMapping] = [:]
    byKey.reserveCapacity(mappings.count)
    var prefixes: Set<String> = []
    var physicalAtomsBySignature: [UInt64: Set<String>] = [:]
    for mapping in mappings {
      // First-writer-wins: matches `mappings.first(where:)` semantics
      // when the caller concatenates `all + normal` and `all` should
      // win on key collision.
      if byKey[mapping.key] == nil {
        byKey[mapping.key] = mapping
      }
      let atoms = NormalModeInterpreter.keyAtoms(from: mapping.key)
      for atom in atoms {
        guard let signature = Self.physicalSignature(for: atom) else { continue }
        physicalAtomsBySignature[signature, default: []].insert(atom)
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
    self.physicalAtomsBySignature = physicalAtomsBySignature
  }

  func mapping(for key: String) -> ModeMapping? { byKey[key] }

  func hasStrictPrefix(_ sequence: String) -> Bool {
    nonAtomicPrefixes.contains(sequence)
  }

  func physicalKeyAtoms(virtualKey: UInt32, cgFlags: CGEventFlags) -> Set<String> {
    physicalAtomsBySignature[
      Self.signature(
        virtualKey: virtualKey,
        modifiers: MappingsCoordinator.carbonModifiers(fromCG: cgFlags))
    ] ?? []
  }

  private static func physicalSignature(for atom: String) -> UInt64? {
    let hotkey: String
    if atom.hasPrefix("ctrl-"), !atom.contains("+") {
      hotkey = "ctrl+" + String(atom.dropFirst("ctrl-".count))
    } else if atom.count == 1, let character = atom.first,
      let base = shiftedPunctuationBase[character]
    {
      hotkey = "shift+\(base)"
    } else if atom.count == 1, let character = atom.first, character.isUppercase {
      hotkey = "shift+\(String(character).lowercased())"
    } else {
      hotkey = atom
    }
    guard let parsed = HotkeySyntax.parse(hotkey: hotkey) else { return nil }
    return signature(virtualKey: parsed.virtualKey, modifiers: parsed.modifiers)
  }

  private static func signature(virtualKey: UInt32, modifiers: UInt32) -> UInt64 {
    (UInt64(modifiers) << 32) | UInt64(virtualKey)
  }

  private static let shiftedPunctuationBase: [Character: Character] = [
    "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
    "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[",
    "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
  ]

}
