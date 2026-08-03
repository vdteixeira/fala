import Foundation

/// Something went wrong with the user's dictionary FILE rather than its contents.
/// Separate from `JargonDictionaryError` because none of these can make the app
/// stop dictating: the bundled default is always available.
public enum JargonStoreError: Error, Equatable, Sendable {
  /// The file could not be written on first run (read-only home, sandbox denial).
  /// Carries the file name only — never the full path, which can contain the
  /// user's real name.
  case cannotCreateUserFile(file: String)
}

/// What the store found on disk, so `doctor` can say which file is in force
/// instead of guessing.
public enum JargonUserFileState: Sendable, Equatable {
  /// Seeded this run with the commented template. First launch: nothing to
  /// merge yet, and the user now has a file to open.
  case created
  /// Present, parsed and merged — even if it asked for nothing.
  case applied
  /// Not on disk and not created (seeding was skipped, or failed).
  case absent(JargonStoreError?)
  /// Present but unusable. The bundled default alone is in force, and the
  /// reason is reportable rather than fatal.
  case ignored(JargonDictionaryError)
}

/// The outcome of loading the dictionary Fala actually uses: bundled default
/// with the user's overrides merged over it, plus everything `doctor` needs to
/// describe the result in one line.
public struct JargonDictionaryStatus: Sendable {

  /// The dictionary to hand to `DictationCoordinator`. Never nil, never partial:
  /// if the user's file could not be used this is the bundled default.
  public let dictionary: JargonDictionary

  /// Where the user's file lives — reported whether or not it exists, because
  /// "the file you should edit is here" is the answer even when it is missing.
  public let userFileURL: URL

  public let userFile: JargonUserFileState

  /// Non-nil exactly when `userFile == .applied`.
  public let merge: JargonOverride.MergeResult?

  /// Public so a caller outside FalaKit (a `doctor` fake, a preview) can build
  /// one without going near the disk. `load()` is still the only thing that
  /// reads a real file.
  public init(
    dictionary: JargonDictionary,
    userFileURL: URL,
    userFile: JargonUserFileState,
    merge: JargonOverride.MergeResult?
  ) {
    self.dictionary = dictionary
    self.userFileURL = userFileURL
    self.userFile = userFile
    self.merge = merge
  }

  /// The bundled file the merge started from — the reference list of `from`
  /// values the user may override or disable. `doctor` should print it, because
  /// it is the only way to discover them: it lives inside the app bundle.
  public var bundledFileURL: URL? { try? JargonDictionary.defaultResourceURL() }

  /// Rules that can fire right now.
  public var activeEntryCount: Int { dictionary.activeEntryCount }

  /// Rules declared, including `risky` ones that are inert.
  public var declaredEntryCount: Int { dictionary.entries.count }

  /// Whether the user's own file contributed anything.
  public var isUsingUserFile: Bool { merge?.isEffective ?? false }

  /// Path with `$HOME` abbreviated to `~`, so a diagnostic can be pasted into a
  /// bug report without carrying the user's account name.
  public var displayPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = userFileURL.path
    guard path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }

  /// One pt-BR line for `doctor`: how many rules are live and where they came
  /// from.
  public var summary: String {
    let active = Self.plural(
      activeEntryCount, "substituição ativa", "substituições ativas")
    guard let merge, merge.isEffective else { return active }
    var parts: [String] = []
    let fromUser = merge.replaced + merge.added
    if fromUser > 0 {
      parts.append(Self.plural(fromUser, "sua", "suas") + " do seu arquivo")
    }
    if merge.disabled > 0 {
      parts.append(Self.plural(merge.disabled, "desligada", "desligadas"))
    }
    return active + " (" + parts.joined(separator: ", ") + ")"
  }

  /// pt-BR problems worth showing the user, in the order they should be shown.
  /// Empty on the happy path — including the first run, where creating the file
  /// is not news the user has to act on.
  public var warnings: [String] {
    var lines: [String] = []
    switch userFile {
    case .ignored(let error):
      lines.append(
        "Seu dicionário em \(displayPath) foi ignorado: \(error.userMessage) "
          + "Valendo só o dicionário embutido.")
    case .absent(.some):
      lines.append(
        "Não foi possível criar \(displayPath). O dicionário embutido continua "
          + "valendo, mas você não consegue editá-lo nesta máquina.")
    case .created, .applied, .absent(.none):
      break
    }
    if let unmatched = merge?.unmatchedDisableKeys, !unmatched.isEmpty {
      let list = unmatched.map { "'\($0)'" }.joined(separator: ", ")
      lines.append(
        "Em 'disable', \(list) não corresponde a nenhuma entrada — verifique a "
          + "grafia do 'from'.")
    }
    return lines
  }

  /// One pt-BR line naming the file that is in force and what happened to it —
  /// the answer to "which dictionary am I actually running?", which `summary`
  /// alone does not give.
  public var fileSummary: String {
    switch userFile {
    case .created:
      return "\(displayPath) (criado agora, vazio)"
    case .applied:
      return isUsingUserFile ? "\(displayPath) (em uso)" : "\(displayPath) (sem alterações)"
    case .absent(.none):
      return "\(displayPath) (ainda não existe)"
    case .absent(.some):
      return "\(displayPath) (não foi possível criar)"
    case .ignored:
      return "\(displayPath) (ignorado)"
    }
  }

  /// Whether `doctor` should print a ✓ or a ✗ for the dictionary. False exactly
  /// when `warnings` has something in it.
  public var isHealthy: Bool { warnings.isEmpty }

  private static func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count) \(count == 1 ? singular : plural)"
  }
}

