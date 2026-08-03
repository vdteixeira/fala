import Foundation
import Testing
import os

@testable import FalaKit

// The history window's model and its re-injection path (TASKS.md T2.12).
//
// The window itself is not testable without a GUI (see the `swift-testing`
// skill), so everything that decides anything lives in `HistoryWindowModel` /
// `TranscriptReinjector` and is exercised here through fakes: no real store, no
// real pasteboard, no second running application, no Accessibility.

// MARK: - Fixtures

private let editor = DestinationApp(bundleIdentifier: "com.microsoft.VSCode", name: "VS Code")
private let mail = DestinationApp(bundleIdentifier: "com.apple.mail", name: "Mail")
private let fala = DestinationApp(bundleIdentifier: "com.fala.app", name: "Fala")
private let ownBundleID: @Sendable () -> String? = { "com.fala.app" }

private var fixedCalendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.locale = Locale(identifier: "pt_BR")
  calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo") ?? .gmt
  return calendar
}

private func stamp(_ text: String) -> Date {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(identifier: "America/Sao_Paulo")
  formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
  guard let date = formatter.date(from: text) else {
    Issue.record("bad fixture date: \(text)")
    return Date(timeIntervalSince1970: 0)
  }
  return date
}

private let now = stamp("2026-08-03 18:00:00")
private let fixedClock: @Sendable () -> Date = { now }

private func made(
  _ text: String,
  at when: String = "2026-08-03 14:32:00",
  app: DestinationApp? = editor
) -> DictationHistoryEntry {
  DictationHistoryEntry(
    text: text, createdAt: stamp(when), duration: 3.4, destinationApp: app)
}

// MARK: - Fakes

/// The store, in memory. Implements the real seam so the model cannot tell the
/// difference; nothing here touches a file.
private actor FakeHistory: DictationHistoryManaging {
  private var entries: [DictationHistoryEntry]
  private let deleteError: DictationHistoryProblem?
  private let eraseError: DictationHistoryProblem?
  private let problem: DictationHistoryProblem?
  private(set) var eraseCount = 0
  private(set) var deletedIDs: [UUID] = []

  init(
    _ entries: [DictationHistoryEntry],
    deleteError: DictationHistoryProblem? = nil,
    eraseError: DictationHistoryProblem? = nil,
    problem: DictationHistoryProblem? = nil
  ) {
    self.entries = entries
    self.deleteError = deleteError
    self.eraseError = eraseError
    self.problem = problem
  }

  func recent(limit: Int) async -> [RecentTranscription] {
    entries.prefix(limit).map(\.recentTranscription)
  }

  func allEntries() async -> [DictationHistoryEntry] { entries }

  func delete(id: UUID) async throws {
    deletedIDs.append(id)
    if let deleteError { throw deleteError }
    entries.removeAll { $0.id == id }
  }

  func eraseAll() async throws {
    eraseCount += 1
    if let eraseError { throw eraseError }
    entries.removeAll()
  }

  func status() async -> DictationHistoryStatus {
    DictationHistoryStatus(
      entryCount: entries.count,
      maxEntries: 500,
      fileURL: URL(fileURLWithPath: "/tmp/fala-test/history.json"),
      fileExists: !entries.isEmpty,
      problem: problem)
  }
}

/// Records what was written without touching any real pasteboard.
private actor FakePasteboard: PasteboardAccessing {
  private let failsWrite: Bool
  private(set) var written: [String] = []

  init(failsWrite: Bool = false) { self.failsWrite = failsWrite }

  func currentChangeCount() async -> Int { 0 }
  func snapshot() async -> PasteboardSnapshot {
    PasteboardSnapshot(items: [], changeCount: 0)
  }
  func write(_ text: String) async throws -> Int {
    if failsWrite { throw InjectionError.pasteboardFailure(reason: "test") }
    written.append(text)
    return 1
  }
  func restore(_ snapshot: PasteboardSnapshot) async throws {}
}

