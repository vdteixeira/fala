// When the pill goes away (TASKS.md T2.3, DESIGN-HANDOFF.md §1).
//
// Split out from the panel because it is the whole behavioural contract of the
// overlay and the one part of it that can be tested without a screen: "success
// after 1.2s, error after 2.5s, warning persists while the HFP route is active".

import Foundation

/// The lifetime of one piece of overlay content.
public enum PillDismissal: Sendable, Equatable {
  /// Stays until the state itself changes. Recording and transcribing (the user
  /// is mid-gesture) and the HFP warning (the condition, not an event).
  case persists
  /// Goes away on its own after this many seconds.
  case after(TimeInterval)

  /// `nil` when it persists — convenient for a caller that just wants a timer.
  public var delay: TimeInterval? {
    guard case .after(let seconds) = self else { return nil }
    return seconds
  }

  public var isAutomatic: Bool { delay != nil }
}

/// The auto-dismiss table. A value, so a test can build one with short delays and
/// the app can build one from the design tokens.
public struct PillDismissPolicy: Sendable, Equatable {
  /// "Confirmação breve: permanece 1,2s e sai."
  public let successDelay: TimeInterval
  /// "Sai após 2,5s."
  public let errorDelay: TimeInterval
  /// The collapsed sliver "some após 2s de inatividade".
  public let idleHideDelay: TimeInterval

  public init(successDelay: TimeInterval, errorDelay: TimeInterval, idleHideDelay: TimeInterval) {
    self.successDelay = successDelay
    self.errorDelay = errorDelay
    self.idleHideDelay = idleHideDelay
  }

  /// The delays are design tokens, so they come from the theme rather than from
  /// literals here. They are identical in both appearances (only the pill's
  /// colours differ), which `PillOverlayTests` asserts.
  public init(pill: ThemePill) {
    self.init(
      successDelay: pill.successDismissDelay,
      errorDelay: pill.errorDismissDelay,
      idleHideDelay: pill.idleHideDelay)
  }

  /// The policy the app ships with.
  public static let standard = PillDismissPolicy(pill: Theme.dark.pill)

  /// How long one of the six states stays on screen.
  ///
  /// `warning` is the case worth stating out loud: it is a CONDITION (the input
  /// route is HFP), not an event, so no timer may take it away. Only the route
  /// changing can.
  public func dismissal(for kind: StateKind) -> PillDismissal {
    switch kind {
    case .idle: return .after(idleHideDelay)
    case .recording, .transcribing: return .persists
    case .success: return .after(successDelay)
    case .error: return .after(errorDelay)
    case .warning: return .persists
    }
  }

  /// The same question asked about what is actually on screen.
  public func dismissal(for content: PillOverlayContent) -> PillDismissal {
    switch content {
    case .hidden: return .persists
    case .collapsed: return .after(idleHideDelay)
    case .pill(let presentation): return dismissal(for: presentation.kind)
    }
  }
}
