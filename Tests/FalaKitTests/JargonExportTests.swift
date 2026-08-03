import Foundation
import Testing

@testable import FalaKit

// Dictionary export (mockup: Ajustes › Dicionário › "Exportar JSON"; SPEC.md
// FR-9 "user-editable").
//
// The decision under test is WHAT is exported. Writing the merged view would
// hand the user a frozen copy of all 43 bundled rules, which then overrides
// every future correction Fala ships — by identity, silently, forever. Export
// therefore writes the user's OWN override, and the tests below pin both halves
// of that: the bundled rules are absent from the file, and the file still
// re-imports into a dictionary that behaves the same.

@Suite struct JargonExportTests {

  // MARK: - Round trip

  /// The contract in one test: what the user wrote comes back byte-for-byte
  /// equal as VALUES, through the same decoder the import button uses.
  @Test("Everything the user wrote survives encode → decode")
  func roundTripPreservesEveryField() throws {
    let override = JargonOverride(
      entries: [
        JargonEntry(from: "cai cedê", to: "CI/CD", safety: .safe, note: "medido no RUN 3"),
        JargonEntry(
          from: "compos", to: "Compose", safety: .contextual,
          contextBefore: ["docker"], contextAfter: ["up", "down"]),
        JargonEntry(from: "esse queuel", to: "SQL"),
      ],
      disable: ["brand", "posterg"])

    let data = try JargonExport.encode(override)
    let decoded = try JargonOverride.decode(json: data)

    #expect(decoded.entries == override.entries)
    #expect(decoded.disable == override.disable)
  }

  /// Half this file is IT jargon. Without `.withoutEscapingSlashes`, "CI/CD" is
  /// written "CI\/CD" — valid JSON that looks broken to the person editing it.
  @Test("Slashes are not escaped and accents are not mangled")
  func outputIsReadable() throws {
    let override = JargonOverride(
      entries: [JargonEntry(from: "cai cedê", to: "CI/CD", note: "ação")])
    let text = String(decoding: try JargonExport.encode(override), as: UTF8.self)
    #expect(text.contains("CI/CD"))
    #expect(!text.contains("CI\\/CD"))
    #expect(text.contains("cai cedê"))
    #expect(text.contains("ação"))
    // A file people diff and open in an editor.
    #expect(text.hasSuffix("\n"))
    #expect(text.contains("\n  "))
  }

  /// This is what `.sortedKeys` buys, and it was measured: encoding every key by
  /// hand in a fixed order instead produced three different byte sequences over
  /// three runs, because Foundation does not preserve insertion order across
  /// processes. A same-process check cannot see that, so the comment on
  /// `JargonExport.encode` carries the evidence and this test guards the rest.
  @Test("Two exports of the same content are byte-identical")
  func encodingIsDeterministic() throws {
    let override = JargonOverride(
      entries: [
        JargonEntry(from: "posterg", to: "Postgres"),
        JargonEntry(from: "cubernetes", to: "Kubernetes"),
      ],
      disable: ["brand"])
    #expect(try JargonExport.encode(override) == JargonExport.encode(override))
  }

  /// Empty context lists and an absent note are omitted rather than written as
  /// `[]` and `null`: a two-field entry that renders as six lines invites the
  /// user to "fill in" fields that mean nothing.
  @Test("Nothing the user did not write appears in their file")
  func emptyFieldsAreOmitted() throws {
    let override = JargonOverride(entries: [JargonEntry(from: "posterg", to: "Postgres")])
    let text = String(decoding: try JargonExport.encode(override), as: UTF8.self)
    #expect(!text.contains("contextBefore"))
    #expect(!text.contains("contextAfter"))
    #expect(!text.contains("note"))
    // `safety` is always written: it is the field whose default most needs to be
    // visible before someone adds a Portuguese word to the list.
    #expect(text.contains("\"safety\" : \"safe\""))
  }

