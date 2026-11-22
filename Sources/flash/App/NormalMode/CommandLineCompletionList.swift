/// The completion list under an open command line: what the word being
/// typed completes to, ranked, and the row highlighted. A keystroke replaces
/// it through `update`; moving and Tab only change `selection`.
struct CommandLineCompletionList {
  /// The buffer up to the word being completed; a completion's insertion
  /// replaces what follows it.
  private(set) var prefix = ""
  private(set) var query = ""
  private(set) var matches: [CommandLineCompletionMatch] = []
  /// The highlighted row; Enter applies a `chosen` one rather than
  /// resolving the text. See `CommandLineCompletionSelection`.
  var selection = CommandLineCompletionSelection.none

  var isEmpty: Bool { matches.isEmpty }

  /// The empty `:` prompt: its list is the whole catalogue, not an answer
  /// to anything typed.
  var isTopLevelEmpty: Bool { prefix == ":" && query.isEmpty }

  /// The highlighted row's completion.
  var selected: NormalModeDispatcher.CommandLineCompletion? {
    guard let index = selection.index, matches.indices.contains(index) else { return nil }
    return matches[index].completion
  }

  /// The buffer once `completion` replaced the word being typed.
  func buffer(inserting completion: NormalModeDispatcher.CommandLineCompletion) -> String {
    prefix + completion.insertion
  }

  /// Rank `context`'s items for its query. `boost` is the frecency of a
  /// label, 0 for one never run.
  mutating func update(
    context: NormalModeDispatcher.CommandLineCompletionContext, boost: (String) -> Int
  ) {
    prefix = context.prefix
    query = context.query
    let trimmedQuery = context.query.trimmed
    let scored: [CommandLineCompletionMatch] = context.items.compactMap { item in
      // Frecency boost surfaces the user's most-typed commands at the
      // top of the empty `:` prompt without distorting the order once
      // they start typing — fuzzy score dominates from the first
      // character because it's an order of magnitude larger than the
      // capped boost.
      let boost = boost(item.label)
      if trimmedQuery.isEmpty {
        return CommandLineCompletionMatch(completion: item, score: boost)
      }
      guard
        let score = NormalModeDispatcher.fuzzyScore(
          query: trimmedQuery, candidate: item.label)
      else { return nil }
      return CommandLineCompletionMatch(completion: item, score: score + boost)
    }
    let sorted = scored.sorted { lhs, rhs in
      // The word the typed query selects — an ex command at its minimum
      // (`:q` is `quit`, not `qall`), an exact word or a unique prefix —
      // ranks first whatever its fuzzy score or frecency: it is what Enter
      // runs, so it is the highlighted row.
      if let selected = context.selectedLabel {
        let lhsSelected = lhs.completion.label == selected
        let rhsSelected = rhs.completion.label == selected
        if lhsSelected != rhsSelected { return lhsSelected }
      }
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return lhs.completion.label.localizedCaseInsensitiveCompare(rhs.completion.label)
        == .orderedAscending
    }
    matches = sorted
    // A keystroke recomputes the highlight from the text; only the
    // resolver's pick is highlighted, so an ambiguous or unknown word, and
    // the empty prompt, show the candidates with no row selected.
    selection =
      context.selectedLabel.flatMap { selected in
        sorted.firstIndex { $0.completion.label == selected }
      }.map(CommandLineCompletionSelection.implied) ?? .none
  }

  func displayItems(windowSize: Int) -> [CandidateDisplayItem] {
    guard !matches.isEmpty else { return [] }
    // Same windowed slice as the flashlight finder. This list used to show
    // every match at once ("reveal the whole catalogue"), but the plugin
    // command set has outgrown the band between the centered prompt and the
    // screen bottom — an unwindowed list drew up across the prompt itself.
    // Arrow keys scroll the window over the full match set.
    let window = CandidateFinder.displayWindow(
      count: matches.count,
      selectedIndex: selection.index ?? 0,
      windowSize: windowSize)
    return matches[window].enumerated().map { offset, match in
      CandidateDisplayItem(
        title: match.completion.label,
        detail: match.completion.detail,
        highlightedRanges: query.isEmpty
          ? []
          : NormalModeDispatcher.fuzzyHighlightRanges(
            query: query, candidate: match.completion.label),
        isSelected: window.lowerBound + offset == selection.index)
    }
  }
}
