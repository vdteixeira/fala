import Foundation

/// How dangerous an entry is to apply, i.e. how likely it is to destroy correct
/// Brazilian Portuguese if it fires on a token it was not meant for.
///
/// The tier controls INCLUSION only. Whether an included entry actually fires is
/// decided independently by boundary anchoring and by the entry's context lists.
public enum JargonSafety: String, Codable, Sendable, CaseIterable {
  /// `from` is not a word (or word sequence) of Brazilian Portuguese, so a
  /// boundary-anchored match cannot overwrite correct text. Always included.
  case safe
  /// `from` could be legitimate Portuguese, but a neighbouring token identifies
  /// the jargon reading. Included, but only fires when that neighbour is present.
  /// Loading fails if such an entry declares no context (see `JargonEntry`).
  case contextual
  /// `from` is common Portuguese and NO local context separates the two readings.
  /// Excluded unless the caller explicitly opts in. Shipping these on by default
  /// would corrupt correct text more often than it would fix jargon.
  case risky
}

/// One deterministic substitution: `from` (an ASR misrendering) becomes `to`
/// (the canonical spelling).
public struct JargonEntry: Sendable, Equatable, Codable {
  /// The misrendered form to look for. May contain several words separated by
  /// spaces ("com pose"); matching is case- and diacritic-insensitive.
  public let from: String
  /// The canonical replacement. Its casing is authoritative when it contains any
  /// uppercase character ("Kubernetes", "RabbitMQ").
  public let to: String
  public let safety: JargonSafety
  /// Single words that must appear shortly BEFORE the match for it to fire.
  public let contextBefore: [String]
  /// Single words that must appear shortly AFTER the match for it to fire.
  public let contextAfter: [String]
  /// Free-form provenance for humans (which measurement motivated the entry).
  public let note: String?

  public init(
    from: String,
    to: String,
    safety: JargonSafety = .safe,
    contextBefore: [String] = [],
    contextAfter: [String] = [],
    note: String? = nil
  ) {
    self.from = from
    self.to = to
    self.safety = safety
    self.contextBefore = contextBefore
    self.contextAfter = contextAfter
    self.note = note
  }

  private enum CodingKeys: String, CodingKey {
    case from, to, safety, contextBefore, contextAfter, note
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.from = try container.decode(String.self, forKey: .from)
    self.to = try container.decode(String.self, forKey: .to)
    self.safety = try container.decodeIfPresent(JargonSafety.self, forKey: .safety) ?? .safe
    self.contextBefore =
      try container.decodeIfPresent([String].self, forKey: .contextBefore) ?? []
    self.contextAfter = try container.decodeIfPresent([String].self, forKey: .contextAfter) ?? []
    self.note = try container.decodeIfPresent(String.self, forKey: .note)
  }
}

public enum JargonDictionaryError: Error, Equatable, Sendable {
  /// The bundled default dictionary is not in `Bundle.module`.
  case defaultResourceMissing
  /// A user-supplied dictionary file could not be read.
  case unreadable(file: String)
  /// The file is not JSON, or has neither an `entries` array nor a
  /// `substitutions` map.
  case malformedJSON(reason: String)
  /// An entry is self-contradictory; `from` identifies it. Never carries
  /// transcript text — only configuration the user wrote.
  case invalidEntry(from: String, reason: String)
}

