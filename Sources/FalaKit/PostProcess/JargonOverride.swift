import Foundation

/// The user's edits to the jargon dictionary: extra rules, replacements for
/// bundled rules, and bundled rules switched off (SPEC.md FR-9 — "ships with a
/// default `Resources/dictionaries/it-jargon.json`; user-editable").
///
/// Pure and file-system free. `JargonDictionaryStore` reads the bytes; this type
/// only decides what the merged rule list is, so the merge rule itself is
/// testable without touching the disk.
///
/// # The merge rule, in full
///
/// The override is merged OVER the bundled default, never in place of it. A user
/// who wants one extra term should not inherit the maintenance of the other
/// forty, and a later release must still be able to fix a mangling for everyone.
///
/// 1. **Identity** is `JargonDictionary.mergeKey(for:)` — the folded word
///    sequence the matcher itself uses. So `"Posterg"`, `"posterg"` and
///    `"póstérg"` are the same rule, and the user never has to guess the casing
///    or accents used in the bundled file.
/// 2. A user entry whose identity matches a bundled entry **replaces it in
///    place**, keeping its position so the documented tie-break (equal-length
///    matches break by declaration order) does not shift under the user's feet.
/// 3. A user entry with a new identity is **appended**. It therefore loses an
///    equal-length tie against a bundled rule; overriding by identity (rule 2)
///    is how you win one deliberately.
/// 4. `disable` **removes** the rule with that identity, and is applied LAST —
///    so it also wins over a user entry from rule 2/3 with the same identity.
///    A `disable` term matching nothing is reported (`unmatchedDisableKeys`),
///    not an error: a typo must not cost the user the rest of their file.
///
/// Everything the user declares stays subject to the safety machinery of
/// `JargonDictionary`: a `contextual` entry with no context words, or an empty
/// `to`, is still a configuration error, and `risky` entries are still inert.
/// The escape hatch is explicit — re-declaring a bundled `risky` rule as `safe`
/// enables it, because the user asserted it, entry by entry.
public struct JargonOverride: Sendable, Equatable {

  /// Rules the user declared, in file order. Same shape as the bundled
  /// `entries` array.
  public let entries: [JargonEntry]

  /// `from` values of rules the user wants switched off. Compared by identity,
  /// so `"Brand"` disables the bundled `"brand"`.
  public let disable: [String]

  public init(entries: [JargonEntry] = [], disable: [String] = []) {
    self.entries = entries
    self.disable = disable
  }

  /// True when the file exists but asks for nothing — the state of the seeded
  /// template, and the reason a first run behaves exactly like no file at all.
  public var isEmpty: Bool { entries.isEmpty && disable.isEmpty }

  // MARK: - Merging

  /// What a merge produced, and what it did — the counts `doctor` reports so a
  /// user can tell "my file was read" from "my file was read and did nothing".
  public struct MergeResult: Sendable, Equatable {
    /// The merged rule list, ready for `JargonDictionary(entries:)`.
    public let entries: [JargonEntry]
    /// Bundled rules replaced by a user rule of the same identity.
    public let replaced: Int
    /// User rules with an identity the bundled file did not have.
    public let added: Int
    /// Rules removed by `disable`.
    public let disabled: Int
    /// `disable` terms that matched no rule — almost always a typo, so it is
    /// surfaced rather than swallowed.
    public let unmatchedDisableKeys: [String]

    /// Whether the user's file changed anything at all.
    public var isEffective: Bool { replaced + added + disabled > 0 }
  }

  /// Merges this override over `base` (the bundled file's declared entries).
  ///
  /// Total: it cannot fail. Contradictions the user wrote (an empty `to`, a
  /// `contextual` rule with no context) survive into the result and are rejected
  /// by `JargonDictionary(entries:)`, which is where every other entry-level
  /// error is already reported.
  public func merged(over base: [JargonEntry]) -> MergeResult {
    var merged = base
    var positionByKey: [String: Int] = [:]
    for (position, entry) in base.enumerated() {
      positionByKey[JargonDictionary.mergeKey(for: entry.from)] = position
    }

    var replacedKeys = Set<String>()
    var addedKeys = Set<String>()
    for entry in entries {
      let key = JargonDictionary.mergeKey(for: entry.from)
      // A `from` with no word characters has no identity. Keep it so the load
      // fails loudly on the user's mistake instead of dropping it in silence.
      guard !key.isEmpty else {
        merged.append(entry)
        continue
      }
      if let position = positionByKey[key] {
        merged[position] = entry
        if position < base.count { replacedKeys.insert(key) }
      } else {
        positionByKey[key] = merged.count
        merged.append(entry)
        addedKeys.insert(key)
      }
    }

    var disabledKeys = Set<String>()
    var unmatched: [String] = []
    for term in disable {
      let key = JargonDictionary.mergeKey(for: term)
      if !key.isEmpty, positionByKey[key] != nil {
        disabledKeys.insert(key)
      } else {
        unmatched.append(term)
      }
    }
    let kept =
      disabledKeys.isEmpty
      ? merged
      : merged.filter { !disabledKeys.contains(JargonDictionary.mergeKey(for: $0.from)) }

    return MergeResult(
      entries: kept,
      replaced: replacedKeys.count,
      added: addedKeys.count,
      disabled: merged.count - kept.count,
      unmatchedDisableKeys: unmatched
    )
  }

