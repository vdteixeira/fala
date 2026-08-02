import AppKit
import Foundation
import Testing
import os

@testable import FalaKit

// MARK: - Fakes
//
// File-private so they cannot collide with mocks other tasks add under
// Tests/FalaKitTests/Mocks/. All of them are actors or immutable structs, so the
// suite never needs `@unchecked Sendable`.

/// In-memory stand-in for `NSPasteboard`, recording an ordered event log so the
/// snapshot/paste/restore sequence itself can be asserted.
private actor FakePasteboard: PasteboardAccessing {
  enum Event: Equatable {
    case snapshot
    case write(String)
    case changeCount
    case restore
    /// Emitted by `FakeDelay`, to place the settle delay on the same timeline.
    case settleDelay
  }

  static let stringType = "public.utf8-plain-text"

  private(set) var events: [Event] = []
  private(set) var items: [PasteboardSnapshot.Item]
  private(set) var changeCount: Int
  private let writeError: InjectionError?
  private let writeErrorClearsContents: Bool
  private let restoreError: InjectionError?

  init(
    items: [PasteboardSnapshot.Item] = [],
    changeCount: Int = 7,
    writeError: InjectionError? = nil,
    writeErrorClearsContents: Bool = true,
    restoreError: InjectionError? = nil
  ) {
    self.items = items
    self.changeCount = changeCount
    self.writeError = writeError
    self.writeErrorClearsContents = writeErrorClearsContents
    self.restoreError = restoreError
  }

  func currentChangeCount() async -> Int {
    events.append(.changeCount)
    return changeCount
  }

  func snapshot() async -> PasteboardSnapshot {
    events.append(.snapshot)
    return PasteboardSnapshot(items: items, changeCount: changeCount)
  }

  func write(_ text: String) async throws -> Int {
    events.append(.write(text))
    if let writeError {
      // `NSPasteboard.clearContents()` runs before a write can fail, so by
      // default the fake models a clipboard that is already wiped.
      if writeErrorClearsContents {
        items = []
        changeCount += 1
      }
      throw writeError
    }
    items = [Self.item(text)]
    changeCount += 1
    return changeCount
  }

  func restore(_ snapshot: PasteboardSnapshot) async throws {
    events.append(.restore)
    if let restoreError { throw restoreError }
    items = snapshot.items
    changeCount += 1
  }

  /// Someone else (the user, a clipboard manager) claiming the pasteboard while
  /// an injection is in flight.
  func simulateExternalWrite(_ text: String) {
    items = [Self.item(text)]
    changeCount += 1
  }

  func noteSettleDelay() {
    events.append(.settleDelay)
  }

  var currentText: String? {
    guard let data = items.first?.data(forType: Self.stringType) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func item(_ text: String) -> PasteboardSnapshot.Item {
    PasteboardSnapshot.Item(
      representations: [.init(type: stringType, data: Data(text.utf8))])
  }
}

private actor FakePasteKeystrokes: PasteKeystrokeEmitting {
  private(set) var sendCount = 0
  private let error: InjectionError?
  private let onSend: (@Sendable () async -> Void)?

  init(error: InjectionError? = nil, onSend: (@Sendable () async -> Void)? = nil) {
    self.error = error
    self.onSend = onSend
  }

  func sendPasteShortcut() async throws {
    sendCount += 1
    await onSend?()
    if let error { throw error }
  }
}

private actor FakeDelay: InjectionDelaying {
  private(set) var waits: [Duration] = []
  private let onWait: (@Sendable () async -> Void)?

  init(onWait: (@Sendable () async -> Void)? = nil) {
    self.onWait = onWait
  }

  func wait(for duration: Duration) async {
    waits.append(duration)
    await onWait?()
  }

  func waitIgnoringCancellation(for duration: Duration) async {
    await wait(for: duration)
  }
}

private struct FakeSecureInput: SecureInputMonitoring {
  let isSecureInputActive: Bool
}

/// A delay that records itself on `pasteboard`'s event log, so the ordering of
/// write → settle → restore is observable from a single timeline.
private func makeDelay(noting pasteboard: FakePasteboard) -> FakeDelay {
  FakeDelay(onWait: { [pasteboard] in await pasteboard.noteSettleDelay() })
}

private func makeInjector(
  pasteboard: FakePasteboard,
  secureInputActive: Bool = false,
  keystrokes: FakePasteKeystrokes = FakePasteKeystrokes(),
  delay: FakeDelay? = nil,
  settleDelay: Duration = .milliseconds(42)
) -> ClipboardInjector {
  ClipboardInjector(
    pasteboard: pasteboard,
    secureInput: FakeSecureInput(isSecureInputActive: secureInputActive),
    keystrokes: keystrokes,
    delay: delay ?? makeDelay(noting: pasteboard),
    pasteSettleDelay: settleDelay
  )
}

// MARK: - Tests

@Suite("ClipboardInjector")
struct ClipboardInjectorTests {

  // MARK: Happy path

  @Test("Restores the previous clipboard after a successful paste")
  func restoresPreviousClipboardAfterPaste() async throws {
    let pasteboard = FakePasteboard(items: [FakePasteboard.item("conteúdo anterior")])
    let keystrokes = FakePasteKeystrokes()
    let injector = makeInjector(pasteboard: pasteboard, keystrokes: keystrokes)

    try await injector.inject("olá mundo")

    let sendCount = await keystrokes.sendCount
    let restoredText = await pasteboard.currentText
    let events = await pasteboard.events
    #expect(sendCount == 1)
    #expect(restoredText == "conteúdo anterior")
    #expect(
      events == [.snapshot, .write("olá mundo"), .settleDelay, .changeCount, .restore]
    )
  }

  @Test("Reports the restore outcome")
  func reportsRestoredOutcome() async throws {
    let pasteboard = FakePasteboard(items: [FakePasteboard.item("antes")])
    let injector = makeInjector(pasteboard: pasteboard)

    let outcome = try await injector.injectReportingRestore("depois")

    let restoredText = await pasteboard.currentText
    #expect(outcome == .restored)
    #expect(restoredText == "antes")
  }

  @Test("Round-trips every item and representation, not just plain text")
  func roundTripPreservesRichContent() async throws {
    let rich = [
      PasteboardSnapshot.Item(representations: [
        .init(type: "public.rtf", data: Data("{\\rtf1 oi}".utf8)),
        .init(type: "public.html", data: Data("<b>oi</b>".utf8)),
        .init(type: FakePasteboard.stringType, data: Data("oi".utf8)),
      ]),
      PasteboardSnapshot.Item(representations: [
        .init(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
      ]),
    ]
    let pasteboard = FakePasteboard(items: rich)
    let injector = makeInjector(pasteboard: pasteboard)

    try await injector.inject("transcrição")

    let restored = await pasteboard.items
    // `[Representation]` equality is order-sensitive, so this now fails if the
    // representations come back reordered — see the dedicated test below.
    #expect(restored == rich)
  }

  /// A reader takes the FIRST pasteboard type it understands, so restoring
  /// `[rtf, html, plain]` as `[plain, html, rtf]` turns the user's styled
  /// clipboard into plain text on the next Cmd+V. The order is data, and the
  /// old `[String: Data]` storage could not carry it.
  @Test("Preserves the reader-preference order of the representations")
  func preservesRepresentationOrder() async throws {
    let ordered: [String] = [
      "public.rtf", "public.html", "public.utf16-external-plain-text",
      FakePasteboard.stringType, "public.png",
    ]
    let item = PasteboardSnapshot.Item(
      representations: ordered.enumerated().map { index, type in
        .init(type: type, data: Data([UInt8(index)]))
      })
    let pasteboard = FakePasteboard(items: [item])
    let injector = makeInjector(pasteboard: pasteboard)

    try await injector.inject("transcrição")

    let restored = await pasteboard.items
    #expect(restored.first?.representations.map(\.type) == ordered)
    // The load-bearing property: the richest type stays ahead of plain text.
    #expect(restored.first?.representations.first?.type == "public.rtf")
  }

  @Test("Restores an empty clipboard as empty")
  func restoresEmptyClipboard() async throws {
    let pasteboard = FakePasteboard(items: [])
    let injector = makeInjector(pasteboard: pasteboard)

    try await injector.inject("texto")

    let restored = await pasteboard.items
    #expect(restored.isEmpty)
  }

  @Test("Waits for the paste to settle before reclaiming the clipboard")
  func waitsBeforeRestoring() async throws {
    let pasteboard = FakePasteboard(items: [FakePasteboard.item("antes")])
    let delay = makeDelay(noting: pasteboard)
    let injector = makeInjector(
      pasteboard: pasteboard, delay: delay, settleDelay: .milliseconds(42))

    try await injector.inject("texto")

    let waits = await delay.waits
    #expect(waits == [.milliseconds(42)])

    // The delay must land after the write and before the restore, otherwise the
    // target app would paste the user's old clipboard.
    let events = await pasteboard.events
    let settleIndex = try #require(events.firstIndex(of: .settleDelay))
    let writeIndex = try #require(events.firstIndex(of: .write("texto")))
    let restoreIndex = try #require(events.firstIndex(of: .restore))
    #expect(writeIndex < settleIndex)
    #expect(settleIndex < restoreIndex)
  }

  // MARK: Failure paths — the clipboard must survive all of them

  @Test("Restores the clipboard even when the paste keystroke fails")
  func restoresWhenPasteFails() async throws {
    let pasteboard = FakePasteboard(items: [FakePasteboard.item("conteúdo anterior")])
    let keystrokes = FakePasteKeystrokes(error: .accessibilityDenied)
    let delay = makeDelay(noting: pasteboard)
    let injector = makeInjector(pasteboard: pasteboard, keystrokes: keystrokes, delay: delay)

    await #expect(throws: InjectionError.accessibilityDenied) {
      try await injector.inject("olá mundo")
    }

    let restoredText = await pasteboard.currentText
    let events = await pasteboard.events
    let waits = await delay.waits
    #expect(restoredText == "conteúdo anterior")
    #expect(events.contains(.restore))
    // No point waiting for a paste that never landed.
    #expect(waits.isEmpty)
  }

  @Test("Restores the clipboard when the pasteboard write fails after clearing")
  func restoresWhenWriteFailsAfterClearing() async throws {
    let failure = InjectionError.pasteboardFailure(reason: "pasteboard rejected the write")
    let pasteboard = FakePasteboard(
      items: [FakePasteboard.item("conteúdo anterior")], writeError: failure)
    let keystrokes = FakePasteKeystrokes()
    let injector = makeInjector(pasteboard: pasteboard, keystrokes: keystrokes)

    await #expect(throws: failure) {
      try await injector.inject("olá mundo")
    }

    let restoredText = await pasteboard.currentText
    let sendCount = await keystrokes.sendCount
    #expect(restoredText == "conteúdo anterior")
    #expect(sendCount == 0)
  }

  @Test("Leaves an untouched clipboard alone when the write fails early")
  func doesNotRewriteClipboardWhenWriteFailsWithoutClearing() async throws {
    let failure = InjectionError.pasteboardFailure(reason: "pasteboard rejected the write")
    let pasteboard = FakePasteboard(
      items: [FakePasteboard.item("conteúdo anterior")],
      writeError: failure,
      writeErrorClearsContents: false)
    let injector = makeInjector(pasteboard: pasteboard)

    await #expect(throws: failure) {
      try await injector.inject("olá mundo")
    }

    let restoredText = await pasteboard.currentText
    let events = await pasteboard.events
    #expect(restoredText == "conteúdo anterior")
    #expect(events.contains(.restore) == false)
  }

  @Test("Surfaces a restore failure as a pasteboard failure")
  func surfacesRestoreFailure() async throws {
    let failure = InjectionError.pasteboardFailure(reason: "pasteboard rejected the restore")
    let pasteboard = FakePasteboard(
      items: [FakePasteboard.item("antes")], restoreError: failure)
    let injector = makeInjector(pasteboard: pasteboard)

    await #expect(throws: failure) {
      try await injector.inject("texto")
    }
  }

  @Test("A paste failure outranks a restore failure")
  func pasteFailureWinsOverRestoreFailure() async throws {
    let pasteboard = FakePasteboard(
      items: [FakePasteboard.item("antes")],
      restoreError: .pasteboardFailure(reason: "pasteboard rejected the restore"))
    let keystrokes = FakePasteKeystrokes(error: .accessibilityDenied)
    let injector = makeInjector(pasteboard: pasteboard, keystrokes: keystrokes)

    await #expect(throws: InjectionError.accessibilityDenied) {
      try await injector.inject("texto")
    }
  }

  // MARK: Snapshot fidelity (promised / lazily provided items)

  /// The clipboard holds a spreadsheet range or a promised file: every type it
  /// advertises is a promise the owner never fulfils, so the snapshot captures
  /// nothing. Writing the transcript would revoke the promise and destroy it.
  /// Before the fidelity gate, that snapshot was indistinguishable from an empty
  /// clipboard: the restore "succeeded" by wiping it and reported `.restored`.
  @Test("Refuses to inject over a clipboard whose contents cannot be captured")
  func refusesWhenSnapshotCannotBeCaptured() async throws {
    let promised = PasteboardSnapshot.Item(
      representations: [],
      unreadableTypes: ["com.microsoft.Excel.range", "public.file-url"])
    let pasteboard = FakePasteboard(items: [promised])
    let keystrokes = FakePasteKeystrokes()
    let injector = makeInjector(pasteboard: pasteboard, keystrokes: keystrokes)

    await #expect(throws: InjectionError.self) {
      try await injector.inject("transcrição")
    }

    // The refusal has to happen BEFORE the write: after it, the promise is gone.
    let events = await pasteboard.events
    let items = await pasteboard.items
    let sendCount = await keystrokes.sendCount
    #expect(events == [.snapshot])
    #expect(items == [promised])
    #expect(sendCount == 0)
  }

  /// Partial capture is not refused — the item survives, possibly downgraded —
  /// but the outcome must not claim an exact restore.
  @Test("Reports a partially captured clipboard as .restoredWithLoss")
  func reportsPartiallyCapturedClipboard() async throws {
    let partial = PasteboardSnapshot.Item(
      representations: [.init(type: FakePasteboard.stringType, data: Data("antes".utf8))],
      unreadableTypes: ["com.microsoft.Excel.range"])
    let pasteboard = FakePasteboard(items: [partial])
    let injector = makeInjector(pasteboard: pasteboard)

    let outcome = try await injector.injectReportingRestore("transcrição")

    let restoredText = await pasteboard.currentText
    #expect(outcome == .restoredWithLoss(unreadableTypes: ["com.microsoft.Excel.range"]))
    #expect(restoredText == "antes")
  }

  /// A degraded-but-present clipboard is not an injection failure: the paste
  /// landed and nothing the injector could do would have saved those bytes.
  @Test("A partial restore does not fail the injection")
  func partialRestoreIsNotAnInjectionFailure() async throws {
    let partial = PasteboardSnapshot.Item(
      representations: [.init(type: FakePasteboard.stringType, data: Data("antes".utf8))],
      unreadableTypes: ["public.tiff"])
    let pasteboard = FakePasteboard(items: [partial])
    let keystrokes = FakePasteKeystrokes()
    let injector = makeInjector(pasteboard: pasteboard, keystrokes: keystrokes)

    try await injector.inject("transcrição")

    #expect(await keystrokes.sendCount == 1)
  }

  // MARK: Change-count discipline

  @Test("Does not clobber something the user copied during the injection")
  func skipsRestoreWhenClipboardChangedDuringPaste() async throws {
    let pasteboard = FakePasteboard(items: [FakePasteboard.item("antes")])
    let keystrokes = FakePasteKeystrokes(onSend: { [pasteboard] in
      await pasteboard.simulateExternalWrite("copiado pelo usuário")
    })
    let injector = makeInjector(pasteboard: pasteboard, keystrokes: keystrokes)

    let outcome = try await injector.injectReportingRestore("texto")

    let currentText = await pasteboard.currentText
    let events = await pasteboard.events
    #expect(outcome == .skippedClipboardChanged)
    #expect(currentText == "copiado pelo usuário")
    #expect(events.contains(.restore) == false)
  }

  // MARK: Secure input (SPEC.md FR-13 / US-3)

  @Test("Refuses to inject while secure input is active, without touching the clipboard")
  func refusesWhenSecureInputActive() async throws {
    let pasteboard = FakePasteboard(items: [FakePasteboard.item("antes")])
    let keystrokes = FakePasteKeystrokes()
    let delay = makeDelay(noting: pasteboard)
    let injector = makeInjector(
      pasteboard: pasteboard, secureInputActive: true, keystrokes: keystrokes, delay: delay)

    await #expect(throws: InjectionError.secureInputActive) {
      try await injector.inject("minha senha")
    }

    // Nothing may reach the pasteboard: not a write, not even a snapshot.
    let events = await pasteboard.events
    let currentText = await pasteboard.currentText
    let sendCount = await keystrokes.sendCount
    let waits = await delay.waits
    #expect(events.isEmpty)
    #expect(currentText == "antes")
    #expect(sendCount == 0)
    #expect(waits.isEmpty)
  }

  @Test("Secure input is checked before anything else, including empty text")
  func secureInputOutranksEmptyText() async throws {
    let pasteboard = FakePasteboard()
    let injector = makeInjector(pasteboard: pasteboard, secureInputActive: true)

    await #expect(throws: InjectionError.secureInputActive) {
      try await injector.inject("")
    }
  }

  // MARK: Empty input

  @Test("Rejects empty text without touching the clipboard")
  func rejectsEmptyText() async throws {
    let pasteboard = FakePasteboard(items: [FakePasteboard.item("antes")])
    let keystrokes = FakePasteKeystrokes()
    let injector = makeInjector(pasteboard: pasteboard, keystrokes: keystrokes)

    await #expect(throws: InjectionError.emptyText) {
      try await injector.inject("")
    }

    let events = await pasteboard.events
    let sendCount = await keystrokes.sendCount
    #expect(events.isEmpty)
    #expect(sendCount == 0)
  }

  @Test("Rejects whitespace-only text", arguments: [" ", "\n", "  \t\n "])
  func rejectsWhitespaceOnlyText(text: String) async throws {
    let pasteboard = FakePasteboard(items: [FakePasteboard.item("antes")])
    let injector = makeInjector(pasteboard: pasteboard)

    await #expect(throws: InjectionError.emptyText) {
      try await injector.inject(text)
    }

    let events = await pasteboard.events
    #expect(events.isEmpty)
  }

  @Test("Injects surrounding whitespace verbatim")
  func injectsSurroundingWhitespaceVerbatim() async throws {
    let pasteboard = FakePasteboard()
    let injector = makeInjector(pasteboard: pasteboard)

    try await injector.inject(" olá ")

    let events = await pasteboard.events
    #expect(events.contains(.write(" olá ")))
  }

  // MARK: - Regressions

  /// Two dictations overlapping — a fast push-to-talk double-tap, or T2.5's
  /// undo-then-redictate. Before serialisation, the second injection snapshotted
  /// while the first still held the clipboard, captured the FIRST TRANSCRIPT as
  /// "the user's clipboard", and restored that: the user's data was destroyed and
  /// a transcript was left resident on the system clipboard.
  @Test("Overlapping injections do not destroy the user's clipboard")
  func overlappingInjectionsPreserveClipboard() async throws {
    let pasteboard = FakePasteboard(items: [FakePasteboard.item("IMPORTANTE")])
    // The settle delay yields repeatedly, so an unserialised second injection has
    // ample opportunity to snapshot while the first still holds the clipboard.
    // Without that the test would pass trivially on broken code.
    let delay = FakeDelay(onWait: {
      for _ in 0..<50 { await Task.yield() }
    })
    let injector = makeInjector(pasteboard: pasteboard, delay: delay)

    async let first: Void = injector.inject("transcricao A")
    async let second: Void = injector.inject("transcricao B")
    _ = try await (first, second)

    let final = await pasteboard.currentText
    #expect(final == "IMPORTANTE")

    // Serialised, not interleaved: each write is followed by its own restore.
    let events = await pasteboard.events
    let writesAndRestores = events.filter {
      if case .write = $0 { return true }
      return $0 == .restore
    }
    #expect(writesAndRestores.count == 4)
    if writesAndRestores.count == 4 {
      #expect(writesAndRestores[1] == .restore)
      #expect(writesAndRestores[3] == .restore)
    }
  }

  /// Serialisation must survive a failing predecessor: one bad injection cannot
  /// wedge every later dictation.
  @Test("A failed injection does not block the next one")
  func failureDoesNotWedgeTheQueue() async throws {
    let pasteboard = FakePasteboard(items: [FakePasteboard.item("IMPORTANTE")])
    let injector = makeInjector(pasteboard: pasteboard)

    await #expect(throws: InjectionError.self) { try await injector.inject("   ") }
    try await injector.inject("depois do erro")

    let events = await pasteboard.events
    #expect(events.contains(.write("depois do erro")))
    #expect(await pasteboard.currentText == "IMPORTANTE")
  }

  /// `.skippedClipboardChanged` means the user's clipboard was NOT put back.
  /// Reporting that as success through `TextInjector` hid real data loss.
  @Test("inject() reports an un-restored clipboard as a failure")
  func unrestoredClipboardSurfacesAsError() async throws {
    let pasteboard = FakePasteboard(items: [FakePasteboard.item("IMPORTANTE")])
    let keystrokes = FakePasteKeystrokes(onSend: {
      // The user copies something else while the paste is settling.
      await pasteboard.simulateExternalWrite("copiado pelo usuário")
    })
    let injector = makeInjector(pasteboard: pasteboard, keystrokes: keystrokes)

    await #expect(throws: InjectionError.self) {
      try await injector.inject("transcrição")
    }
  }

  /// FR-13 is a hard refusal, not a best effort: transcription takes ~100-150 ms,
  /// so the user can focus a password field after the initial check.
  @Test("Secure input engaging mid-injection blocks the paste")
  func secureInputEngagingMidInjectionBlocksPaste() async throws {
    let pasteboard = FakePasteboard(items: [FakePasteboard.item("IMPORTANTE")])
    let keystrokes = FakePasteKeystrokes()
    let secureInput = ToggleableSecureInput()
    let injector = ClipboardInjector(
      pasteboard: pasteboard,
      secureInput: secureInput,
      keystrokes: keystrokes,
      delay: FakeDelay(),
      pasteSettleDelay: .milliseconds(1))

    await secureInput.engageAfterFirstCheck()

    await #expect(throws: InjectionError.secureInputActive) {
      try await injector.inject("transcrição")
    }
    #expect(await keystrokes.sendCount == 0)
    #expect(await pasteboard.currentText == "IMPORTANTE")
  }
}