/// The app's one `TextInjector`, faked. Records the text so a test can prove
/// re-injection sent the FULL transcript and not a preview of it.
private actor FakeInjector: TextInjector {
  private let error: InjectionError?
  private(set) var injected: [String] = []

  init(error: InjectionError? = nil) { self.error = error }

  func inject(_ text: String) async throws {
    injected.append(text)
    if let error { throw error }
  }

  var count: Int { injected.count }
}

private actor MutableFrontmost: FrontmostApplicationProviding {
  private var app: DestinationApp?
  private(set) var reads = 0

  init(_ app: DestinationApp?) { self.app = app }

  func current() async -> DestinationApp? {
    reads += 1
    return app
  }

  func set(_ app: DestinationApp?) { self.app = app }
}

private actor FakeActivator: ApplicationActivating {
  private let frontmost: MutableFrontmost
  private let becomes: DestinationApp?
  private let succeeds: Bool
  private(set) var requests: [String] = []

  /// - Parameter becomes: what the frontmost app turns into. `nil` models an
  ///   activation that REPORTS success but never brings the app forward.
  init(frontmost: MutableFrontmost, becomes: DestinationApp?, succeeds: Bool = true) {
    self.frontmost = frontmost
    self.becomes = becomes
    self.succeeds = succeeds
  }

  func activate(bundleIdentifier: String) async -> Bool {
    requests.append(bundleIdentifier)
    guard succeeds else { return false }
    if let becomes { await frontmost.set(becomes) }
    return true
  }
}

private struct InstantDelay: InjectionDelaying {
  func wait(for duration: Duration) async throws {}
  func waitIgnoringCancellation(for duration: Duration) async {}
}

/// Records every re-injection request, so the model's guards can be observed.
private actor FakeReinjector: TranscriptReinjecting {
  private let outcome: ReinjectOutcome
  private(set) var requests: [UUID] = []

  init(_ outcome: ReinjectOutcome = .injected(destination: "VS Code")) {
    self.outcome = outcome
  }

  func reinject(_ entry: DictationHistoryEntry) async -> ReinjectOutcome {
    requests.append(entry.id)
    return outcome
  }

  var count: Int { requests.count }
}

/// A history whose reads suspend, so `forget()` can land between `load()`'s two
/// awaits — the interleaving that used to repopulate the model after the window
/// was gone.
private actor SlowHistory: DictationHistoryManaging {
  private let entries: [DictationHistoryEntry]
  init(_ entries: [DictationHistoryEntry]) { self.entries = entries }

  func allEntries() async -> [DictationHistoryEntry] {
    await Task.yield()
    await Task.yield()
    return entries
  }
  func status() async -> DictationHistoryStatus {
    DictationHistoryStatus(
      entryCount: entries.count,
      maxEntries: 500,
      fileURL: URL(fileURLWithPath: "/tmp/fala-test/history.json"),
      fileExists: !entries.isEmpty,
      problem: nil)
  }
  func delete(id: UUID) async throws {}
  func eraseAll() async throws {}
  func recent(limit: Int) async -> [RecentTranscription] { [] }
}

@MainActor
private func makeModel(
  _ entries: [DictationHistoryEntry],
  history: FakeHistory? = nil,
  pasteboard: FakePasteboard = FakePasteboard(),
  reinjector: (any TranscriptReinjecting)? = nil
) -> HistoryWindowModel {
  HistoryWindowModel(
    history: history ?? FakeHistory(entries),
    pasteboard: pasteboard,
    reinjector: reinjector,
    calendar: fixedCalendar,
    clock: fixedClock)
}

// MARK: - Loading and grouping

@Suite("History window model")
@MainActor
struct HistoryWindowModelTests {

  @Test("nothing is read until load runs")
  func lazyLoad() async {
    let model = makeModel([made("oi")])
    #expect(!model.isLoaded)
    #expect(model.days.isEmpty)
    // Not "empty history" — the window must not flash that over a full store.
    #expect(model.emptyMessage == nil)
    await model.load()
    #expect(model.isLoaded)
    #expect(model.totalCount == 1)
  }

