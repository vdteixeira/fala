import Foundation
import Testing

@testable import FalaKit

/// Parsing the "Adicionar termo" field.
///
/// The mockup draws one text field and a list of single words, because it
/// imagined the dictionary as a list of terms to preserve. It is a list of
/// `from → to` substitutions, and a button that could only add rules where
/// `from == to` would add rules that correct nothing. The field therefore
/// accepts a separator, and this suite pins what it does with each shape.
@Suite("DictionaryTermInput")
struct DictionaryTermInputTests {

  private static func parse(
    _ raw: String,
    existing: [DictionaryTerm] = []
  ) -> DictionaryTermInput {
    DictionaryTermInput.parse(raw, existing: existing)
  }

  private static func accepted(_ raw: String) -> JargonEntry? {
    guard case .accepted(let entry) = parse(raw) else { return nil }
    return entry
  }

  @Test("A bare term pins its own spelling")
  func bareTermPinsSpelling() {
    let entry = Self.accepted("Kubernetes")
    #expect(entry?.from == "Kubernetes")
    #expect(entry?.to == "Kubernetes")
    #expect(entry?.safety == .safe)
  }

  /// The shape that actually fixes ASR output. All three separators, because the
  /// user types on a Brazilian keyboard: `=` is one key, `->` is what people
  /// type, `→` is what the list prints back at them.
  @Test("Every separator splits heard from written, and both sides are trimmed")
  func separatorsSplit() {
    let shapes = [
      "cubernetes = Kubernetes",
      "cubernetes -> Kubernetes",
      "cubernetes → Kubernetes",
      "  cubernetes  =  Kubernetes  ",
    ]
    for raw in shapes {
      let entry = Self.accepted(raw)
      #expect(entry?.from == "cubernetes", "failed for \(raw)")
      #expect(entry?.to == "Kubernetes", "failed for \(raw)")
    }
  }

  @Test("Empty input, half a rule, and two separators are all refused in pt-BR")
  func malformedInputIsRefused() {
    let refusals = ["", "   ", "= Kubernetes", "cubernetes =", "a = b = c"]
    for raw in refusals {
      guard case .rejected(let reason) = Self.parse(raw) else {
        Issue.record("'\(raw)' should be refused")
        continue
      }
      #expect(!reason.isEmpty)
    }
  }

  /// `mergeKey` is the matcher's own identity. Empty means the text has no
  /// letters or digits at all, so no transcript could ever match it — an entry
  /// that would sit in the file forever doing nothing.
  @Test("A term with no letters or digits cannot match anything, so it is refused")
  func unmatchableTermIsRefused() {
    guard case .rejected(let reason) = Self.parse("!!! ???") else {
      Issue.record("punctuation should be refused")
      return
    }
    #expect(reason.contains("letras"))
    guard case .rejected = Self.parse("deploy = ---") else {
      Issue.record("an unwritable replacement should be refused")
      return
    }
  }

  @Test("Adding a rule that is already in the list, unchanged, is refused")
  func exactDuplicateIsRefused() {
    let existing = [
      DictionaryTerm(id: "cubernetes", from: "cubernetes", to: "Kubernetes", origin: .bundled)
    ]
    guard case .rejected(let reason) = Self.parse("cubernetes = Kubernetes", existing: existing)
    else {
      Issue.record("an exact duplicate should be refused")
      return
    }
    #expect(reason.contains("já está na lista"))
  }

  /// Overriding a bundled rule by identity is the DOCUMENTED way to win against
  /// it (`JargonOverride`, rule 2). Refusing it as a duplicate would take the
  /// escape hatch away.
  @Test("Changing what an existing rule writes is accepted, not refused")
  func overridingAnExistingRuleIsAllowed() {
    let existing = [
      DictionaryTerm(id: "cubernetes", from: "cubernetes", to: "Kubernetes", origin: .bundled)
    ]
    guard case .accepted(let entry) = Self.parse("cubernetes = K8s", existing: existing) else {
      Issue.record("an override should be accepted")
      return
    }
    #expect(entry.to == "K8s")
  }

