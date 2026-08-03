import CoreGraphics
import Foundation
import Observation

// Everything the history window renders and does (TASKS.md T2.12,
// DESIGN-HANDOFF.md §1 "history-window — Surface 4").
//
// Same split as the menu bar: all the decisions live here so `FalaKitTests` can
// reach them, and the SwiftUI window in `Sources/Fala/UI` only draws what this
// publishes.
//
// PRIVACY — this is the highest-risk surface in the app, because it is the one
// that puts transcripts on screen. The rules this file keeps:
//  1. Nothing here logs. There is no `Logger`, no `print`, no `os_log` in this
//     file or in anything it calls, and no transcript is ever interpolated into
//     a message — every notice below is a fixed pt-BR string or a store problem
//     that carries file NAMES only.
//  2. The search query is never persisted. It lives in `searchText` and dies
//     with `forget()`; see `HistorySearch.swift` for why the window does not use
//     `NSSearchField`'s recents at all.
//  3. `forget()` drops every transcript from memory when the window closes, so
//     a menu-bar app that runs for weeks is not holding 500 dictations in RAM
//     because someone opened this once.
//  4. The only writes are the ones the user asked for: delete, erase-all, copy
//     to the clipboard, re-inject.

// MARK: - Layout

/// The dimensions this surface has that `tokens.json` does not cover — window
/// sizes and list metrics, not design tokens. Named here so DESIGN.md's "no raw
/// numbers in views" holds, exactly as `MenuBarLayout` does for the popover.
///
/// There is NO mockup for Surface 4 (DESIGN.md §"Actual /design structure"), so
/// these are derived from the two rendered windows: `settings-window.dc.html`
/// draws a 520pt content column, and the row/section treatment is the popover's
/// "Recentes" pattern at comfortable density, as DESIGN-HANDOFF.md §1 asks for.
public enum HistoryWindowLayout {
  /// Wider than Ajustes' 520pt column because this window's content is prose,
  /// not label/control pairs — a transcript at 520pt wraps every eight words.
  public static let defaultSize = CGSize(width: 620, height: 640)
  /// Below this the meta line ("14:32 · VS Code · 3,4 s") starts colliding with
  /// the three row actions.
  public static let minSize = CGSize(width: 440, height: 320)
  /// The 1px rules the mockups draw, same token-less constant as
  /// `MenuBarLayout.hairline`.
  public static let hairline: CGFloat = 1
  /// Lines of transcript a collapsed row shows before "Mostrar tudo" appears.
  public static let collapsedLineLimit = 4
  /// Roughly `collapsedLineLimit` lines at the caption size in the default
  /// window. An estimate by construction — see `HistoryRow.needsExpansion`.
  public static let collapsedCharacterBudget = 260
  /// `NSWindow.setFrameAutosaveName`. Stores a window FRAME in UserDefaults and
  /// nothing else — no query, no transcript.
  public static let frameAutosaveName = "FalaHistoryWindow"
}

// MARK: - Strings

/// pt-BR copy for the history window.
///
/// The strings DESIGN-HANDOFF.md already fixed live in `DictationHistoryStrings`
/// (window title, empty state, "Apagar tudo", the privacy note, copy/delete
/// labels) and are reused verbatim here rather than restated — a second copy of
/// "Apagar tudo" is a second thing to keep in sync.
public enum HistoryWindowStrings {
  public static let searchPlaceholder = "Buscar nas ditadas"
  public static let clearSearch = "Limpar busca"
  public static let reinject = "Inserir de novo"
  public static let reinjectUnavailable =
    "Não dá para inserir de novo: não sei em qual app esta ditada entrou."
  public static let showMore = "Mostrar tudo"
  public static let showLess = "Mostrar menos"
  public static let copied = "Texto copiado."
  public static let copyFailed = "Não consegui copiar o texto."
  public static let deleted = "Ditada apagada."
  public static let erased = "Histórico apagado."
  public static let reinjectUnavailableNotice =
    "Inserir de novo ainda não está disponível."
  public static let cancel = "Cancelar"
  /// Prefix kept apart from the quoted query so the view can style them, the
  /// same way `PermissionsBanner` splits its prefix from its names.
  public static let noResultsPrefix = "Nenhum resultado para "

  /// "Nenhum resultado para “codigo”." — the query is echoed back because it is
  /// already on screen in the field two points above; nothing is persisted.
  public static func noResults(_ query: String) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return DictationHistoryStrings.empty }
    return "\(noResultsPrefix)“\(trimmed)”."
  }

  /// "1 ditada" / "42 ditadas".
  public static func entryCount(_ count: Int) -> String {
    count == 1 ? "1 ditada" : "\(count) ditadas"
  }

  /// "7 de 42 ditadas" while a filter is active, plain count otherwise.
  public static func countLine(matching: Int, of total: Int) -> String {
    guard matching != total else { return entryCount(total) }
    return "\(matching) de \(entryCount(total))"
  }
}