  @Test("load groups by day and reports the storage path")
  func loadGroups() async {
    let model = makeModel([
      made("hoje", at: "2026-08-03 14:00:00"),
      made("ontem", at: "2026-08-02 09:00:00"),
    ])
    await model.load()
    #expect(model.days.map(\.title) == ["Hoje", "Ontem"])
    #expect(model.countLine == "2 ditadas")
    #expect(model.storagePath?.hasSuffix("history.json") == true)
  }

  @Test("an empty store says so; a filtered-out list says something else")
  func emptyStates() async {
    let empty = makeModel([])
    await empty.load()
    #expect(empty.emptyMessage == DictationHistoryStrings.empty)
    #expect(!empty.isFilteredEmpty)

    let full = makeModel([made("revisar o código")])
    await full.load()
    full.setSearchText("kubernetes")
    #expect(full.emptyMessage == "Nenhum resultado para “kubernetes”.")
    #expect(full.isFilteredEmpty, "the window must offer Limpar busca here")
    #expect(full.totalCount == 1, "the entry still exists behind the filter")
  }

  @Test("search filters the sections, accent-insensitively, and counts both")
  func searchFilters() async {
    let model = makeModel([
      made("revisar o código", at: "2026-08-03 14:00:00"),
      made("marcar reunião", at: "2026-08-02 09:00:00"),
    ])
    await model.load()
    model.setSearchText("codigo")
    #expect(model.days.count == 1)
    #expect(model.days.first?.rows.first?.fullText == "revisar o código")
    #expect(model.matchCount == 1)
    #expect(model.countLine == "1 de 2 ditadas")
    #expect(model.isSearching)
  }

  @Test("clearing the search brings every section back")
  func clearSearch() async {
    let model = makeModel([made("um"), made("dois")])
    await model.load()
    model.setSearchText("um")
    #expect(model.matchCount == 1)
    model.clearSearch()
    #expect(model.matchCount == 2)
    #expect(!model.isSearching)
    #expect(model.searchText.isEmpty)
  }
}

// MARK: - Privacy

@Suite("History window privacy")
@MainActor
struct HistoryWindowPrivacyTests {

  private let secret = "minha senha do banco é bananas"

  /// The rule from CLAUDE.md, asserted rather than assumed: every string this
  /// surface can publish OUTSIDE the row itself is built from timestamps, app
  /// names and fixed pt-BR copy.
  @Test("no notice, count line or empty message can carry transcript text")
  func noticesNeverCarryTranscripts() async {
    let pasteboard = FakePasteboard()
    let model = makeModel(
      [made(secret)], pasteboard: pasteboard,
      reinjector: FakeReinjector(.injected(destination: "VS Code")))
    await model.load()

    let row = try? #require(model.days.first?.rows.first)
    guard let row else { return }

    await model.copy(row)
    #expect(model.notice?.message.contains("bananas") == false)
    await model.reinject(row)
    #expect(model.notice?.message.contains("bananas") == false)
    await model.delete(row)
    #expect(model.notice?.message.contains("bananas") == false)
    #expect(!model.countLine.contains("bananas"))
    #expect(model.emptyMessage?.contains("bananas") != true)
  }

  /// The search field echoes the QUERY back in the empty state, which is fine —
  /// it is on screen two points above. It must never echo an ENTRY.
  @Test("the empty-result message quotes the query, never a transcript")
  func emptyResultQuotesQueryOnly() async {
    let model = makeModel([made(secret)])
    await model.load()
    model.setSearchText("kubernetes")
    #expect(model.emptyMessage == "Nenhum resultado para “kubernetes”.")
    #expect(model.emptyMessage?.contains("bananas") == false)
  }

  /// Closing the window must not leave 500 dictations resident in a menu-bar
  /// app that runs for weeks — and must not leave the query behind either.
  @Test("forget drops every transcript, the index and the query")
  func forgetClearsEverything() async {
    let model = makeModel([made(secret), made("outra")])
    await model.load()
    model.setSearchText("bananas")
    #expect(model.matchCount == 1)

    model.forget()
    #expect(model.days.isEmpty)
    #expect(model.searchText.isEmpty)
    #expect(model.totalCount == 0)
    #expect(model.matchCount == 0)
    #expect(!model.isLoaded)
    #expect(model.notice == nil)
    #expect(model.storagePath == nil)

    // And the folded index really is gone, not merely hidden: a search that
    // matched before now matches nothing.
    model.setSearchText("bananas")
    #expect(model.days.isEmpty)
    #expect(model.matchCount == 0)
  }