  /// Identity is case- and accent-insensitive, exactly like the matcher, so a
  /// user retyping "Posterg" is told it is already there.
  @Test("Duplicate detection folds case and accents, like the matcher")
  func duplicateDetectionFolds() {
    let existing = [
      DictionaryTerm(id: "posterg", from: "posterg", to: "Postgres", origin: .bundled)
    ]
    guard case .rejected = Self.parse("Pósterg = Postgres", existing: existing) else {
      Issue.record("a folded duplicate should be refused")
      return
    }
  }
}

@Suite("DictionaryTerm")
struct DictionaryTermTests {

  /// The mockup prints one word per row. A row reading only "deploy" cannot say
  /// whether deleting it stops a correction or removes a word, so a substitution
  /// shows both sides — in the one mono line the mockup draws.
  @Test("A substitution shows both sides; a spelling rule shows the term alone")
  func displayTextTellsThemApart() {
    let substitution = DictionaryTerm(
      entry: JargonEntry(from: "cubernetes", to: "Kubernetes"), origin: .bundled)
    #expect(substitution.displayText == "cubernetes → Kubernetes")
    #expect(!substitution.isSpellingOnly)

    let spelling = DictionaryTerm(
      entry: JargonEntry(from: "Kubernetes", to: "Kubernetes"), origin: .user)
    #expect(spelling.displayText == "Kubernetes")
    #expect(spelling.isSpellingOnly)
  }

  /// A rule that only normalises casing or accents is a spelling rule, not a
  /// correction — the row must not print "posterg → Posterg" as though it were.
  @Test("Casing and accents alone still count as a spelling rule")
  func foldedIdentityIsSpellingOnly() {
    let term = DictionaryTerm(
      entry: JargonEntry(from: "kubernetes", to: "Kubernetes"), origin: .user)
    #expect(term.isSpellingOnly)
    #expect(term.displayText == "Kubernetes")
  }

  @Test("The row identity is the merge key, so it matches back to the rule")
  func identityIsTheMergeKey() {
    let term = DictionaryTerm(entry: JargonEntry(from: "Com  Pose", to: "Compose"), origin: .user)
    #expect(term.id == JargonDictionary.mergeKey(for: "com pose"))
  }
}

@Suite("DictionaryPanePresenter")
@MainActor
struct DictionaryPanePresenterTests {

  /// A fresh directory per test: nothing here may touch the developer's own
  /// `~/Library/Application Support/Fala/it-jargon.json`.
  private static func makeStore() -> JargonDictionaryStore {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fala-dictionary-\(UUID().uuidString)", isDirectory: true)
    return JargonDictionaryStore(directory: directory)
  }

  private static func remove(_ store: JargonDictionaryStore) {
    try? FileManager.default.removeItem(at: store.directory)
  }

  // MARK: - Reading

  @Test("The list opens on the bundled rules, all of them attributed to the app")
  func listStartsFromTheBundledRules() {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    #expect(!presenter.terms.isEmpty)
    let allBundled = presenter.terms.allSatisfy { $0.isBundled }
    #expect(allBundled)
    #expect(!presenter.hasUserOverride)
    #expect(presenter.pane.caption == "Termos técnicos preservados na transcrição (PT-EN):")
  }

  /// `risky` rules never fire. Listing them under a caption that says
  /// "preservados na transcrição" would be false, and giving them a trash icon
  /// would invite the user to switch off something already inert.
  @Test("Inert risky rules are not listed")
  func riskyRulesAreNotListed() throws {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let bundled = try JargonDictionary.loadDefault(includeRisky: true).entries
    let risky = bundled.filter { $0.safety == .risky }
    try #require(!risky.isEmpty, "the bundled file is expected to carry risky rules")

    let presenter = DictionaryPanePresenter(store: store)
    let listed = Set(presenter.terms.map(\.id))
    for entry in risky {
      #expect(!listed.contains(JargonDictionary.mergeKey(for: entry.from)))
    }
  }

