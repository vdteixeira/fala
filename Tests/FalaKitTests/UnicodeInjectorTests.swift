import AppKit
import Foundation
import Testing
import os

@testable import FalaKit

// MARK: - Fakes
//
// File-private so they cannot collide with the fakes other suites declare.
// Actors or lock-backed structs throughout, so nothing needs `@unchecked
// Sendable` (forbidden by CLAUDE.md).

/// Records what would have been typed, in order, without posting anything.
private actor RecordingUnicodeKeystrokes: UnicodeKeystrokeEmitting {
  enum Event: Equatable {
    case send(String)
    /// Emitted by `RecordingDelay`, to put the sleeps on the same timeline.
    case delay(Duration)
  }

  private(set) var events: [Event] = []
  private let error: InjectionError?
  private let onSend: (@Sendable (Int) async -> Void)?

  init(error: InjectionError? = nil, onSend: (@Sendable (Int) async -> Void)? = nil) {
    self.error = error
    self.onSend = onSend
  }

  func send(_ chunk: String) async throws {
    events.append(.send(chunk))
    await onSend?(chunks.count)
    if let error { throw error }
  }

  func note(_ duration: Duration) {
    events.append(.delay(duration))
  }

  /// Everything that was handed to the emitter, in order.
  var chunks: [String] {
    events.compactMap {
      if case .send(let chunk) = $0 { return chunk }
      return nil
    }
  }

  var typedText: String { chunks.joined() }

  var delays: [Duration] {
    events.compactMap {
      if case .delay(let duration) = $0 { return duration }
      return nil
    }
  }
}

