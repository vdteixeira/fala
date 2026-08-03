import Foundation
import Testing

@testable import FalaKit

// MARK: - Fakes

/// A `TextInjector` that records what it was asked to inject.
private actor RecordingInjector: TextInjector {
  private(set) var injected: [String] = []
  private let error: (any Error)?
  private let onInject: (@Sendable () async -> Void)?

  init(error: (any Error)? = nil, onInject: (@Sendable () async -> Void)? = nil) {
    self.error = error
    self.onInject = onInject
  }

  func inject(_ text: String) async throws {
    injected.append(text)
    await onInject?()
    if let error { throw error }
  }
}

private struct StubFrontmost: FrontmostApplicationProviding {
  let bundleIdentifier: String?

  func current() async -> DestinationApp? {
    DestinationApp(bundleIdentifier: bundleIdentifier, name: nil)
  }
}

private struct FixedSecure: SecureInputMonitoring {
  let isSecureInputActive: Bool
}

private actor StubPasteboard: PasteboardAccessing {
  private(set) var items: [PasteboardSnapshot.Item]
  private(set) var changeCount: Int
  private(set) var writeCount = 0
  private let writeError: InjectionError?
  private let restoreError: InjectionError?

  init(
    items: [PasteboardSnapshot.Item] = [],
    changeCount: Int = 3,
    writeError: InjectionError? = nil,
    restoreError: InjectionError? = nil
  ) {
    self.items = items
    self.changeCount = changeCount
    self.writeError = writeError
    self.restoreError = restoreError
  }

  func currentChangeCount() async -> Int { changeCount }

  func snapshot() async -> PasteboardSnapshot {
    PasteboardSnapshot(items: items, changeCount: changeCount)
  }

  func write(_ text: String) async throws -> Int {
    writeCount += 1
    if let writeError { throw writeError }
    items = [Self.textItem(text)]
    changeCount += 1
    return changeCount
  }

  func restore(_ snapshot: PasteboardSnapshot) async throws {
    if let restoreError { throw restoreError }
    items = snapshot.items
    changeCount += 1
  }

  func simulateExternalWrite() {
    items = [Self.textItem("copiado pelo usuário")]
    changeCount += 1
  }

  static func textItem(_ text: String) -> PasteboardSnapshot.Item {
    PasteboardSnapshot.Item(
      representations: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])
  }

  /// The case FR-12 exists for: a copied spreadsheet range or promised file,
  /// advertised but not readable, which `ClipboardInjector` refuses to clear.
  static let promisedItem = PasteboardSnapshot.Item(
    representations: [], unreadableTypes: ["com.microsoft.Excel.range"])
}

