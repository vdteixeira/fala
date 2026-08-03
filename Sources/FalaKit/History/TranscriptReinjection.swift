import Foundation

// "Re-inject" — the history window's `arrow.uturn.left` row action
// (DESIGN-HANDOFF.md §1, §5).
//
// It goes through the SAME `TextInjector` the dictation flow uses. There is
// deliberately no second path to the pasteboard here: `ClipboardInjector` is
// what snapshots and restores the user's clipboard, refuses on a secure field,
// and serialises overlapping injections, and re-implementing any of that would
// mean maintaining two versions of the one operation that touches other apps'
// documents.
//
// PRIVACY (CLAUDE.md, NFR-1): the transcript reaches the injector and nothing
// else. `ReinjectOutcome` carries app names and error kinds only — by
// construction it cannot hold transcript text.

// MARK: - Outcome

/// What re-injecting one history entry did.
public enum ReinjectOutcome: Sendable, Equatable {
  /// The text was handed to the injector, which reported success.
  case injected(destination: String?)
  /// The entry holds no text (only reachable from a hand-edited history file).
  case emptyText
  /// The entry has no verifiable destination app, so there is nowhere safe to
  /// put the text — see `TranscriptReinjector` for why "wherever is in front"
  /// is not an option here.
  case unknownDestination
  /// The destination app could not be brought forward — it is not running, it
  /// refused, or another app is in front and it is not ours to push aside.
  case destinationUnavailable(expected: String?, actual: String?)
  /// The injector refused or failed. Secure input lands here.
  case failed(InjectionError)

  public var isInjected: Bool {
    if case .injected = self { return true }
    return false
  }

  /// pt-BR, safe to show: app names and file-free reasons only.
  public var message: String {
    switch self {
    case .injected(let destination):
      guard let destination, !destination.isEmpty else { return "Texto inserido." }
      return "Texto inserido em “\(destination)”."
    case .emptyText:
      return "Nada para inserir."
    case .unknownDestination:
      return "Não sei em qual app o texto entrou — não vou inserir às cegas."
    case .destinationUnavailable(let expected, _):
      guard let expected, !expected.isEmpty else {
        return "Abra o app onde o texto entrou e tente de novo."
      }
      return "Abra “\(expected)” e tente de novo."
    case .failed(let error):
      // The coordinator's own map, reused rather than restated, so the pill and
      // this window cannot describe the same refusal two different ways.
      return DictationCoordinator.message(for: error)
    }
  }

  /// Which of the six states the notice is tinted with (DESIGN-HANDOFF.md §2).
  ///
  /// The two refusals are `warning`, not `error`: nothing failed, the app simply
  /// declined to paste somewhere it could not verify, and the user can fix it in
  /// one step. `error` is reserved for a blocked or broken injection.
  public var stateKind: StateKind {
    switch self {
    case .injected: return .success
    case .unknownDestination, .destinationUnavailable: return .warning
    case .emptyText, .failed: return .error
    }
  }
}

// MARK: - Seam

/// Re-injection, behind a protocol so the window can be tested without
/// Accessibility, a pasteboard, or a second running application.
public protocol TranscriptReinjecting: Sendable {
  func reinject(_ entry: DictationHistoryEntry) async -> ReinjectOutcome
}

// MARK: - Focus policy

/// The result of trying to put a destination app back in front.
///
/// Extracted as its own value because `InjectionUndoService` needs exactly the
/// same policy and expresses it as a private method returning `UndoOutcome`.
/// This one is outcome-neutral so both callers can map it into their own
/// vocabulary; adopting it there is a follow-up, and until then the RULE is
/// written down twice but decided once, here.
public enum DestinationFocusResult: Sendable, Equatable {
  /// The destination is frontmost now. Safe to inject.
  case frontmost
  /// It is not, and could not be made so. `actual` is whoever is in front.
  case refused(actual: DestinationApp?)
}

/// "Bring the destination app forward, or refuse."
///
/// The one app this will ever pull focus away from is **Fala itself**. In the
/// history window that is always the case — the user just clicked a button in
/// our window, which made us frontmost — so activating the destination is
/// finishing what they asked for. Doing the same while a third app is in front
/// would be yanking focus out of something they are using.
struct DestinationFocus: Sendable {
  let frontmost: any FrontmostApplicationProviding
  let activator: (any ApplicationActivating)?
  let delay: any InjectionDelaying
  let ownBundleIdentifier: @Sendable () -> String?
  let activationDelay: Duration

  func bringForward(
    _ destination: DestinationApp,
    bundleID: String
  ) async -> DestinationFocusResult {
    let current = await frontmost.current()
    if current?.bundleIdentifier == bundleID { return .frontmost }

    guard let own = ownBundleIdentifier(), current?.bundleIdentifier == own,
      let activator
    else {
      return .refused(actual: current)
    }
    guard await activator.activate(bundleIdentifier: bundleID) else {
      return .refused(actual: current)
    }
    // Activation is asynchronous: the answer to "did it work?" is not the
    // return value above, it is who is frontmost afterwards.
    await delay.waitIgnoringCancellation(for: activationDelay)
    let afterActivation = await frontmost.current()
    guard afterActivation?.bundleIdentifier == bundleID else {
      return .refused(actual: afterActivation)
    }
    return .frontmost
  }
}

