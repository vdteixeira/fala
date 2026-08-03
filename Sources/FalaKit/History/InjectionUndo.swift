import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

// MARK: - Errors

/// Why synthesising the undo chord failed. Separate from `InjectionError`
/// because none of that enum's cases describe this path: undo never touches the
/// pasteboard and never has "text" to be empty.
public enum UndoError: Error, Equatable, Sendable {
  /// Accessibility is not granted, so no synthetic key event can be posted.
  case accessibilityDenied
  /// Quartz refused to build or post the event.
  case eventSynthesisFailed(reason: String)
}

// MARK: - Seam

/// Posting Cmd+Z, behind a protocol for the same reason `PasteKeystrokeEmitting`
/// exists: `CGEvent` needs Accessibility and a real frontmost app, so the policy
/// around it is what gets tested, not the posting itself.
public protocol UndoKeystrokeEmitting: Sendable {
  func sendUndoShortcut() async throws
}

// MARK: - Outcome

/// What `undoLastInjection()` did.
///
/// Note the name of the success case: **`requested`**, not `succeeded`. See
/// `InjectionUndoService` for why nothing stronger can honestly be claimed.
public enum UndoOutcome: Sendable, Equatable {
  /// Cmd+Z was posted to the destination app. Whether that app undid the paste,
  /// undid something else, or did nothing at all is not observable from here.
  case requested(destination: String?)
  /// No injection has been recorded yet.
  case nothingToUndo
  /// Undo already fired for this injection. Sending a second Cmd+Z would start
  /// eating whatever the user did afterwards.
  case alreadyUndone(at: Date)
  /// Too much time has passed for the target app's undo stack to still have our
  /// paste on top with any confidence.
  case expired(age: TimeInterval)
  /// The destination could not be identified when the text was injected, so
  /// there is nothing to verify against and no safe app to send the chord to.
  case unknownDestination
  /// A different app is in front now. Cmd+Z would undo the user's work there.
  case destinationChanged(expected: String?, actual: String?)
  /// A secure text field has focus (SPEC.md FR-13 / US-3).
  case secureInputActive
  case failed(UndoError)

  /// True only for the one case where a chord actually left the process.
  public var isRequested: Bool {
    if case .requested = self { return true }
    return false
  }

  /// pt-BR, safe to show: app names and file-free reasons only, never transcript
  /// text (the undo path never receives any — see `UndoableInjection`).
  public var message: String {
    switch self {
    case .requested(let destination):
      guard let destination, !destination.isEmpty else { return "Desfazer enviado." }
      return "Desfazer enviado para “\(destination)”."
    case .nothingToUndo:
      return "Nada para desfazer."
    case .alreadyUndone:
      return "A última ditada já foi desfeita."
    case .expired:
      return "A última ditada é antiga demais para desfazer com segurança."
    case .unknownDestination:
      return "Não sei em qual app o texto entrou — não vou enviar ⌘Z às cegas."
    case .destinationChanged(let expected, _):
      guard let expected, !expected.isEmpty else {
        return "Volte para o app onde o texto entrou e tente de novo."
      }
      return "Volte para “\(expected)” e tente de novo."
    case .secureInputActive:
      return "Campo protegido — desfazer bloqueado."
    case .failed(.accessibilityDenied):
      return "Permissão de Acessibilidade necessária."
    case .failed(.eventSynthesisFailed):
      return "Não consegui enviar ⌘Z."
    }
  }
}

// MARK: - Service

/// The undo seam the UI depends on (SPEC.md US-5).
public protocol InjectionUndoing: Sendable {
  func undoLastInjection() async -> UndoOutcome
}