private actor StubPasteKeystrokes: PasteKeystrokeEmitting {
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

private struct InstantDelay: InjectionDelaying {
  func wait(for duration: Duration) async {}
  func waitIgnoringCancellation(for duration: Duration) async {}
}

/// A REAL `ClipboardInjector` driven into a chosen failure. Used instead of a
/// hand-built `InjectionError` so the fallback rules are tested against the
/// errors the shipping injector actually throws — the wording lives in
/// `ClipboardInjector`, and these are the tripwires that fire if it changes.
private func realClipboardInjector(
  pasteboard: StubPasteboard,
  secureInputActive: Bool = false,
  keystrokes: StubPasteKeystrokes = StubPasteKeystrokes()
) -> ClipboardInjector {
  ClipboardInjector(
    pasteboard: pasteboard,
    secureInput: FixedSecure(isSecureInputActive: secureInputActive),
    keystrokes: keystrokes,
    delay: InstantDelay(),
    pasteSettleDelay: .milliseconds(1))
}

private func makeAdaptive(
  clipboard: any TextInjector,
  unicode: any TextInjector,
  bundleIdentifier: String? = "com.example.editor",
  policy: InjectionPolicy = .default
) -> AdaptiveTextInjector {
  AdaptiveTextInjector(
    clipboard: clipboard,
    unicode: unicode,
    chooser: InjectionStrategyChooser(
      policy: policy, frontmostApp: StubFrontmost(bundleIdentifier: bundleIdentifier)))
}

// MARK: - Fallback eligibility

@Suite("InjectionFallbackEligibility")
struct InjectionFallbackEligibilityTests {
  /// Retyping into a focused password field is the single worst thing this
  /// component could do, and it is exactly what a naive "clipboard failed, try
  /// the other one" would produce (FR-13 / US-3).
  @Test("Never retypes after a secure-input refusal")
  func neverRetypesAfterSecureInput() {
    #expect(InjectionFallbackEligibility.allowsRetyping(after: .secureInputActive) == false)
  }

  @Test("Never retypes when Accessibility is missing — both paths need it")
  func neverRetypesWithoutAccessibility() {
    #expect(InjectionFallbackEligibility.allowsRetyping(after: .accessibilityDenied) == false)
  }

  @Test("Never retypes empty text")
  func neverRetypesEmptyText() {
    #expect(InjectionFallbackEligibility.allowsRetyping(after: .emptyText) == false)
  }

  @Test("Retypes after a refusal that happened before anything was pasted")
  func retypesAfterPreInsertionRefusal() {
    let reasons = [
      "clipboard holds promised content that could not be captured",
      "pasteboard rejected the write",
      "clipboard write failed",
    ]
    for reason in reasons {
      #expect(
        InjectionFallbackEligibility.allowsRetyping(after: .pasteboardFailure(reason: reason)),
        "expected a retype for: \(reason)")
    }
  }

  /// The failure this classifier exists to avoid: in both of these the text
  /// ALREADY reached the document, so retyping would insert it twice.
  @Test("Never retypes after a failure that happened once the paste had landed")
  func neverRetypesAfterInsertion() {
    let reasons = [
      "clipboard changed during injection; previous contents not restored",
      "clipboard restore failed",
      "pasteboard rejected the restore",
    ]
    for reason in reasons {
      #expect(
        InjectionFallbackEligibility.allowsRetyping(after: .pasteboardFailure(reason: reason))
          == false,
        "expected no retype for: \(reason)")
    }
  }

  /// An allowlist, not a denylist: an unrecognised reason must NOT retype. That
  /// way a new failure mode upstream costs one dictation instead of duplicating
  /// text in the user's document.
  @Test("An unrecognised reason does not retype")
  func unknownReasonDoesNotRetype() {
    let unknown = InjectionError.pasteboardFailure(reason: "algo novo que ninguém previu")
    #expect(InjectionFallbackEligibility.allowsRetyping(after: unknown) == false)
  }
}

// MARK: - AdaptiveTextInjector

@Suite("AdaptiveTextInjector")
struct AdaptiveTextInjectorTests {
  private static let text = "faz o deploy no endpoint do Kubernetes"

  // MARK: Choosing

  @Test("Uses the clipboard for an app with no rule, and never the unicode path")
  func usesClipboardByDefault() async throws {
    let clipboard = RecordingInjector()
    let unicode = RecordingInjector()
    let injector = makeAdaptive(clipboard: clipboard, unicode: unicode)

    let outcome = try await injector.injectReportingStrategy(Self.text)

    #expect(await clipboard.injected == [Self.text])
    #expect(await unicode.injected.isEmpty)
    #expect(outcome.strategyUsed == .clipboard)
    #expect(outcome.didFallBack == false)
    #expect(outcome.decision.isDefault)
  }

  @Test("Uses the unicode path when the policy asks for it, without touching the clipboard")
  func usesUnicodeWhenPolicySaysSo() async throws {
    let clipboard = RecordingInjector()
    let unicode = RecordingInjector()
    let policy = InjectionPolicy(rules: [
      InjectionRule(
        bundleIdentifier: "com.example.editor", strategy: .unicode,
        evidence: .observed, reason: "test rule")
    ])
    let injector = makeAdaptive(clipboard: clipboard, unicode: unicode, policy: policy)

    let outcome = try await injector.injectReportingStrategy(Self.text)

    #expect(await unicode.injected == [Self.text])
    #expect(await clipboard.injected.isEmpty)
    #expect(outcome.strategyUsed == .unicode)
    #expect(outcome.didFallBack == false)
  }