/// Deterministic PT-EN IT jargon substitution over a finished transcript
/// (SPEC.md FR-9, US-2).
///
/// Pure and synchronous: `apply(to:)` performs no I/O and touches no global
/// state, so it is safe to call from the hotkey-release path. All file access
/// happens in the `load*` initialisers — load once, apply many.
///
/// # Safety rule (READ THIS BEFORE ADDING AN ENTRY)
///
/// Spike 0 (SPEC.md §6, RUN 1) measured Parakeet turning `deploy` into `depois`
/// and `merge` into `me` — both of which are ordinary Portuguese words, and one
/// of which (`depois`) appears CORRECTLY in the very same fixture sentence. A
/// naive find-and-replace would therefore have fixed one word and broken
/// another in a single utterance. Leaving jargon misspelled is recoverable;
/// silently rewriting correct Portuguese is not. Two independent gates enforce
/// that asymmetry:
///
/// 1. **Boundary anchoring — always on, not configurable.** A match must cover
///    whole word tokens. A word token is a maximal run of Unicode letters and
///    digits, so `me` never matches inside `mesmo` or `comentário`, and the
///    multi-word form `com pose` only matches when its words are consecutive
///    tokens separated by whitespace ALONE — `com, pose` does not match.
///    Matching is case- and diacritic-insensitive (`comitê` matches `comite`),
///    which is what makes a single entry cover the accented and unaccented
///    renderings the decoder alternates between.
///
/// 2. **Safety tier + context — declared per entry in JSON.** `safe` entries fire
///    on any boundary match because `from` is not Portuguese at all
///    (`posterg`, `endipoint`, `cubernetes`). `contextual` entries additionally
///    require one of their `contextBefore` / `contextAfter` words within
///    `contextWindow` word tokens on the matching side, because `from` IS
///    plausible Portuguese (`com pose`, `comitê`). `risky` entries are excluded
///    unless the caller passes `includeRisky: true`; they exist so the JSON can
///    record the measured failure without acting on it.
///
/// Consequences that are deliberate, not oversights:
/// - `depois → deploy` and `me → merge` ship DISABLED. Those two failures cannot
///   be fixed at this layer at all; they belong to the engine (vocabulary
///   biasing via `biasTerms`, or the WhisperKit fallback of SPEC.md NFR-2).
/// - Substitution is single-pass and left-to-right over the ORIGINAL text.
///   Replacements are never rescanned, so entries cannot cascade into each
///   other and the result cannot depend on entry order beyond longest-match.
/// - Context is looked up in the original tokens, so an entry's context word
///   still counts even if that word was itself replaced earlier in the pass.
/// - Where several entries match at the same position, the one covering the most
///   word tokens wins (`docker com pose` beats `com pose`); ties break by
///   declaration order in the JSON.
public struct JargonDictionary: Sendable {

  /// How many word tokens on each side count as "shortly before/after".
  /// Wide enough for `no último <commit>`, narrow enough that an unrelated
  /// clause cannot license a substitution.
  public static let contextWindow = 3

  /// Every entry as declared, including `risky` ones that are not active.
  public let entries: [JargonEntry]

  /// Whether `risky` entries were opted into at construction time.
  public let includesRiskyEntries: Bool

  /// Canonical spellings to hand to `TranscriptionEngine.transcribe(_:biasTerms:)`.
  ///
  /// Intentionally drawn from ALL declared entries, including excluded `risky`
  /// ones: biasing the decoder toward "deploy" cannot corrupt anything, and it
  /// is the only mitigation available for the failures this type refuses to fix
  /// by substitution.
  public let biasTerms: [String]

  /// Entries that can actually fire, bucketed by their first folded word and
  /// ordered longest-match-first.
  private let index: [String: [CompiledEntry]]

  /// Number of entries that can fire.
  public var activeEntryCount: Int { index.values.reduce(0) { $0 + $1.count } }

  // MARK: - Construction

  /// Primary seam: build from entries already in memory. No I/O, so tests
  /// construct dictionaries directly instead of going through the file system.
  ///
  /// - Throws: `JargonDictionaryError.invalidEntry` if an entry is unusable.
  public init(entries: [JargonEntry], includeRisky: Bool = false) throws {
    self.entries = entries
    self.includesRiskyEntries = includeRisky

    var seen = Set<String>()
    var terms: [String] = []
    for entry in entries where !entry.to.isEmpty && seen.insert(entry.to).inserted {
      terms.append(entry.to)
    }
    self.biasTerms = terms

    var buckets: [String: [CompiledEntry]] = [:]
    var order = 0
    for entry in entries {
      let compiled = try CompiledEntry(entry: entry, order: order)
      order += 1
      guard includeRisky || entry.safety != .risky else { continue }
      guard let head = compiled.words.first else { continue }
      buckets[head, default: []].append(compiled)
    }
    for key in buckets.keys {
      buckets[key]?.sort {
        $0.words.count == $1.words.count
          ? $0.order < $1.order
          : $0.words.count > $1.words.count
      }
    }
    self.index = buckets
  }

