import AppKit
import FlashTerminal
import Foundation

/// A local sequence recognizer. Payloads stay opaque so replay preserves the
/// original event, its modifiers, and the terminal that originally received it.
struct TerminalInputMappingState<Event, Origin: Equatable> {
  struct Input {
    let atoms: [String]
    let event: Event
    let origin: Origin
    var keyCode: UInt16? = nil
    var isRelease = false
    var advancesMapping = true
    var isRepeat = false
  }

  enum Effect {
    case replay(event: Event, origin: Origin)
    case dispatch(mapping: ModeMapping, origin: Origin)
  }

  private(set) var generation: UInt64 = 0
  private(set) var mappings: CompiledMappings
  private var mappingRanks: [String: Int]
  private var pending: [Input] = []
  private var candidates: [[String]] = []
  private var completed: (count: Int, mapping: ModeMapping)?
  private var pressedOrigins: [(code: UInt16, origin: Origin)] = []
  private var consumedPresses: [(code: UInt16, origin: Origin)] = []
  private var repeating: (mapping: ModeMapping, atom: String, origin: Origin)?

  var isPending: Bool { !pending.isEmpty }

  init(mappings: CompiledMappings) {
    self.mappings = mappings
    mappingRanks = Self.ranks(in: mappings)
  }

  mutating func receive(_ input: Input) -> [Effect] {
    var routed = input
    if let code = input.keyCode {
      if input.isRelease {
        if let index = pressedOrigins.firstIndex(where: { $0.code == code }) {
          routed = Input(
            atoms: [], event: input.event, origin: pressedOrigins[index].origin,
            keyCode: code, isRelease: true, advancesMapping: input.advancesMapping)
          pressedOrigins.remove(at: index)
        }
      } else if !input.isRepeat {
        // A release may have gone to another app while focus was elsewhere.
        // A fresh press establishes a new owner and cannot inherit that old key.
        pressedOrigins.removeAll { $0.code == code }
        consumedPresses.removeAll { $0.code == code }
        pressedOrigins.append((code, input.origin))
      } else if !pressedOrigins.contains(where: { $0.code == code }) {
        pressedOrigins.append((code, input.origin))
      }
    }
    if input.advancesMapping && !input.isRelease { generation &+= 1 }
    var effects: [Effect] = []
    if let origin = pending.first?.origin, origin != routed.origin {
      effects += flush()
    }
    effects += advance(routed)
    return effects
  }

  /// A stale timer can never dispatch or replay a newer sequence.
  mutating func expire(generation expected: UInt64) -> [Effect] {
    guard expected == generation, isPending else { return [] }
    generation &+= 1
    var effects: [Effect] = []
    while isPending { effects += resolvePending() }
    return effects
  }

  /// Focus and configuration changes replay unresolved input, including an
  /// ambiguous complete prefix; they must not run a command in the next view.
  mutating func flush() -> [Effect] {
    generation &+= 1
    let effects = pending.map { Effect.replay(event: $0.event, origin: $0.origin) }
    clearPending()
    repeating = nil
    return effects
  }

  mutating func replaceMappings(_ mappings: CompiledMappings) -> [Effect] {
    let effects = flush()
    self.mappings = mappings
    mappingRanks = Self.ranks(in: mappings)
    return effects
  }

  private mutating func advance(_ input: Input) -> [Effect] {
    if input.isRelease || !input.advancesMapping {
      if input.isRelease, let code = input.keyCode,
        let index = consumedPresses.firstIndex(where: {
          $0.code == code && $0.origin == input.origin
        })
      {
        consumedPresses.remove(at: index)
        return []
      }
      if pending.isEmpty { return [.replay(event: input.event, origin: input.origin)] }
      pending.append(input)
      return []
    }
    if pending.isEmpty, let repeating {
      if repeating.origin == input.origin, input.atoms.contains(repeating.atom) {
        consume([input])
        return [.dispatch(mapping: repeating.mapping, origin: input.origin)]
      }
      self.repeating = nil
    }
    let prior = pending.isEmpty ? [[]] : candidates
    pending.append(input)
    var seen = Set<String>()
    candidates = prior.flatMap { prefix in input.atoms.map { prefix + [$0] } }.filter {
      let key = NormalModeInterpreter.encodeKeyAtoms($0)
      return seen.insert(key).inserted
        && (mappings.mapping(for: key) != nil || mappings.hasStrictPrefix(key))
    }
    if let match = candidates.compactMap({ atoms in
      mappings.mapping(for: NormalModeInterpreter.encodeKeyAtoms(atoms))
    }).min(by: { mappingRanks[$0.key, default: .max] < mappingRanks[$1.key, default: .max] }) {
      completed = (pending.count, match)
    }
    if candidates.isEmpty { return resolvePending() }
    let hasLonger = candidates.contains {
      mappings.hasStrictPrefix(NormalModeInterpreter.encodeKeyAtoms($0))
    }
    if !hasLonger { return resolvePending() }
    return []
  }