// MARK: - Notice

/// The one-line result of a row action, shown until it is dismissed or
/// superseded.
///
/// PRIVACY: `message` is always a fixed pt-BR string, a `ReinjectOutcome`
/// message (app names only) or a `DictationHistoryProblem` message (file names
/// only). A transcript can never reach it.
public struct HistoryNotice: Sendable, Equatable {
  public let message: String
  public let kind: StateKind

  public init(message: String, kind: StateKind) {
    self.message = message
    self.kind = kind
  }

  public var dismissTitle: String { MenuBarStrings.dismiss }
}

// MARK: - Erase confirmation

/// "Apagar tudo" must SAY it is destructive before it does anything
/// (DESIGN-HANDOFF.md §1; TASKS.md T2.12).
///
/// Modelled as a value that only exists while the alert is up, for the same
/// reason `PermissionsBanner` is failable: "no confirmation pending" is the
/// absence of this value, so no code path can erase without one having been
/// built first.
public struct HistoryEraseConfirmation: Sendable, Equatable {
  public let entryCount: Int

  public init(entryCount: Int) {
    self.entryCount = entryCount
  }

  /// The designed string, verbatim (`DictationHistoryStrings.eraseAllConfirm`).
  public var title: String { DictationHistoryStrings.eraseAllConfirm }

  /// States the size of what is about to be destroyed. "Deste Mac" is literal:
  /// `DictationHistoryStore.eraseAll()` removes the history file AND the
  /// quarantined copy, so there is no second file left behind.
  public var message: String {
    "\(HistoryWindowStrings.entryCount(entryCount)) serão removidas deste Mac."
  }

  public var confirmTitle: String { DictationHistoryStrings.eraseAll }
  public var cancelTitle: String { HistoryWindowStrings.cancel }
}

// MARK: - Model

/// Everything the history window shows and every action it can run.
///
/// `@MainActor @Observable`, like `MenuBarPresenter` and `ModelPanePresenter`:
/// the window reads properties, calls methods, and holds no state of its own
/// beyond per-row expansion.
@MainActor
@Observable
public final class HistoryWindowModel {

  /// Day sections, newest first, already filtered by `searchText`.
  public private(set) var days: [HistoryDay] = []
  /// What the user typed. Set through `setSearchText(_:)` so filtering happens
  /// once per edit instead of once per view body.
  public private(set) var searchText: String = ""
  /// Entries in the store, before filtering.
  public private(set) var totalCount: Int = 0
  /// Entries after filtering.
  public private(set) var matchCount: Int = 0
  /// False until `load()` has run once, so the window can tell "empty" from
  /// "not read yet" instead of flashing "Nenhuma ditada guardada ainda."
  public private(set) var isLoaded: Bool = false
  public private(set) var notice: HistoryNotice?
  /// Non-nil while the destructive alert is up.
  public private(set) var eraseConfirmation: HistoryEraseConfirmation?
  /// `~/Library/Application Support/Fala/history.json`, `$HOME` abbreviated.
  /// Shown under the privacy note so "fica só neste Mac" names a real file the
  /// user can open.
  public private(set) var storagePath: String?
  /// The store's own complaint (an unreadable file, a failed write), if any.
  /// File names only — never a path, never transcript text.
  public private(set) var storageProblem: String?
  /// True while a row action is in flight, so the window can refuse a second one.
  public private(set) var isWorking: Bool = false

  @ObservationIgnored private let history: any DictationHistoryManaging
  @ObservationIgnored private let pasteboard: any PasteboardAccessing
  @ObservationIgnored private let reinjector: (any TranscriptReinjecting)?
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private let clock: @Sendable () -> Date
  /// Folded search text, computed once per load. Not observable: it changes
  /// only when `days` is about to be recomputed anyway.
  @ObservationIgnored private var index = HistorySearchIndex([])