  /// Build from raw JSON bytes.
  public init(json data: Data, includeRisky: Bool = false) throws {
    let document: JargonDocument
    do {
      document = try JSONDecoder().decode(JargonDocument.self, from: data)
    } catch let error as JargonDictionaryError {
      throw error
    } catch let error as DecodingError {
      throw JargonDictionaryError.malformedJSON(reason: Self.describe(error, in: data))
    } catch {
      throw JargonDictionaryError.malformedJSON(reason: "não foi possível ler o arquivo")
    }
    try self.init(entries: document.entries, includeRisky: includeRisky)
  }

  /// Load a user override from an arbitrary location (SPEC.md FR-9: the
  /// dictionary is user-editable).
  public static func load(contentsOf url: URL, includeRisky: Bool = false) throws
    -> JargonDictionary
  {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw JargonDictionaryError.unreadable(file: url.lastPathComponent)
    }
    return try JargonDictionary(json: data, includeRisky: includeRisky)
  }

  /// Load the dictionary that ships inside FalaKit.
  public static func loadDefault(includeRisky: Bool = false) throws -> JargonDictionary {
    try load(contentsOf: defaultResourceURL(), includeRisky: includeRisky)
  }

  /// Location of the bundled default, e.g. so the CLI can tell the user which
  /// file to copy before editing.
  ///
  /// `.process("Resources")` flattens the source tree, so the file that lives at
  /// `Sources/FalaKit/Resources/dictionaries/it-jargon.json` is emitted at the
  /// bundle root. The subdirectory lookup is kept as a fallback in case SwiftPM
  /// ever preserves the structure.
  public static func defaultResourceURL() throws -> URL {
    let bundle = Bundle.module
    if let url = bundle.url(forResource: defaultResourceName, withExtension: "json") {
      return url
    }
    if let url = bundle.url(
      forResource: defaultResourceName,
      withExtension: "json",
      subdirectory: "dictionaries"
    ) {
      return url
    }
    throw JargonDictionaryError.defaultResourceMissing
  }

  private static let defaultResourceName = "it-jargon"

  // MARK: - Application

  /// Rewrites `text`, replacing every eligible misrendering with its canonical
  /// spelling. Whitespace, punctuation and every unmatched character are
  /// preserved byte-for-byte.
  ///
  /// Pure: same input, same output, always. Cost is O(word tokens × candidate
  /// entries sharing a first word), with no I/O and no locking.
  public func apply(to text: String) -> String {
    guard !text.isEmpty, !index.isEmpty else { return text }
    let tokens = Self.tokenize(text)
    guard !tokens.isEmpty else { return text }

    var output = ""
    var cursor = text.startIndex
    var position = 0
    while position < tokens.count {
      guard let candidates = index[tokens[position].folded] else {
        position += 1
        continue
      }
      var advanced = false
      for candidate in candidates {
        guard let end = candidate.matchEnd(tokens: tokens, from: position, in: text) else {
          continue
        }
        guard candidate.hasRequiredContext(tokens: tokens, start: position, end: end) else {
          continue
        }
        output += text[cursor..<tokens[position].range.lowerBound]
        output += Self.cased(
          candidate.replacement,
          sourceStartsUppercase: tokens[position].startsUppercase
        )
        cursor = tokens[end - 1].range.upperBound
        position = end
        advanced = true
        break
      }
      if !advanced { position += 1 }
    }
    output += text[cursor...]
    return output
  }

  /// The canonical spelling in the JSON wins whenever it carries any uppercase
  /// letter — "Kubernetes" and "RabbitMQ" are spellings, not capitalisations.
  /// An all-lowercase replacement inherits a leading capital from the text it
  /// replaces, so a sentence-initial "Comite" becomes "Commit", not "commit".
  private static func cased(_ replacement: String, sourceStartsUppercase: Bool) -> String {
    guard sourceStartsUppercase,
      let first = replacement.first,
      !replacement.contains(where: { $0.isUppercase })
    else { return replacement }
    return first.uppercased() + replacement.dropFirst()
  }

  // MARK: - Tokenisation

  /// A maximal run of Unicode letters/digits, plus what is needed to splice a
  /// replacement back into the original string.
  fileprivate struct Token {
    let range: Range<String.Index>
    let folded: String
    let startsUppercase: Bool
  }

  fileprivate static func tokenize(_ text: String) -> [Token] {
    var tokens: [Token] = []
    var cursor = text.startIndex
    while cursor < text.endIndex {
      guard text[cursor].isWordCharacter else {
        cursor = text.index(after: cursor)
        continue
      }
      let start = cursor
      while cursor < text.endIndex, text[cursor].isWordCharacter {
        cursor = text.index(after: cursor)
      }
      let slice = text[start..<cursor]
      tokens.append(
        Token(
          range: start..<cursor,
          folded: fold(slice),
          startsUppercase: slice.first?.isUppercase ?? false
        )
      )
    }
    return tokens
  }

  /// The identity of a rule: the folded word sequence `apply(to:)` matches on,
  /// joined by single spaces. Two entries share an identity exactly when they
  /// would fire on the same input, which is what makes a user override written
  /// as "Posterg" or "com  pose" replace the bundled "posterg" / "com pose"
  /// (see `JargonOverride`). Empty when `from` has no word characters.
  ///
  /// Derived from `tokenize`/`fold` on purpose: an override that used its own
  /// notion of equality would drift from the matcher without any test noticing.
  static func mergeKey(for from: some StringProtocol) -> String {
    tokenize(String(from)).map(\.folded).joined(separator: " ")
  }

  /// Case- and diacritic-insensitive normal form. The locale is pinned so the
  /// result never depends on the user's regional settings (notably the Turkish
  /// dotless-i rule).
  fileprivate static func fold(_ value: some StringProtocol) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }

  /// Shared with `JargonOverride` so both file formats report a decoding failure
  /// the same way — in Brazilian Portuguese, naming the failing entry. It used
  /// to hand back `context.debugDescription`, i.e. raw English decoder prose,
  /// straight into a pt-BR warning.
  static func describe(_ error: DecodingError, in data: Data? = nil) -> String {
    JargonDecodingDiagnostic.describe(error, in: data)
  }
}

