import Foundation

// Search for the history window (TASKS.md T2.12, DESIGN-HANDOFF.md §1
// "history-window ... search field").
//
// PRIVACY (CLAUDE.md, NFR-1). Everything here is a pure function over values
// held in memory. The query is NEVER written anywhere: not to disk, not to
// `os_log`, not to `UserDefaults`, and not to `NSSearchField`'s recent-searches
// autosave — this type is what the window uses INSTEAD of that control, so
// there is no autosave name to forget to clear. Nothing in this file performs
// I/O of any kind.

/// Case- and accent-insensitive folding, so a Brazilian user can type without
/// accents and still find what they dictated ("codigo" → "código").
///
/// The locale is PINNED to pt-BR rather than taken from the machine. Case
/// folding is locale-dependent: on a Mac set to Turkish, folding "I" with the
/// current locale yields "ı" (dotless), so typing "item" would stop finding
/// "Item". Fala's UI is pt-BR by project rule on every machine it runs on, and
/// its search has to behave the same way on all of them.
public enum HistoryTextFolding {
  /// Pinned — see the type comment. Also used as the calendar's locale, so the
  /// two never disagree about which language this app is.
  public static let locale = Locale(identifier: "pt_BR")

  /// Measured against Foundation, not assumed: `ção` → `cao` (the cedilla is a
  /// diacritic), `PÃO` → `pao`, and a decomposed `co` + U+0301 + `digo` folds
  /// to the same `codigo` as the precomposed form — which matters because
  /// macOS's own text input produces both.
  public static func fold(_ text: String) -> String {
    text.folding(
      options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
      locale: locale)
  }
}

/// What the user typed, reduced to the terms that can be matched.
///
/// Whitespace-separated terms are ANDed: "codigo deploy" finds a dictation that
/// mentions both, in any order. OR would flood the list with every entry that
/// happens to contain "de", which is the opposite of what a filter is for.
public struct HistoryQuery: Sendable, Equatable {
  /// Exactly what the user typed, kept only so the empty-result message can
  /// quote it back. Never persisted.
  public let raw: String
  /// Folded, non-empty terms. Empty means "show everything".
  public let terms: [String]

  public init(_ raw: String) {
    self.raw = raw
    self.terms =
      raw
      .split(whereSeparator: \.isWhitespace)
      .map { HistoryTextFolding.fold(String($0)) }
      // A term can fold to nothing (a stray zero-width character pasted in).
      // Keeping it would make `contains("")` true for every entry, i.e. an
      // active filter that silently matches everything.
      .filter { !$0.isEmpty }
  }

  /// No terms — every entry passes.
  public var isActive: Bool { !terms.isEmpty }

  /// `haystack` must ALREADY be folded (`HistorySearchIndex` does it once per
  /// entry, at load, instead of once per entry per keystroke).
  public func matchesFolded(_ haystack: String) -> Bool {
    guard isActive else { return true }
    return terms.allSatisfy(haystack.contains)
  }
}

/// The entries, each with its folded search text computed once.
///
/// Built when the window loads and thrown away when it closes. Folding 500
/// transcripts on every keystroke would be pure waste; folding the query is
/// three characters of work.
public struct HistorySearchIndex: Sendable {
  /// One entry and the text a query is matched against.
  public struct Item: Sendable {
    public let entry: DictationHistoryEntry
    /// Folded transcript + folded destination app name, joined by a newline.
    ///
    /// A single term can never span the join: terms are split on whitespace,
    /// so none of them contains one, and the newline is whitespace.
    public let haystack: String
  }

  public let items: [Item]

  public init(_ entries: [DictationHistoryEntry]) {
    self.items = entries.map { entry in
      var haystack = HistoryTextFolding.fold(entry.text)
      // The destination app is searchable on purpose: "vs code" is how someone
      // finds what they dictated into their editor, and the row already shows
      // that name, so nothing hidden is being matched.
      if let app = entry.destinationApp?.displayName, !app.isEmpty {
        haystack += "\n" + HistoryTextFolding.fold(app)
      }
      return Item(entry: entry, haystack: haystack)
    }
  }

  public var isEmpty: Bool { items.isEmpty }

  public var count: Int { items.count }

  /// Preserves the store's order (newest first).
  public func filter(_ query: HistoryQuery) -> [DictationHistoryEntry] {
    guard query.isActive else { return items.map(\.entry) }
    return items.filter { query.matchesFolded($0.haystack) }.map(\.entry)
  }
}