/// Reports "not secure" on the first probe and "secure" afterwards, modelling the
/// user clicking into a password field while transcription runs.
///
/// `SecureInputMonitoring.isSecureInputActive` is synchronous, so this cannot be an
/// actor. `OSAllocatedUnfairLock` is genuinely `Sendable` and shares one allocation
/// across copies, so no `@unchecked Sendable` is needed (CLAUDE.md forbids it).
private struct ToggleableSecureInput: SecureInputMonitoring {
  private struct State {
    var checkCount = 0
    var armed = false
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  func engageAfterFirstCheck() async {
    state.withLock { $0.armed = true }
  }

  var isSecureInputActive: Bool {
    state.withLock { state in
      defer { state.checkCount += 1 }
      return state.armed && state.checkCount > 0
    }
  }
}

@Suite("SecureInputMonitor")
struct SecureInputMonitorTests {
  @Test("Forwards the system probe", arguments: [true, false])
  func forwardsProbe(active: Bool) {
    let monitor = SecureInputMonitor(probe: { active })
    #expect(monitor.isSecureInputActive == active)
  }
}

// MARK: - SystemPasteboard (against a real NSPasteboard)

/// An `NSPasteboardItemDataProvider` that provides nothing.
///
/// This is the observable shape of a promised payload whose owner does not
/// fulfil it — a spreadsheet range, a promised file, an app that has quit:
/// `NSPasteboardItem.data(forType:)` returns nil for a type the item advertises.
/// Modelled with a real provider rather than a fake so the test exercises the
/// actual AppKit path `SystemPasteboard.snapshot()` walks.
private final class UnfulfilledPromiseProvider: NSObject, NSPasteboardItemDataProvider {
  func pasteboard(
    _ pasteboard: NSPasteboard?,
    item: NSPasteboardItem,
    provideDataForType type: NSPasteboard.PasteboardType
  ) {
    // Deliberately empty: the promise is never honoured.
  }
}

/// Real snapshot/restore against `NSPasteboard.withUniqueName()` — a private
/// pasteboard that needs no TCC grant, no `NSApplication` and no GUI, and that
/// never touches the user's own clipboard. Requires a running pasteboard server
/// (i.e. a normal user session), which is why the suite pins itself to the main
/// actor: AppKit pasteboard access is not documented as thread safe.
@Suite("SystemPasteboard")
@MainActor
struct SystemPasteboardTests {
  private static let rtf = NSPasteboard.PasteboardType("public.rtf")
  private static let html = NSPasteboard.PasteboardType("public.html")
  private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
  private static let promisedType = NSPasteboard.PasteboardType("com.fala.test.promised")