// MARK: - Compiled form

extension JargonDictionary {

  /// An entry pre-folded and pre-split so `apply(to:)` never re-parses anything.
  fileprivate struct CompiledEntry: Sendable {
    let words: [String]
    let replacement: String
    let contextBefore: [String]
    let contextAfter: [String]
    let requiresContext: Bool
    let order: Int

    init(entry: JargonEntry, order: Int) throws {
      // The `reason` strings are pt-BR because they are USER-FACING: they are
      // interpolated verbatim into `JargonDictionaryError.userMessage`, which is
      // what `doctor` and the menu bar show when a hand-written entry is
      // rejected. Identifiers and JSON keys stay English — they are the file
      // format, not prose.
      let words = JargonDictionary.tokenize(entry.from).map(\.folded)
      guard !words.isEmpty else {
        throw JargonDictionaryError.invalidEntry(
          from: entry.from,
          reason: "'from' não tem nenhuma letra ou número"
        )
      }
      guard !entry.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw JargonDictionaryError.invalidEntry(
          from: entry.from,
          reason: "'to' está vazio; apagar não é substituir"
        )
      }
      let before = try Self.foldContext(entry.contextBefore, of: entry)
      let after = try Self.foldContext(entry.contextAfter, of: entry)
      if entry.safety == .contextual && before.isEmpty && after.isEmpty {
        throw JargonDictionaryError.invalidEntry(
          from: entry.from,
          reason: "safety 'contextual' exige contextBefore e/ou contextAfter"
        )
      }
      self.words = words
      self.replacement = entry.to
      self.contextBefore = before
      self.contextAfter = after
      self.requiresContext = !(before.isEmpty && after.isEmpty)
      self.order = order
    }

