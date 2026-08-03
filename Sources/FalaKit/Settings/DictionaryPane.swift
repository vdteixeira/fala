import Foundation
import Observation

/// Every fixed string of Ajustes › Dicionário (mockup: the DICIONÁRIO section).
public enum DictionaryPaneStrings {
  /// Shown when an edit is refused because the file on disk cannot be parsed.
  /// Names the file so the user can go fix it; refuses rather than overwriting,
  /// because the unreadable file may hold rules they spent time on.
  public static let refusedBecauseFileUnreadable =
    "Não dá para editar enquanto o arquivo estiver com erro. "
    + "Corrija it-jargon.json e reabra os Ajustes."

  /// The mockup's caption, verbatim.
  public static let caption = "Termos técnicos preservados na transcrição (PT-EN):"

  /// The mockup's placeholder, verbatim.
  public static let addPlaceholder = "Adicionar termo…"
  public static let addButton = "Adicionar termo"
  /// The line under the field. The mockup has none, because it drew the
  /// dictionary as a list of words; the dictionary is a list of SUBSTITUTIONS,
  /// and the field has to say how to write one.
  public static let addHint =
    "Um termo por linha. Para corrigir o que o \(MenuBarStrings.brandName) ouve errado, escreva "
    + "“como ele ouve = como escrever”."

  public static let removeHelp = "Remover do dicionário"
  public static let importButton = "Importar JSON"
  public static let exportButton = "Exportar JSON"
  public static let undo = "Desfazer"
  public static let empty = "Nenhum termo ainda."

  /// Shown next to a rule that came from the bundled dictionary, so "remover"
  /// reads as what it is — switching a factory rule off, reversibly, rather than
  /// deleting something the user typed.
  public static let bundledBadge = "de fábrica"

  public static func removed(_ term: String) -> String {
    "'\(term)' removido."
  }

  public static func added(_ term: String) -> String {
    "'\(term)' adicionado."
  }

  public static func replacedBundled(_ term: String) -> String {
    "'\(term)' adicionado — substitui a regra de fábrica com o mesmo termo."
  }
}

/// Where one rule in the list came from. Drives what "remover" has to write, and
/// nothing else.
public enum DictionaryTermOrigin: Sendable, Equatable {
  /// Declared in the bundled `it-jargon.json`. Removing it appends its `from` to
  /// the override's `disable`, which is reversible by undo or by editing the file.
  case bundled
  /// Declared by the user. Removing it takes the entry out of `entries`.
  case user
}

/// One row of the jargon list.
public struct DictionaryTerm: Sendable, Equatable, Identifiable {
  /// `JargonDictionary.mergeKey(for:)` — the same identity the merge uses, so a
  /// row can be matched back to the rule it came from without string guessing.
  public let id: String
  public let from: String
  public let to: String
  public let origin: DictionaryTermOrigin

  public init(id: String, from: String, to: String, origin: DictionaryTermOrigin) {
    self.id = id
    self.from = from
    self.to = to
    self.origin = origin
  }

  public init(entry: JargonEntry, origin: DictionaryTermOrigin) {
    self.init(
      id: JargonDictionary.mergeKey(for: entry.from),
      from: entry.from,
      to: entry.to,
      origin: origin)
  }

  /// What the mono label shows.
  ///
  /// The mockup prints a single word per row, because it imagined the dictionary
  /// as a list of terms to preserve. It is a list of `from → to` substitutions,
  /// and a row reading only "deploy" cannot say whether deleting it stops a
  /// correction or removes a word. So a rule that rewrites one spelling into
  /// another shows both, in the one mono line the mockup draws; a rule that only
  /// pins a spelling shows the term alone, exactly as drawn.
  public var displayText: String {
    isSpellingOnly ? to : "\(from) → \(to)"
  }

  /// True when the rule only normalises casing/accents of a term (`from` and
  /// `to` are the same word).
  public var isSpellingOnly: Bool {
    JargonDictionary.mergeKey(for: from) == JargonDictionary.mergeKey(for: to)
  }

  public var isBundled: Bool { origin == .bundled }

  public var accessibilityLabel: String {
    isSpellingOnly ? to : "\(from), escrito \(to)"
  }
}

/// What parsing the "Adicionar termo" field produced.
public enum DictionaryTermInput: Sendable, Equatable {
  case accepted(JargonEntry)
  /// pt-BR reason. The field keeps its text so the user can fix it.
  case rejected(reason: String)
}

extension DictionaryTermInput {

