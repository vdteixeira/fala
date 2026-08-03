import Foundation
import Testing

@testable import FalaKit

// MARK: - Fakes

private let editor = DestinationApp(bundleIdentifier: "com.microsoft.VSCode", name: "VS Code")
private let browser = DestinationApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
private let fala = DestinationApp(bundleIdentifier: "com.fala.app", name: "Fala")
private let injectedAt = Date(timeIntervalSince1970: 1_770_000_000)

/// Stands in for the history store. Holds exactly what `LastInjectionProviding`
/// exposes — which is, deliberately, no transcript text.
private actor FakeLastInjection: LastInjectionProviding {
  private var injection: UndoableInjection?
  private(set) var marks: [(id: UUID, date: Date)] = []

  init(_ injection: UndoableInjection?) { self.injection = injection }

  func lastInjection() async -> UndoableInjection? { injection }

  func markUndoRequested(id: UUID, at date: Date) async {
    marks.append((id, date))
    guard let current = injection, current.id == id, current.undoRequestedAt == nil else { return }
    injection = UndoableInjection(
      id: current.id,
      destination: current.destination,
      injectedAt: current.injectedAt,
      undoRequestedAt: date)
  }

  var markCount: Int { marks.count }
}

/// A frontmost app the test can change — including from inside the fake
/// activator, which is how "activation actually worked" is modelled.
private actor MutableFrontmost: FrontmostApplicationProviding {
  private var app: DestinationApp?

  init(_ app: DestinationApp?) { self.app = app }

  func current() async -> DestinationApp? { app }

  func set(_ app: DestinationApp?) { self.app = app }
}