  // MARK: - Adding

  /// THE test that the button does something. Not "the array grew": the
  /// dictionary handed to the app afterwards actually rewrites the transcript.
  @Test("An added term reaches a dictionary that rewrites the text")
  func addedTermChangesTranscripts() {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    var delivered: JargonDictionary?
    presenter.onDictionaryChanged = { delivered = $0 }

    presenter.draft = "terraformi = Terraform"
    #expect(presenter.addTerm())
    #expect(delivered?.apply(to: "subi o terraformi ontem") == "subi o Terraform ontem")
    #expect(presenter.draft.isEmpty)
    #expect(presenter.status == "'Terraform' adicionado.")
    #expect(presenter.isStatusAProblem == false)
  }

  /// The write goes to the file the APP reads, not to memory: a second store
  /// pointed at the same directory has to see it, and `load()` — the startup
  /// path — has to merge it.
  @Test("An added term is on disk and survives into the startup load")
  func addedTermPersists() throws {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    presenter.draft = "terraformi = Terraform"
    #expect(presenter.addTerm())

    let reopened = DictionaryPanePresenter(store: JargonDictionaryStore(directory: store.directory))
    #expect(reopened.terms.contains { $0.to == "Terraform" && $0.origin == .user })

    let status = try JargonDictionaryStore(directory: store.directory).load()
    #expect(status.merge?.added == 1)
    #expect(status.dictionary.apply(to: "o terraformi subiu") == "o Terraform subiu")
  }

  @Test("A refused term reports why and leaves the file untouched")
  func refusedTermChangesNothing() {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    presenter.draft = "!!!"
    #expect(!presenter.addTerm())
    #expect(presenter.isStatusAProblem)
    #expect(presenter.draft == "!!!")
    #expect(!presenter.hasUserOverride)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
  }

  @Test("Overriding a bundled rule says so, and the override wins")
  func overridingABundledRuleIsAnnounced() {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    var delivered: JargonDictionary?
    presenter.onDictionaryChanged = { delivered = $0 }

    presenter.draft = "posterg = PostgreSQL"
    #expect(presenter.addTerm())
    #expect(presenter.status?.contains("substitui a regra de fábrica") == true)
    #expect(delivered?.apply(to: "o posterg caiu") == "o PostgreSQL caiu")
    // Replaced in place, not appended: the list must not show the rule twice.
    let matches = presenter.terms.filter { $0.id == JargonDictionary.mergeKey(for: "posterg") }
    #expect(matches.count == 1)
    #expect(matches.first?.origin == .user)
  }

  // MARK: - Removing

  /// Removing a bundled rule cannot delete anything — the rule lives in the app
  /// bundle. It has to become a `disable`, and that has to reach the merge.
  @Test("Removing a bundled rule switches it off for real")
  func removingABundledRuleDisablesIt() throws {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    let key = JargonDictionary.mergeKey(for: "posterg")
    let target = try #require(presenter.terms.first { $0.id == key })
    #expect(target.isBundled)

    #expect(presenter.remove(target))
    #expect(!presenter.terms.contains { $0.id == key })

    let status = try JargonDictionaryStore(directory: store.directory).load()
    #expect(status.merge?.disabled == 1)
    #expect(status.dictionary.apply(to: "o posterg caiu") == "o posterg caiu")
  }

  @Test("Removing a term the user added takes it out of their entries")
  func removingAUserRuleDeletesIt() throws {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    presenter.draft = "terraformi = Terraform"
    #expect(presenter.addTerm())
    let added = try #require(presenter.terms.first { $0.to == "Terraform" && $0.origin == .user })
    #expect(presenter.remove(added))
    #expect(!presenter.terms.contains { $0.from == "terraformi" })
    #expect(!presenter.hasUserOverride)
  }