  /// - Parameters:
  ///   - history: the ONE `DictationHistoryStore` the app already owns. A second
  ///     instance would show a stale list and delete from a different cache.
  ///   - pasteboard: reused rather than reinvented — `SystemPasteboard.write`
  ///     already writes `.currentHostOnly` (keeping the transcript off Universal
  ///     Clipboard, i.e. off the user's other devices) and marks the item
  ///     concealed so clipboard managers do not archive it. Copying a transcript
  ///     needs exactly those two precautions.
  ///   - reinjector: `nil` renders every "Inserir de novo" disabled, the same
  ///     honest representation `MenuBarActions` uses for a surface that is not
  ///     wired yet.
  public init(
    history: any DictationHistoryManaging,
    pasteboard: any PasteboardAccessing = SystemPasteboard(),
    reinjector: (any TranscriptReinjecting)? = nil,
    calendar: Calendar = HistoryCalendar.ptBR,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.history = history
    self.pasteboard = pasteboard
    self.reinjector = reinjector
    self.calendar = calendar
    self.clock = clock
  }

  // MARK: Derived

  /// The window title (`DictationHistoryStrings.windowTitle`).
  public var windowTitle: String { DictationHistoryStrings.windowTitle }

  /// "7 de 42 ditadas".
  public var countLine: String {
    HistoryWindowStrings.countLine(matching: matchCount, of: totalCount)
  }

  /// What to show instead of the list, or `nil` when there are rows.
  ///
  /// Two different empty states on purpose: an empty history is a fact about
  /// the app ("Nenhuma ditada guardada ainda."), an empty result is a fact
  /// about the query, and printing the first one over a populated history that
  /// simply did not match is how a user concludes the app lost their data.
  public var emptyMessage: String? {
    guard isLoaded, days.isEmpty else { return nil }
    guard totalCount > 0 else { return DictationHistoryStrings.empty }
    return HistoryWindowStrings.noResults(searchText)
  }

  /// Whether the empty state is caused by the filter rather than by an empty
  /// store — the view offers "Limpar busca" only then.
  public var isFilteredEmpty: Bool {
    isLoaded && days.isEmpty && totalCount > 0
  }

  public var isSearching: Bool { HistoryQuery(searchText).isActive }

  /// "Apagar tudo" is offered only when there is something to destroy.
  public var canEraseAll: Bool { totalCount > 0 && !isWorking }

  /// DESIGN-HANDOFF.md §1: "Privacy note: history is stored locally only".
  public var privacyNote: String { DictationHistoryStrings.privacyNote }

  public var privacySymbol: String { FalaSymbol.privacyShield }

  /// True from `forget()` until the next `beginSession()`.
  ///
  /// A generation counter was not enough: `show()` starts `load()` in an
  /// unstructured Task, so a window closed immediately after opening runs
  /// `forget()` BEFORE that task has even begun. The load then had a token
  /// nothing had invalidated and happily repopulated a model whose window was
  /// gone. A session flag covers both orders — the load that has not started
  /// yet, and the one already suspended.
  private var isDismissed = false

  /// Reopens the model for a new window session. Must be called before `load()`;
  /// `forget()` closes the session again.
  public func beginSession() {
    isDismissed = false
  }

  // MARK: Loading

  /// Reads the store and rebuilds the list.
  ///
  /// Call it when the window appears and after a mutation — not from a view
  /// body: it walks the whole history and folds every transcript.
  public func load() async {
    // Checked before AND after the suspensions: closing the window mid-load used
    // to let the continuation REPOPULATE the model afterwards, leaving every
    // transcript and its folded search copy resident for the rest of the
    // process — defeating the one guarantee this type advertises.
    guard !isDismissed else { return }

    let entries = await history.allEntries()
    let status = await history.status()
    guard !isDismissed else { return }

    index = HistorySearchIndex(entries)
    totalCount = entries.count
    storagePath = status.displayPath
    storageProblem = status.problem?.message
    isLoaded = true
    regroup()
  }

  /// Drops every transcript, the folded index and the query.
  ///
  /// Called when the window closes. Without it a menu-bar app that runs for
  /// weeks keeps up to 500 dictations — and their folded copies — resident
  /// because someone opened this window once on Monday.
  public func forget() {
    // Invalidates any load, in flight or not yet started — see `load()`.
    isDismissed = true
    index = HistorySearchIndex([])
    days = []
    searchText = ""
    totalCount = 0
    matchCount = 0
    isLoaded = false
    notice = nil
    eraseConfirmation = nil
    storagePath = nil
    storageProblem = nil
  }

  // MARK: Search

  public func setSearchText(_ text: String) {
    guard text != searchText else { return }
    searchText = text
    regroup()
  }

  public func clearSearch() {
    setSearchText("")
  }

  private func regroup() {
    let matches = index.filter(HistoryQuery(searchText))
    matchCount = matches.count
    days = HistoryDayGrouping.groups(for: matches, now: clock(), calendar: calendar)
  }

  // MARK: Notices