private actor RecordingDelay: InjectionDelaying {
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

/// A delay that records itself on the emitter's log, so send/sleep ordering is
/// observable from one timeline.
private func makeDelay(noting emitter: RecordingUnicodeKeystrokes) -> RecordingDelay {
  RecordingDelay(onWait: { [emitter] in
    await emitter.note(UnicodeInjector.defaultInterChunkDelay)
  })
}

private struct FixedSecureInput: SecureInputMonitoring {
  let isSecureInputActive: Bool
}

/// Reports "not secure" for the first `safeProbes` reads and "secure"
/// afterwards — the user clicking into a password field mid-dictation.
///
/// `isSecureInputActive` is synchronous so this cannot be an actor;
/// `OSAllocatedUnfairLock` is genuinely `Sendable` and shares one allocation
/// across copies, so no `@unchecked Sendable` is needed.
private struct SecureInputEngagingAfter: SecureInputMonitoring {
  let safeProbes: Int
  private let probeCount = OSAllocatedUnfairLock(initialState: 0)

  init(safeProbes: Int) {
    self.safeProbes = safeProbes
  }

  var isSecureInputActive: Bool {
    probeCount.withLock { count in
      defer { count += 1 }
      return count >= safeProbes
    }
  }
}

private func makeInjector(
  keystrokes: RecordingUnicodeKeystrokes,
  secureInput: any SecureInputMonitoring = FixedSecureInput(isSecureInputActive: false),
  delay: RecordingDelay? = nil,
  chunker: UnicodeChunker = UnicodeChunker(),
  interChunkDelay: Duration = UnicodeInjector.defaultInterChunkDelay
) -> UnicodeInjector {
  UnicodeInjector(
    keystrokes: keystrokes,
    secureInput: secureInput,
    delay: delay ?? makeDelay(noting: keystrokes),
    chunker: chunker,
    interChunkDelay: interChunkDelay)
}

// MARK: - Chunker

@Suite("UnicodeChunker")
struct UnicodeChunkerTests {
  /// Strings the chunker must survive. Heavy on the two things that break a
  /// naive UTF-16 split: Brazilian accents (including decomposed ones, which an
  /// ASR engine is under no obligation to normalise) and multi-scalar emoji.
  static let corpus: [String] = [
    "a",
    "olá mundo",
    "faz o deploy no endpoint do Kubernetes e sobe o container",
    "coração, ação, não é fácil pôr açúcar à mão",
    // Decomposed (NFD): every accent is a separate scalar after its base.
    "e\u{0301}poca a\u{0303}ncora cinqu\u{0308}enta pa\u{0301}ssaro tambe\u{0301}m",
    "emoji 😀😃😄😁 e bandeiras 🇧🇷🇵🇹 no meio",
    "família 👨‍👩‍👧‍👦 inteira num cluster só",
    "teclas 1️⃣2️⃣3️⃣ e símbolos ⌘⌥⇧",
    "  espaços  em  volta  ",
    "linha um\nlinha dois\r\nlinha três",
    String(repeating: "a", count: 100),
    String(repeating: "é", count: 37),
    String(repeating: "😀", count: 13),
  ]

  @Test("Reassembles the string exactly", arguments: corpus)
  func reassemblesExactly(text: String) {
    let chunks = UnicodeChunker().chunks(of: text)
    #expect(chunks.joined() == text)
  }

  /// The load-bearing property. Splitting a surrogate pair or separating a
  /// combining mark from its base changes how many grapheme clusters exist, so
  /// counting `Character`s across the chunks is a direct test that no cluster
  /// was cut in half.
  @Test("Never splits a grapheme cluster", arguments: corpus)
  func neverSplitsGraphemes(text: String) {
    let chunks = UnicodeChunker().chunks(of: text)
    #expect(chunks.map(\.count).reduce(0, +) == text.count)
  }

  /// The same property seen from the other side: a chunk that began with a
  /// combining mark would mean the previous chunk kept its base letter, and the
  /// target app would be asked to combine across two separate key events.
  @Test("No chunk starts with a combining mark", arguments: corpus)
  func noChunkStartsWithCombiningMark(text: String) {
    for chunk in UnicodeChunker().chunks(of: text) {
      guard let scalar = chunk.unicodeScalars.first else {
        Issue.record("empty chunk")
        continue
      }
      #expect(scalar.properties.isGraphemeExtend == false)
    }
  }

  @Test("Keeps every chunk inside the UTF-16 budget", arguments: corpus)
  func respectsTheBudget(text: String) {
    for chunk in UnicodeChunker().chunks(of: text) {
      // The documented exception: a single cluster bigger than the budget goes
      // out whole rather than being corrupted.
      #expect(chunk.utf16.count <= UnicodeChunker.defaultMaxUnitsPerChunk || chunk.count == 1)
    }
  }

  @Test("Splits plain ASCII into full chunks of the budget")
  func splitsAsciiIntoFullChunks() {
    let chunks = UnicodeChunker().chunks(of: String(repeating: "a", count: 100))
    #expect(chunks.count == 5)
    #expect(chunks.allSatisfy { $0.count == 20 })
  }

  @Test("Emits nothing for an empty string")
  func emptyStringYieldsNoChunks() {
    #expect(UnicodeChunker().chunks(of: "").isEmpty)
  }

  @Test("Preserves order")
  func preservesOrder() {
    let text = (0..<10).map { String(repeating: "\($0)", count: 20) }.joined()
    let chunks = UnicodeChunker().chunks(of: text)
    #expect(chunks == (0..<10).map { String(repeating: "\($0)", count: 20) })
  }

  /// An emoji is a surrogate pair: at 19 units used it cannot fit, and half of
  /// it must NOT be sent in the outgoing chunk.
  @Test("Moves a surrogate pair to the next chunk rather than splitting it")
  func movesSurrogatePairRatherThanSplitting() {
    let text = String(repeating: "a", count: 19) + "😀" + "resto"
    let chunks = UnicodeChunker().chunks(of: text)

    #expect(chunks[0] == String(repeating: "a", count: 19))
    #expect(chunks[1].first == "😀")
    #expect(chunks.joined() == text)
  }

  @Test("Fills the budget exactly when a surrogate pair just fits")
  func fillsBudgetExactlyWithSurrogatePair() {
    let text = String(repeating: "a", count: 18) + "😀" + "b"
    let chunks = UnicodeChunker().chunks(of: text)

    #expect(chunks[0].utf16.count == 20)
    #expect(chunks[0].hasSuffix("😀"))
    #expect(chunks[1] == "b")
  }

  /// Portuguese, decomposed: "é" is `e` + U+0301. Cutting between them delivers
  /// a bare "e" and then an accent looking for a base in the next event.
  @Test("Keeps a decomposed accent with its base letter across a boundary")
  func keepsDecomposedAccentWithItsBase() {
    let accented = "e\u{0301}"
    let text = String(repeating: "a", count: 19) + accented + "poca"
    let chunks = UnicodeChunker().chunks(of: text)

    #expect(chunks[0] == String(repeating: "a", count: 19))
    #expect(chunks[1].unicodeScalars.first == "e")
    #expect(chunks[1].unicodeScalars.dropFirst().first == "\u{0301}")
    #expect(chunks.joined() == text)
  }

  /// A ZWJ family is 11 UTF-16 units and 7 scalars. With a budget of 4 it
  /// cannot fit — and the answer is to send it whole and over budget, because
  /// the alternative is four unrelated people.
  @Test("Sends an oversized grapheme cluster whole rather than splitting it")
  func sendsOversizedClusterWhole() {
    let family = "👨‍👩‍👧‍👦"
    let chunks = UnicodeChunker(maxUnitsPerChunk: 4).chunks(of: "ab" + family + "cd")

    #expect(chunks.contains(family))
    #expect(chunks.joined() == "ab" + family + "cd")
    #expect(family.utf16.count > 4)
  }

  @Test("Honours a custom budget", arguments: [1, 2, 3, 7, 20, 64])
  func honoursCustomBudget(budget: Int) {
    let text = "coração 😀 deploy no endpoint\ncom acentuação decomposta e\u{0301}poca"
    let chunker = UnicodeChunker(maxUnitsPerChunk: budget)
    let chunks = chunker.chunks(of: text)

    #expect(chunks.joined() == text)
    #expect(chunks.map(\.count).reduce(0, +) == text.count)
    for chunk in chunks {
      #expect(chunk.utf16.count <= budget || chunk.count == 1)
    }
  }

  /// A zero or negative budget would either loop forever or emit empty events.
  @Test("Clamps a nonsensical budget to one unit", arguments: [0, -1, Int.min])
  func clampsNonsensicalBudget(budget: Int) {
    let chunker = UnicodeChunker(maxUnitsPerChunk: budget)
    #expect(chunker.maxUnitsPerChunk == 1)
    #expect(chunker.chunks(of: "olá").joined() == "olá")
  }

  @Test("Defaults to FR-12's ~20 UniChars")
  func defaultsToSpecBudget() {
    #expect(UnicodeChunker().maxUnitsPerChunk == 20)
    #expect(UnicodeChunker.defaultMaxUnitsPerChunk == 20)
  }
}

// MARK: - UnicodeInjector

@Suite("UnicodeInjector")
struct UnicodeInjectorTests {
  private static let sentence =
    "faz o deploy no endpoint do Kubernetes, com acentuação e emoji 😀 no fim"

  @Test("Types the whole transcript, in order, in chunker-sized pieces")
  func typesWholeTranscriptInOrder() async throws {
    let keystrokes = RecordingUnicodeKeystrokes()
    let injector = makeInjector(keystrokes: keystrokes)

    try await injector.inject(Self.sentence)

    let chunks = await keystrokes.chunks
    #expect(await keystrokes.typedText == Self.sentence)
    #expect(chunks == UnicodeChunker().chunks(of: Self.sentence))
    #expect(chunks.count > 1)
  }

  @Test("Sleeps between events, never before the first or after the last")
  func sleepsBetweenEvents() async throws {
    let keystrokes = RecordingUnicodeKeystrokes()
    let delay = makeDelay(noting: keystrokes)
    let injector = makeInjector(keystrokes: keystrokes, delay: delay)

    try await injector.inject(Self.sentence)

    let expected = UnicodeChunker().chunks(of: Self.sentence).count
    let waits = await delay.waits
    #expect(waits.count == expected - 1)
    #expect(waits.allSatisfy { $0 == UnicodeInjector.defaultInterChunkDelay })

    // Strictly alternating on one timeline: send, delay, send, delay, send…
    let events = await keystrokes.events
    #expect(events.count == expected * 2 - 1)
    for (index, event) in events.enumerated() {
      let isSend: Bool
      if case .send = event { isSend = true } else { isSend = false }
      #expect(isSend == (index % 2 == 0))
    }
  }

  @Test("Does not sleep at all for a single chunk")
  func doesNotSleepForSingleChunk() async throws {
    let keystrokes = RecordingUnicodeKeystrokes()
    let delay = makeDelay(noting: keystrokes)
    let injector = makeInjector(keystrokes: keystrokes, delay: delay)

    try await injector.inject("olá")

    #expect(await keystrokes.chunks == ["olá"])
    #expect(await delay.waits.isEmpty)
  }

  @Test("Uses the configured inter-chunk delay")
  func usesConfiguredDelay() async throws {
    let keystrokes = RecordingUnicodeKeystrokes()
    let delay = RecordingDelay()
    let injector = makeInjector(
      keystrokes: keystrokes, delay: delay, interChunkDelay: .milliseconds(7))

    try await injector.inject(String(repeating: "a", count: 60))

    #expect(await delay.waits == [.milliseconds(7), .milliseconds(7)])
  }

  // MARK: Secure input (FR-13 / US-3)

  @Test("Refuses while secure input is active, without typing anything")
  func refusesWhileSecureInputActive() async throws {
    let keystrokes = RecordingUnicodeKeystrokes()
    let delay = RecordingDelay()
    let injector = makeInjector(
      keystrokes: keystrokes,
      secureInput: FixedSecureInput(isSecureInputActive: true),
      delay: delay)

    await #expect(throws: InjectionError.secureInputActive) {
      try await injector.inject("minha senha")
    }

    #expect(await keystrokes.events.isEmpty)
    #expect(await delay.waits.isEmpty)
  }

  @Test("Secure input outranks empty text")
  func secureInputOutranksEmptyText() async throws {
    let keystrokes = RecordingUnicodeKeystrokes()
    let injector = makeInjector(
      keystrokes: keystrokes, secureInput: FixedSecureInput(isSecureInputActive: true))

    await #expect(throws: InjectionError.secureInputActive) {
      try await injector.inject("")
    }
  }

  /// The entry check is not enough: it is re-read immediately before every post.
  /// `safeProbes: 1` lets the entry check pass and fails the one guarding the
  /// first event, so NOTHING is typed.
  @Test("Secure input engaging after the entry check blocks the first event")
  func secureInputEngagingAfterEntryCheckBlocksFirstEvent() async throws {
    let keystrokes = RecordingUnicodeKeystrokes()
    let injector = makeInjector(
      keystrokes: keystrokes, secureInput: SecureInputEngagingAfter(safeProbes: 1))

    await #expect(throws: InjectionError.secureInputActive) {
      try await injector.inject(Self.sentence)
    }

    #expect(await keystrokes.events.isEmpty)
  }

  /// The honest limit of a non-atomic strategy: whatever was already typed stays
  /// in the document, but nothing more is delivered. Pinned so the partial
  /// insertion is a KNOWN property rather than a surprise — it is the reason
  /// FR-11 keeps the clipboard as the default strategy.
  @Test("Secure input engaging mid-transcript stops the typing where it is")
  func secureInputEngagingMidTranscriptStopsTyping() async throws {
    let keystrokes = RecordingUnicodeKeystrokes()
    let injector = makeInjector(
      keystrokes: keystrokes, secureInput: SecureInputEngagingAfter(safeProbes: 3))

    await #expect(throws: InjectionError.secureInputActive) {
      try await injector.inject(Self.sentence)
    }

    let chunks = await keystrokes.chunks
    let all = UnicodeChunker().chunks(of: Self.sentence)
    // Entry probe + one probe per event: 3 safe probes = 2 events typed.
    #expect(chunks == Array(all.prefix(2)))
    #expect(chunks.count < all.count)
  }

  // MARK: Empty input

  @Test("Rejects empty and whitespace-only text", arguments: ["", " ", "\n", "  \t\n "])
  func rejectsEmptyText(text: String) async throws {
    let keystrokes = RecordingUnicodeKeystrokes()
    let injector = makeInjector(keystrokes: keystrokes)

    await #expect(throws: InjectionError.emptyText) {
      try await injector.inject(text)
    }

    #expect(await keystrokes.events.isEmpty)
  }

  @Test("Types surrounding whitespace verbatim")
  func typesSurroundingWhitespaceVerbatim() async throws {
    let keystrokes = RecordingUnicodeKeystrokes()
    let injector = makeInjector(keystrokes: keystrokes)

    try await injector.inject(" olá ")

    #expect(await keystrokes.typedText == " olá ")
  }

  // MARK: The whole point — no pasteboard

  /// FR-12's clipboard-free promise. `UnicodeInjector` has no pasteboard
  /// dependency to inject, so this watches the real thing instead: the general
  /// pasteboard's change count must not move, and a private pasteboard standing
  /// in for "the user's clipboard" must come out byte-identical.
  ///
  /// The general-pasteboard half has a ~millisecond window in which a human
  /// copying something would fail this test. Kept anyway: it is the only
  /// observation that can catch a future edit reaching for `NSPasteboard`.
  @Test("Never touches the pasteboard")
  @MainActor
  func neverTouchesThePasteboard() async throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("conteúdo importante do usuário", forType: .string)
    let boardChangeCount = board.changeCount
    let generalChangeCount = NSPasteboard.general.changeCount

    let keystrokes = RecordingUnicodeKeystrokes()
    let injector = makeInjector(keystrokes: keystrokes)
    try await injector.inject(Self.sentence)

    #expect(await keystrokes.typedText == Self.sentence)
    #expect(board.changeCount == boardChangeCount)
    #expect(board.string(forType: .string) == "conteúdo importante do usuário")
    #expect(NSPasteboard.general.changeCount == generalChangeCount)
  }

  // MARK: Failure and concurrency

  @Test("Propagates an emitter failure")
  func propagatesEmitterFailure() async throws {
    let keystrokes = RecordingUnicodeKeystrokes(error: .accessibilityDenied)
    let injector = makeInjector(keystrokes: keystrokes)

    await #expect(throws: InjectionError.accessibilityDenied) {
      try await injector.inject(Self.sentence)
    }

    // It stops at the first failure instead of typing the rest into the void.
    #expect(await keystrokes.chunks.count == 1)
  }

  /// Two dictations overlapping — a fast push-to-talk double tap. Unserialised,
  /// the two transcripts would interleave chunk by chunk into one scrambled
  /// line, which no user could untangle.
  @Test("Overlapping injections do not interleave")
  func overlappingInjectionsDoNotInterleave() async throws {
    let first = String(repeating: "A", count: 100)
    let second = String(repeating: "B", count: 100)
    // Yielding inside the delay gives an unserialised implementation ample
    // opportunity to interleave; without it the test would pass on broken code.
    let keystrokes = RecordingUnicodeKeystrokes()
    let delay = RecordingDelay(onWait: {
      for _ in 0..<20 { await Task.yield() }
    })
    let injector = makeInjector(keystrokes: keystrokes, delay: delay)

    async let a: Void = injector.inject(first)
    async let b: Void = injector.inject(second)
    _ = try await (a, b)

    let typed = await keystrokes.typedText
    #expect(typed == first + second || typed == second + first)
  }

  /// A cancelled dictation must not leave half a sentence in the document: once
  /// typing starts it runs to the end. (Two mechanisms guarantee it — the
  /// injection runs in an unstructured task, and the inter-chunk wait ignores
  /// cancellation — and this pins the observable result of both.)
  @Test("Cancelling the caller still delivers the whole transcript")
  func cancellationStillDeliversWholeTranscript() async throws {
    let keystrokes = RecordingUnicodeKeystrokes()
    let delay = RecordingDelay(onWait: { await Task.yield() })
    let injector = makeInjector(keystrokes: keystrokes, delay: delay)

    let task = Task { try await injector.inject(Self.sentence) }
    // Cancel once typing is genuinely under way.
    while await keystrokes.chunks.isEmpty {
      await Task.yield()
    }
    task.cancel()
    try await task.value

    #expect(await keystrokes.typedText == Self.sentence)
  }
}

// MARK: - SystemUnicodeKeystrokeEmitter

@Suite("SystemUnicodeKeystrokeEmitter")
struct SystemUnicodeKeystrokeEmitterTests {
  /// Only the DENIED path is exercised. Letting the granted path run would post
  /// real key events into whatever app happens to be frontmost while the tests
  /// run — see the `swift-testing` skill's "not unit-testable" list.
  @Test("Refuses to type without Accessibility")
  func refusesWithoutAccessibility() async throws {
    let emitter = SystemUnicodeKeystrokeEmitter(isProcessTrusted: { false })

    await #expect(throws: InjectionError.accessibilityDenied) {
      try await emitter.send("olá")
    }
  }

  /// The guard order matters: an empty chunk returns before the permission
  /// probe, so an empty send is a no-op rather than a spurious denial.
  @Test("An empty chunk is a no-op")
  func emptyChunkIsNoOp() async throws {
    let emitter = SystemUnicodeKeystrokeEmitter(isProcessTrusted: { false })
    try await emitter.send("")
  }
}