  @Test("a reloaded window sees the store again after forget")
  func loadAfterForget() async {
    let model = makeModel([made("oi")])
    model.beginSession()
    await model.load()
    model.forget()

    // Reopening is a NEW session. Without beginSession() the model stays
    // dismissed on purpose — that is what stops a load left over from the
    // previous window from repopulating it.
    model.beginSession()
    await model.load()
    #expect(model.totalCount == 1)
  }

  @Test("A load without an open session does nothing")
  func loadOutsideASessionIsRefused() async {
    let model = makeModel([made("oi")])
    model.beginSession()
    await model.load()
    model.forget()

    await model.load()
    #expect(model.totalCount == 0)
    #expect(!model.isLoaded)
  }
}

// MARK: - Row actions

@Suite("History window row actions")
@MainActor
struct HistoryWindowActionTests {

  @Test("copy writes the FULL transcript, not the collapsed preview")
  func copyWritesFullText() async {
    let text = "primeira linha\nsegunda linha"
    let pasteboard = FakePasteboard()
    let model = makeModel([made(text)], pasteboard: pasteboard)
    await model.load()
    guard let row = model.days.first?.rows.first else {
      Issue.record("no row")
      return
    }
    #expect(row.collapsedText != text, "fixture must differ from the full text")
    await model.copy(row)
    #expect(await pasteboard.written == [text])
    #expect(model.notice?.message == HistoryWindowStrings.copied)
    #expect(model.notice?.kind == .success)
  }

  @Test("a refused pasteboard reports a failure instead of claiming success")
  func copyFailure() async {
    let model = makeModel([made("oi")], pasteboard: FakePasteboard(failsWrite: true))
    await model.load()
    guard let row = model.days.first?.rows.first else { return }
    await model.copy(row)
    #expect(model.notice?.message == HistoryWindowStrings.copyFailed)
    #expect(model.notice?.kind == .error)
  }

  @Test("delete removes the row and reloads the list")
  func deleteRemovesRow() async {
    let keep = made("fica", at: "2026-08-03 09:00:00")
    let drop = made("some", at: "2026-08-03 14:00:00")
    let history = FakeHistory([drop, keep])
    let model = makeModel([], history: history)
    await model.load()
    guard let row = model.days.first?.rows.first else { return }
    #expect(row.fullText == "some")

    await model.delete(row)
    #expect(await history.deletedIDs == [drop.id])
    #expect(model.totalCount == 1)
    #expect(model.days.first?.rows.map(\.fullText) == ["fica"])
    #expect(model.notice?.message == HistoryWindowStrings.deleted)
  }

  /// A failed delete must not report success and must not leave the list
  /// showing a row the store still has.
  @Test("a delete the store refuses surfaces the store's own message")
  func deleteFailure() async {
    let entry = made("fica mesmo")
    let history = FakeHistory(
      [entry], deleteError: .cannotWrite(file: "history.json"))
    let model = makeModel([], history: history)
    await model.load()
    guard let row = model.days.first?.rows.first else { return }

    await model.delete(row)
    #expect(model.notice?.kind == .error)
    #expect(model.notice?.message.contains("history.json") == true)
    #expect(model.totalCount == 1, "the row is still there, because it was not deleted")
  }

  @Test("delete keeps the active search")
  func deleteKeepsSearch() async {
    let model = makeModel([
      made("deploy um", at: "2026-08-03 14:00:00"),
      made("deploy dois", at: "2026-08-03 13:00:00"),
      made("outra coisa", at: "2026-08-03 12:00:00"),
    ])
    await model.load()
    model.setSearchText("deploy")
    #expect(model.matchCount == 2)
    guard let row = model.days.first?.rows.first else { return }
    await model.delete(row)
    #expect(model.searchText == "deploy")
    #expect(model.matchCount == 1)
    #expect(model.totalCount == 2)
  }
}

