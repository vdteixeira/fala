import Foundation

// MARK: - Which failures a retype can rescue

/// Decides whether a failure of the clipboard path may be retried by typing the
/// transcript instead (SPEC.md FR-12/FR-14).
///
/// The hard part is not "did it fail" but "did any text already reach the
/// document". `ClipboardInjector.inject` reports several genuinely different
/// situations through one case, `pasteboardFailure(reason:)`:
///
/// | reason (abridged)                          | text inserted? |
/// |--------------------------------------------|----------------|
/// | clipboard holds promised content …         | no             |
/// | pasteboard rejected the write              | no             |
/// | clipboard write failed                     | no             |
/// | paste shortcut failed                      | no             |
/// | clipboard changed during injection …       | **YES**        |
/// | clipboard restore failed / rejected …      | **YES**        |
///
/// Retrying one of the last two would type the transcript a SECOND time into a
/// document that already has it. So this is an ALLOWLIST of reasons known to
/// precede any insertion, never a denylist of the dangerous ones: if the wording
/// upstream changes, an allowlist stops recognising a case and we lose a
/// fallback (the user repeats one dictation), whereas a denylist would start
/// double-inserting. Matching on prose is fragile by nature, which is why
/// `AdaptiveTextInjectorTests` drives a REAL `ClipboardInjector` into each of
/// these states rather than hand-building the errors — those tests are the
/// tripwire that fires when the wording drifts.
public enum InjectionFallbackEligibility {
  /// Substrings of `InjectionError.pasteboardFailure(reason:)` raised strictly
  /// before the ⌘V chord is posted.
  ///
  /// "paste shortcut failed" is deliberately ABSENT even though nothing is
  /// inserted in that case: it means Quartz refused to build or post a key
  /// event, and the unicode path builds and posts the same kind of event, so a
  /// retype would fail identically. `accessibilityDenied` is excluded for the
  /// same reason, by its own case below.
  static let retypableReasonMarkers = [
    "promised content",
    "rejected the write",
    "clipboard write failed",
  ]

  public static func allowsRetyping(after error: InjectionError) -> Bool {
    switch error {
    case .secureInputActive:
      // FR-13 / US-3 is absolute. This is the one case where falling back would
      // do the exact thing the requirement exists to prevent: type a transcript
      // into a focused password field, one synthetic keystroke at a time.
      return false
    case .accessibilityDenied:
      // Both strategies synthesise CGEvents and need the same grant.
      return false
    case .emptyText:
      // Nothing to inject; both strategies agree.
      return false
    case .pasteboardFailure(let reason):
      return retypableReasonMarkers.contains { reason.contains($0) }
    }
  }
}

// MARK: - AdaptiveTextInjector

/// The injector the app actually uses: consults the per-app policy, runs the
/// chosen strategy, and retypes with the clipboard-free one when the clipboard
/// path refuses (SPEC.md FR-11, FR-12, FR-14).
///
/// The refusal this exists for is not hypothetical. `ClipboardInjector` REFUSES
/// to inject while the clipboard holds content it cannot capture and restore —
/// a copied spreadsheet range, a promised file — because clearing it destroys
/// data nothing can bring back. Before this type, that refusal cost the user the
/// whole dictation with no recovery; now it costs the clipboard strategy only.
///
/// Direction matters: the fallback is clipboard → unicode and never the reverse.
/// A failed unicode attempt may have typed PART of the transcript already (it is
/// not atomic), so retrying it through the clipboard would duplicate text; and
/// the clipboard path is the one that can damage data the user did not put at
/// risk.
public actor AdaptiveTextInjector: TextInjector {
  /// What actually happened, for tests and for a future `doctor` line. Carries
  /// no transcript text.
  public struct Outcome: Sendable, Equatable {
    public let decision: InjectionDecision
    public let strategyUsed: InjectionStrategy

    public init(decision: InjectionDecision, strategyUsed: InjectionStrategy) {
      self.decision = decision
      self.strategyUsed = strategyUsed
    }

    public var didFallBack: Bool { strategyUsed != decision.strategy }
  }

  private let clipboard: any TextInjector
  private let unicode: any TextInjector
  private let chooser: InjectionStrategyChooser
  /// Tail of the injection chain, for the same reason `ClipboardInjector` has
  /// one: two overlapping dictations that pick DIFFERENT strategies would not be
  /// serialised by either underlying injector, because each one only chains
  /// against itself.
  private var pending: Task<Outcome, Error>?

  public init(
    clipboard: any TextInjector = ClipboardInjector(),
    unicode: any TextInjector = UnicodeInjector(),
    chooser: InjectionStrategyChooser = InjectionStrategyChooser()
  ) {
    self.clipboard = clipboard
    self.unicode = unicode
    self.chooser = chooser
  }

  public func inject(_ text: String) async throws {
    _ = try await injectReportingStrategy(text)
  }

  /// `inject`, reporting which strategy the text went through.
  @discardableResult
  public func injectReportingStrategy(_ text: String) async throws -> Outcome {
    let predecessor = pending
    let task = Task { [predecessor] () async throws -> Outcome in
      // A failed predecessor must not cancel this one.
      _ = await predecessor?.result
      return try await self.performInjection(text)
    }
    pending = task
    return try await task.value
  }

  private func performInjection(_ text: String) async throws -> Outcome {
    let decision = await chooser.decide()
    do {
      try await injector(for: decision.strategy).inject(text)
      return Outcome(decision: decision, strategyUsed: decision.strategy)
    } catch let error as InjectionError {
      guard let retry = fallbackStrategy(after: error, decision: decision, text: text) else {
        throw error
      }
      // If the retype fails too, ITS error is what surfaces, not the clipboard
      // refusal that started this: it is the more recent and more actionable of
      // the two (typically `accessibilityDenied`), and every case already has a
      // pt-BR message in `DictationCoordinator.message(for:)`.
      try await injector(for: retry).inject(text)
      return Outcome(decision: decision, strategyUsed: retry)
    }
    // A non-`InjectionError` is an unknown state — we cannot tell whether text
    // landed — so it propagates untouched rather than being retried.
  }

  /// The strategy to retry with, or `nil` to let the failure stand.
  private func fallbackStrategy(
    after error: InjectionError,
    decision: InjectionDecision,
    text: String
  ) -> InjectionStrategy? {
    guard decision.strategy == .clipboard else { return nil }
    guard decision.fallback.permits(text) else { return nil }
    guard InjectionFallbackEligibility.allowsRetyping(after: error) else { return nil }
    return .unicode
  }

  private func injector(for strategy: InjectionStrategy) -> any TextInjector {
    switch strategy {
    case .clipboard: return clipboard
    case .unicode: return unicode
    }
  }
}