  /// The separators the field accepts between "what Fala hears" and "what to
  /// write". Three of them because the user types on a Brazilian keyboard: `=`
  /// is one key, `->` is what people type when they mean an arrow, and `→` is
  /// what this app prints back at them in the list.
  static let separators: [String] = ["=", "→", "->"]

  /// Parses one line of the field.
  ///
  /// Two shapes, both from the mockup's own caption ("termos técnicos
  /// preservados"):
  ///
  /// - `Kubernetes` — pin the spelling. Becomes `from: "Kubernetes", to:
  ///   "Kubernetes"`, which rewrites any casing or accent variant to exactly
  ///   that. Harmless for an all-lowercase word, because `JargonDictionary`
  ///   already inherits a sentence-initial capital for a lowercase replacement.
  /// - `cubernetes = Kubernetes` — correct a misrendering. This is the shape
  ///   that actually fixes ASR output, and without it the button could only ever
  ///   add rules that change nothing.
  ///
  /// `existing` is the list currently on screen. A line that repeats a rule
  /// already there verbatim is refused; a line that changes what an existing
  /// rule writes is ACCEPTED — overriding a bundled rule by identity is the
  /// documented way to win against it (`JargonOverride`, rule 2).
  public static func parse(_ raw: String, existing: [DictionaryTerm]) -> DictionaryTermInput {
    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else {
      return .rejected(reason: "Digite um termo.")
    }

    var from = line
    var to = line
    if let separator = separators.first(where: { line.contains($0) }) {
      let halves = line.components(separatedBy: separator)
      guard halves.count == 2 else {
        return .rejected(reason: "Use um separador só: “ouvido = escrito”.")
      }
      from = halves[0].trimmingCharacters(in: .whitespacesAndNewlines)
      to = halves[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !from.isEmpty, !to.isEmpty else {
        return .rejected(reason: "Escreva os dois lados: “ouvido = escrito”.")
      }
    }

    // `mergeKey` is the matcher's own notion of identity: empty means the text
    // has no letters or digits at all, so nothing could ever match it.
    let key = JargonDictionary.mergeKey(for: from)
    guard !key.isEmpty else {
      return .rejected(reason: "Um termo precisa ter letras ou números.")
    }
    guard !JargonDictionary.mergeKey(for: to).isEmpty else {
      return .rejected(reason: "A forma escrita precisa ter letras ou números.")
    }
    if let duplicate = existing.first(where: { $0.id == key }), duplicate.to == to {
      return .rejected(reason: "Esse termo já está na lista.")
    }
    return .accepted(JargonEntry(from: from, to: to))
  }
}

/// Everything Ajustes › Dicionário renders, as one value.
public struct DictionaryPane: Sendable, Equatable {
  public let terms: [DictionaryTerm]
  public let draft: String
  /// The status line under the list: what the last action did, or why it did not.
  public let status: String?
  public let isStatusAProblem: Bool
  /// True when the last change can still be taken back.
  public let canUndo: Bool

  public init(
    terms: [DictionaryTerm],
    draft: String,
    status: String?,
    isStatusAProblem: Bool,
    canUndo: Bool
  ) {
    self.terms = terms
    self.draft = draft
    self.status = status
    self.isStatusAProblem = isStatusAProblem
    self.canUndo = canUndo
  }

  public var caption: String { DictionaryPaneStrings.caption }
  public var isEmpty: Bool { terms.isEmpty }
  public var termSymbol: String { FalaSymbol.dictionary }
  public var removeSymbol: String { FalaSymbol.delete }
  public var importSymbol: String { FalaSymbol.importJSON }
  public var exportSymbol: String { FalaSymbol.exportJSON }

  /// The add button is live only for text that would produce a rule.
  public var canAdd: Bool {
    guard case .accepted = DictionaryTermInput.parse(draft, existing: terms) else {
      return false
    }
    return true
  }
}

/// Owns the user's override while the window is open, and writes every change
/// straight through to the file the app reads.
///
/// ## Why every action writes immediately
///
/// There is no Save button in the mockup and there should not be one: the file
/// is the source of truth, `doctor` reads it, and the user may have it open in
/// an editor at the same time. Holding edits in memory would mean two versions
/// of the dictionary — the one on screen and the one dictation is using — with
/// no way for the user to tell which is in force. So each action is a complete
/// read-modify-write, and `undo` is a single-level restore of the override the
/// last one replaced.
///
/// Changes take effect on the NEXT dictation: `DictationCoordinator` is
/// constructed with a `JargonDictionary` value, so the app must rebuild or
/// re-inject one for a change to reach a running pipeline. That is the window
/// controller's wiring, and `onDictionaryChanged` is where it hooks in.
@MainActor
@Observable
public final class DictionaryPanePresenter {