    /// Context terms are matched against single tokens, so a multi-word term
    /// could never match. Reject it instead of silently disabling the entry.
    private static func foldContext(_ terms: [String], of entry: JargonEntry) throws -> [String] {
      try terms.map { term in
        let tokens = JargonDictionary.tokenize(term)
        guard tokens.count == 1, let only = tokens.first else {
          throw JargonDictionaryError.invalidEntry(
            from: entry.from,
            reason: "o contexto '\(term)' precisa ter exatamente uma palavra"
          )
        }
        return only.folded
      }
    }

    /// Token index just past the match, or `nil` if the entry does not match
    /// starting at `start`. Multi-word entries additionally require every gap
    /// between their words to be whitespace only.
    func matchEnd(tokens: [JargonDictionary.Token], from start: Int, in text: String) -> Int? {
      guard start + words.count <= tokens.count else { return nil }
      for offset in 0..<words.count where tokens[start + offset].folded != words[offset] {
        return nil
      }
      for offset in 1..<words.count {
        let gap =
          tokens[start + offset - 1].range.upperBound..<tokens[start + offset].range.lowerBound
        guard text[gap].allSatisfy(\.isWhitespace) else { return nil }
      }
      return start + words.count
    }

    /// True when the entry needs no context, or when one declared context word
    /// sits within `contextWindow` word tokens on its declared side.
    func hasRequiredContext(tokens: [JargonDictionary.Token], start: Int, end: Int) -> Bool {
      guard requiresContext else { return true }
      let window = JargonDictionary.contextWindow
      if !contextBefore.isEmpty {
        for position in max(0, start - window)..<start
        where contextBefore.contains(tokens[position].folded) {
          return true
        }
      }
      if !contextAfter.isEmpty {
        for position in end..<min(tokens.count, end + window)
        where contextAfter.contains(tokens[position].folded) {
          return true
        }
      }
      return false
    }
  }
}

// MARK: - JSON document

/// On-disk shape. Accepts the tiered `entries` array, and — for hand-written
/// user overrides — the flat `substitutions` map this file used before tiers
/// existed. Flat entries are treated as `safe`, which is the user's own
/// assertion: they wrote the mapping.
///
/// Both keys are read and concatenated, for the same reason `OverrideDocument`
/// does it: an if/else-if here would drop a `substitutions` map without a word
/// as soon as an `entries` array — even an empty one — was also present.
private struct JargonDocument: Decodable {
  let entries: [JargonEntry]

  private enum CodingKeys: String, CodingKey {
    case entries
    case substitutions
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    var collected: [JargonEntry] = []
    var recognisedAKey = false
    // Flat map first so a `from` present in both resolves to the tiered entry,
    // which is the only shape that can carry `safety` and context.
    if let map = try container.decodeIfPresent([String: String].self, forKey: .substitutions) {
      // Sorted so the compiled order is stable across runs (JSON objects are
      // unordered, and entry order is the documented tie-break).
      collected = map.sorted { $0.key < $1.key }.map { JargonEntry(from: $0.key, to: $0.value) }
      recognisedAKey = true
    }
    if let list = try container.decodeIfPresent([JargonEntry].self, forKey: .entries) {
      collected += list
      recognisedAKey = true
    }
    guard recognisedAKey else {
      throw JargonDictionaryError.malformedJSON(
        reason: "esperava uma lista 'entries' ou um objeto 'substitutions'")
    }
    entries = collected
  }
}

extension Character {
  /// Word characters for tokenisation. Punctuation, whitespace, hyphens and
  /// underscores all end a token, which is what makes `e-mail` two tokens and
  /// keeps `com pose` from matching `com-pose`.
  fileprivate var isWordCharacter: Bool { isLetter || isNumber }
}