  /// The header is documentation for the user, and the decoder has to ignore it
  /// — otherwise the file Fala writes is a file Fala refuses to read.
  @Test("The pt-BR header is present and survives re-import")
  func headerIsIgnoredOnImport() throws {
    let data = try JargonExport.encode(JargonOverride())
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("$comment"))
    #expect(text.contains("dicionário embutido"))
    #expect(try JargonOverride.decode(json: data).isEmpty)
  }

  // MARK: - The decision: user's own entries, never the merged view

  @Test("Export contains the user's entries and NOT the bundled dictionary")
  func exportExcludesTheBundledDictionary() throws {
    let directory = Self.temporaryDirectory()
    defer { Self.remove(directory) }
    let store = try Self.store(
      in: directory,
      containing: #"{ "entries": [ { "from": "esse queuel", "to": "SQL" } ] }"#)

    let destination = directory.appendingPathComponent("export.json")
    let summary = try store.exportUserOverride(to: destination)

    #expect(summary.entryCount == 1)
    #expect(summary.disabledCount == 0)
    #expect(!summary.isEmpty)

    let exported = try JargonOverride.decode(json: Data(contentsOf: destination))
    #expect(exported.entries.count == 1)
    #expect(exported.entries.first?.to == "SQL")

    // 43 bundled rules exist; not one of them may be in the user's file.
    let bundled = try JargonDictionary.loadDefault(includeRisky: true)
    #expect(bundled.entries.count > 10)
    let exportedKeys = Set(exported.entries.map { JargonDictionary.mergeKey(for: $0.from) })
    for entry in bundled.entries {
      #expect(!exportedKeys.contains(JargonDictionary.mergeKey(for: entry.from)))
    }
    let text = String(decoding: try Data(contentsOf: destination), as: UTF8.self)
    #expect(!text.contains("posterg"))
  }

  /// The point of exporting the override rather than the merge: the restored
  /// machine keeps tracking the bundled dictionary. Here the export predates a
  /// bundled fix, and the fix still reaches the user after re-import.
  @Test("A re-imported export still merges under a NEWER bundled rule")
  func exportStaysADiffAgainstFutureVersions() throws {
    let source = Self.temporaryDirectory()
    defer { Self.remove(source) }
    let store = try Self.store(
      in: source,
      containing: #"{ "entries": [ { "from": "esse queuel", "to": "SQL" } ], "#
        + #""disable": ["brand"] }"#)

    let destination = source.appendingPathComponent("export.json")
    try store.exportUserOverride(to: destination)

    // A later Fala version ships a correction the user has never seen.
    let futureBundled = [
      JargonEntry(from: "brand", to: "branch"),
      JargonEntry(from: "corrigido depois", to: "CORRIGIDO"),
    ]
    let restored = try JargonOverride.decode(json: Data(contentsOf: destination))
    let merged = restored.merged(over: futureBundled)
    let dictionary = try JargonDictionary(entries: merged.entries)

    // The user's own term came back…
    #expect(dictionary.apply(to: "roda um esse queuel") == "roda um SQL")
    // …their `disable` came back…
    #expect(dictionary.apply(to: "criei a brand nova") == "criei a brand nova")
    // …and the NEW bundled rule still applies, which a merged export would have
    // frozen out.
    #expect(dictionary.apply(to: "isso é corrigido depois") == "isso é CORRIGIDO")
  }

  @Test("An exported file re-imports as the user's file and behaves identically")
  func exportedFileIsAValidUserFile() throws {
    let source = Self.temporaryDirectory()
    defer { Self.remove(source) }
    let original = try Self.store(
      in: source,
      containing: #"{ "entries": [ { "from": "esse queuel", "to": "SQL", "#
        + #""safety": "safe", "note": "meu termo" } ], "disable": ["brand"] }"#)
    let before = try original.load()

    let exportURL = source.appendingPathComponent("export.json")
    try original.exportUserOverride(to: exportURL)

    // Another machine: a fresh Application Support directory, the exported file
    // dropped in as the user's own.
    let target = Self.temporaryDirectory()
    defer { Self.remove(target) }
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let restoredStore = JargonDictionaryStore(directory: target)
    try FileManager.default.copyItem(at: exportURL, to: restoredStore.fileURL)

    let after = try restoredStore.load()
    #expect(after.userFile == .applied)
    #expect(after.warnings.isEmpty)
    #expect(after.activeEntryCount == before.activeEntryCount)
    #expect(after.merge?.added == before.merge?.added)
    #expect(after.merge?.disabled == before.merge?.disabled)
    #expect(after.dictionary.apply(to: "roda um esse queuel") == "roda um SQL")
    #expect(try restoredStore.loadUserOverride().entries.first?.note == "meu termo")
  }

  // MARK: - Failure modes

  /// The failure that must not be silent: writing `{"entries": []}` from a file
  /// with a misplaced comma looks exactly like a successful backup of the terms
  /// it just dropped.
  @Test("A broken user file fails the export instead of exporting nothing")
  func brokenSourceRefusesToExport() throws {
    let directory = Self.temporaryDirectory()
    defer { Self.remove(directory) }
    let store = try Self.store(in: directory, containing: #"{ "entries": [ }"#)
    let destination = directory.appendingPathComponent("export.json")

    #expect(throws: JargonExportError.self) {
      try store.exportUserOverride(to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  /// A misspelled key (`entrys`) is the same class of failure: the user's terms
  /// are there, Fala cannot see them, and an export must not pretend otherwise.
  @Test("An unrecognised key fails the export too")
  func unrecognisedKeyRefusesToExport() throws {
    let directory = Self.temporaryDirectory()
    defer { Self.remove(directory) }
    let store = try Self.store(in: directory, containing: #"{ "entrys": [] }"#)
    let destination = directory.appendingPathComponent("export.json")
    #expect(throws: JargonExportError.self) {
      try store.exportUserOverride(to: destination)
    }
  }

  /// Not an error: it is the state of a first run, and of a user who emptied
  /// their file on purpose. The summary says so instead of the window claiming
  /// a backup happened.
  @Test("With no user file, the export is empty, valid and honest about it")
  func missingSourceExportsAnEmptyOverride() throws {
    let directory = Self.temporaryDirectory()
    defer { Self.remove(directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = JargonDictionaryStore(directory: directory)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

    let destination = directory.appendingPathComponent("export.json")
    let summary = try store.exportUserOverride(to: destination)

    #expect(summary.isEmpty)
    #expect(summary.message.contains("vazio"))
    #expect(try JargonOverride.decode(json: Data(contentsOf: destination)).isEmpty)
  }

  @Test("The seeded template exports as an empty override")
  func seededTemplateExportsEmpty() throws {
    let directory = Self.temporaryDirectory()
    defer { Self.remove(directory) }
    let store = JargonDictionaryStore(directory: directory)
    _ = try store.load()

    let destination = directory.appendingPathComponent("export.json")
    #expect(try store.exportUserOverride(to: destination).isEmpty)
  }

  @Test("A destination that cannot be written is reported by name only")
  func unwritableDestinationIsReported() throws {
    let directory = Self.temporaryDirectory()
    defer { Self.remove(directory) }
    let store = try Self.store(
      in: directory, containing: #"{ "entries": [ { "from": "a", "to": "B" } ] }"#)
    // A directory that does not exist: the write must fail, not create it.
    let missing = directory.appendingPathComponent("nao-existe", isDirectory: true)
    let destination = missing.appendingPathComponent("export.json")

    let error = #expect(throws: JargonExportError.self) {
      try store.exportUserOverride(to: destination)
    }
    #expect(error == .cannotWrite(file: "export.json"))
  }

  /// Never the full path: it carries the user's account name.
  @Test("No error message carries a path")
  func errorsCarryNoPath() {
    let error = JargonExportError.cannotWrite(file: "export.json")
    guard case .cannotWrite(let file) = error else { return }
    #expect(!file.contains("/"))
  }

  // MARK: - Summary copy

  @Test("The summary is pt-BR and counts what was written")
  func summaryReportsCounts() {
    let url = URL(fileURLWithPath: "/tmp/export.json")
    #expect(
      JargonExportSummary(url: url, entryCount: 1, disabledCount: 0).message
        == "Exportado: 1 termo seu.")
    #expect(
      JargonExportSummary(url: url, entryCount: 3, disabledCount: 2).message
        == "Exportado: 3 termos seus, 2 desligados.")
    #expect(JargonExportSummary(url: url, entryCount: 0, disabledCount: 0).isEmpty)
    #expect(!JargonExportSummary(url: url, entryCount: 0, disabledCount: 1).isEmpty)
  }

  @Test("The suggested file name is the one the app already reads")
  func suggestedNameMatchesTheUserFile() {
    #expect(JargonExport.suggestedFileName == JargonDictionaryStore.fileName)
  }

  // MARK: - Helpers

  private static func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("fala-jargon-export-\(UUID().uuidString)", isDirectory: true)
  }

  private static func store(
    in directory: URL,
    containing json: String
  ) throws -> JargonDictionaryStore {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = JargonDictionaryStore(directory: directory)
    try Data(json.utf8).write(to: store.fileURL)
    return store
  }

  private static func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}