  public private(set) var terms: [DictionaryTerm] = []
  public private(set) var status: String?
  public private(set) var isStatusAProblem = false
  public var draft: String = ""

  /// The override before the last change, for `undo()`. Single level on purpose:
  /// the file is editable by hand, so a deep stack would let the window restore
  /// something the user changed underneath it.
  @ObservationIgnored private var undoState: JargonOverride?

  @ObservationIgnored private var override = JargonOverride()
  @ObservationIgnored private var bundled: [JargonEntry] = []
  @ObservationIgnored private let store: JargonDictionaryStore

  /// Called after every successful write, with the merged dictionary the app
  /// should now be using. Wire it, or edits here do nothing until the next
  /// launch.
  @ObservationIgnored public var onDictionaryChanged: ((JargonDictionary) -> Void)?

  public init(store: JargonDictionaryStore = JargonDictionaryStore()) {
    self.store = store
    reload()
  }

  public var pane: DictionaryPane {
    DictionaryPane(
      terms: terms,
      draft: draft,
      status: status,
      isStatusAProblem: isStatusAProblem,
      canUndo: undoState != nil)
  }

  /// True when the user's file has something in it — what the window checks
  /// before letting an import replace it.
  public var hasUserOverride: Bool { !override.isEmpty }

  // MARK: - Reading

  /// Re-reads the bundled dictionary and the user's file. Called when the tab
  /// appears, so an edit made in a text editor shows up here.
  ///
  /// Drops the pending undo, and it must: the file may have been changed in an
  /// editor since the last action, and restoring an override captured before
  /// that would discard the user's own edit with no warning at all. Also clears
  /// the status line, so reopening the window does not show what happened the
  /// last time it was open.
  /// False while the user's override file cannot be parsed. Every mutation is
  /// refused until it can: the in-memory override is empty in that state, and
  /// committing it would atomically replace a file that still holds the user's
  /// rules. The view also dims the controls, but this is the enforcement.
  public private(set) var isSourceUsable = true

  public func reload() {
    undoState = nil
    report(nil, isProblem: false)
    isSourceUsable = true
    bundled = (try? JargonDictionary.loadDefault(includeRisky: true))?.entries ?? []
    do {
      override = try store.loadUserOverride()
      rebuildTerms()
    } catch let error as JargonDictionaryError {
      // The list is still drawn from the bundled rules: the app is running on
      // them right now, and showing an empty list would imply the user has no
      // dictionary at all.
      override = JargonOverride()
      rebuildTerms()
      // The in-memory override is now EMPTY, so any edit committed from here
      // would write that emptiness over a file that still holds the user's
      // rules — atomically, with no backup. Editing is refused until the file
      // parses, which is what this type's own header already promised
      // ("Reported instead of overwriting: the file may hold terms the user
      // spent time on") but did not enforce.
      isSourceUsable = false
      report(JargonEditError.sourceUnusable(error).message, isProblem: true)
    } catch {
      override = JargonOverride()
      rebuildTerms()
      isSourceUsable = false
    }
  }

  private func rebuildTerms() {
    let userKeys = Set(override.entries.map { JargonDictionary.mergeKey(for: $0.from) })
    // `risky` rules are excluded from the list because they are excluded from
    // the matcher: they never fire, so showing them under a caption that says
    // "preservados na transcrição" would be false, and giving them a trash icon
    // would invite the user to switch off something already inert. They stay in
    // `bundled` for merging, so re-declaring one as `safe` still overrides it by
    // identity — the documented escape hatch in `JargonOverride`.
    terms = override.merged(over: bundled).entries
      .filter { $0.safety != .risky }
      .map { entry in
        let key = JargonDictionary.mergeKey(for: entry.from)
        return DictionaryTerm(entry: entry, origin: userKeys.contains(key) ? .user : .bundled)
      }
  }

  // MARK: - Changing

  /// Adds whatever is in `draft`.
  @discardableResult
  public func addTerm() -> Bool {
    switch DictionaryTermInput.parse(draft, existing: terms) {
    case .rejected(let reason):
      report(reason, isProblem: true)
      return false
    case .accepted(let entry):
      let key = JargonDictionary.mergeKey(for: entry.from)
      let replacesBundled = bundled.contains {
        JargonDictionary.mergeKey(for: $0.from) == key
      }
      // Re-adding a term the user had switched off means switching it back on,
      // not carrying a `disable` that would delete the entry they just wrote.
      let next = JargonOverride(
        entries: override.entries.filter {
          JargonDictionary.mergeKey(for: $0.from) != key
        } + [entry],
        disable: override.disable.filter { JargonDictionary.mergeKey(for: $0) != key })
      guard commit(next, undoable: true) else { return false }
      draft = ""
      report(
        replacesBundled
          ? DictionaryPaneStrings.replacedBundled(entry.to)
          : DictionaryPaneStrings.added(entry.to),
        isProblem: false)
      return true
    }
  }

