import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

// MARK: - Seams

/// An immutable copy of the pasteboard's contents, faithful enough to put the
/// user's clipboard back exactly as we found it (SPEC.md FR-11).
///
/// Deliberately AppKit-free (`String` type identifiers, raw `Data`) so the
/// snapshot/restore logic can be exercised with a fake pasteboard in tests.
public struct PasteboardSnapshot: Sendable, Equatable {
  /// One `NSPasteboardItem` and every representation it carried.
  public struct Item: Sendable, Equatable {
    /// Raw `NSPasteboard.PasteboardType` values mapped to their payload.
    public let representations: [String: Data]

    public init(representations: [String: Data]) {
      self.representations = representations
    }

    public var isEmpty: Bool { representations.isEmpty }
  }

  public let items: [Item]
  /// `NSPasteboard.changeCount` at the instant of the snapshot.
  public let changeCount: Int

  public init(items: [Item], changeCount: Int) {
    self.items = items
    self.changeCount = changeCount
  }

  public var isEmpty: Bool { items.allSatisfy(\.isEmpty) }
}

/// The slice of `NSPasteboard` that `ClipboardInjector` needs.
///
/// Every member is `async` on purpose: the production implementation hops to the
/// main actor (AppKit does not promise pasteboard thread safety), and tests can
/// satisfy the protocol with an `actor` fake instead of an unchecked-`Sendable`
/// class.
public protocol PasteboardAccessing: Sendable {
  /// The pasteboard's current change count. Used to notice a third party (the
  /// user, a clipboard manager) writing while an injection is in flight.
  func currentChangeCount() async -> Int

  /// Captures the current contents, including non-text representations.
  func snapshot() async -> PasteboardSnapshot

  /// Replaces the contents with `text`. Returns the resulting change count.
  func write(_ text: String) async throws -> Int

  /// Replaces the contents with a previously captured snapshot.
  func restore(_ snapshot: PasteboardSnapshot) async throws
}

/// Synthesis of the Cmd+V chord, behind a protocol because posting `CGEvent`s
/// needs Accessibility and a real frontmost app — see the `swift-testing` skill's
/// "not unit-testable" list.
public protocol PasteKeystrokeEmitting: Sendable {
  func sendPasteShortcut() async throws
}

/// Injected wait, so the settle delay between paste and restore is instant in
/// tests (no sleeping test suites) and observable.
public protocol InjectionDelaying: Sendable {
  func wait(for duration: Duration) async throws

  /// Waits the full duration even if the surrounding task is cancelled.
  ///
  /// Required for the post-paste settle window: cancelling there would restore
  /// the clipboard before the frontmost app has read the transcript, so the user
  /// gets their previous clipboard pasted into their document instead.
  func waitIgnoringCancellation(for duration: Duration) async
}

/// What happened to the user's clipboard during an injection.
public enum PasteboardRestoreOutcome: Sendable, Equatable {
  /// The previous contents were put back.
  case restored
  /// Someone else wrote to the pasteboard after us; restoring would have
  /// destroyed whatever the user just copied, so we left it alone.
  case skippedClipboardChanged
  /// The pasteboard refused the restore. The user's clipboard now holds the
  /// transcript instead of their data.
  case failed(reason: String)
}

// MARK: - ClipboardInjector