  private func makeBoard() -> NSPasteboard { NSPasteboard.withUniqueName() }

  private func types(of board: NSPasteboard) -> [[String]] {
    (board.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
  }

  @Test("Round-trips a rich item and preserves its reader-preference type order")
  func roundTripsRichItemPreservingOrder() async throws {
    let board = makeBoard()
    defer { board.releaseGlobally() }
    let item = NSPasteboardItem()
    item.setData(Data("{\\rtf1 olá}".utf8), forType: Self.rtf)
    item.setData(Data("<b>olá</b>".utf8), forType: Self.html)
    item.setData(Data("olá".utf8), forType: .string)
    board.clearContents()
    #expect(board.writeObjects([item]))
    let originalTypes = types(of: board)

    let sut = SystemPasteboard(pasteboard: board)
    let snapshot = await sut.snapshot()

    #expect(snapshot.items.count == 1)
    #expect(snapshot.isFaithful)
    #expect(snapshot.hasUnrecoverableItems == false)
    // The snapshot carries the board's own order, not an arbitrary one.
    #expect(snapshot.items.map { $0.representations.map(\.type) } == originalTypes)
    #expect(snapshot.items.first?.representations.first?.type == Self.rtf.rawValue)

    // Stand in for the injection: the transcript replaces everything.
    _ = try await sut.write("transcrição")
    #expect(board.data(forType: Self.rtf) == nil)

    try await sut.restore(snapshot)

    #expect(types(of: board) == originalTypes)
    #expect(board.string(forType: .string) == "olá")
    #expect(board.data(forType: Self.rtf) == Data("{\\rtf1 olá}".utf8))
    #expect(board.data(forType: Self.html) == Data("<b>olá</b>".utf8))
    // RTF must still outrank plain text, or the next Cmd+V pastes unstyled text.
    #expect(types(of: board).first?.first == Self.rtf.rawValue)
  }

  @Test("Restores an empty clipboard as empty")
  func restoresEmptyClipboardAsEmpty() async throws {
    let board = makeBoard()
    defer { board.releaseGlobally() }
    board.clearContents()

    let sut = SystemPasteboard(pasteboard: board)
    let snapshot = await sut.snapshot()
    #expect(snapshot.isEmpty)
    #expect(snapshot.hasUnrecoverableItems == false)

    _ = try await sut.write("transcrição")
    #expect(board.string(forType: .string) == "transcrição")

    try await sut.restore(snapshot)

    #expect(board.pasteboardItems?.isEmpty ?? true)
    #expect(board.string(forType: .string) == nil)
  }

  @Test("Tracks the pasteboard's change count")
  func tracksChangeCount() async throws {
    let board = makeBoard()
    defer { board.releaseGlobally() }
    let sut = SystemPasteboard(pasteboard: board)

    let before = await sut.currentChangeCount()
    let afterWrite = try await sut.write("transcrição")
    let observed = await sut.currentChangeCount()

    #expect(afterWrite > before)
    #expect(observed == afterWrite)
    #expect(observed == board.changeCount)
  }

  /// Regression guard on the privacy handling (NFR-1): the transcript is written
  /// `.currentHostOnly` so Universal Clipboard cannot sync it off-device, and
  /// carries the marker clipboard-history apps use to skip an item. Asserted,
  /// not changed.
  @Test("Marks the transcript with the concealed-type marker")
  func marksTranscriptAsConcealed() async throws {
    let board = makeBoard()
    defer { board.releaseGlobally() }
    let sut = SystemPasteboard(pasteboard: board)

    _ = try await sut.write("transcrição")

    let written = try #require(types(of: board).first)
    #expect(written.contains(Self.concealed.rawValue))
    #expect(board.string(forType: .string) == "transcrição")
  }

  // MARK: Promised (lazily provided) items

  @Test("Flags an unfulfilled promise as an unreadable type")
  func flagsUnfulfilledPromise() async throws {
    let board = makeBoard()
    defer { board.releaseGlobally() }
    let provider = UnfulfilledPromiseProvider()
    let item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: [Self.promisedType])
    board.clearContents()
    #expect(board.writeObjects([item]))

    let snapshot = await SystemPasteboard(pasteboard: board).snapshot()

    let captured = try #require(snapshot.items.first)
    #expect(snapshot.items.count == 1)
    #expect(captured.representations.isEmpty)
    #expect(captured.unreadableTypes == [Self.promisedType.rawValue])
    #expect(captured.isUnrecoverable)
    // The distinction the old snapshot could not express: NOT an empty clipboard.
    #expect(snapshot.isEmpty == false)
    #expect(snapshot.isFaithful == false)
    #expect(snapshot.hasUnrecoverableItems)
  }

