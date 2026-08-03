import Foundation
import Testing

@testable import FalaKit

/// The merge rule itself, with no file system involved.
@Suite struct JargonOverrideMergeTests {

  private let base: [JargonEntry] = [
    JargonEntry(from: "posterg", to: "Postgres", safety: .safe),
    JargonEntry(from: "brand", to: "branch", safety: .safe),
    JargonEntry(from: "depois", to: "deploy", safety: .risky),
  ]

  @Test("An override with a new 'from' is appended, leaving the base intact")
  func newEntryIsAppended() {
    let override = JargonOverride(entries: [JargonEntry(from: "esse queuel", to: "SQL")])
    let result = override.merged(over: base)
    #expect(result.entries.count == base.count + 1)
    #expect(result.entries.prefix(base.count) == ArraySlice(base))
    #expect(result.added == 1)
    #expect(result.replaced == 0)
    #expect(result.isEffective)
  }

  /// Identity is the folded word sequence the matcher itself uses, so the user
  /// never has to reproduce the bundled file's casing or accents.
  @Test("An override replaces a base entry IN PLACE, matching case- and accent-blind")
  func matchingEntryReplacesInPlace() {
    let replacement = JargonEntry(from: "PÓSTERG", to: "PostgreSQL", safety: .safe)
    let result = JargonOverride(entries: [replacement]).merged(over: base)
    #expect(result.entries.count == base.count)
    #expect(result.entries[0] == replacement)
    #expect(result.entries[1] == base[1])
    #expect(result.replaced == 1)
    #expect(result.added == 0)
  }