/// Default injection strategy: snapshot the clipboard, put the transcript on it,
/// press Cmd+V, put the clipboard back (SPEC.md FR-11).
///
/// The operation is a read-modify-restore sequence over a process-wide resource,
/// so overlapping injections must not interleave: if a second one snapshots while
/// the first is holding the clipboard, it captures the first one's TRANSCRIPT as
/// "the user's clipboard" and later restores that, destroying the real contents.
///
/// Being an `actor` is NOT sufficient to prevent this — Swift actors are reentrant
/// across `await`, and this method suspends several times. Serialisation is done
/// explicitly by chaining each injection onto the previous one (`pending`).
public actor ClipboardInjector: TextInjector {
  /// How long the frontmost app gets to read the pasteboard before we take it
  /// back. Purely empirical — see the note in `injectReportingRestore`.
  public static let defaultPasteSettleDelay: Duration = .milliseconds(150)

  private let pasteboard: any PasteboardAccessing
  private let secureInput: any SecureInputMonitoring
  private let keystrokes: any PasteKeystrokeEmitting
  private let delay: any InjectionDelaying
  private let pasteSettleDelay: Duration
  /// Tail of the injection chain. Each call awaits its predecessor before
  /// snapshotting, which is what actually serialises overlapping injections.
  private var pending: Task<PasteboardRestoreOutcome, Error>?

  public init(
    pasteboard: any PasteboardAccessing = SystemPasteboard(),
    secureInput: any SecureInputMonitoring = SecureInputMonitor(),
    keystrokes: any PasteKeystrokeEmitting = SystemPasteKeystrokeEmitter(),
    delay: any InjectionDelaying = SystemInjectionDelay(),
    pasteSettleDelay: Duration = ClipboardInjector.defaultPasteSettleDelay
  ) {
    self.pasteboard = pasteboard
    self.secureInput = secureInput
    self.keystrokes = keystrokes
    self.delay = delay
    self.pasteSettleDelay = pasteSettleDelay
  }

  public func inject(_ text: String) async throws {
    let outcome = try await injectReportingRestore(text)
    // `.skippedClipboardChanged` means the user's clipboard was NOT put back.
    // Reporting that as success would hide data loss from every `TextInjector`
    // caller, so surface it as the failure it is.
    if case .skippedClipboardChanged = outcome {
      throw InjectionError.pasteboardFailure(
        reason: "clipboard changed during injection; previous contents not restored")
    }
  }

  /// `inject`, but reporting what became of the user's clipboard.
  ///
  /// Exposed so the clipboard-safety contract is directly assertable in tests and
  /// reportable by `Fala doctor`; the `TextInjector` protocol stays `Void`.
  @discardableResult
  public func injectReportingRestore(_ text: String) async throws -> PasteboardRestoreOutcome {
    // Serialise against any injection still in flight (see the type's doc
    // comment). A failed predecessor must not cancel this one, hence `try?`.
    let predecessor = pending
    let task = Task { [predecessor] () async throws -> PasteboardRestoreOutcome in
      _ = await predecessor?.result
      return try await self.performInjection(text)
    }
    // Kept after completion on purpose: the next caller simply awaits an already
    // finished task. It retains an outcome enum, never the transcript.
    pending = task
    return try await task.value
  }

  private func performInjection(_ text: String) async throws -> PasteboardRestoreOutcome {
    // FR-13 / US-3: refuse before the transcript touches any shared surface.
    // Nothing below this line runs while a password field has focus, and the
    // text is never stored on `self`.
    guard !secureInput.isSecureInputActive else {
      throw InjectionError.secureInputActive
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw InjectionError.emptyText
    }

    let snapshot = await pasteboard.snapshot()
    let ownedChangeCount = try await writeToPasteboard(text, snapshot: snapshot)

    // From here on we are holding the user's clipboard hostage: every exit path
    // below must reach `restoreIfUntouched`, including the failure ones. That is
    // why the paste error is captured instead of thrown.
    var pasteFailure: InjectionError?
    do {
      // Re-check secure input immediately before posting: transcription takes
      // ~100-150 ms, which is ample time for the user to click into a password
      // field after the first check (FR-13 is a hard refusal, not a best effort).
      guard !secureInput.isSecureInputActive else {
        throw InjectionError.secureInputActive
      }
      try await keystrokes.sendPasteShortcut()
      // The frontmost app reads the pasteboard asynchronously, after the chord
      // is delivered. Restoring immediately would race that read and paste the
      // user's old clipboard instead of the transcript.
      //
      // Cancellation-immune on purpose: `Task.sleep` throws instantly when the
      // task is cancelled, and swallowing that with `try?` would fall straight
      // through to the restore — yanking the clipboard back microseconds after
      // Cmd+V and pasting the user's OLD clipboard into their document. Once the
      // chord is posted this wait is not optional.
      await delay.waitIgnoringCancellation(for: pasteSettleDelay)
    } catch let error as InjectionError {
      pasteFailure = error
    } catch {
      pasteFailure = .pasteboardFailure(reason: "paste shortcut failed")
    }

    let outcome = await restoreIfUntouched(snapshot, ownedChangeCount: ownedChangeCount)

    // The paste failure is the more informative one, so it wins.
    if let pasteFailure {
      throw pasteFailure
    }
    if case .failed(let reason) = outcome {
      throw InjectionError.pasteboardFailure(reason: reason)
    }
    return outcome
  }

  /// Writes the transcript, undoing the damage if the write itself fails.
  ///
  /// `NSPasteboard` requires `clearContents()` before a write, so a write that
  /// fails halfway leaves the user with an *empty* clipboard. That is still our
  /// mess to clean up.
  private func writeToPasteboard(
    _ text: String,
    snapshot: PasteboardSnapshot
  ) async throws -> Int {
    do {
      return try await pasteboard.write(text)
    } catch {
      await restoreAfterFailedWrite(snapshot)
      if let injectionError = error as? InjectionError {
        throw injectionError
      }
      throw InjectionError.pasteboardFailure(reason: "clipboard write failed")
    }
  }

  private func restoreAfterFailedWrite(_ snapshot: PasteboardSnapshot) async {
    // If the change count never moved, the pasteboard was not touched and
    // rewriting it would only churn the change count for clipboard managers.
    let current = await pasteboard.currentChangeCount()
    guard current != snapshot.changeCount else { return }
    try? await pasteboard.restore(snapshot)
  }

  /// Puts `snapshot` back unless someone else claimed the pasteboard after our
  /// write, in which case their content is newer than ours and must survive.
  private func restoreIfUntouched(
    _ snapshot: PasteboardSnapshot,
    ownedChangeCount: Int
  ) async -> PasteboardRestoreOutcome {
    let current = await pasteboard.currentChangeCount()
    guard current == ownedChangeCount else {
      return .skippedClipboardChanged
    }
    do {
      try await pasteboard.restore(snapshot)
      return .restored
    } catch InjectionError.pasteboardFailure(let reason) {
      return .failed(reason: reason)
    } catch {
      return .failed(reason: "clipboard restore failed")
    }
  }
}