// MARK: - Apagar tudo

@Suite("History window erase all")
@MainActor
struct HistoryWindowEraseTests {

  /// The requirement in the brief: "Apagar tudo" must SAY it is destructive
  /// before doing it. Asserted structurally — `confirmEraseAll()` refuses
  /// unless a confirmation was built first, so no view can shortcut it.
  @Test("confirming without asking first erases nothing")
  func eraseRequiresConfirmation() async {
    let history = FakeHistory([made("oi")])
    let model = makeModel([], history: history)
    await model.load()

    await model.confirmEraseAll()
    #expect(await history.eraseCount == 0)
    #expect(model.totalCount == 1)
  }

  @Test("the confirmation states what is about to be destroyed")
  func confirmationCopy() async {
    let model = makeModel([made("um"), made("dois"), made("três")])
    await model.load()
    model.requestEraseAll()
    let confirmation = model.eraseConfirmation
    #expect(confirmation?.entryCount == 3)
    #expect(confirmation?.title == DictationHistoryStrings.eraseAllConfirm)
    #expect(confirmation?.title.contains("não pode ser desfeito") == true)
    #expect(confirmation?.message == "3 ditadas serão removidas deste Mac.")
    #expect(confirmation?.confirmTitle == DictationHistoryStrings.eraseAll)
    #expect(confirmation?.cancelTitle == "Cancelar")
  }

  @Test("cancelling closes the alert and erases nothing")
  func cancelErase() async {
    let history = FakeHistory([made("oi")])
    let model = makeModel([], history: history)
    await model.load()
    model.requestEraseAll()
    model.cancelEraseAll()
    #expect(model.eraseConfirmation == nil)
    await model.confirmEraseAll()
    #expect(await history.eraseCount == 0)
  }

  /// "Genuinely destructive": the store really is asked to erase, and the
  /// window really does come back empty rather than just clearing its own list.
  @Test("confirming erases the store and empties the window")
  func eraseAll() async {
    let history = FakeHistory([made("um"), made("dois")])
    let model = makeModel([], history: history)
    await model.load()
    model.requestEraseAll()
    await model.confirmEraseAll()

    #expect(await history.eraseCount == 1)
    #expect(model.totalCount == 0)
    #expect(model.days.isEmpty)
    #expect(model.emptyMessage == DictationHistoryStrings.empty)
    #expect(model.notice?.message == HistoryWindowStrings.erased)
    #expect(model.eraseConfirmation == nil)
  }

  @Test("a store that cannot erase says so, naming the file only")
  func eraseFailure() async {
    let history = FakeHistory(
      [made("um")], eraseError: .cannotErase(file: "history.json"))
    let model = makeModel([], history: history)
    await model.load()
    model.requestEraseAll()
    await model.confirmEraseAll()
    #expect(model.notice?.kind == .error)
    #expect(model.notice?.message.contains("history.json") == true)
    #expect(model.notice?.message.contains("/Users") == false, "no path, no account name")
  }

  @Test("there is nothing to confirm on an empty history")
  func eraseAllDisabledWhenEmpty() async {
    let model = makeModel([])
    await model.load()
    #expect(!model.canEraseAll)
    model.requestEraseAll()
    #expect(model.eraseConfirmation == nil)
  }
}

// MARK: - Re-injection through the model

@Suite("History window re-injection")
@MainActor
struct HistoryWindowReinjectTests {

  @Test("with no reinjector wired, the action refuses and says so")
  func noReinjector() async {
    let model = makeModel([made("oi")])
    await model.load()
    guard let row = model.days.first?.rows.first else { return }
    await model.reinject(row)
    #expect(model.notice?.message == HistoryWindowStrings.reinjectUnavailableNotice)
    #expect(model.notice?.kind == .warning)
  }

  /// The row's own guard, enforced again in the model: an entry with no
  /// verifiable destination must never reach the injector, because at that
  /// moment the frontmost application is Fala's own window.
  @Test("an entry with no verifiable destination never reaches the injector")
  func refusesUnknownDestination() async {
    let reinjector = FakeReinjector()
    let model = makeModel([made("oi", app: nil)], reinjector: reinjector)
    await model.load()
    guard let row = model.days.first?.rows.first else { return }
    #expect(!row.canReinject)

    await model.reinject(row)
    #expect(await reinjector.count == 0)
    #expect(model.notice?.kind == .warning)
  }

