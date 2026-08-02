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
    guard let data = items.first?.representations[Self.stringType] else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func item(_ text: String) -> PasteboardSnapshot.Item {
    PasteboardSnapshot.Item(representations: [stringType: Data(text.utf8)])
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
        FakePasteboard.stringType: Data("oi".utf8),
        "public.html": Data("<b>oi</b>".utf8),
      ]),
      PasteboardSnapshot.Item(representations: [
        "public.png": Data([0x89, 0x50, 0x4E, 0x47])
      ]),
    ]
    let pasteboard = FakePasteboard(items: rich)
    let injector = makeInjector(pasteboard: pasteboard)

    try await injector.inject("transcrição")

    let restored = await pasteboard.items
    #expect(restored == rich)
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