  @Test("Whitespace between words is not part of the identity")
  func identityIgnoresExtraWhitespace() {
    #expect(
      JargonDictionary.mergeKey(for: "com  pose") == JargonDictionary.mergeKey(for: "Com Pose"))
    #expect(JargonDictionary.mergeKey(for: "   ").isEmpty)
  }

  @Test("'disable' removes a base entry")
  func disableRemovesBaseEntry() {
    let result = JargonOverride(disable: ["Brand"]).merged(over: base)
    #expect(result.entries.count == base.count - 1)
    #expect(!result.entries.contains { $0.from == "brand" })
    #expect(result.disabled == 1)
    #expect(result.unmatchedDisableKeys.isEmpty)
  }

  /// `disable` is applied last on purpose: one list decides what is OFF, and it
  /// cannot be contradicted by something further up the same file.
  @Test("'disable' wins over an entry the same file declares")
  func disableWinsOverDeclaredEntry() {
    let override = JargonOverride(
      entries: [JargonEntry(from: "posterg", to: "MEUBANCO")],
      disable: ["posterg"])
    let result = override.merged(over: base)
    #expect(!result.entries.contains { $0.to == "MEUBANCO" })
    #expect(result.disabled == 1)
  }

  @Test("A 'disable' term that matches nothing is reported, not fatal")
  func unmatchedDisableKeyIsReported() {
    let override = JargonOverride(
      entries: [JargonEntry(from: "esse queuel", to: "SQL")],
      disable: ["postgrez"])
    let result = override.merged(over: base)
    #expect(result.unmatchedDisableKeys == ["postgrez"])
    #expect(result.disabled == 0)
    #expect(result.added == 1)
  }

  @Test("The last of two user entries with the same identity wins, and counts once")
  func duplicateUserEntriesCollapse() {
    let override = JargonOverride(entries: [
      JargonEntry(from: "posterg", to: "FIRST"),
      JargonEntry(from: "Posterg", to: "SECOND"),
    ])
    let result = override.merged(over: base)
    #expect(result.entries.count == base.count)
    #expect(result.entries[0].to == "SECOND")
    #expect(result.replaced == 1)
  }

  @Test("An empty override is a no-op and reports itself as one")
  func emptyOverrideChangesNothing() {
    let result = JargonOverride().merged(over: base)
    #expect(result.entries == base)
    #expect(!result.isEffective)
    #expect(JargonOverride().isEmpty)
  }

  /// If two bundled entries ever shared an identity, "the user's entry replaces
  /// the bundled one" would be ambiguous. Pin it at the source.
  @Test("Every entry in the bundled dictionary has a unique identity")
  func bundledEntriesHaveUniqueIdentities() throws {
    let entries = try JargonDictionary.loadDefault(includeRisky: true).entries
    let keys = entries.map { JargonDictionary.mergeKey(for: $0.from) }
    let hasAnonymousEntry = keys.contains(where: \.isEmpty)
    #expect(Set(keys).count == keys.count)
    #expect(!hasAnonymousEntry)
  }

  // MARK: - Decoding

  @Test("An override may declare only 'disable'")
  func disableOnlyDocumentDecodes() throws {
    let override = try JargonOverride.decode(json: Data(#"{ "disable": ["brand"] }"#.utf8))
    #expect(override.entries.isEmpty)
    #expect(override.disable == ["brand"])
  }

  @Test("'disabled' is accepted as an alias for 'disable'")
  func disabledAliasDecodes() throws {
    let override = try JargonOverride.decode(json: Data(#"{ "disabled": ["brand"] }"#.utf8))
    #expect(override.disable == ["brand"])
  }

  @Test("The legacy flat 'substitutions' map is accepted in an override too")
  func legacyFlatMapDecodes() throws {
    let json = #"{ "substitutions": { "becape": "backup" } }"#
    let override = try JargonOverride.decode(json: Data(json.utf8))
    #expect(override.entries.first?.from == "becape")
    #expect(override.entries.first?.safety == .safe)
  }

  /// The defect: `entries` and `substitutions` were an if/else-if, so the flat
  /// map was dropped in silence whenever `entries` was present — and the SEEDED
  /// TEMPLATE always writes `"entries": []`. A user who followed the documented
  /// flat-map path in the file Fala itself created got nothing, and no warning.
  @Test("'substitutions' still applies next to the empty 'entries' the template seeds")
  func substitutionsSurviveAnEmptyEntriesArray() throws {
    let json = #"{ "entries": [], "substitutions": { "becape": "backup" } }"#
    let override = try JargonOverride.decode(json: Data(json.utf8))
    #expect(override.entries.map(\.from) == ["becape"])
    #expect(!override.isEmpty)
  }

  @Test("Both rule shapes in one file are read together, not one instead of the other")
  func bothRuleShapesAreRead() throws {
    let json = """
      {
        "entries": [ { "from": "esse queuel", "to": "SQL" } ],
        "substitutions": { "becape": "backup" }
      }
      """
    let override = try JargonOverride.decode(json: Data(json.utf8))
    #expect(Set(override.entries.map(\.from)) == ["becape", "esse queuel"])
  }

  /// Order matters: `merged(over:)` lets the LAST entry with a given identity
  /// win, and only the tiered shape can carry `safety` and context, so it has to
  /// be the one that survives a `from` declared in both.
  @Test("A 'from' declared in both shapes resolves to the tiered entry")
  func tieredEntryWinsOverTheFlatMap() throws {
    let json = """
      {
        "entries": [ { "from": "becape", "to": "Backup", "safety": "contextual",
                       "contextBefore": ["rodar"] } ],
        "substitutions": { "becape": "backup" }
      }
      """
    let override = try JargonOverride.decode(json: Data(json.utf8))
    let merged = override.merged(over: [])
    #expect(merged.entries.count == 1)
    #expect(merged.entries.first?.to == "Backup")
    #expect(merged.entries.first?.safety == .contextual)
  }

  /// Emptying the file is a legitimate way to switch your customisations off.
  @Test("A whitespace-only file decodes as 'no overrides'")
  func blankFileDecodesAsEmpty() throws {
    #expect(try JargonOverride.decode(json: Data("\n  \n".utf8)).isEmpty)
    #expect(try JargonOverride.decode(json: Data()).isEmpty)
  }

  /// The failure a lenient decoder would hide: a misspelled key silently doing
  /// nothing is the one thing the user cannot diagnose.
  @Test("An object with no recognised key is rejected rather than read as empty")
  func unrecognisedKeysAreRejected() {
    expectMalformed(#"{ "entrys": [] }"#)
    expectMalformed("{}")
    expectMalformed("{ not json")
  }

  private func expectMalformed(
    _ json: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    do {
      _ = try JargonOverride.decode(json: Data(json.utf8))
      Issue.record("expected .malformedJSON", sourceLocation: sourceLocation)
    } catch let error as JargonDictionaryError {
      guard case .malformedJSON = error else {
        Issue.record("expected .malformedJSON, got \(error)", sourceLocation: sourceLocation)
        return
      }
    } catch {
      Issue.record("expected JargonDictionaryError, got \(error)", sourceLocation: sourceLocation)
    }
  }
}

/// The startup path: seed on first run, merge on every run, and degrade to the
/// bundled default — loudly — when the user's file is broken.
@Suite struct JargonDictionaryStoreTests {

  // MARK: - Location

  @Test("The user file lives in ~/Library/Application Support/Fala")
  func defaultLocationIsConventional() {
    let store = JargonDictionaryStore()
    #expect(store.directory.path.hasSuffix("Application Support/Fala"))
    #expect(store.fileURL.lastPathComponent == "it-jargon.json")
  }

  @Test("The reported path abbreviates the home directory")
  func displayPathAbbreviatesHome() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let status = JargonDictionaryStatus(
      dictionary: try JargonDictionary.loadDefault(),
      userFileURL: home.appendingPathComponent("Library/Application Support/Fala/it-jargon.json"),
      userFile: .created,
      merge: nil)
    #expect(status.displayPath == "~/Library/Application Support/Fala/it-jargon.json")
  }

  // MARK: - First run

  @Test("First run creates a template the user can open, and changes nothing")
  func firstRunSeedsAnInertTemplate() throws {
    let directory = Self.temporaryDirectory()
    defer { Self.remove(directory) }
    let store = JargonDictionaryStore(directory: directory)

    let status = try store.load()
    #expect(status.userFile == .created)
    #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    #expect(status.warnings.isEmpty)

    let bundled = try JargonDictionary.loadDefault()
    #expect(status.activeEntryCount == bundled.activeEntryCount)

    let written = try Data(contentsOf: store.fileURL)
    #expect((try? JSONSerialization.jsonObject(with: written)) != nil)
    #expect(try JargonOverride.decode(json: written).isEmpty)
  }

  /// The user cannot discover which rules exist to override or disable unless
  /// something points at the bundled file, which lives inside the app bundle.
  @Test("The bundled file is reported alongside the user's")
  func bundledFileIsReported() throws {
    let directory = Self.temporaryDirectory()
    defer { Self.remove(directory) }
    let status = try JargonDictionaryStore(directory: directory).load(seedIfMissing: false)
    let bundled = try #require(status.bundledFileURL)
    #expect(FileManager.default.fileExists(atPath: bundled.path))
    #expect(bundled.lastPathComponent == JargonDictionaryStore.fileName)
  }

  @Test("A second run reads the file instead of re-creating it, and never overwrites")
  func secondRunDoesNotOverwrite() throws {
    let directory = Self.temporaryDirectory()
    defer { Self.remove(directory) }
    let store = JargonDictionaryStore(directory: directory)
    _ = try store.load()

    let edited = #"{ "entries": [ { "from": "esse queuel", "to": "SQL" } ] }"#
    try Data(edited.utf8).write(to: store.fileURL)

    let status = try store.load()
    #expect(status.userFile == .applied)
    #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == edited)
    #expect(status.dictionary.apply(to: "roda um esse queuel") == "roda um SQL")
  }

  @Test("Seeding can be skipped, and then nothing is written")
  func seedingIsOptional() throws {
    let directory = Self.temporaryDirectory()
    defer { Self.remove(directory) }
    let store = JargonDictionaryStore(directory: directory)
    let status = try store.load(seedIfMissing: false)
    #expect(status.userFile == .absent(nil))
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    #expect(status.warnings.isEmpty)
  }

  @Test("A file that cannot be created is reported, and dictation still works")
  func unwritableLocationDegrades() throws {
    // A regular file where the directory should be: createDirectory must fail.
    let blocked = Self.temporaryDirectory()
    defer { Self.remove(blocked) }
    try Data("not a directory".utf8).write(to: blocked)

    let store = JargonDictionaryStore(directory: blocked)
    let status = try store.load()
    #expect(status.userFile == .absent(.cannotCreateUserFile(file: "it-jargon.json")))
    #expect(status.warnings.count == 1)
    #expect(status.activeEntryCount > 0)
  }

  // MARK: - Merging from disk

  @Test("A user entry is merged over the bundled default")
  func userEntryIsMerged() throws {
    let store = try Self.store(
      containing: """
        { "entries": [ { "from": "cai cede", "to": "CI/CD", "safety": "safe" } ] }
        """)
    defer { Self.remove(store.directory) }

    let status = try store.load()
    #expect(status.userFile == .applied)
    #expect(status.isUsingUserFile)
    #expect(status.merge?.added == 1)
    #expect(status.merge?.replaced == 0)
    #expect(status.dictionary.apply(to: "roda o cai cede") == "roda o CI/CD")
    #expect(status.dictionary.apply(to: "no posterg") == "no Postgres")
  }

  /// End-to-end through the real seeded file: take the template Fala writes on
  /// first run — which always contains `"entries": []` — add the documented flat
  /// map to it, and the terms must actually fire. Before the fix they were
  /// dropped without a word.
  @Test("A flat 'substitutions' map added to the SEEDED template takes effect")
  func substitutionsWorkInASeededFile() throws {
    let directory = Self.temporaryDirectory()
    defer { Self.remove(directory) }
    let store = JargonDictionaryStore(directory: directory)
    #expect(try store.load().userFile == .created)

    // The seeded template verbatim, plus the one key the docs tell users to add.
    let seeded = try String(contentsOf: store.fileURL, encoding: .utf8)
    let added = "\"entries\": [], \"substitutions\": { \"cai cede\": \"CI/CD\" },"
    let edited = seeded.replacingOccurrences(of: "\"entries\": [],", with: added)
    #expect(edited != seeded)
    try Data(edited.utf8).write(to: store.fileURL)

    let status = try store.load()
    #expect(status.userFile == .applied)
    #expect(status.isUsingUserFile)
    #expect(status.merge?.added == 1)
    #expect(status.dictionary.apply(to: "roda o cai cede") == "roda o CI/CD")
    #expect(status.warnings.isEmpty)
  }

  @Test("A user entry with a bundled 'from' wins over the bundled rule")
  func userEntryWinsOverBundled() throws {
    let store = try Self.store(
      containing: """
        { "entries": [ { "from": "PÓSTERG", "to": "PostgreSQL", "safety": "safe" } ] }
        """)
    defer { Self.remove(store.directory) }

    let status = try store.load()
    #expect(status.merge?.replaced == 1)
    #expect(status.merge?.added == 0)
    #expect(status.dictionary.apply(to: "no posterg") == "no PostgreSQL")
    #expect(status.declaredEntryCount == (try JargonDictionary.loadDefault().entries.count))
  }

  @Test("A user can switch a bundled rule off")
  func userCanDisableABundledRule() throws {
    let store = try Self.store(containing: #"{ "disable": ["brand"] }"#)
    defer { Self.remove(store.directory) }

    let bundled = try JargonDictionary.loadDefault()
    let status = try store.load()
    #expect(status.merge?.disabled == 1)
    #expect(status.dictionary.apply(to: "cria uma brand nova") == "cria uma brand nova")
    #expect(status.activeEntryCount == bundled.activeEntryCount - 1)
  }

  @Test("A 'disable' typo warns and leaves the rest of the file working")
  func disableTypoWarns() throws {
    let store = try Self.store(
      containing: """
        {
          "entries": [ { "from": "esse queuel", "to": "SQL" } ],
          "disable": ["postgrez"]
        }
        """)
    defer { Self.remove(store.directory) }

    let status = try store.load()
    #expect(status.userFile == .applied)
    #expect(status.merge?.unmatchedDisableKeys == ["postgrez"])
    #expect(status.warnings.count == 1)
    #expect(status.warnings[0].contains("postgrez"))
    #expect(status.dictionary.apply(to: "roda um esse queuel") == "roda um SQL")
  }

  /// The documented escape hatch for the entries this project refuses to enable:
  /// re-declaring one as `safe` is the user asserting it, rule by rule.
  @Test("A user can enable a risky bundled rule by re-declaring it as safe")
  func userCanPromoteARiskyRule() throws {
    let store = try Self.store(
      containing: """
        { "entries": [ { "from": "post", "to": "Postgres", "safety": "safe" } ] }
        """)
    defer { Self.remove(store.directory) }

    let status = try store.load()
    #expect(status.merge?.replaced == 1)
    #expect(status.dictionary.apply(to: "um post no blog") == "um Postgres no blog")
  }

  @Test("An empty user file behaves exactly like no overrides")
  func emptyUserFileIsInert() throws {
    let store = try Self.store(containing: "\n")
    defer { Self.remove(store.directory) }

    let status = try store.load()
    #expect(status.userFile == .applied)
    #expect(status.isUsingUserFile == false)
    #expect(status.warnings.isEmpty)
    #expect(status.activeEntryCount == (try JargonDictionary.loadDefault().activeEntryCount))
  }

  // MARK: - Degrading

  @Test("Malformed JSON degrades to the bundled default with a reportable error")
  func malformedFileDegrades() throws {
    let store = try Self.store(containing: "{ isso não é JSON")
    defer { Self.remove(store.directory) }

    let bundled = try JargonDictionary.loadDefault()
    let status = try store.load()
    guard case .ignored(let error) = status.userFile else {
      Issue.record("expected .ignored, got \(status.userFile)")
      return
    }
    guard case .malformedJSON = error else {
      Issue.record("expected .malformedJSON, got \(error)")
      return
    }
    #expect(status.activeEntryCount == bundled.activeEntryCount)
    #expect(status.dictionary.apply(to: "no posterg") == "no Postgres")
    #expect(status.warnings.count == 1)
    #expect(status.warnings[0].contains("it-jargon.json"))
    #expect(!status.isUsingUserFile)
  }

  @Test("A self-contradictory user entry degrades, naming the entry")
  func invalidUserEntryDegrades() throws {
    let store = try Self.store(
      containing: """
        { "entries": [ { "from": "com pose", "to": "Compose", "safety": "contextual" } ] }
        """)
    defer { Self.remove(store.directory) }

    let status = try store.load()
    #expect(
      status.userFile
        == .ignored(
          .invalidEntry(
            from: "com pose",
            reason: "safety 'contextual' exige contextBefore e/ou contextAfter")))
    #expect(status.warnings[0].contains("com pose"))
    #expect(status.activeEntryCount > 0)
    Self.expectPortuguese(status.warnings[0])
  }

  @Test("An unreadable file degrades instead of throwing")
  func unreadableFileDegrades() throws {
    let directory = Self.temporaryDirectory()
    defer { Self.remove(directory) }
    let store = JargonDictionaryStore(directory: directory)
    // A directory where the file should be: readable path, unreadable contents.
    try FileManager.default.createDirectory(
      at: store.fileURL, withIntermediateDirectories: true)

    let status = try store.load()
    #expect(status.userFile == .ignored(.unreadable(file: "it-jargon.json")))
    #expect(status.activeEntryCount > 0)
  }

  // MARK: - Reporting

  @Test("The summary states the active count, and the merge when there is one")
  func summaryDescribesWhatIsInForce() throws {
    let store = try Self.store(
      containing: """
        {
          "entries": [ { "from": "esse queuel", "to": "SQL" } ],
          "disable": ["brand"]
        }
        """)
    defer { Self.remove(store.directory) }

    let status = try store.load()
    #expect(status.summary.hasPrefix("\(status.activeEntryCount) substituições ativas"))
    #expect(status.summary.contains("1 sua do seu arquivo"))
    #expect(status.summary.contains("1 desligada"))
  }

  @Test("Reported strings carry only configuration, never a transcript")
  func errorMessagesArePortugueseAndSafe() {
    #expect(
      JargonDictionaryError.unreadable(file: "it-jargon.json").userMessage
        .contains("não foi possível ler"))
    #expect(JargonDictionaryError.malformedJSON(reason: "x").userMessage.contains("inválido"))
    #expect(JargonDictionaryError.defaultResourceMissing.userMessage.contains("embutido"))
    #expect(
      JargonDictionaryError.invalidEntry(from: "brand", reason: "y").userMessage
        .contains("'brand'"))
  }

  /// What `doctor` prints for the file itself, as opposed to the rule count.
  @Test("The file summary names the file and what happened to it")
  func fileSummaryNamesTheFileInForce() throws {
    let store = try Self.store(
      containing: #"{ "entries": [ { "from": "esse queuel", "to": "SQL" } ] }"#)
    defer { Self.remove(store.directory) }

    let applied = try store.load()
    #expect(applied.fileSummary.contains("it-jargon.json"))
    #expect(applied.fileSummary.contains("em uso"))
    #expect(applied.isHealthy)

    let seeded = JargonDictionaryStore(directory: Self.temporaryDirectory())
    defer { Self.remove(seeded.directory) }
    #expect(try seeded.load().fileSummary.contains("criado agora"))

    let untouched = JargonDictionaryStore(directory: Self.temporaryDirectory())
    defer { Self.remove(untouched.directory) }
    #expect(try untouched.load(seedIfMissing: false).fileSummary.contains("ainda não existe"))
  }

  // MARK: - pt-BR decoder messages
  //
  // The previous test for this fed `JargonDictionaryError` values built by hand,
  // so it asserted the pt-BR frame around a `reason` the test itself wrote. Every
  // reason a REAL file produces came from `JSONDecoder`, in English, and was
  // interpolated verbatim: "Cannot initialize JargonSafety from invalid String
  // value seguro", "The given data was not valid JSON." These go through the
  // store, from bytes on disk, so the message under test is the one the user
  // actually reads.

  @Test("A file that is not JSON says so in pt-BR, with no decoder English")
  func notJSONIsExplainedInPortuguese() throws {
    let status = try Self.warning(for: "{ isso não é JSON")
    #expect(status.contains("não é JSON válido"))
    #expect(status.contains("vírgulas"))
    Self.expectPortuguese(status)
  }

  /// The message the defect names: `JargonSafety` is a Swift type the user has
  /// never heard of, and the three valid spellings are not guessable.
  @Test("An invalid 'safety' quotes what the user wrote and lists the valid values")
  func invalidSafetyIsExplainedInPortuguese() throws {
    let warning = try Self.warning(
      for: #"{ "entries": [ { "from": "posterg", "to": "Postgres", "safety": "seguro" } ] }"#)
    #expect(warning.contains("'safety'"))
    #expect(warning.contains("'seguro'"))
    #expect(warning.contains("'safe'"))
    #expect(warning.contains("'contextual'"))
    #expect(warning.contains("'risky'"))
    Self.expectPortuguese(warning)
  }

  /// The second half of the defect: an entry-level failure discarded the whole
  /// file while naming neither the entry nor its position in it.
  @Test("A missing key names the entry by ordinal AND by its own 'from'")
  func missingKeyNamesTheOffendingEntry() throws {
    let warning = try Self.warning(
      for: """
        {
          "entries": [
            { "from": "posterg", "to": "Postgres" },
            { "from": "esse queuel" }
          ]
        }
        """)
    #expect(warning.contains("nº 2"))
    #expect(warning.contains("esse queuel"))
    #expect(warning.contains("falta a chave 'to'"))
    Self.expectPortuguese(warning)
  }

  @Test("A field of the wrong type names the field and the type it should be")
  func typeMismatchIsExplainedInPortuguese() throws {
    let warning = try Self.warning(
      for: #"{ "entries": [ { "from": "posterg", "to": 42 } ] }"#)
    #expect(warning.contains("nº 1"))
    #expect(warning.contains("'to' deveria ser texto"))
    Self.expectPortuguese(warning)
  }

  @Test("A top-level key of the wrong type is named without inventing an entry")
  func topLevelTypeMismatchHasNoEntryOrdinal() throws {
    let warning = try Self.warning(for: #"{ "disable": "brand" }"#)
    #expect(warning.contains("'disable' deveria ser uma lista"))
    #expect(!warning.contains("entrada nº"))
    Self.expectPortuguese(warning)
  }

  /// A misspelled key is the one failure a lenient decoder makes undiagnosable,
  /// so the rejection has to be readable too.
  @Test("An unrecognised top-level key is rejected in pt-BR, listing what is valid")
  func unrecognisedKeyIsExplainedInPortuguese() throws {
    let warning = try Self.warning(for: #"{ "entrys": [] }"#)
    #expect(warning.contains("'entries'"))
    #expect(warning.contains("'substitutions'"))
    #expect(warning.contains("'disable'"))
    Self.expectPortuguese(warning)
  }

  /// A pasted paragraph in `from` must not become the warning.
  @Test("A quoted value from the user's file is clipped")
  func quotedValuesAreClipped() throws {
    let long = String(repeating: "x", count: 200)
    let warning = try Self.warning(for: #"{ "entries": [ { "from": "\#(long)" } ] }"#)
    #expect(warning.contains("…"))
    #expect(!warning.contains(long))
    #expect(warning.contains(String(repeating: "x", count: 40)))
  }

  // MARK: - Helpers

  /// English the decoder emits that must never reach the user. `#expect` on
  /// absence, because the defect was invisible to every assertion that only
  /// checked for the Portuguese half.
  private static let englishTells = [
    "Cannot initialize", "The given data", "Expected to decode", "No value associated",
    "but found", "missing key", "invalid String value", "unreadable JSON", "expected",
  ]

  private static func expectPortuguese(
    _ text: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    for tell in englishTells where text.contains(tell) {
      Issue.record(
        "English decoder text leaked: '\(tell)' in \(text)", sourceLocation: sourceLocation)
    }
  }

  /// The single warning a broken file produces, read through the real store so
  /// the string under test is the one `doctor` prints.
  private static func warning(
    for json: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> String {
    let store = try Self.store(containing: json)
    defer { Self.remove(store.directory) }
    let status = try store.load()
    #expect(!status.isHealthy, sourceLocation: sourceLocation)
    #expect(status.activeEntryCount > 0, "the bundled default must survive")
    return status.warnings.first ?? ""
  }

  private static func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("fala-jargon-store-\(UUID().uuidString)", isDirectory: true)
  }

  private static func store(containing json: String) throws -> JargonDictionaryStore {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = JargonDictionaryStore(directory: directory)
    try Data(json.utf8).write(to: store.fileURL)
    return store
  }

  private static func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}