  @Test("a successful re-injection reports where the text went")
  func reinjectSuccess() async {
    let reinjector = FakeReinjector(.injected(destination: "VS Code"))
    let model = makeModel([made("oi")], reinjector: reinjector)
    await model.load()
    guard let row = model.days.first?.rows.first else { return }
    await model.reinject(row)
    #expect(await reinjector.count == 1)
    #expect(model.notice?.message == "Texto inserido em “VS Code”.")
    #expect(model.notice?.kind == .success)
  }

  @Test("a refusal is surfaced with the outcome's own state and message")
  func reinjectRefusal() async {
    let reinjector = FakeReinjector(.failed(.secureInputActive))
    let model = makeModel([made("oi")], reinjector: reinjector)
    await model.load()
    guard let row = model.days.first?.rows.first else { return }
    await model.reinject(row)
    #expect(model.notice?.kind == .error)
    #expect(model.notice?.message == "Campo protegido — injeção bloqueada.")
  }
}

// MARK: - The re-injection service

@Suite("Transcript reinjector")
struct TranscriptReinjectorTests {

  private func makeReinjector(
    injector: FakeInjector,
    frontmost: MutableFrontmost,
    activator: FakeActivator?
  ) -> TranscriptReinjector {
    TranscriptReinjector(
      injector: injector,
      frontmost: frontmost,
      activator: activator,
      delay: InstantDelay(),
      ownBundleIdentifier: ownBundleID,
      activationDelay: .zero)
  }

  /// The core requirement in the brief: re-inject goes through the SAME
  /// injector the coordinator uses. There is no second pasteboard path here —
  /// the only thing this service does with the text is hand it over.
  @Test("the full transcript goes to the injector, verbatim")
  func routesThroughTheInjector() async {
    let text = "primeira linha\nsegunda linha com acento: ação"
    let injector = FakeInjector()
    let frontmost = MutableFrontmost(editor)
    let service = makeReinjector(injector: injector, frontmost: frontmost, activator: nil)

    let outcome = await service.reinject(made(text))
    #expect(outcome == .injected(destination: "VS Code"))
    #expect(await injector.injected == [text])
  }

  /// The situation this whole policy exists for: the user clicked a button in
  /// our window, so WE are frontmost. Injecting "at the cursor" would type the
  /// transcript into Fala's own search field.
  @Test("when Fala is frontmost the destination is activated first")
  func activatesDestinationWhenWeAreFrontmost() async {
    let injector = FakeInjector()
    let frontmost = MutableFrontmost(fala)
    let activator = FakeActivator(frontmost: frontmost, becomes: editor)
    let service = makeReinjector(
      injector: injector, frontmost: frontmost, activator: activator)

    let outcome = await service.reinject(made("oi"))
    #expect(outcome.isInjected)
    #expect(await activator.requests == ["com.microsoft.VSCode"])
    #expect(await injector.count == 1)
  }

  /// `activate()` returning true does NOT mean the app came forward —
  /// activation is asynchronous. The answer is who is frontmost afterwards.
  @Test("an activation that reports success but does not land injects nothing")
  func activationThatNeverLands() async {
    let injector = FakeInjector()
    let frontmost = MutableFrontmost(fala)
    let activator = FakeActivator(frontmost: frontmost, becomes: nil)
    let service = makeReinjector(
      injector: injector, frontmost: frontmost, activator: activator)

    let outcome = await service.reinject(made("oi"))
    #expect(outcome == .destinationUnavailable(expected: "VS Code", actual: "Fala"))
    #expect(await injector.count == 0)
  }

  @Test("an activation the system refuses injects nothing")
  func activationRefused() async {
    let injector = FakeInjector()
    let frontmost = MutableFrontmost(fala)
    let activator = FakeActivator(frontmost: frontmost, becomes: editor, succeeds: false)
    let service = makeReinjector(
      injector: injector, frontmost: frontmost, activator: activator)

    #expect(!(await service.reinject(made("oi"))).isInjected)
    #expect(await injector.count == 0)
  }