  /// Re-adding a term that was switched off must switch it back ON, not leave a
  /// `disable` behind that would delete the entry the user just typed —
  /// `disable` is applied LAST and wins over an entry with the same identity.
  @Test("Re-adding a rule that was switched off brings it back")
  func reAddingClearsTheDisable() throws {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    var delivered: JargonDictionary?
    presenter.onDictionaryChanged = { delivered = $0 }

    let key = JargonDictionary.mergeKey(for: "posterg")
    let target = try #require(presenter.terms.first { $0.id == key })
    #expect(presenter.remove(target))
    presenter.draft = "posterg = Postgres"
    #expect(presenter.addTerm())
    #expect(presenter.terms.contains { $0.id == key })
    #expect(delivered?.apply(to: "o posterg caiu") == "o Postgres caiu")
  }

  // MARK: - Undo

  /// The mockup has no undo, and a delete with no way back is exactly what a
  /// list of forty rules and one trash icon per row invites.
  @Test("Undo restores the previous file, once")
  func undoRestoresTheFile() {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    let before = presenter.terms.count
    let target = presenter.terms[0]

    #expect(presenter.remove(target))
    #expect(presenter.terms.count == before - 1)
    #expect(presenter.pane.canUndo)

    #expect(presenter.undo())
    #expect(presenter.terms.count == before)
    #expect(presenter.terms.contains { $0.id == target.id })
    #expect(!presenter.pane.canUndo)
    #expect(!presenter.undo())
  }

  @Test("Undo is offered only after a change")
  func undoIsNotOfferedUpFront() {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    #expect(!DictionaryPanePresenter(store: store).pane.canUndo)
  }

  /// Reopening the tab re-reads a file the user may have edited in a text
  /// editor since the last action. An undo captured before that edit would
  /// restore the pre-edit override and discard their work with no warning, so
  /// the pending undo is dropped — along with the status line, which would
  /// otherwise report what happened the last time the window was open.
  @Test("Reloading drops the pending undo and the stale status")
  func reloadDropsUndoAndStatus() throws {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    let target = try #require(presenter.terms.first)
    #expect(presenter.remove(target))
    #expect(presenter.pane.canUndo)
    #expect(presenter.status != nil)

    presenter.reload()
    #expect(!presenter.pane.canUndo)
    #expect(presenter.status == nil)
    // The change itself survives — only the way back is gone.
    #expect(!presenter.terms.contains { $0.id == target.id })
  }

  // MARK: - The add button

  @Test("The add button is live only for text that would produce a rule")
  func addButtonTracksTheDraft() {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    #expect(!presenter.pane.canAdd)
    presenter.draft = "  "
    #expect(!presenter.pane.canAdd)
    presenter.draft = "terraformi = Terraform"
    #expect(presenter.pane.canAdd)
  }

  // MARK: - Files