  // MARK: The case this whole task exists for

  /// The clipboard holds a copied spreadsheet range: `ClipboardInjector`
  /// refuses, because clearing it would destroy data nothing can bring back.
  /// Before T2.8 that cost the user the whole dictation. Driven through a REAL
  /// `ClipboardInjector`, so this fails if the refusal or its wording changes.
  @Test("Retypes the transcript when the clipboard cannot be captured")
  func retypesWhenClipboardCannotBeCaptured() async throws {
    let pasteboard = StubPasteboard(items: [StubPasteboard.promisedItem])
    let unicode = RecordingInjector()
    let injector = makeAdaptive(
      clipboard: realClipboardInjector(pasteboard: pasteboard), unicode: unicode)

    let outcome = try await injector.injectReportingStrategy(Self.text)

    #expect(await unicode.injected == [Self.text])
    #expect(outcome.strategyUsed == .unicode)
    #expect(outcome.didFallBack)
    // The user's uncapturable clipboard is still exactly where it was.
    #expect(await pasteboard.writeCount == 0)
    #expect(await pasteboard.items == [StubPasteboard.promisedItem])
    #expect(await pasteboard.changeCount == 3)
  }

  /// A broken pasteboard is not a reason to lose a dictation: nothing was
  /// inserted, and the unicode path does not need a pasteboard at all.
  @Test("Retypes when the pasteboard rejects the write")
  func retypesWhenPasteboardRejectsWrite() async throws {
    let pasteboard = StubPasteboard(
      items: [StubPasteboard.textItem("antes")],
      writeError: .pasteboardFailure(reason: "pasteboard rejected the write"))
    let unicode = RecordingInjector()
    let injector = makeAdaptive(
      clipboard: realClipboardInjector(pasteboard: pasteboard), unicode: unicode)

    let outcome = try await injector.injectReportingStrategy(Self.text)

    #expect(await unicode.injected == [Self.text])
    #expect(outcome.didFallBack)
  }