/// Reads — and on first run seeds — the user-editable jargon dictionary, and
/// reports what it did. This is the second half of SPEC.md FR-9: `JargonDictionary`
/// already knew how to load an arbitrary file, but nothing ever pointed it at one,
/// so in practice a user could not add a term without recompiling.
///
/// Not an actor and not global state: it holds a directory and does its I/O in
/// `load()`, which the app calls ONCE at startup. `apply(to:)` stays pure and
/// file-system free on the hotkey-release path.
public struct JargonDictionaryStore: Sendable {

  /// Same name as the bundled resource on purpose: the user's file is the same
  /// format, so a bundled entry can be pasted into it unchanged.
  public static let fileName = "it-jargon.json"

  /// `~/Library/Application Support/Fala/it-jargon.json`.
  ///
  /// Application Support is where macOS expects user-editable app data that is
  /// not a preference (Preferences is for `defaults`-managed plists, and this is
  /// a document the user opens in an editor). Resolved through `FileManager` so
  /// it follows the container automatically if Fala is ever sandboxed.
  public static var defaultDirectory: URL {
    let fallback = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fallback
    // Deliberately NOT MenuBarStrings.brandName: this is where the user's data
    // lives. Following a rename would orphan every existing dictionary and
    // history file in a directory nothing looks at any more.
    return base.appendingPathComponent("Fala", isDirectory: true)
  }

  public let directory: URL

  /// - Parameter directory: overridable so tests never touch the real
  ///   Application Support directory.
  public init(directory: URL = JargonDictionaryStore.defaultDirectory) {
    self.directory = directory
  }

  /// `FileManager` is not `Sendable`, so it is fetched per call rather than
  /// stored — the same pattern `ModelStatus` uses.
  private var fileManager: FileManager { .default }

  public var fileURL: URL {
    directory.appendingPathComponent(Self.fileName, isDirectory: false)
  }

  // MARK: - Loading

  /// The startup path: seed the file if it is missing, read it, merge it over
  /// the bundled default, and report all of it.
  ///
  /// A broken user file degrades to the bundled default and is reported through
  /// `JargonDictionaryStatus.userFile` / `.warnings`; it never throws and never
  /// leaves the app without a dictionary. The ONLY throwing case is the bundled
  /// default itself being unloadable, which is a packaging defect, not user error.
  ///
  /// - Throws: `JargonDictionaryError` from the bundled resource.
  public func load(
    includeRisky: Bool = false,
    seedIfMissing: Bool = true
  ) throws -> JargonDictionaryStatus {
    let bundled = try JargonDictionary.loadDefault(includeRisky: includeRisky)

    guard fileManager.fileExists(atPath: fileURL.path) else {
      var state = JargonUserFileState.absent(nil)
      if seedIfMissing {
        do {
          state = try createTemplateIfMissing() ? .created : .absent(nil)
        } catch let error as JargonStoreError {
          state = .absent(error)
        }
      }
      return JargonDictionaryStatus(
        dictionary: bundled, userFileURL: fileURL, userFile: state, merge: nil)
    }

    do {
      let data: Data
      do {
        data = try Data(contentsOf: fileURL)
      } catch {
        throw JargonDictionaryError.unreadable(file: Self.fileName)
      }
      let override = try JargonOverride.decode(json: data)
      let result = override.merged(over: bundled.entries)
      let dictionary = try JargonDictionary(entries: result.entries, includeRisky: includeRisky)
      return JargonDictionaryStatus(
        dictionary: dictionary, userFileURL: fileURL, userFile: .applied, merge: result)
    } catch let error as JargonDictionaryError {
      return JargonDictionaryStatus(
        dictionary: bundled, userFileURL: fileURL, userFile: .ignored(error), merge: nil)
    } catch {
      // Degrade rather than propagate: nothing about the user's file may be
      // allowed to take the dictionary away from the rest of the app.
      return JargonDictionaryStatus(
        dictionary: bundled,
        userFileURL: fileURL,
        userFile: .ignored(.unreadable(file: Self.fileName)),
        merge: nil)
    }
  }

