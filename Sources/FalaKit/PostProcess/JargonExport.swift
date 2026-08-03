import Foundation

/// Something went wrong exporting the user's dictionary (mockup: Ajustes ›
/// Dicionário › "Exportar JSON").
///
/// Separate from `JargonStoreError` so that adding an export failure cannot
/// change the meaning of the states `doctor` already reports about the user's
/// file, and separate from `JargonDictionaryError` because none of these are
/// about the CONTENT being wrong.
public enum JargonExportError: Error, Equatable, Sendable {
  /// The user's own file exists but cannot be read or parsed, so there is
  /// nothing trustworthy to export.
  ///
  /// Reported instead of writing an empty file: an "export" that silently
  /// produces `{"entries": []}` from a file with a misplaced comma looks like a
  /// successful backup of the terms it just dropped, and the user finds out only
  /// when they restore it.
  case sourceUnusable(JargonDictionaryError)

  /// The destination could not be written (read-only volume, sandbox denial, a
  /// path that vanished between the save panel and the write). Carries the file
  /// NAME only — never the full path, which can contain the user's real name.
  case cannotWrite(file: String)
}

/// What an export produced, so the window can say what happened instead of
/// flashing a save panel and going quiet.
public struct JargonExportSummary: Sendable, Equatable {
  /// Where it was written.
  public let url: URL
  /// Entries the user declared.
  public let entryCount: Int
  /// Bundled rules the user switched off.
  public let disabledCount: Int

  public init(url: URL, entryCount: Int, disabledCount: Int) {
    self.url = url
    self.entryCount = entryCount
    self.disabledCount = disabledCount
  }

  /// True when the user has customised nothing. The file is still valid and
  /// still importable — it just asks for nothing, exactly like the template
  /// seeded on first run.
  public var isEmpty: Bool { entryCount == 0 && disabledCount == 0 }

  /// One pt-BR line for the window.
  public var message: String {
    guard !isEmpty else {
      return "Você ainda não tem termos seus — o arquivo exportado está vazio."
    }
    var parts = [Self.plural(entryCount, "termo seu", "termos seus")]
    if disabledCount > 0 {
      parts.append(Self.plural(disabledCount, "desligado", "desligados"))
    }
    return "Exportado: " + parts.joined(separator: ", ") + "."
  }

  private static func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count) \(count == 1 ? singular : plural)"
  }
}

/// Writes the user's jargon customisations to a file they can read, edit and
/// re-import (mockup: Ajustes › Dicionário, "Exportar JSON" next to "Importar
/// JSON"; SPEC.md FR-9 "user-editable").
///
/// # THE DECISION: this exports the user's OVERRIDE, not the merged dictionary
///
/// Exporting the merged view is the intuitive choice and it is the wrong one.
/// `JargonOverride` merges the user's file OVER the bundled default, so a file
/// containing all ~43 bundled rules is a file that pins every one of them to the
/// version that shipped the day of the export. A later release that corrects a
/// mangling could never reach that user: their frozen copy overrides the fix by
/// identity, silently, forever. It also makes `disable` meaningless (you cannot
/// tell "I turned this off" from "this is not in my copy") and hands the user
/// 43 rules to maintain when they added one.
///
/// So the exported file contains exactly `entries` + `disable` — the user's own
/// five lines — and stays a *diff against whatever Fala ships next*. That is the
/// same reasoning `JargonDictionaryStore.createTemplateIfMissing()` already
/// applies when it seeds an EMPTY template rather than a copy, and export must
/// not contradict it: the file it writes is the same file the template becomes.
///
/// Consequences, deliberate:
/// - A user who has customised nothing exports an empty (valid, importable)
///   file. `JargonExportSummary.isEmpty` says so, rather than pretending.
/// - The exported file is NOT a way to read the bundled rules. `Fala doctor`
///   prints the bundled file's path; that is the way.
/// - Round-tripping is canonicalising, not byte-preserving: a `substitutions`
///   flat map comes back as `entries`, and Fala's own template prose is replaced
///   by a fresh header. Everything the user WROTE — every `from`, `to`, `safety`,
///   context list and `note` — survives unchanged (pinned by a round-trip test).
public enum JargonExport {

  /// What to pre-fill in the save panel. Same name as the file it came from, so
  /// re-importing is a copy rather than a rename.
  public static let suggestedFileName = JargonDictionaryStore.fileName

  // MARK: - Encoding

  /// The exported bytes for an override already in memory. Pure: no I/O, so the
  /// round trip can be tested without a file system.
  ///
  /// - Throws: only an `EncodingError`, which for this fully concrete document
  ///   of strings would be a programming error rather than anything the user can
  ///   cause. `write(_:to:)` maps it to `JargonExportError.cannotWrite`.
  public static func encode(_ override: JargonOverride) throws -> Data {
    let encoder = JSONEncoder()
    // `.sortedKeys` is NOT cosmetic here, and it is not free either: it puts
    // `note` between `from` and `to`, which is the adjacency a substitution file
    // most wants. It stays because the alternative was MEASURED — dropping it
    // and encoding every key by hand in a fixed order still produced three
    // different byte sequences over three runs of the same input, because
    // Foundation's JSON encoding of a keyed container does not preserve
    // insertion order across processes. Without it, two exports of an unchanged
    // dictionary differ, which turns a file people keep in a dotfiles repo into
    // a permanent spurious diff.
    // `.withoutEscapingSlashes` because half this file is IT jargon: without it
    // "CI/CD" is written "CI\/CD", which is valid JSON and looks broken to the
    // person who has to edit it.
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(ExportDocument(override))
    // A trailing newline: this is a file people open in an editor and pipe
    // through `git diff`, and POSIX text files end with one.
    data.append(0x0A)
    return data
  }