  /// The deliberate hole in the allowlist: if Quartz would not build the ⌘V
  /// events, it will not build the unicode ones either, so retyping buys a
  /// second identical failure.
  @Test("Does not retype when the paste chord could not be built")
  func doesNotRetypeWhenChordCouldNotBeBuilt() async throws {
    let pasteboard = StubPasteboard(items: [StubPasteboard.textItem("antes")])
    let keystrokes = StubPasteKeystrokes(
      error: .pasteboardFailure(reason: "could not build key events"))
    let unicode = RecordingInjector()
    let injector = makeAdaptive(
      clipboard: realClipboardInjector(pasteboard: pasteboard, keystrokes: keystrokes),
      unicode: unicode)

    await #expect(throws: InjectionError.self) {
      try await injector.inject(Self.text)
    }
    #expect(await unicode.injected.isEmpty)
  }

  // MARK: Failures that must NOT be retyped

  /// The transcript already landed in the document; the failure is about the
  /// user's clipboard not being restored. Retyping would insert it twice.
  @Test("Does not retype when the paste succeeded and only the restore failed")
  func doesNotRetypeAfterASuccessfulPaste() async throws {
    let pasteboard = StubPasteboard(
      items: [StubPasteboard.textItem("antes")],
      restoreError: .pasteboardFailure(reason: "pasteboard rejected the restore"))
    let unicode = RecordingInjector()
    let injector = makeAdaptive(
      clipboard: realClipboardInjector(pasteboard: pasteboard), unicode: unicode)

    await #expect(throws: InjectionError.self) {
      try await injector.inject(Self.text)
    }

    #expect(await unicode.injected.isEmpty)
  }

  /// Same shape, different route: the user copied something during the paste,
  /// so the clipboard was left alone and `inject` reports the loss — but the
  /// transcript is in the document already.
  @Test("Does not retype when the clipboard changed during a successful paste")
  func doesNotRetypeWhenClipboardChangedDuringPaste() async throws {
    let pasteboard = StubPasteboard(items: [StubPasteboard.textItem("antes")])
    let keystrokes = StubPasteKeystrokes(onSend: { [pasteboard] in
      await pasteboard.simulateExternalWrite()
    })
    let unicode = RecordingInjector()
    let injector = makeAdaptive(
      clipboard: realClipboardInjector(pasteboard: pasteboard, keystrokes: keystrokes),
      unicode: unicode)

    await #expect(throws: InjectionError.self) {
      try await injector.inject(Self.text)
    }

    #expect(await keystrokes.sendCount == 1)
    #expect(await unicode.injected.isEmpty)
  }

  /// FR-13 / US-3. A password field has focus: the clipboard path refuses, and
  /// the recovery must NOT be to type the transcript into it one chunk at a
  /// time. Driven through a real `ClipboardInjector` so the refusal is the
  /// shipping one.
  @Test("Never retypes into a secure field")
  func neverRetypesIntoASecureField() async throws {
    let pasteboard = StubPasteboard(items: [StubPasteboard.textItem("antes")])
    let unicode = RecordingInjector()
    let injector = makeAdaptive(
      clipboard: realClipboardInjector(pasteboard: pasteboard, secureInputActive: true),
      unicode: unicode)

    await #expect(throws: InjectionError.secureInputActive) {
      try await injector.inject("minha senha")
    }

    #expect(await unicode.injected.isEmpty)
    #expect(await pasteboard.writeCount == 0)
  }

  @Test("Does not retype when Accessibility is missing")
  func doesNotRetypeWithoutAccessibility() async throws {
    let clipboard = RecordingInjector(error: InjectionError.accessibilityDenied)
    let unicode = RecordingInjector()
    let injector = makeAdaptive(clipboard: clipboard, unicode: unicode)

    await #expect(throws: InjectionError.accessibilityDenied) {
      try await injector.inject(Self.text)
    }
    #expect(await unicode.injected.isEmpty)
  }

  @Test("Does not retype empty text")
  func doesNotRetypeEmptyText() async throws {
    let clipboard = RecordingInjector(error: InjectionError.emptyText)
    let unicode = RecordingInjector()
    let injector = makeAdaptive(clipboard: clipboard, unicode: unicode)

    await #expect(throws: InjectionError.emptyText) {
      try await injector.inject("   ")
    }
    #expect(await unicode.injected.isEmpty)
  }

  /// An error the classifier has never seen leaves the state of the document
  /// unknown, so it propagates untouched.
  @Test("Propagates a non-injection error without retyping")
  func propagatesUnknownErrorWithoutRetyping() async throws {
    struct Boom: Error {}
    let clipboard = RecordingInjector(error: Boom())
    let unicode = RecordingInjector()
    let injector = makeAdaptive(clipboard: clipboard, unicode: unicode)

    await #expect(throws: Boom.self) {
      try await injector.inject(Self.text)
    }
    #expect(await unicode.injected.isEmpty)
  }

  /// The fallback is one-directional. A failed unicode attempt may have typed
  /// PART of the transcript already, so a clipboard retry would duplicate it.
  @Test("Never falls back from the unicode path to the clipboard")
  func neverFallsBackFromUnicodeToClipboard() async throws {
    let clipboard = RecordingInjector()
    let unicode = RecordingInjector(
      error: InjectionError.pasteboardFailure(reason: "promised content"))
    let policy = InjectionPolicy(rules: [
      InjectionRule(
        bundleIdentifier: "com.example.editor", strategy: .unicode,
        evidence: .observed, reason: "test rule")
    ])
    let injector = makeAdaptive(clipboard: clipboard, unicode: unicode, policy: policy)

    await #expect(throws: InjectionError.self) {
      try await injector.inject(Self.text)
    }
    #expect(await clipboard.injected.isEmpty)
  }

  // MARK: Per-app fallback restrictions (FR-14)

  /// The terminal rule. A typed newline presses Return at a shell prompt, so a
  /// multi-line transcript is not retyped even though the clipboard refused —
  /// the dictation is lost instead, which the user can repeat.
  @Test("Refuses to retype multiline text into a terminal")
  func refusesToRetypeMultilineTextIntoATerminal() async throws {
    let pasteboard = StubPasteboard(items: [StubPasteboard.promisedItem])
    let unicode = RecordingInjector()
    let injector = makeAdaptive(
      clipboard: realClipboardInjector(pasteboard: pasteboard),
      unicode: unicode,
      bundleIdentifier: "com.apple.Terminal")

    await #expect(throws: InjectionError.self) {
      try await injector.inject("git commit\nrm -rf /tmp/x")
    }
    #expect(await unicode.injected.isEmpty)
  }

  /// …and the other half of the same rule: single-line text carries no such
  /// hazard, so the user still gets their dictation.
  @Test("Still retypes single-line text into a terminal")
  func retypesSingleLineTextIntoATerminal() async throws {
    let pasteboard = StubPasteboard(items: [StubPasteboard.promisedItem])
    let unicode = RecordingInjector()
    let injector = makeAdaptive(
      clipboard: realClipboardInjector(pasteboard: pasteboard),
      unicode: unicode,
      bundleIdentifier: "com.apple.Terminal")

    let outcome = try await injector.injectReportingStrategy("git status")

    #expect(await unicode.injected == ["git status"])
    #expect(outcome.didFallBack)
  }

  @Test("Honours a blanket fallback refusal")
  func honoursBlanketFallbackRefusal() async throws {
    let policy = InjectionPolicy(rules: [
      InjectionRule(
        bundleIdentifier: "com.example.editor", strategy: .clipboard,
        fallback: .refused, evidence: .observed, reason: "test rule")
    ])
    let pasteboard = StubPasteboard(items: [StubPasteboard.promisedItem])
    let unicode = RecordingInjector()
    let injector = makeAdaptive(
      clipboard: realClipboardInjector(pasteboard: pasteboard),
      unicode: unicode,
      policy: policy)

    await #expect(throws: InjectionError.self) {
      try await injector.inject(Self.text)
    }
    #expect(await unicode.injected.isEmpty)
  }

  // MARK: Concurrency

  /// Two overlapping dictations that pick DIFFERENT strategies are not
  /// serialised by either underlying injector — each one only chains against
  /// itself — so the composite has to do it.
  @Test("Overlapping injections are serialised across strategies")
  func overlappingInjectionsAreSerialised() async throws {
    let order = RecordingInjector()
    let clipboard = RecordingInjector(
      error: InjectionError.pasteboardFailure(reason: "clipboard holds promised content"),
      onInject: { for _ in 0..<20 { await Task.yield() } })
    let injector = makeAdaptive(clipboard: clipboard, unicode: order)

    async let first: Void = injector.inject("primeira")
    async let second: Void = injector.inject("segunda")
    _ = try await (first, second)

    let injected = await order.injected
    #expect(injected == ["primeira", "segunda"] || injected == ["segunda", "primeira"])
  }

  @Test("A failed injection does not wedge the next one")
  func failureDoesNotWedgeTheQueue() async throws {
    let clipboard = RecordingInjector(error: InjectionError.accessibilityDenied)
    let unicode = RecordingInjector()
    let injector = makeAdaptive(clipboard: clipboard, unicode: unicode)

    await #expect(throws: InjectionError.self) { try await injector.inject("primeira") }
    await #expect(throws: InjectionError.self) { try await injector.inject("segunda") }

    #expect(await clipboard.injected == ["primeira", "segunda"])
  }
}
