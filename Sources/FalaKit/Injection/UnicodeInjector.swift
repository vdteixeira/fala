import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Chunking

/// Splits text into the pieces one synthetic key event may carry (SPEC.md FR-12).
///
/// This is the half of the unicode path that CAN be unit-tested: posting events
/// needs Accessibility and a real frontmost app, but deciding where to cut is
/// arithmetic over UTF-16 (see the `swift-testing` skill's testable list).
///
/// The cut is made on GRAPHEME boundaries even though the budget is counted in
/// UTF-16 units. Those are different things, and getting it wrong is silent
/// corruption rather than a crash:
/// - an emoji is a surrogate PAIR — two UTF-16 units that mean nothing apart;
/// - `é` written as `e` + U+0301 is two units, and delivering the base letter in
///   one event and the accent in the next asks the target app to re-combine
///   across two separate key events. Portuguese is full of these, and text
///   arriving from an ASR engine is not guaranteed to be normalised (NFC);
/// - flags, keycaps and ZWJ sequences are longer still.
public struct UnicodeChunker: Sendable, Equatable {
  /// FR-12's "~20 UniChars".
  ///
  /// `CGEventKeyboardSetUnicodeString` accepts a length, but the payload is
  /// copied into the event's fixed internal buffer, so a long string is
  /// truncated with no error. 20 is the size FR-12 fixes as the contract; it is
  /// not measured here (see the report's "could not verify").
  public static let defaultMaxUnitsPerChunk = 20

  /// Budget per chunk, in UTF-16 code units — the unit
  /// `CGEventKeyboardSetUnicodeString` counts.
  public let maxUnitsPerChunk: Int

  public init(maxUnitsPerChunk: Int = UnicodeChunker.defaultMaxUnitsPerChunk) {
    // A zero or negative budget would loop forever or emit empty events; one
    // unit per chunk is the smallest thing that still makes progress.
    self.maxUnitsPerChunk = max(1, maxUnitsPerChunk)
  }

  /// Splits `text` in order, so that `chunks(of: text).joined() == text`.
  ///
  /// Every chunk fits the budget EXCEPT one produced by a single grapheme
  /// cluster that is bigger than the budget on its own (a ZWJ family emoji is 11
  /// UTF-16 units; combining sequences have no upper bound). Such a cluster is
  /// emitted whole and over budget on purpose: splitting it is the one outcome
  /// that corrupts the user's text, whereas an over-long event risks at worst a
  /// truncation of a character that could not have survived the split either.
  public func chunks(of text: String) -> [String] {
    guard !text.isEmpty else { return [] }

    var chunks: [String] = []
    var current = ""
    var currentUnits = 0

    // Iterating `Character` is what keeps the cut on grapheme boundaries: Swift
    // has already done the (non-trivial) clustering, and we only ever decide
    // BETWEEN clusters, never inside one.
    for character in text {
      let units = character.utf16.count
      if currentUnits > 0, currentUnits + units > maxUnitsPerChunk {
        chunks.append(current)
        current = ""
        currentUnits = 0
      }
      current.append(character)
      currentUnits += units
    }
    if !current.isEmpty {
      chunks.append(current)
    }
    return chunks
  }
}

// MARK: - Seam

/// Posting one chunk as a synthetic key event, behind a protocol because
/// `CGEvent.post` needs Accessibility and a real frontmost app — the same reason
/// `PasteKeystrokeEmitting` exists.
public protocol UnicodeKeystrokeEmitting: Sendable {
  /// Delivers `chunk` to the frontmost app as if it had been typed.
  func send(_ chunk: String) async throws
}

// MARK: - UnicodeInjector