// MARK: - Service

/// Injects a past transcript again, into the app it originally went to.
///
/// **Why the ORIGINAL app and not "wherever the cursor is".** By the time this
/// runs, the frontmost application is Fala: pressing a button in our window made
/// it so. Injecting "at the cursor" would therefore type the transcript into our
/// own search field. Something has to be brought forward first, and the only
/// destination this app can name honestly is the one recorded with the entry —
/// which the row already displays, and which the button repeats
/// ("Inserir de novo em “VS Code”"), so the target is stated before the press
/// rather than discovered after it.
///
/// The cost is real and is the open design question on this surface: a user who
/// wants a three-day-old transcript in a DIFFERENT app cannot get it here, and
/// must copy instead. Hiding Fala and injecting into whatever the system brings
/// forward was the alternative; it is unpredictable in exactly the situation
/// that matters (the text lands in an unknown window), so the predictable
/// refusal was preferred. See the report for the designer.
///
/// Entries with no verifiable destination cannot be re-injected at all
/// (`.unknownDestination`); their button is disabled rather than guessing.
public actor TranscriptReinjector: TranscriptReinjecting {
  /// How long the destination app gets to come forward before we re-check who
  /// is frontmost. Same value as `InjectionUndoService`, for the same reason.
  public static let defaultActivationDelay: Duration = .milliseconds(250)

  private let injector: any TextInjector
  private let focus: DestinationFocus
  /// Tail of the re-injection chain. See `reinject(_:)`.
  private var pending: Task<ReinjectOutcome, Never>?

  /// - Parameters:
  ///   - injector: MUST be the same instance the `DictationCoordinator` uses.
  ///     `ClipboardInjector` serialises overlapping injections against its own
  ///     `pending` chain; a second instance would snapshot the clipboard while
  ///     the first was holding the transcript on it and "restore" that.
  ///   - activator: pass `nil` to disable the activation path entirely, in
  ///     which case re-injection refuses whenever the destination is not
  ///     already frontmost.
  ///   - ownBundleIdentifier: how the service recognises "the frontmost app is
  ///     us". Injected because `Bundle.main` in a test process is the test
  ///     runner, not Fala.
  public init(
    injector: any TextInjector,
    frontmost: any FrontmostApplicationProviding = SystemFrontmostApplication(),
    activator: (any ApplicationActivating)? = SystemApplicationActivator(),
    delay: any InjectionDelaying = SystemInjectionDelay(),
    ownBundleIdentifier: @escaping @Sendable () -> String? = { Bundle.main.bundleIdentifier },
    activationDelay: Duration = TranscriptReinjector.defaultActivationDelay
  ) {
    self.injector = injector
    self.focus = DestinationFocus(
      frontmost: frontmost,
      activator: activator,
      delay: delay,
      ownBundleIdentifier: ownBundleIdentifier,
      activationDelay: activationDelay)
  }

  /// Serialises re-injections so two of them cannot interleave their
  /// activate-then-inject sequences.
  ///
  /// Being an `actor` is NOT enough — Swift actors are reentrant across `await`,
  /// and this suspends at least four times. Two overlapping calls could
  /// otherwise both verify "VS Code is frontmost", then have the second one
  /// inject after the user had already switched away. Same defect class as
  /// `ClipboardInjector` and `InjectionUndoService`, same fix.
  ///
  /// Note it does NOT deduplicate: two deliberate presses mean two insertions,
  /// which is what a button promises. Only the ORDER is guaranteed.
  public func reinject(_ entry: DictationHistoryEntry) async -> ReinjectOutcome {
    let predecessor = pending
    let task = Task { [predecessor] () async -> ReinjectOutcome in
      _ = await predecessor?.value
      return await self.perform(entry)
    }
    pending = task
    return await task.value
  }

  private func perform(_ entry: DictationHistoryEntry) async -> ReinjectOutcome {
    let text = entry.text
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .emptyText
    }
    guard let destination = entry.destinationApp, destination.isVerifiable,
      let bundleID = destination.bundleIdentifier
    else {
      return .unknownDestination
    }

    if case .refused(let actual) = await focus.bringForward(destination, bundleID: bundleID) {
      return .destinationUnavailable(
        expected: destination.displayName, actual: actual?.displayName)
    }

    do {
      // Secure input, the pasteboard snapshot and the per-app strategy are all
      // the injector's job — the same job it does for a live dictation.
      try await injector.inject(text)
    } catch let error as InjectionError {
      return .failed(error)
    } catch {
      return .failed(.pasteboardFailure(reason: "reinjection failed"))
    }
    return .injected(destination: destination.displayName)
  }
}