  /// Writes an in-memory override to `url`.
  ///
  /// Atomic, because the destination is often a file the user is overwriting on
  /// purpose (a previous export in their dotfiles repo) and a half-written
  /// replacement of a good backup is the worst outcome available here.
  @discardableResult
  public static func write(_ override: JargonOverride, to url: URL) throws -> JargonExportSummary {
    let data: Data
    do {
      data = try encode(override)
    } catch {
      throw JargonExportError.cannotWrite(file: url.lastPathComponent)
    }
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      throw JargonExportError.cannotWrite(file: url.lastPathComponent)
    }
    return JargonExportSummary(
      url: url, entryCount: override.entries.count, disabledCount: override.disable.count)
  }

  // MARK: - Header

  /// pt-BR, because it is read by the user in their editor — the same rule the
  /// seeded template follows. The JSON KEYS stay English: they are the file
  /// format, shared with the bundled dictionary.
  static let comment =
    "Suas entradas do dicionário do \(MenuBarStrings.brandName). "
    + "O dicionário embutido NÃO está aqui, de "
    + "propósito: ele é mesclado por baixo destas entradas, então as correções das "
    + "próximas versões do \(MenuBarStrings.brandName) continuam valendo para você."

  static let howItWorks = [
    "entries: suas substituições. Se o 'from' já existir no dicionário embutido "
      + "(ignorando maiúsculas e acentos), a sua entrada SUBSTITUI a de fábrica; "
      + "se não existir, ela é acrescentada.",
    "disable: lista de 'from' de fábrica que devem ficar DESLIGADOS.",
    "Para restaurar em outra máquina: importe este arquivo em Ajustes › Dicionário, "
      + "ou copie-o para ~/Library/Application Support/Fala/\(JargonDictionaryStore.fileName).",
  ]
}

// MARK: - The store's export

extension JargonDictionaryStore {

  /// The user's own file, parsed, with nothing merged into it.
  ///
  /// A missing file is an EMPTY override, not an error: that is the state of a
  /// first run, and of a user who deliberately emptied the file to switch their
  /// customisations off.
  ///
  /// - Throws: `JargonDictionaryError` when the file is present but unusable.
  public func loadUserOverride() throws -> JargonOverride {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return JargonOverride()
    }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw JargonDictionaryError.unreadable(file: Self.fileName)
    }
    return try JargonOverride.decode(json: data)
  }

  /// Reads the user's file and writes it to `url` in the canonical export shape.
  ///
  /// - Throws: `JargonExportError.sourceUnusable` when the user's own file is
  ///   broken — the one case where doing nothing is better than writing a file
  ///   that claims to be their dictionary. `JargonExportError.cannotWrite` when
  ///   the destination refuses.
  @discardableResult
  public func exportUserOverride(to url: URL) throws -> JargonExportSummary {
    let override: JargonOverride
    do {
      override = try loadUserOverride()
    } catch let error as JargonDictionaryError {
      throw JargonExportError.sourceUnusable(error)
    } catch {
      throw JargonExportError.sourceUnusable(.unreadable(file: Self.fileName))
    }
    return try JargonExport.write(override, to: url)
  }
}

// MARK: - On-disk shape

/// The exported document.
///
/// Mirrors what `JargonOverride.decode` accepts, plus a pt-BR header. The header
/// keys start with `$` for three reasons: they cannot collide with a real key,
/// `OverrideDocument` ignores unrecognised keys so they survive a round trip
/// harmlessly, and `$` sorts before every letter, so the explanation is the
/// first thing in the file.
private struct ExportDocument: Encodable {
  let entries: [ExportEntry]
  let disable: [String]

  init(_ override: JargonOverride) {
    self.entries = override.entries.map(ExportEntry.init)
    self.disable = override.disable
  }

  enum CodingKeys: String, CodingKey {
    case comment = "$comment"
    case howItWorks = "$comoFunciona"
    case entries
    case disable
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(JargonExport.comment, forKey: .comment)
    try container.encode(JargonExport.howItWorks, forKey: .howItWorks)
    try container.encode(entries, forKey: .entries)
    try container.encode(disable, forKey: .disable)
  }
}

/// `JargonEntry` written for a human.
///
/// A hand-rolled encoder rather than `JargonEntry`'s synthesised one so the
/// output is a file someone will actually edit: empty context lists and an
/// absent `note` are omitted instead of appearing as `[]` and `null`, which
/// triple the length of a two-field entry and invite the user to "fill them in".
/// `safety` is always written, because it is the field whose default (`safe`)
/// most needs to be visible before someone adds a Portuguese word to the list.
private struct ExportEntry: Encodable {
  let entry: JargonEntry

  init(_ entry: JargonEntry) {
    self.entry = entry
  }

  enum CodingKeys: String, CodingKey {
    case from, to, safety, contextBefore, contextAfter, note
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(entry.from, forKey: .from)
    try container.encode(entry.to, forKey: .to)
    try container.encode(entry.safety, forKey: .safety)
    if !entry.contextBefore.isEmpty {
      try container.encode(entry.contextBefore, forKey: .contextBefore)
    }
    if !entry.contextAfter.isEmpty {
      try container.encode(entry.contextAfter, forKey: .contextAfter)
    }
    try container.encodeIfPresent(entry.note, forKey: .note)
  }
}