  /// Export writes the user's own override; import puts one back. Round-tripping
  /// through both is the only thing that proves the two halves agree.
  @Test("Export then import restores the same list")
  func exportImportRoundTrip() throws {
    let source = Self.makeStore()
    let destination = Self.makeStore()
    defer {
      Self.remove(source)
      Self.remove(destination)
    }
    let presenter = DictionaryPanePresenter(store: source)
    presenter.draft = "terraformi = Terraform"
    #expect(presenter.addTerm())
    let bundledRow = try #require(presenter.terms.first { $0.isBundled })
    #expect(presenter.remove(bundledRow))

    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("fala-export-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let exported = presenter.export(to: file)
    #expect(exported?.entryCount == 1)
    #expect(exported?.disabledCount == 1)

    let other = DictionaryPanePresenter(store: destination)
    let imported = other.importOverride(from: file)
    #expect(imported?.entryCount == 1)
    #expect(imported?.disabledCount == 1)
    #expect(other.terms.map(\.id) == presenter.terms.map(\.id))
    #expect(other.status?.contains("Importado") == true)
  }

  @Test("Importing something that is not a dictionary reports it and keeps the file")
  func badImportIsRefused() throws {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    presenter.draft = "terraformi = Terraform"
    #expect(presenter.addTerm())
    let before = try Data(contentsOf: store.fileURL)

    let junk = FileManager.default.temporaryDirectory
      .appendingPathComponent("fala-junk-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: junk) }
    try Data("{ nope".utf8).write(to: junk)

    #expect(presenter.importOverride(from: junk) == nil)
    #expect(presenter.isStatusAProblem)
    #expect(try Data(contentsOf: store.fileURL) == before)
    #expect(presenter.terms.contains { $0.to == "Terraform" })
  }

  @Test("Importing a file that does not exist is reported, not crashed on")
  func missingImportFileIsReported() {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    let missing = store.directory.appendingPathComponent("nao-existe.json")
    #expect(presenter.importOverride(from: missing) == nil)
    #expect(presenter.isStatusAProblem)
  }

  /// An import replaces, so the window has to know when it would destroy
  /// something. This flag is the only signal it has.
  @Test("The window can tell whether an import would destroy anything")
  func hasUserOverrideTracksTheFile() {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    let presenter = DictionaryPanePresenter(store: store)
    #expect(!presenter.hasUserOverride)
    presenter.draft = "terraformi = Terraform"
    #expect(presenter.addTerm())
    #expect(presenter.hasUserOverride)
  }

  // MARK: - A broken file

  /// The app is running on the bundled rules right now, so an empty list would
  /// be a second lie on top of the syntax error.
  @Test("A broken user file is reported, and the bundled rules stay on screen")
  func brokenUserFileIsReported() throws {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    try FileManager.default.createDirectory(
      at: store.directory, withIntermediateDirectories: true)
    try Data("{ \"entries\": [ ".utf8).write(to: store.fileURL)

    let presenter = DictionaryPanePresenter(store: store)
    #expect(presenter.isStatusAProblem)
    #expect(presenter.status?.contains("Corrija o arquivo") == true)
    #expect(!presenter.terms.isEmpty)
    let allBundled = presenter.terms.allSatisfy { $0.isBundled }
    #expect(allBundled)
  }

  /// Refusing to write beats overwriting: the file may hold terms the user spent
  /// time on, and a syntax error is recoverable in an editor.
  @Test("An entry the app could not load is never written to disk")
  func invalidEntriesAreNeverWritten() {
    let store = Self.makeStore()
    defer { Self.remove(store) }
    // `contextual` with no context words is the configuration error
    // `JargonDictionary` rejects at load time.
    let broken = JargonOverride(
      entries: [JargonEntry(from: "compos", to: "Compose", safety: .contextual)])
    #expect(throws: JargonEditError.self) { try store.saveUserOverride(broken) }
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
  }

  /// THE data-loss regression. A user file that fails to parse leaves the
  /// in-memory override EMPTY; committing any edit then wrote that emptiness
  /// atomically over a file that still held the user's rules — unrecoverable,
  /// no backup. The status line already said the file was broken; nothing acted
  /// on it. Every mutation must now refuse.
  @Test("A broken user file cannot be overwritten by an edit")
  func brokenUserFileRefusesEdits() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fala-broken-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Valid-looking, but missing a closing brace.
    let broken = """
      { "entries": [ { "from": "cubernetes", "to": "Kubernetes" }
      """
    let file = directory.appendingPathComponent(JargonDictionaryStore.fileName)
    try broken.write(to: file, atomically: true, encoding: .utf8)

    let presenter = DictionaryPanePresenter(store: JargonDictionaryStore(directory: directory))
    presenter.reload()

    #expect(presenter.isStatusAProblem)
    #expect(!presenter.isSourceUsable)

    // Every mutation path must refuse, and the bytes on disk must be untouched.
    if let first = presenter.terms.first {
      #expect(presenter.remove(first) == false)
    }
    presenter.draft = "posterg = Postgres"
    #expect(presenter.addTerm() == false)

    let after = try String(contentsOf: file, encoding: .utf8)
    #expect(after == broken)
  }
}