  /// The primitive must not turn "I captured nothing" into `clearContents()`:
  /// that swaps the transcript the user can still paste for an empty clipboard.
  @Test("Refuses to clear a clipboard whose contents it could not capture")
  func refusesToClearUncapturedClipboard() async throws {
    let board = makeBoard()
    defer { board.releaseGlobally() }
    let provider = UnfulfilledPromiseProvider()
    let item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: [Self.promisedType])
    board.clearContents()
    #expect(board.writeObjects([item]))

    let sut = SystemPasteboard(pasteboard: board)
    let snapshot = await sut.snapshot()
    _ = try await sut.write("transcrição")

    await #expect(throws: InjectionError.self) {
      try await sut.restore(snapshot)
    }
    #expect(board.string(forType: .string) == "transcrição")
  }

  /// End-to-end on a real pasteboard: the user copied something we cannot
  /// reproduce, so the injection is refused BEFORE the write and the clipboard
  /// survives untouched. Previously this path wiped the clipboard and reported
  /// `.restored`.
  @Test("An injection over a promised clipboard is refused, leaving it intact")
  func injectionOverPromisedClipboardIsRefused() async throws {
    let board = makeBoard()
    defer { board.releaseGlobally() }
    let provider = UnfulfilledPromiseProvider()
    let item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: [Self.promisedType])
    board.clearContents()
    #expect(board.writeObjects([item]))
    let changeCountBefore = board.changeCount

    let keystrokes = FakePasteKeystrokes()
    let injector = ClipboardInjector(
      pasteboard: SystemPasteboard(pasteboard: board),
      secureInput: FakeSecureInput(isSecureInputActive: false),
      keystrokes: keystrokes,
      delay: FakeDelay(),
      pasteSettleDelay: .milliseconds(1))

    await #expect(throws: InjectionError.self) {
      try await injector.inject("transcrição")
    }

    #expect(await keystrokes.sendCount == 0)
    #expect(board.changeCount == changeCountBefore)
    #expect(types(of: board) == [[Self.promisedType.rawValue]])
  }

  /// Partial capture: the item advertises a promise AND a concrete preview. The
  /// preview survives the round trip, the promise cannot, and the outcome says
  /// so instead of claiming an exact restore.
  @Test("A partially promised item survives as far as it can, and reports the loss")
  func partiallyPromisedItemReportsLoss() async throws {
    let board = makeBoard()
    defer { board.releaseGlobally() }
    let provider = UnfulfilledPromiseProvider()
    let item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: [Self.promisedType])
    item.setString("prévia", forType: .string)
    board.clearContents()
    #expect(board.writeObjects([item]))

    let injector = ClipboardInjector(
      pasteboard: SystemPasteboard(pasteboard: board),
      secureInput: FakeSecureInput(isSecureInputActive: false),
      keystrokes: FakePasteKeystrokes(),
      delay: FakeDelay(),
      pasteSettleDelay: .milliseconds(1))

    let outcome = try await injector.injectReportingRestore("transcrição")

    #expect(outcome == .restoredWithLoss(unreadableTypes: [Self.promisedType.rawValue]))
    #expect(board.string(forType: .string) == "prévia")
    #expect(board.data(forType: Self.promisedType) == nil)
  }

  /// The mixed snapshot: one readable item plus one unfulfilled promise.
  ///
  /// The guard used to be `!writable.isEmpty`, which this case satisfies (the
  /// readable item is writable), so `clearContents()` ran and the promised item
  /// was destroyed with nothing written back — while the caller was told the
  /// restore succeeded. Every other promised-item test uses a SINGLE item, so
  /// none of them could see it.
  @Test("A mixed snapshot is refused rather than partially destroyed")
  func mixedSnapshotIsRefused() async throws {
    let readable = PasteboardSnapshot.Item(
      representations: [.init(type: "public.utf8-plain-text", data: Data("importante".utf8))],
      unreadableTypes: [])
    let promised = PasteboardSnapshot.Item(
      representations: [], unreadableTypes: ["com.microsoft.Excel.range"])
    let snapshot = PasteboardSnapshot(items: [readable, promised], changeCount: 1)

    let board = makeBoard()
    board.clearContents()
    board.setString("o que o usuário copiou", forType: .string)
    let pasteboard = SystemPasteboard(pasteboard: board)

    await #expect(throws: InjectionError.self) {
      try await pasteboard.restore(snapshot)
    }
    // The refusal must happen BEFORE clearContents, so the board is untouched.
    #expect(board.string(forType: .string) == "o que o usuário copiou")
  }
}