/// Undo of the last injection — and an honest account of what that means.
///
/// **What undo cannot be.** The text is not ours. By the time US-5 applies, the
/// transcript is a range inside ANOTHER application's document, owned by that
/// application's own undo stack. Fala has no handle on it: there is no API to
/// retract a paste, and deleting "the last N characters" by synthesising
/// backspaces would be strictly worse — it would delete whatever is at the
/// cursor now, which may be the user's own typing. So undo cannot be a data
/// operation on our side, and this type does not pretend otherwise.
///
/// **What it actually is.** Synthesising ⌘Z to the app the text went into, which
/// is exactly what the user would press themselves. The value this type adds is
/// not the keystroke — it is the four refusals in front of it:
///
/// - the destination app must be the one that received the text (verified by
///   bundle identifier, not by name), so the chord cannot land in someone
///   else's document;
/// - the injection must be recent (`undoWindow`), because an old paste is no
///   longer on top of that app's undo stack;
/// - each injection is undoable ONCE — a second attempt reports
///   `.alreadyUndone` instead of eating the user's subsequent work;
/// - a secure input field blocks it, like every other synthetic event we post.
///
/// **What it still cannot guarantee, even when it returns `.requested`.**
/// 1. That the app undid *our* paste. One paste is one undo step in most apps,
///    but not all — some coalesce, some split, some (terminals, many web text
///    areas, immediate-mode canvases) have no undo for that field at all.
/// 2. That the user did not type between the injection and the undo. If they
///    did, ⌘Z undoes their typing first. The time window narrows this; it
///    cannot close it, because nothing tells us what happened inside another
///    app.
/// 3. That the frontmost app is the one editing. An app can be frontmost with
///    focus in a panel, a palette, or another window entirely.
///
/// This is why the success case is called `.requested`. A `.succeeded` would be
/// a claim this code is in no position to make.
public actor InjectionUndoService: InjectionUndoing {
  /// How long after an injection undo is still offered.
  ///
  /// Two minutes: long enough to notice a bad transcription, read it, and
  /// react; short enough that the paste is plausibly still the top of the
  /// target app's undo stack. Arbitrary in the way every such threshold is —
  /// the app-identity check is the real safety, this only bounds the blast
  /// radius of a stale record.
  public static let defaultUndoWindow: TimeInterval = 120

  /// How long the destination app gets to come forward before we re-check who
  /// is frontmost. Only used on the popover path (see `activator`).
  public static let defaultActivationDelay: Duration = .milliseconds(250)

  private let history: any LastInjectionProviding
  private let frontmost: any FrontmostApplicationProviding
  private let secureInput: any SecureInputMonitoring
  private let keystrokes: any UndoKeystrokeEmitting
  private let activator: (any ApplicationActivating)?
  private let delay: any InjectionDelaying
  private let clock: @Sendable () -> Date
  private let ownBundleIdentifier: @Sendable () -> String?
  private let undoWindow: TimeInterval
  private let activationDelay: Duration

  /// - Parameters:
  ///   - activator: used ONLY to hand focus back when Fala itself is frontmost
  ///     — i.e. the user triggered undo from our popover, which activated us.
  ///     Pass `nil` to disable that path entirely; undo then simply refuses
  ///     whenever the destination is not already in front.
  ///   - ownBundleIdentifier: how the service recognises "the frontmost app is
  ///     us". Injected so the rule is testable; `Bundle.main` in a test process
  ///     is the test runner, not Fala.
  /// Tail of the undo chain. See `undoLastInjection()`.
  private var pending: Task<UndoOutcome, Never>?

  public init(
    history: any LastInjectionProviding,
    frontmost: any FrontmostApplicationProviding = SystemFrontmostApplication(),
    secureInput: any SecureInputMonitoring = SecureInputMonitor(),
    keystrokes: any UndoKeystrokeEmitting = SystemUndoKeystrokeEmitter(),
    activator: (any ApplicationActivating)? = SystemApplicationActivator(),
    delay: any InjectionDelaying = SystemInjectionDelay(),
    clock: @escaping @Sendable () -> Date = { Date() },
    ownBundleIdentifier: @escaping @Sendable () -> String? = { Bundle.main.bundleIdentifier },
    undoWindow: TimeInterval = InjectionUndoService.defaultUndoWindow,
    activationDelay: Duration = InjectionUndoService.defaultActivationDelay
  ) {
    self.history = history
    self.frontmost = frontmost
    self.secureInput = secureInput
    self.keystrokes = keystrokes
    self.activator = activator
    self.delay = delay
    self.clock = clock
    self.ownBundleIdentifier = ownBundleIdentifier
    self.undoWindow = undoWindow
    self.activationDelay = activationDelay
  }

  /// Serialises undo requests so a double click, or a held hotkey, cannot post
  /// two chords for one injection.
  ///
  /// Being an `actor` is NOT enough — Swift actors are reentrant across `await`,
  /// and this method suspends at least four times (reading history, activating
  /// the destination, posting the chord, marking it undone). Two concurrent
  /// callers both saw `undoRequestedAt == nil` and both posted, so a
  /// double-click undid TWO steps in the user's document: the first their
  /// dictation, the second whatever they had typed before it. Same defect class
  /// as `ClipboardInjector`, same fix — chain each request onto the previous one.
  public func undoLastInjection() async -> UndoOutcome {
    let predecessor = pending
    let task = Task { [predecessor] () async -> UndoOutcome in
      _ = await predecessor?.value
      return await self.performUndo()
    }
    pending = task
    return await task.value
  }

  private func performUndo() async -> UndoOutcome {
    guard let injection = await history.lastInjection() else { return .nothingToUndo }
    if let undoneAt = injection.undoRequestedAt { return .alreadyUndone(at: undoneAt) }

    // A NEGATIVE age means the clock moved backwards (skew, DST, a manual
    // change), not that the injection is in the future. Refusing there would
    // take undo away for a reason the user cannot see or fix; the identity
    // check below is what actually protects them.
    let age = clock().timeIntervalSince(injection.injectedAt)
    guard age <= undoWindow else { return .expired(age: age) }

    guard let destination = injection.destination, let bundleID = destination.bundleIdentifier,
      destination.isVerifiable
    else {
      return .unknownDestination
    }

    // Checked before anything is posted, and before we ask another app to
    // activate: FR-13 is a refusal, not a best effort.
    guard !secureInput.isSecureInputActive else { return .secureInputActive }

    if let refusal = await bringDestinationForward(destination, bundleID: bundleID) {
      return refusal
    }

    do {
      try await keystrokes.sendUndoShortcut()
    } catch let error as UndoError {
      // Deliberately NOT marked as undone: a missing permission is something the
      // user can grant and retry, and burning the one undo for it would punish
      // them for our failure.
      return .failed(error)
    } catch {
      return .failed(.eventSynthesisFailed(reason: "undo shortcut failed"))
    }

    await history.markUndoRequested(id: injection.id, at: clock())
    return .requested(destination: destination.displayName)
  }

  /// `nil` when the destination is (now) frontmost; otherwise the refusal to
  /// return.
  private func bringDestinationForward(
    _ destination: DestinationApp,
    bundleID: String
  ) async -> UndoOutcome? {
    let current = await frontmost.current()
    if current?.bundleIdentifier == bundleID { return nil }

    // The ONLY app we will pull focus away from is ourselves. Fala is frontmost
    // exactly when the user opened our popover to press undo, so activating the
    // destination is finishing what they asked for. Doing the same from a third
    // app would be yanking focus out of something they are using.
    guard let own = ownBundleIdentifier(), current?.bundleIdentifier == own,
      let activator
    else {
      return .destinationChanged(
        expected: destination.displayName, actual: current?.displayName)
    }
    guard await activator.activate(bundleIdentifier: bundleID) else {
      return .destinationChanged(
        expected: destination.displayName, actual: current?.displayName)
    }
    // Activation is asynchronous, so the answer to "did it work?" is not the
    // return value above — it is who is frontmost afterwards.
    await delay.waitIgnoringCancellation(for: activationDelay)
    let afterActivation = await frontmost.current()
    guard afterActivation?.bundleIdentifier == bundleID else {
      return .destinationChanged(
        expected: destination.displayName, actual: afterActivation?.displayName)
    }
    return nil
  }
}