/// Clipboard-free injection: the transcript is typed as Unicode payloads on
/// synthetic key events (SPEC.md FR-12).
///
/// This exists because `ClipboardInjector` legitimately REFUSES some
/// dictations — when the clipboard holds content it cannot capture and restore
/// (a copied spreadsheet range, a promised file), overwriting it would destroy
/// data nothing can bring back. This path never reads, writes, clears or even
/// looks at the pasteboard, so that whole class of refusal does not apply to it.
/// Nothing in this file imports AppKit, which is the structural reason it cannot
/// touch the pasteboard by accident.
///
/// Trade-offs against the clipboard path, which is why FR-11 keeps clipboard as
/// the default:
/// - it is NOT atomic. A 200-character transcript is ~10 events over ~20 ms, and
///   anything that interrupts it (secure input engaging, the process dying)
///   leaves the user with half a sentence. The clipboard path either pastes
///   everything or nothing;
/// - an app that reads the key CODE instead of the Unicode payload sees
///   `kVK_ANSI_A` repeatedly. That is the documented failure mode of this
///   technique, and it is silent;
/// - the events are indistinguishable from typing, so anything that reacts to
///   keystrokes (a shell prompt, a vim in normal mode, an autocomplete popup)
///   reacts to them. See `InjectionPolicy` for the terminal rule this motivates.
///
/// Like `ClipboardInjector`, overlapping injections must not interleave — here
/// the damage is two transcripts shuffled character-group by character-group
/// into one line. Being an actor is not enough (actors are reentrant across
/// `await`, and this suspends between every chunk), so each injection is chained
/// onto its predecessor.
public actor UnicodeInjector: TextInjector {
  /// Pause between chunks.
  ///
  /// FR-12 asks for "a short sleep between events" without fixing a number.
  /// 2 ms is a guess with a rationale, not a measurement: it is long enough that
  /// an app draining its event queue on a timer sees separate events, and short
  /// enough that a 200-character transcript costs ~20 ms — inside the latency
  /// budget NFR-3 allows for the whole dictation. Tune it if the manual check
  /// shows dropped or reordered characters.
  public static let defaultInterChunkDelay: Duration = .milliseconds(2)

  private let keystrokes: any UnicodeKeystrokeEmitting
  private let secureInput: any SecureInputMonitoring
  private let delay: any InjectionDelaying
  private let chunker: UnicodeChunker
  private let interChunkDelay: Duration
  /// Tail of the injection chain; see the type's doc comment.
  private var pending: Task<Void, Error>?

  public init(
    keystrokes: any UnicodeKeystrokeEmitting = SystemUnicodeKeystrokeEmitter(),
    secureInput: any SecureInputMonitoring = SecureInputMonitor(),
    delay: any InjectionDelaying = SystemInjectionDelay(),
    chunker: UnicodeChunker = UnicodeChunker(),
    interChunkDelay: Duration = UnicodeInjector.defaultInterChunkDelay
  ) {
    self.keystrokes = keystrokes
    self.secureInput = secureInput
    self.delay = delay
    self.chunker = chunker
    self.interChunkDelay = interChunkDelay
  }

  public func inject(_ text: String) async throws {
    let predecessor = pending
    let task = Task { [predecessor] () async throws -> Void in
      // A failed predecessor must not cancel this one, hence the discarded
      // result rather than a `try`.
      _ = await predecessor?.result
      try await self.performInjection(text)
    }
    pending = task
    try await task.value
  }

  private func performInjection(_ text: String) async throws {
    // FR-13 / US-3: refuse before a single event is built. The text is never
    // stored on `self`, and nothing below runs while a password field has focus.
    guard !secureInput.isSecureInputActive else {
      throw InjectionError.secureInputActive
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw InjectionError.emptyText
    }

    let chunks = chunker.chunks(of: text)
    for (index, chunk) in chunks.enumerated() {
      if index > 0 {
        // Cancellation-immune, for the same reason `ClipboardInjector`'s settle
        // wait is: a cancelled `Task.sleep` throws instantly, which here would
        // abort mid-transcript and leave a truncated sentence in the user's
        // document. The whole loop is bounded by chunk count × 2 ms, so ignoring
        // cancellation for it costs tens of milliseconds at most.
        await delay.waitIgnoringCancellation(for: interChunkDelay)
      }
      // Re-checked immediately before every post, not once up front: typing a
      // long transcript spans tens of milliseconds, and FR-13 is a hard refusal
      // rather than a best effort. Whatever was already typed stays in the
      // document — the honest limit of a non-atomic strategy — but nothing more
      // is delivered once a secure field has focus.
      guard !secureInput.isSecureInputActive else {
        throw InjectionError.secureInputActive
      }
      try await keystrokes.send(chunk)
    }
  }
}

// MARK: - System implementation

/// Types one chunk through Quartz, using `CGEventKeyboardSetUnicodeString`.
///
/// Requires Accessibility, and note the trap in CLAUDE.md: run from a terminal
/// the grant belongs to the PARENT process, so this only works from a signed app
/// bundle. Not unit-testable beyond the permission guard — verified manually
/// (see the T2.8 checklist in `docs/architecture.md`).
public struct SystemUnicodeKeystrokeEmitter: UnicodeKeystrokeEmitting {
  /// Key code the synthetic events carry. The Unicode payload is what the
  /// receiving app is supposed to read; the code is required because a keyboard
  /// event must have one. `kVK_ANSI_A` (0) is the conventional choice — and an
  /// app that ignores the payload types "a", which is the documented failure
  /// mode of this technique.
  private static let carrierKeyCode: CGKeyCode = 0

  private let isProcessTrusted: @Sendable () -> Bool

  /// - Parameter isProcessTrusted: Accessibility probe, injected for testing.
  ///   Defaults to `AXIsProcessTrusted()`, which never prompts.
  public init(isProcessTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
    self.isProcessTrusted = isProcessTrusted
  }

  public func send(_ chunk: String) async throws {
    guard !chunk.isEmpty else { return }
    guard isProcessTrusted() else {
      throw InjectionError.accessibilityDenied
    }
    guard let source = CGEventSource(stateID: .combinedSessionState) else {
      throw InjectionError.pasteboardFailure(reason: "no event source")
    }
    guard
      let keyDown = CGEvent(
        keyboardEventSource: source, virtualKey: Self.carrierKeyCode, keyDown: true),
      let keyUp = CGEvent(
        keyboardEventSource: source, virtualKey: Self.carrierKeyCode, keyDown: false)
    else {
      throw InjectionError.pasteboardFailure(reason: "could not build key events")
    }

    // Cleared explicitly rather than inherited: `.combinedSessionState` seeds new
    // events with the CURRENT hardware modifier state, and the push-to-talk key
    // may still be physically held. A stray ⌥ or ⌘ on a synthetic event turns
    // typed text into commands in the target app.
    keyDown.flags = []
    keyUp.flags = []

    let units = Array(chunk.utf16)
    // Set on BOTH events: apps differ in which one they read the payload from,
    // and a key-up carrying the same string is how every long-lived
    // implementation of this technique does it.
    units.withUnsafeBufferPointer { buffer in
      guard let base = buffer.baseAddress else { return }
      keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
      keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
    }

    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
  }
}