// MARK: - System implementations

/// `NSPasteboard.general` behind `PasteboardAccessing`.
///
/// Holds no state, so `Sendable` is free; the actual AppKit calls are made on the
/// main actor because pasteboard access is not documented as thread safe.
public struct SystemPasteboard: PasteboardAccessing {
  public init() {}

  public func currentChangeCount() async -> Int {
    await MainActor.run { NSPasteboard.general.changeCount }
  }

  public func snapshot() async -> PasteboardSnapshot {
    await MainActor.run {
      let board = NSPasteboard.general
      let items = (board.pasteboardItems ?? []).map { item in
        var representations: [String: Data] = [:]
        for type in item.types {
          if let data = item.data(forType: type) {
            representations[type.rawValue] = data
          }
        }
        return PasteboardSnapshot.Item(representations: representations)
      }
      return PasteboardSnapshot(items: items, changeCount: board.changeCount)
    }
  }

  /// Marker respected by clipboard-history apps (Maccy, Raycast, Alfred, Paste):
  /// items carrying it are not recorded. The convention password managers use.
  private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

  public func write(_ text: String) async throws -> Int {
    try await MainActor.run {
      let board = NSPasteboard.general
      // NFR-1 / CLAUDE.md: "transcripts NEVER leave the machine". A plain
      // `clearContents()` + `setString` puts every dictation on the ordinary
      // system clipboard, which macOS pushes to Universal Clipboard — i.e. to the
      // user's other iCloud devices — and which clipboard-history apps archive.
      // `.currentHostOnly` blocks the cross-device sync; the concealed type asks
      // history apps not to record it. Both are required; neither alone suffices.
      board.prepareForNewContents(with: .currentHostOnly)
      guard board.setString(text, forType: .string) else {
        throw InjectionError.pasteboardFailure(reason: "pasteboard rejected the write")
      }
      board.setData(Data(), forType: Self.concealedType)
      return board.changeCount
    }
  }

  public func restore(_ snapshot: PasteboardSnapshot) async throws {
    try await MainActor.run {
      let board = NSPasteboard.general
      board.clearContents()
      // An empty snapshot means the clipboard was empty: clearing is the restore.
      let items = snapshot.items.filter { !$0.isEmpty }.map { item -> NSPasteboardItem in
        let restored = NSPasteboardItem()
        for (rawType, data) in item.representations {
          restored.setData(data, forType: NSPasteboard.PasteboardType(rawType))
        }
        return restored
      }
      guard !items.isEmpty else { return }
      guard board.writeObjects(items) else {
        throw InjectionError.pasteboardFailure(reason: "pasteboard rejected the restore")
      }
    }
  }
}

/// Posts a synthetic Cmd+V through Quartz.
///
/// Requires Accessibility. Note the trap in CLAUDE.md: run from a terminal, the
/// grant belongs to the *parent* process, so this only works from a signed app
/// bundle. Not unit-testable — verified manually (TASKS.md T1.8/T1.10).
public struct SystemPasteKeystrokeEmitter: PasteKeystrokeEmitting {
  private let isProcessTrusted: @Sendable () -> Bool

  /// - Parameter isProcessTrusted: Accessibility probe, injected for testing.
  ///   Defaults to `AXIsProcessTrusted()`, which never prompts.
  public init(isProcessTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
    self.isProcessTrusted = isProcessTrusted
  }

  public func sendPasteShortcut() async throws {
    guard isProcessTrusted() else {
      throw InjectionError.accessibilityDenied
    }
    guard let source = CGEventSource(stateID: .combinedSessionState) else {
      throw InjectionError.pasteboardFailure(reason: "no event source")
    }
    let vKey = CGKeyCode(kVK_ANSI_V)
    guard
      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
    else {
      throw InjectionError.pasteboardFailure(reason: "could not build key events")
    }
    // Set the flags explicitly rather than inheriting them: the push-to-talk key
    // may still be physically held when injection starts, and a stray modifier
    // would turn Cmd+V into a different command in the target app.
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
  }
}

/// `Task.sleep`, behind `InjectionDelaying`.
public struct SystemInjectionDelay: InjectionDelaying {
  public init() {}

  public func wait(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }

  public func waitIgnoringCancellation(for duration: Duration) async {
    // Detached so cancellation of the caller does not propagate: `Task.sleep`
    // throws immediately on cancellation, which is exactly what must not happen
    // between Cmd+V and the clipboard restore.
    await Task.detached {
      try? await Task.sleep(for: duration)
    }.value
  }
}