  public func dismissNotice() {
    notice = nil
  }

  // MARK: Row actions

  /// `doc.on.doc`. Puts the transcript on the clipboard through the same
  /// `PasteboardAccessing` seam the injector uses.
  public func copy(_ row: HistoryRow) async {
    do {
      _ = try await pasteboard.write(row.fullText)
      notice = HistoryNotice(message: HistoryWindowStrings.copied, kind: .success)
    } catch {
      // The error is deliberately not interpolated: a pasteboard failure
      // reason is not user-actionable and is not worth the risk of it ever
      // carrying content.
      notice = HistoryNotice(message: HistoryWindowStrings.copyFailed, kind: .error)
    }
  }

  /// `arrow.uturn.left`. Routed through `TranscriptReinjecting`, which routes
  /// through the app's ONE `TextInjector` — see `TranscriptReinjection.swift`.
  public func reinject(_ row: HistoryRow) async {
    guard let reinjector else {
      notice = HistoryNotice(
        message: HistoryWindowStrings.reinjectUnavailableNotice, kind: .warning)
      return
    }
    guard row.canReinject else {
      notice = HistoryNotice(message: ReinjectOutcome.unknownDestination.message, kind: .warning)
      return
    }
    guard !isWorking else {
      // Silently returning told the user nothing: a second trash click during
      // the first delete left its row on screen under a green "apagada" notice,
      // so the app reported a success for a row that still existed. The view
      // also disables the buttons while `isWorking`, but this is the enforcement.
      notice = HistoryNotice(
        message: DictationHistoryStrings.busyRetryShortly, kind: .warning)
      return
    }
    isWorking = true
    // `defer` rather than a plain assignment after the await: if the surrounding
    // task is cancelled while the destination app is coming forward, a stuck
    // `isWorking` would disable every row action for the rest of the session.
    defer { isWorking = false }
    let outcome = await reinjector.reinject(row.entry)
    // NOTE for whoever wires this: a successful re-injection has just put
    // ANOTHER app in front, so this notice lands on a window the user is no
    // longer looking at. It is still worth setting — it is what they come back
    // to — but it is not the primary feedback; the text appearing in their
    // document is.
    notice = HistoryNotice(message: outcome.message, kind: outcome.stateKind)
  }

  /// `trash`. One entry, no confirmation: it is a single row, it is visible, and
  /// the destructive confirmation is reserved for "Apagar tudo".
  public func delete(_ row: HistoryRow) async {
    guard !isWorking else {
      // Silently returning told the user nothing: a second trash click during
      // the first delete left its row on screen under a green "apagada" notice,
      // so the app reported a success for a row that still existed. The view
      // also disables the buttons while `isWorking`, but this is the enforcement.
      notice = HistoryNotice(
        message: DictationHistoryStrings.busyRetryShortly, kind: .warning)
      return
    }
    isWorking = true
    defer { isWorking = false }
    do {
      try await history.delete(id: row.id)
      await load()
      notice = HistoryNotice(message: HistoryWindowStrings.deleted, kind: .success)
    } catch let problem as DictationHistoryProblem {
      await load()
      notice = HistoryNotice(message: problem.message, kind: .error)
    } catch {
      await load()
      notice = HistoryNotice(
        message: DictationHistoryProblem.cannotWrite(
          file: DictationHistoryStore.fileName
        ).message,
        kind: .error)
    }
  }

  // MARK: Apagar tudo

  /// Opens the destructive confirmation. Does NOT erase anything.
  public func requestEraseAll() {
    guard canEraseAll else { return }
    eraseConfirmation = HistoryEraseConfirmation(entryCount: totalCount)
  }

  public func cancelEraseAll() {
    eraseConfirmation = nil
  }

  /// The only path that erases. Reachable only after `requestEraseAll()` built
  /// a confirmation, so "Apagar tudo" cannot fire without the alert having been
  /// shown — the guard is what makes the promise structural rather than a
  /// convention the view has to remember.
  public func confirmEraseAll() async {
    guard eraseConfirmation != nil else { return }
    eraseConfirmation = nil
    isWorking = true
    defer { isWorking = false }
    do {
      try await history.eraseAll()
      await load()
      notice = HistoryNotice(message: HistoryWindowStrings.erased, kind: .success)
    } catch let problem as DictationHistoryProblem {
      await load()
      notice = HistoryNotice(message: problem.message, kind: .error)
    } catch {
      await load()
      notice = HistoryNotice(
        message: DictationHistoryProblem.cannotErase(
          file: DictationHistoryStore.fileName
        ).message,
        kind: .error)
    }
  }
}