  /// Removes one row. A user rule leaves `entries`; a bundled rule joins
  /// `disable`, which is what "off" means for something the app ships.
  @discardableResult
  public func remove(_ term: DictionaryTerm) -> Bool {
    let key = term.id
    let entries = override.entries.filter { JargonDictionary.mergeKey(for: $0.from) != key }
    var disable = override.disable
    let stillInBundled = bundled.contains { JargonDictionary.mergeKey(for: $0.from) == key }
    if stillInBundled, !disable.contains(where: { JargonDictionary.mergeKey(for: $0) == key }) {
      disable.append(term.from)
    }
    guard commit(JargonOverride(entries: entries, disable: disable), undoable: true) else {
      return false
    }
    report(DictionaryPaneStrings.removed(term.displayText), isProblem: false)
    return true
  }

  /// Puts back the override the last change replaced.
  @discardableResult
  public func undo() -> Bool {
    guard let undoState else { return false }
    guard commit(undoState, undoable: false) else { return false }
    self.undoState = nil
    report(nil, isProblem: false)
    return true
  }

  // MARK: - Files

  /// Writes the user's own override to `url` (the save panel's destination).
  @discardableResult
  public func export(to url: URL) -> JargonExportSummary? {
    do {
      let summary = try store.exportUserOverride(to: url)
      report(summary.message, isProblem: false)
      return summary
    } catch let error as JargonExportError {
      report(Self.message(for: error), isProblem: true)
      return nil
    } catch {
      report(JargonEditError.cannotWrite(file: url.lastPathComponent).message, isProblem: true)
      return nil
    }
  }

  /// Replaces the user's file with `url`'s contents.
  ///
  /// The window must confirm first when `hasUserOverride` is true — this is a
  /// replacement, and the terms it drops are not recoverable from here.
  @discardableResult
  public func importOverride(from url: URL) -> JargonImportSummary? {
    let previous = override
    do {
      let summary = try store.importUserOverride(from: url)
      override = (try? store.loadUserOverride()) ?? override
      rebuildTerms()
      undoState = previous
      notifyDictionaryChanged()
      report(summary.message, isProblem: false)
      return summary
    } catch let error as JargonEditError {
      report(error.message, isProblem: true)
      return nil
    } catch {
      let failure = JargonEditError.importUnusable(.unreadable(file: url.lastPathComponent))
      report(failure.message, isProblem: true)
      return nil
    }
  }

  // MARK: - Plumbing

  /// Writes `next`, adopts it only if the write succeeded, and reports a failure
  /// otherwise. The in-memory list never gets ahead of the file.
  private func commit(_ next: JargonOverride, undoable: Bool) -> Bool {
    // Single choke point: every mutation (add, remove, import, undo) ends here,
    // so refusing here cannot be bypassed by a caller that forgot to check.
    guard isSourceUsable else {
      report(DictionaryPaneStrings.refusedBecauseFileUnreadable, isProblem: true)
      return false
    }
    let previous = override
    do {
      try store.saveUserOverride(next)
    } catch let error as JargonEditError {
      report(error.message, isProblem: true)
      return false
    } catch {
      let failure = JargonEditError.cannotWrite(file: JargonDictionaryStore.fileName)
      report(failure.message, isProblem: true)
      return false
    }
    override = next
    if undoable { undoState = previous }
    rebuildTerms()
    notifyDictionaryChanged()
    return true
  }

  private func notifyDictionaryChanged() {
    guard let onDictionaryChanged else { return }
    let merged = override.merged(over: bundled)
    guard let dictionary = try? JargonDictionary(entries: merged.entries) else { return }
    onDictionaryChanged(dictionary)
  }

  private func report(_ message: String?, isProblem: Bool) {
    status = message
    isStatusAProblem = isProblem
  }

  private static func message(for error: JargonExportError) -> String {
    switch error {
    case .sourceUnusable(let cause):
      return JargonEditError.sourceUnusable(cause).message
    case .cannotWrite(let file):
      return JargonEditError.cannotWrite(file: file).message
    }
  }
}