  /// The one app this will pull focus from is Fala. A third app in front means
  /// the user is working somewhere else, and yanking focus out of it — then
  /// pasting — would be the worst thing this window could do.
  @Test("a third app in front is never pushed aside")
  func neverStealsFocusFromAThirdApp() async {
    let injector = FakeInjector()
    let frontmost = MutableFrontmost(mail)
    let activator = FakeActivator(frontmost: frontmost, becomes: editor)
    let service = makeReinjector(
      injector: injector, frontmost: frontmost, activator: activator)

    let outcome = await service.reinject(made("oi"))
    #expect(outcome == .destinationUnavailable(expected: "VS Code", actual: "Mail"))
    #expect(await activator.requests.isEmpty)
    #expect(await injector.count == 0)
  }

  @Test("an entry with no bundle identifier is refused before anything moves")
  func unknownDestination() async {
    let injector = FakeInjector()
    let frontmost = MutableFrontmost(fala)
    let activator = FakeActivator(frontmost: frontmost, becomes: editor)
    let service = makeReinjector(
      injector: injector, frontmost: frontmost, activator: activator)

    let nameOnly = DestinationApp(bundleIdentifier: nil, name: "Algum App")
    #expect(await service.reinject(made("oi", app: nameOnly)) == .unknownDestination)
    #expect(await service.reinject(made("oi", app: nil)) == .unknownDestination)
    #expect(await activator.requests.isEmpty)
    #expect(await injector.count == 0)
  }

  @Test("an empty transcript is refused without touching anything")
  func emptyText() async {
    let injector = FakeInjector()
    let frontmost = MutableFrontmost(editor)
    let service = makeReinjector(injector: injector, frontmost: frontmost, activator: nil)
    #expect(await service.reinject(made("   \n  ")) == .emptyText)
    #expect(await injector.count == 0)
  }

  /// FR-13: a secure field blocks re-injection exactly as it blocks a live
  /// dictation, and the user is told in the coordinator's own words.
  @Test("the injector's refusal is passed through, in the coordinator's words")
  func injectorRefusal() async {
    let injector = FakeInjector(error: .secureInputActive)
    let frontmost = MutableFrontmost(editor)
    let service = makeReinjector(injector: injector, frontmost: frontmost, activator: nil)

    let outcome = await service.reinject(made("oi"))
    #expect(outcome == .failed(.secureInputActive))
    #expect(outcome.message == "Campo protegido — injeção bloqueada.")
    #expect(outcome.stateKind == .error)
  }

  @Test("with no activator, re-injection only works into an app already in front")
  func withoutActivator() async {
    let injector = FakeInjector()
    let inFront = MutableFrontmost(editor)
    #expect(
      (await makeReinjector(injector: injector, frontmost: inFront, activator: nil)
        .reinject(made("oi"))).isInjected)

