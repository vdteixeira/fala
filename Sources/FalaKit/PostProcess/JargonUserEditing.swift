// Writing the user's jargon override — the half of FR-9 that only existed as a
// "open the file in your editor" until Ajustes › Dicionário needed a list with a
// delete button and an "Importar JSON".
//
// `JargonDictionaryStore` could seed, read and merge the file; `JargonExport`
// could write one to an arbitrary destination. Nothing could put a changed
// override BACK where the app reads it, which is what every button on that tab
// does. This file adds exactly that, plus import, in the export's canonical
// shape so a file written by the window is a file the user can keep editing by
// hand.

import Foundation

/// Something went wrong changing the user's dictionary from the settings window.
///
/// Separate from `JargonStoreError` (which is only about first-run seeding) and
/// from `JargonExportError` (which is only about writing somewhere else), so
/// each surface keeps a closed set of cases it has to explain.
public enum JargonEditError: Error, Equatable, Sendable {
  /// The user's own file is present but unreadable, so a change would be built
  /// on top of nothing. Reported instead of overwriting: the file may hold terms
  /// the user spent time on, and a syntax error is recoverable in an editor.
  case sourceUnusable(JargonDictionaryError)

  /// The file being imported is not a usable override.
  case importUnusable(JargonDictionaryError)

  /// The override could not be written. Carries the file NAME only — never the
  /// full path, which can contain the user's real name.
  case cannotWrite(file: String)

  /// pt-BR, for the status line under the list.
  public var message: String {
    switch self {
    case .sourceUnusable(let error):
      return "Seu dicionário não pôde ser lido — \(error.userMessage) "
        + "Corrija o arquivo antes de editar aqui."
    case .importUnusable(let error):
      return "O arquivo escolhido não é um dicionário válido — \(error.userMessage)"
    case .cannotWrite(let file):
      return "Não foi possível salvar '\(file)'."
    }
  }
}

/// What an import replaced the user's file with.
public struct JargonImportSummary: Sendable, Equatable {
  public let entryCount: Int
  public let disabledCount: Int
  /// Bundled rules this override replaces by identity.
  public let replacedBundled: Int
  /// Rules the bundled dictionary does not have.
  public let addedNew: Int

  public init(entryCount: Int, disabledCount: Int, replacedBundled: Int, addedNew: Int) {
    self.entryCount = entryCount
    self.disabledCount = disabledCount
    self.replacedBundled = replacedBundled
    self.addedNew = addedNew
  }

  public var isEmpty: Bool { entryCount == 0 && disabledCount == 0 }

  /// One pt-BR line for the window. Says what the file ASKED for, which is not
  /// the same as how many rows appear: a `disable` term that matches nothing is
  /// counted here and changes nothing on screen.
  public var message: String {
    guard !isEmpty else {
      return "Arquivo importado, mas ele não tem nenhum termo seu."
    }
    var parts = [Self.plural(entryCount, "termo seu", "termos seus")]
    if disabledCount > 0 {
      parts.append(Self.plural(disabledCount, "desligado", "desligados"))
    }
    return "Importado: " + parts.joined(separator: ", ") + "."
  }

  private static func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count) \(count == 1 ? singular : plural)"
  }
}

extension JargonDictionaryStore {

  /// Replaces the user's override file with `override`.
  ///
  /// Validated first: `JargonDictionary(entries:)` rejects an empty `to`, a
  /// `contextual` rule with no context words, and a `from` with no word
  /// characters. Writing an override the app itself would then refuse to load
  /// would turn one bad row into a dictionary the user cannot use at all, and
  /// the only sign would be a `doctor` warning they have no reason to run.
  ///
  /// Written in `JargonExport`'s canonical shape — same encoder, same pt-BR
  /// header — so the file the window writes is the file the user keeps editing
  /// by hand, and re-exporting it produces identical bytes.
  ///
  /// - Throws: `JargonEditError.importUnusable` when the entries are invalid
  ///   (the same shape as a bad file, because that is what it would become),
  ///   `JargonEditError.cannotWrite` when the disk refuses.
  public func saveUserOverride(_ override: JargonOverride) throws {
    do {
      // `includeRisky: true` so a risky entry is still VALIDATED rather than
      // skipped: it is inert at match time, but a malformed one must not be
      // written to a file that will later be loaded with a different flag.
      _ = try JargonDictionary(entries: override.entries, includeRisky: true)
    } catch let error as JargonDictionaryError {
      throw JargonEditError.importUnusable(error)
    }

    let data: Data
    do {
      data = try JargonExport.encode(override)
    } catch {
      throw JargonEditError.cannotWrite(file: Self.fileName)
    }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      // Atomic: this replaces a file the user may have terms in, and a
      // half-written override is worse than either version of it.
      try data.write(to: fileURL, options: .atomic)
    } catch {
      throw JargonEditError.cannotWrite(file: Self.fileName)
    }
  }

  /// Reads an exported override and makes it the user's file.
  ///
  /// REPLACES rather than merges. Import is the other half of export, and export
  /// writes the whole override; merging two overrides would need a conflict rule
  /// the user has no way to see or predict, and would make importing the same
  /// file twice mean two different things. The window is responsible for
  /// confirming when the current file is not empty — this level cannot ask.
  ///
  /// - Throws: `JargonEditError.importUnusable` when the file is not a usable
  ///   override, `JargonEditError.cannotWrite` when the destination refuses.
  @discardableResult
  public func importUserOverride(from url: URL) throws -> JargonImportSummary {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw JargonEditError.importUnusable(.unreadable(file: url.lastPathComponent))
    }
    let override: JargonOverride
    do {
      override = try JargonOverride.decode(json: data)
    } catch let error as JargonDictionaryError {
      throw JargonEditError.importUnusable(error)
    }
    try saveUserOverride(override)

    // Reported against the bundled file so the summary can say "replaces 2 of
    // ours" rather than only "5 entries". A packaging failure here must not fail
    // an import that already succeeded, so the counts degrade to zero.
    let bundled = (try? JargonDictionary.loadDefault(includeRisky: true))?.entries ?? []
    let merge = override.merged(over: bundled)
    return JargonImportSummary(
      entryCount: override.entries.count,
      disabledCount: override.disable.count,
      replacedBundled: merge.replaced,
      addedNew: merge.added)
  }
}