private actor FakeActivator: ApplicationActivating {
  private let frontmost: MutableFrontmost
  private let becomes: DestinationApp?
  private let succeeds: Bool
  private(set) var requests: [String] = []

  /// - Parameter becomes: what the frontmost app turns into when this activator
  ///   is asked. `nil` models an activation that reports success but never
  ///   actually brings the app forward.
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

private actor FakeUndoKeystrokes: UndoKeystrokeEmitting {
  private let error: UndoError?
  private(set) var sendCount = 0

  init(error: UndoError? = nil) { self.error = error }

  func sendUndoShortcut() async throws {
    sendCount += 1
    if let error { throw error }
  }
}

private struct FakeSecureInput: SecureInputMonitoring {
  let isSecureInputActive: Bool
}

/// No sleeping in tests: the activation wait is injected.
private struct InstantDelay: InjectionDelaying {
  func wait(for duration: Duration) async throws {}
  func waitIgnoringCancellation(for duration: Duration) async {}
}

private func makeService(
  injection: UndoableInjection? = UndoableInjection(
    id: UUID(), destination: editor, injectedAt: injectedAt),
  history: FakeLastInjection? = nil,
  frontmost: MutableFrontmost = MutableFrontmost(editor),
  secureInput: Bool = false,
  keystrokes: FakeUndoKeystrokes = FakeUndoKeystrokes(),
  activator: (any ApplicationActivating)? = nil,
  now: Date = injectedAt.addingTimeInterval(5),
  ownBundleIdentifier: String? = "com.fala.app",
  window: TimeInterval = InjectionUndoService.defaultUndoWindow
) -> (InjectionUndoService, FakeLastInjection, FakeUndoKeystrokes) {
  let store = history ?? FakeLastInjection(injection)
  let service = InjectionUndoService(
    history: store,
    frontmost: frontmost,
    secureInput: FakeSecureInput(isSecureInputActive: secureInput),
    keystrokes: keystrokes,
    activator: activator,
    delay: InstantDelay(),
    clock: { now },
    ownBundleIdentifier: { ownBundleIdentifier },
    undoWindow: window,
    activationDelay: .zero)
  return (service, store, keystrokes)
}

// MARK: - Tests

@Suite("InjectionUndoService")
struct InjectionUndoServiceTests {

  @Test("The happy path posts one Cmd+Z to the app the text went into")
  func postsUndoToTheDestination() async throws {
    let (service, store, keystrokes) = makeService()

    let outcome = await service.undoLastInjection()

    #expect(outcome == .requested(destination: "VS Code"))
    #expect(outcome.isRequested)
    #expect(outcome.message == "Desfazer enviado para “VS Code”.")
    #expect(await keystrokes.sendCount == 1)
    #expect(await store.markCount == 1)
  }

  @Test("Undo fires once per injection: a second attempt sends nothing")
  func undoIsSingleShot() async throws {
    let (service, _, keystrokes) = makeService()

    _ = await service.undoLastInjection()
    let second = await service.undoLastInjection()

    #expect(second == .alreadyUndone(at: injectedAt.addingTimeInterval(5)))
    #expect(second.message == "A última ditada já foi desfeita.")
    // The point of the whole mechanism: no second chord to eat the user's own
    // work after the paste was already undone.
    #expect(await keystrokes.sendCount == 1)
  }

  @Test("An injection already marked as undone in the store is refused on the first try")
  func alreadyMarkedInStore() async throws {
    let marked = UndoableInjection(
      id: UUID(),
      destination: editor,
      injectedAt: injectedAt,
      undoRequestedAt: injectedAt.addingTimeInterval(1))
    let (service, _, keystrokes) = makeService(injection: marked)

    #expect(await service.undoLastInjection().isRequested == false)
    #expect(await keystrokes.sendCount == 0)
  }

  @Test("With no history there is nothing to undo and nothing is posted")
  func nothingToUndo() async throws {
    let (service, _, keystrokes) = makeService(injection: nil)

    let outcome = await service.undoLastInjection()

    #expect(outcome == .nothingToUndo)
    #expect(outcome.message == "Nada para desfazer.")
    #expect(await keystrokes.sendCount == 0)
  }

  @Test("An old injection is refused: it is no longer on top of the app's undo stack")
  func expiredInjection() async throws {
    let (service, _, keystrokes) = makeService(
      now: injectedAt.addingTimeInterval(500), window: 120)

    let outcome = await service.undoLastInjection()

    #expect(outcome == .expired(age: 500))
    #expect(await keystrokes.sendCount == 0)
  }

  @Test("A clock that moved backwards does not take undo away")
  func negativeAgeStillUndoable() async throws {
    // Skew, DST or a manual clock change makes the age negative. Refusing there
    // would disable undo for a reason the user can neither see nor fix.
    let (service, _, keystrokes) = makeService(now: injectedAt.addingTimeInterval(-30))

    #expect(await service.undoLastInjection().isRequested)
    #expect(await keystrokes.sendCount == 1)
  }

  @Test("A different app in front refuses, and says which app to go back to")
  func destinationChanged() async throws {
    let (service, store, keystrokes) = makeService(frontmost: MutableFrontmost(browser))

    let outcome = await service.undoLastInjection()

    #expect(outcome == .destinationChanged(expected: "VS Code", actual: "Safari"))
    #expect(outcome.message == "Volte para “VS Code” e tente de novo.")
    #expect(await keystrokes.sendCount == 0)
    // NOT consumed: the user can switch back and undo for real.
    #expect(await store.markCount == 0)
  }

  @Test("An unidentifiable destination refuses rather than posting Cmd+Z blindly")
  func unknownDestination() async throws {
    let nameOnly = UndoableInjection(
      id: UUID(),
      destination: DestinationApp(bundleIdentifier: nil, name: "Um app qualquer"),
      injectedAt: injectedAt)
    let (service, _, keystrokes) = makeService(injection: nameOnly)

    #expect(await service.undoLastInjection() == .unknownDestination)
    #expect(await keystrokes.sendCount == 0)

    let noDestination = UndoableInjection(id: UUID(), destination: nil, injectedAt: injectedAt)
    let (second, _, secondKeys) = makeService(injection: noDestination)
    #expect(await second.undoLastInjection() == .unknownDestination)
    #expect(await secondKeys.sendCount == 0)
  }

  @Test("A secure field blocks undo, like it blocks injection (FR-13)")
  func secureInputBlocksUndo() async throws {
    let (service, store, keystrokes) = makeService(secureInput: true)

    let outcome = await service.undoLastInjection()

    #expect(outcome == .secureInputActive)
    #expect(outcome.message == "Campo protegido — desfazer bloqueado.")
    #expect(await keystrokes.sendCount == 0)
    #expect(await store.markCount == 0)
  }

  @Test("A missing Accessibility grant reports itself and does NOT burn the undo")
  func accessibilityDenied() async throws {
    let (service, store, keystrokes) = makeService(
      keystrokes: FakeUndoKeystrokes(error: .accessibilityDenied))

    let outcome = await service.undoLastInjection()

    #expect(outcome == .failed(.accessibilityDenied))
    #expect(outcome.message == "Permissão de Acessibilidade necessária.")
    #expect(await keystrokes.sendCount == 1)
    // Retryable once the user grants the permission.
    #expect(await store.markCount == 0)
  }

  @Test("A Quartz failure is reported in pt-BR without leaking the internal reason")
  func synthesisFailure() async throws {
    let (service, _, _) = makeService(
      keystrokes: FakeUndoKeystrokes(error: .eventSynthesisFailed(reason: "no event source")))

    let outcome = await service.undoLastInjection()

    #expect(outcome == .failed(.eventSynthesisFailed(reason: "no event source")))
    #expect(outcome.message == "Não consegui enviar ⌘Z.")
    #expect(!outcome.message.contains("event source"))
  }

  // MARK: Popover path

  @Test("Undo from our own popover hands focus back to the destination first")
  func activatesTheDestinationWhenFalaIsFrontmost() async throws {
    let frontmost = MutableFrontmost(fala)
    let activator = FakeActivator(frontmost: frontmost, becomes: editor)
    let (service, _, keystrokes) = makeService(frontmost: frontmost, activator: activator)

    let outcome = await service.undoLastInjection()

    #expect(outcome.isRequested)
    #expect(await activator.requests == ["com.microsoft.VSCode"])
    #expect(await keystrokes.sendCount == 1)
    #expect(await frontmost.current() == editor)
  }

  @Test("If activation never brings the app forward, nothing is posted")
  func activationThatDoesNotStick() async throws {
    let frontmost = MutableFrontmost(fala)
    // Reports success but the frontmost app never changes — the app is hung, or
    // another window grabbed focus first.
    let activator = FakeActivator(frontmost: frontmost, becomes: nil)
    let (service, _, keystrokes) = makeService(frontmost: frontmost, activator: activator)

    let outcome = await service.undoLastInjection()

    #expect(outcome == .destinationChanged(expected: "VS Code", actual: "Fala"))
    #expect(await keystrokes.sendCount == 0)
  }

  @Test("An activation that is refused outright refuses the undo")
  func activationRefused() async throws {
    let frontmost = MutableFrontmost(fala)
    let activator = FakeActivator(frontmost: frontmost, becomes: editor, succeeds: false)
    let (service, _, keystrokes) = makeService(frontmost: frontmost, activator: activator)

    #expect(await service.undoLastInjection().isRequested == false)
    #expect(await keystrokes.sendCount == 0)
  }

  @Test("Without an activator, Fala being frontmost is just another wrong app")
  func noActivatorMeansNoFocusStealing() async throws {
    let (service, _, keystrokes) = makeService(
      frontmost: MutableFrontmost(fala), activator: nil)

    let refused = UndoOutcome.destinationChanged(expected: "VS Code", actual: "Fala")
    #expect(await service.undoLastInjection() == refused)
    #expect(await keystrokes.sendCount == 0)
  }

  @Test("Focus is never pulled away from a THIRD app, even with an activator")
  func neverStealsFocusFromAnotherApp() async throws {
    let frontmost = MutableFrontmost(browser)
    let activator = FakeActivator(frontmost: frontmost, becomes: editor)
    let (service, _, keystrokes) = makeService(frontmost: frontmost, activator: activator)

    let outcome = await service.undoLastInjection()

    #expect(outcome == .destinationChanged(expected: "VS Code", actual: "Safari"))
    #expect(await activator.requests.isEmpty)
    #expect(await keystrokes.sendCount == 0)
    #expect(await frontmost.current() == browser)
  }

  @Test("An app with no bundle identifier of our own cannot be mistaken for us")
  func unknownOwnBundleIdentifier() async throws {
    // `Bundle.main.bundleIdentifier` is nil for a bare executable. A frontmost
    // app that also has none must NOT be read as "that is us, activate away".
    let frontmost = MutableFrontmost(DestinationApp(bundleIdentifier: nil, name: "Algo"))
    let activator = FakeActivator(frontmost: frontmost, becomes: editor)
    let (service, _, keystrokes) = makeService(
      frontmost: frontmost, activator: activator, ownBundleIdentifier: nil)

    #expect(await service.undoLastInjection().isRequested == false)
    #expect(await activator.requests.isEmpty)
    #expect(await keystrokes.sendCount == 0)
  }

  // MARK: Contracts

  @Test("Two simultaneous undo requests post at most one chord")
  func concurrentUndoPostsOnce() async throws {
    let (service, _, keystrokes) = makeService()

    async let first = service.undoLastInjection()
    async let second = service.undoLastInjection()
    let outcomes = await [first, second]

    #expect(outcomes.filter(\.isRequested).count == 1)
    #expect(await keystrokes.sendCount == 1)
  }

  @Test("Every outcome has a non-empty pt-BR message and none can carry a transcript")
  func messagesArePortugueseAndTextFree() {
    let outcomes: [UndoOutcome] = [
      .requested(destination: "VS Code"),
      .requested(destination: nil),
      .nothingToUndo,
      .alreadyUndone(at: injectedAt),
      .expired(age: 300),
      .unknownDestination,
      .destinationChanged(expected: "VS Code", actual: "Safari"),
      .destinationChanged(expected: nil, actual: nil),
      .secureInputActive,
      .failed(.accessibilityDenied),
      .failed(.eventSynthesisFailed(reason: "could not build key events")),
    ]
    // English tell-tales that would mean an internal string reached the user.
    let english = ["could not", "failed", "event", "Accessibility is"]
    for outcome in outcomes {
      #expect(!outcome.message.isEmpty)
      for tell in english {
        #expect(!outcome.message.contains(tell))
      }
    }
    #expect(outcomes.filter(\.isRequested).count == 2)
  }

  @Test("The service name does not overpromise: only one case means a chord left")
  func onlyRequestedMeansSomethingHappened() {
    #expect(UndoOutcome.requested(destination: nil).isRequested)
    #expect(!UndoOutcome.nothingToUndo.isRequested)
    #expect(!UndoOutcome.expired(age: 1).isRequested)
    #expect(!UndoOutcome.secureInputActive.isRequested)
    #expect(!UndoOutcome.failed(.accessibilityDenied).isRequested)
  }
}

// MARK: - Store + undo, together

@Suite("Undo over the real history store")
struct UndoOverHistoryStoreTests {

  private struct StubFrontmost: FrontmostApplicationProviding {
    let app: DestinationApp?
    func current() async -> DestinationApp? { app }
  }

  @Test("Undo consumes the store's newest entry, and the entry stays in history")
  func undoMarksTheStoredEntry() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fala-undo-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = injectedAt
    let store = DictationHistoryStore(
      directory: directory,
      frontmost: StubFrontmost(app: editor),
      clock: { now })
    await store.record(text: "transcrição ruim", duration: 1)

    let keystrokes = FakeUndoKeystrokes()
    let service = InjectionUndoService(
      history: store,
      frontmost: StubFrontmost(app: editor),
      secureInput: FakeSecureInput(isSecureInputActive: false),
      keystrokes: keystrokes,
      activator: nil,
      delay: InstantDelay(),
      clock: { now.addingTimeInterval(3) },
      ownBundleIdentifier: { "com.fala.app" })

    #expect(await service.undoLastInjection().isRequested)
    #expect(await service.undoLastInjection() == .alreadyUndone(at: now.addingTimeInterval(3)))
    #expect(await keystrokes.sendCount == 1)

    // Undo is not a delete: the row is still there to copy or re-inject, and the
    // "already undone" flag survives a relaunch.
    let reopened = DictationHistoryStore(
      directory: directory, frontmost: StubFrontmost(app: editor), clock: { now })
    #expect(await reopened.allEntries().map(\.text) == ["transcrição ruim"])
    #expect(await reopened.lastInjection()?.undoRequestedAt == now.addingTimeInterval(3))
  }

  @Test("A newer dictation makes undo available again")
  func newDictationReopensUndo() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fala-undo-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = injectedAt
    let store = DictationHistoryStore(
      directory: directory,
      frontmost: StubFrontmost(app: editor),
      clock: { now })
    await store.record(text: "primeira", duration: 1)
    let first = try #require(await store.lastInjection())
    await store.markUndoRequested(id: first.id, at: now)

    await store.record(text: "segunda", duration: 1)

    let latest = try #require(await store.lastInjection())
    #expect(latest.id != first.id)
    #expect(latest.undoRequestedAt == nil)
  }
}