  // MARK: - Decoding

  /// Parses a user override file.
  ///
  /// Accepts the same `entries` array and legacy flat `substitutions` map as the
  /// bundled format, plus `disable` (alias `disabled`). Whitespace-only bytes
  /// mean "no overrides" — emptying the file is a legitimate way to switch your
  /// customisations off. An object with none of the recognised keys is an ERROR
  /// rather than an empty override, because the common cause is a misspelled key
  /// (`"entrys"`), and silence there is exactly the failure the user cannot
  /// diagnose.
  ///
  /// `entries` and `substitutions` are read TOGETHER, not as alternatives — see
  /// `OverrideDocument`.
  ///
  /// - Throws: `JargonDictionaryError.malformedJSON`.
  public static func decode(json data: Data) throws -> JargonOverride {
    let text = String(decoding: data, as: UTF8.self)
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return JargonOverride()
    }
    do {
      let document = try JSONDecoder().decode(OverrideDocument.self, from: data)
      return JargonOverride(entries: document.entries, disable: document.disable)
    } catch let error as JargonDictionaryError {
      throw error
    } catch let error as DecodingError {
      // The bytes are passed along so the message can name the failing entry and
      // quote back the value the user wrote (`JargonDecodingDiagnostic`).
      throw JargonDictionaryError.malformedJSON(
        reason: JargonDecodingDiagnostic.describe(error, in: data))
    } catch {
      throw JargonDictionaryError.malformedJSON(reason: "não foi possível ler o arquivo")
    }
  }
}

// MARK: - On-disk shape

/// Mirrors the bundled document deliberately: the user's file is the same format
/// plus `disable`, so a user can paste a bundled entry into it unchanged.
///
/// # Why both rule keys are read, not one of them
///
/// `entries` and `substitutions` used to be an if/else-if, so a `substitutions`
/// map was DISCARDED, silently, whenever `entries` was also present. The seeded
/// template always writes `"entries": []` — so from any file Fala itself
/// created, the documented flat-map path could not work at all, and the user got
/// no warning to explain why their terms did nothing. That is precisely the
/// failure this module's own doc comment says must never be silent, so both keys
/// are now read and concatenated.
private struct OverrideDocument: Decodable {
  let entries: [JargonEntry]
  let disable: [String]

  private enum CodingKeys: String, CodingKey {
    case entries
    case substitutions
    case disable
    case disabled
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    var recognisedAKey = false
    var entries: [JargonEntry] = []

    // The flat map comes FIRST so that a `from` declared in both shapes resolves
    // to the tiered one: `JargonOverride.merged(over:)` lets the last entry with
    // a given identity win, and the tiered form is the only one that can carry
    // `safety` and context, so it must be the one that survives.
    if let map = try container.decodeIfPresent([String: String].self, forKey: .substitutions) {
      // Sorted so compiled order is stable across runs: JSON objects are
      // unordered and entry order is the documented tie-break.
      entries = map.sorted { $0.key < $1.key }.map { JargonEntry(from: $0.key, to: $0.value) }
      recognisedAKey = true
    }
    if let list = try container.decodeIfPresent([JargonEntry].self, forKey: .entries) {
      entries += list
      recognisedAKey = true
    }

    var disable: [String] = []
    // Both spellings are accepted because this file is hand-written and the
    // wrong guess would otherwise fail silently.
    for key in [CodingKeys.disable, .disabled] {
      if let list = try container.decodeIfPresent([String].self, forKey: key) {
        disable += list
        recognisedAKey = true
      }
    }

    guard recognisedAKey else {
      throw JargonDictionaryError.malformedJSON(
        reason: "nenhuma chave reconhecida — use 'entries', 'substitutions' ou 'disable'")
    }
    self.entries = entries
    self.disable = disable
  }
}