  // MARK: - Seeding

  /// Writes the commented template if — and only if — no file is there yet.
  ///
  /// The template is deliberately NOT a copy of the bundled dictionary. A copy
  /// would pin every rule to the version that shipped on the day of first run:
  /// later corrections could never reach the user, because their frozen copy
  /// would override them by identity. It also makes `disable` pointless and
  /// hands the user 200 lines to navigate. What they get instead is an empty
  /// override that explains the merge rule and shows the entry shape.
  ///
  /// - Returns: `true` if it created the file, `false` if one already existed.
  /// - Throws: `JargonStoreError.cannotCreateUserFile`.
  @discardableResult
  public func createTemplateIfMissing() throws -> Bool {
    guard !fileManager.fileExists(atPath: fileURL.path) else { return false }
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      // `.withoutOverwriting` rather than `.atomic`: losing a race here must
      // never clobber a file the user already edited.
      try Data(Self.template.utf8).write(to: fileURL, options: .withoutOverwriting)
      return true
    } catch {
      throw JargonStoreError.cannotCreateUserFile(file: Self.fileName)
    }
  }

  /// Seeded on first run. pt-BR because it is read by the user, in their editor:
  /// it is documentation that happens to be shipped as JSON, and project rule is
  /// that user-facing text is Brazilian Portuguese. The KEYS stay English —
  /// they are the file format, shared with the bundled dictionary.
  static let template = """
    {
      "$comment": "Este arquivo é seu. O \(MenuBarStrings.brandName) nunca sobrescreve o que você escrever aqui.",
      "$comoFunciona": [
        "Ele é MESCLADO por cima do dicionário embutido: o que estiver aqui vence.",
        "entries: mesma forma das entradas embutidas. Se o 'from' já existir no \
    dicionário embutido (ignorando maiúsculas e acentos), a sua entrada SUBSTITUI a de \
    fábrica; se não existir, ela é acrescentada.",
        "disable: lista de 'from' que devem ser DESLIGADOS. É aplicada por último, \
    então vence até sobre uma entrada declarada aqui.",
        "safety: 'safe' = o 'from' não é palavra do português; 'contextual' = só troca \
    quando uma das palavras de contextBefore/contextAfter estiver a até 3 palavras de \
    distância; 'risky' = fica desligado.",
        "A troca só acontece em palavras inteiras, sem diferenciar maiúsculas nem acentos.",
        "Para ver os 'from' de fábrica (os que você pode substituir ou desligar), rode \
    'fala doctor': ele mostra o caminho do dicionário embutido.",
        "Se este arquivo tiver erro de sintaxe, o \(MenuBarStrings.brandName) volta a usar só o dicionário \
    embutido e explica o motivo em 'fala doctor'. Sua ditada não para por causa disso."
      ],
      "$exemplo": {
        "entries": [
          { "from": "cai cedê", "to": "CI/CD", "safety": "safe", "note": "por que você adicionou" },
          { "from": "compos", "to": "Compose", "safety": "contextual", "contextBefore": ["docker"] }
        ],
        "disable": ["brand"]
      },
      "entries": [],
      "disable": []
    }

    """
}

extension JargonDictionaryError {
  /// Short pt-BR explanation for `doctor`. Carries only configuration the user
  /// wrote and file names — never audio, never transcript text.
  ///
  /// Every `reason` reaching this point is itself pt-BR: decoder failures go
  /// through `JargonDecodingDiagnostic`, and the entry-level reasons are written
  /// in Portuguese at their throw sites. It used to interpolate raw English
  /// (`"The given data was not valid JSON."`), which made the one sentence meant
  /// to explain the problem the half the user could not read.
  public var userMessage: String {
    switch self {
    case .defaultResourceMissing:
      return "o dicionário embutido não foi empacotado no app."
    case .unreadable(let file):
      return "não foi possível ler '\(file)'."
    case .malformedJSON(let reason):
      return "o arquivo está inválido — \(reason)."
    case .invalidEntry(let from, let reason):
      return "a entrada '\(from)' está inválida — \(reason)."
    }
  }
}