  private mutating func resolvePending() -> [Effect] {
    guard let first = pending.first else { return [] }
    let tail: [Input]
    var effects: [Effect]
    if let completed {
      consume(Array(pending.prefix(completed.count)))
      effects = [.dispatch(mapping: completed.mapping, origin: first.origin)]
      tail = Array(pending.dropFirst(completed.count))
      if completed.mapping.repeatsOnFinalKey,
        let atom = NormalModeInterpreter.keyAtoms(from: completed.mapping.key).last
      {
        repeating = (completed.mapping, atom, first.origin)
      }
    } else {
      effects = [.replay(event: first.event, origin: first.origin)]
      tail = Array(pending.dropFirst())
    }
    clearPending()
    for input in tail { effects += advance(input) }
    return effects
  }

  private mutating func consume(_ inputs: [Input]) {
    for input in inputs {
      guard let code = input.keyCode else { continue }
      consumedPresses.removeAll { $0.code == code && $0.origin == input.origin }
      if !input.isRelease { consumedPresses.append((code, input.origin)) }
    }
  }

  private mutating func clearPending() {
    pending.removeAll(keepingCapacity: true)
    candidates.removeAll(keepingCapacity: true)
    completed = nil
  }

  private static func ranks(in mappings: CompiledMappings) -> [String: Int] {
    var ranks: [String: Int] = [:]
    for (index, mapping) in mappings.ordered.enumerated() where ranks[mapping.key] == nil {
      ranks[mapping.key] = index
    }
    return ranks
  }
}

/// Main-thread adapter for a popup's local key event route. Replayed events continue
/// through that terminal's copy/paste and VT encoder, never global dispatch.
final class TerminalInputMappingHandler<Origin: Equatable> {
  private var state: TerminalInputMappingState<NSEvent, Origin>
  private var timeoutMs: Int
  private var timer: DispatchWorkItem?
  private let replay: (NSEvent, Origin) -> Void
  private let dispatch: (ModeMapping, Origin) -> Void

  init(
    mappings: CompiledMappings,
    timeoutMs: Int,
    replay: @escaping (NSEvent, Origin) -> Void,
    dispatch: @escaping (ModeMapping, Origin) -> Void
  ) {
    state = .init(mappings: mappings)
    self.timeoutMs = timeoutMs
    self.replay = replay
    self.dispatch = dispatch
  }

  deinit { timer?.cancel() }

  func handle(event: NSEvent, origin: Origin) {
    let atoms = Self.atoms(for: event, mappings: state.mappings)
    deliver(
      state.receive(
        .init(
          atoms: atoms, event: event, origin: origin,
          keyCode: event.keyCode, isRelease: TerminalView.isKeyRelease(event),
          advancesMapping: event.type == .keyDown,
          isRepeat: event.type == .keyDown && event.isARepeat)))
    if event.type == .keyDown { scheduleTimeout() }
  }

  func replaceMappings(_ mappings: CompiledMappings, timeoutMs: Int) {
    timer?.cancel()
    self.timeoutMs = timeoutMs
    deliver(state.replaceMappings(mappings))
  }

  func flush() {
    timer?.cancel()
    deliver(state.flush())
  }

  private func scheduleTimeout() {
    timer?.cancel()
    guard state.isPending else { return }
    let generation = state.generation
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.deliver(self.state.expire(generation: generation))
    }
    timer = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: work)
  }

  private func deliver(_ effects: [TerminalInputMappingState<NSEvent, Origin>.Effect]) {
    for effect in effects {
      switch effect {
      case .replay(let event, let origin): replay(event, origin)
      case .dispatch(let mapping, let origin): dispatch(mapping, origin)
      }
    }
  }

  static func atoms(for event: NSEvent, mappings: CompiledMappings) -> [String] {
    guard event.type == .keyDown else { return [] }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if !flags.intersection([.command, .control, .option]).isEmpty {
      return mappings.physicalKeyAtoms(
        virtualKey: UInt32(event.keyCode), cgFlags: CGEventFlags(rawValue: UInt64(flags.rawValue))
      ).sorted()
    }
    var atoms: [String] = []
    if let text = event.characters, text.count == 1,
      text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    {
      atoms.append(text == " " ? "space" : text)
    }
    if let name = HotkeySyntax.canonicalKeyName(virtualKey: UInt32(event.keyCode)),
      name.count > 1, !atoms.contains(name)
    {
      if flags.contains(.shift),
        let shifted = NormalModeInterpreter.canonicalModifiedKeyAtom(
          modifiers: ["shift"], key: name)
      {
        atoms.append(shifted)
      } else {
        atoms.append(name)
      }
    }
    // Named keys (including function/forward-delete keys) use physical identity;
    // printable unmodified keys continue to follow the active keyboard layout.
    for atom in mappings.physicalKeyAtoms(
      virtualKey: UInt32(event.keyCode), cgFlags: CGEventFlags(rawValue: UInt64(flags.rawValue))
    ).sorted() where atom.count > 1 && !atoms.contains(atom) {
      atoms.append(atom)
    }
    return atoms
  }
}