    let elsewhere = MutableFrontmost(fala)
    let outcome = await makeReinjector(
      injector: injector, frontmost: elsewhere, activator: nil
    ).reinject(made("oi"))
    #expect(!outcome.isInjected)
  }

  /// Actors are reentrant across `await`, and this path suspends four times.
  /// Two overlapping calls must not interleave their activate-then-inject
  /// sequences — same defect class as `ClipboardInjector` and
  /// `InjectionUndoService`, same fix.
  @Test("overlapping re-injections are serialised, and neither is dropped")
  func serialisesOverlappingRequests() async {
    let injector = FakeInjector()
    let frontmost = MutableFrontmost(editor)
    let service = makeReinjector(injector: injector, frontmost: frontmost, activator: nil)

    async let first = service.reinject(made("um"))
    async let second = service.reinject(made("dois"))
    let outcomes = await [first, second]

    // Hoisted out of `#expect`: the macro's rethrows analysis rejects a
    // key-path `allSatisfy` inside it.
    let bothInjected = outcomes.allSatisfy { $0.isInjected }
    #expect(bothInjected)
    // Two deliberate presses mean two insertions: only the ORDER is guaranteed,
    // never deduplication.
    #expect(await injector.count == 2)
    #expect(Set(await injector.injected) == ["um", "dois"])
  }

  /// PRIVACY: the outcome is what the window renders, and it is built from app
  /// names and error kinds. A transcript cannot structurally reach it.
  @Test("no outcome message can carry transcript text")
  func outcomesCarryNoTranscript() async {
    let secret = "minha senha é bananas"
    let injector = FakeInjector(error: .pasteboardFailure(reason: "x"))
    let frontmost = MutableFrontmost(editor)
    let service = makeReinjector(injector: injector, frontmost: frontmost, activator: nil)
    let outcome = await service.reinject(made(secret))
    #expect(!outcome.message.contains("bananas"))

    for sample in [
      ReinjectOutcome.injected(destination: "VS Code"),
      .emptyText,
      .unknownDestination,
      .destinationUnavailable(expected: "VS Code", actual: "Mail"),
      .failed(.accessibilityDenied),
    ] {
      #expect(!sample.message.isEmpty)
      #expect(!sample.message.contains("bananas"))
    }
  }

  @Test("every outcome maps onto one of the six states")
  func stateKinds() {
    #expect(ReinjectOutcome.injected(destination: nil).stateKind == .success)
    #expect(ReinjectOutcome.unknownDestination.stateKind == .warning)
    #expect(
      ReinjectOutcome.destinationUnavailable(expected: nil, actual: nil).stateKind == .warning)
    #expect(ReinjectOutcome.emptyText.stateKind == .error)
    #expect(ReinjectOutcome.failed(.accessibilityDenied).stateKind == .error)
  }

  @Test("a destination with no name still produces readable pt-BR")
  func unnamedDestination() {
    #expect(ReinjectOutcome.injected(destination: nil).message == "Texto inserido.")
    #expect(
      ReinjectOutcome.destinationUnavailable(expected: nil, actual: nil).message
        == "Abra o app onde o texto entrou e tente de novo.")
  }

  /// THE privacy regression. `load()` suspends twice; `forget()` runs
  /// synchronously from `windowWillClose`. Without a generation token the
  /// continuation repopulated the model AFTER the window was gone, leaving every
  /// transcript — and its folded search copy — resident for the process lifetime.
  /// That is the one guarantee this type advertises.
  @MainActor
  @Test("Closing the window during a load leaves no transcript behind")
  func forgetBeatsAnInFlightLoad() async {
    let secret = "minha senha do banco"
    let model = HistoryWindowModel(
      history: SlowHistory([made(secret)]),
      pasteboard: FakePasteboard(),
      reinjector: nil,
      calendar: fixedCalendar,
      clock: fixedClock)

    model.beginSession()
    let load = Task { await model.load() }
    model.forget()
    await load.value

    #expect(model.totalCount == 0)
    #expect(model.days.isEmpty)
    #expect(!model.isLoaded)

    // The folded search index must be gone too, not just the visible rows.
    model.setSearchText("senha")
    #expect(model.matchCount == 0)
  }

  /// The other half of the same guarantee: `forget()` landing BETWEEN `load()`'s
  /// two suspensions. The entry guard cannot see this one — the load is already
  /// past it — so only the post-await check stops the continuation writing every
  /// transcript back into a model whose window has closed.
  @MainActor
  @Test("Closing the window mid-load leaves no transcript behind")
  func forgetDuringAnInFlightLoad() async {
    let secret = "minha senha do banco"
    let model = HistoryWindowModel(
      history: SlowHistory([made(secret)]),
      pasteboard: FakePasteboard(),
      reinjector: nil,
      calendar: fixedCalendar,
      clock: fixedClock)

    model.beginSession()
    let load = Task { await model.load() }
    // Let the load start and reach its first suspension inside the store.
    await Task.yield()
    model.forget()
    await load.value

    #expect(model.totalCount == 0)
    #expect(model.days.isEmpty)
    #expect(!model.isLoaded)
    model.setSearchText("senha")
    #expect(model.matchCount == 0)
  }
}