// MARK: - System implementation

/// Posts a synthetic Cmd+Z through Quartz.
///
/// Same trap as `SystemPasteKeystrokeEmitter` (CLAUDE.md): run from a terminal,
/// Accessibility is attributed to the PARENT process, so this only works from a
/// signed app bundle. Not unit-testable — verified manually.
public struct SystemUndoKeystrokeEmitter: UndoKeystrokeEmitting {
  private let isProcessTrusted: @Sendable () -> Bool

  /// - Parameter isProcessTrusted: Accessibility probe, injected for testing.
  ///   Defaults to `AXIsProcessTrusted()`, which never prompts.
  public init(isProcessTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
    self.isProcessTrusted = isProcessTrusted
  }

  public func sendUndoShortcut() async throws {
    guard isProcessTrusted() else { throw UndoError.accessibilityDenied }
    guard let source = CGEventSource(stateID: .combinedSessionState) else {
      throw UndoError.eventSynthesisFailed(reason: "no event source")
    }
    let zKey = CGKeyCode(kVK_ANSI_Z)
    guard
      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: zKey, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: zKey, keyDown: false)
    else {
      throw UndoError.eventSynthesisFailed(reason: "could not build key events")
    }
    // Set explicitly rather than inheriting: a modifier the user still happens
    // to be holding would turn ⌘Z into ⇧⌘Z, which is REDO in most apps — the
    // exact opposite of what was asked for.
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
  }
}
