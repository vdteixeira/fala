import Foundation

// MARK: - Vocabulary

/// Which way the transcript reaches the cursor.
public enum InjectionStrategy: String, Sendable, Equatable, CaseIterable {
  /// `ClipboardInjector` — snapshot, write, ⌘V, restore (SPEC.md FR-11).
  case clipboard
  /// `UnicodeInjector` — typed as synthetic key events (SPEC.md FR-12).
  case unicode
}

/// Whether the OTHER strategy may be tried when the chosen one refuses.
///
/// Separate from the strategy because "clipboard is better here" and "typing
/// here would be dangerous" are different claims, and only the second one is
/// worth costing the user a dictation.
public enum InjectionFallback: Sendable, Equatable {
  /// Switch strategies rather than lose the dictation. The default.
  case allowed
  /// Never switch for this app: a refusal ends the dictation and the user
  /// repeats it. Reserved for apps where the other strategy could do damage.
  case refused
  /// Switch only while the text is a single line.
  ///
  /// The terminal case: typed characters ARE keystrokes, so a newline inside a
  /// transcript presses Return at a shell prompt and executes whatever precedes
  /// it. A pasted newline does not, because modern shells frame a paste with
  /// bracketed-paste escapes and treat its contents as data. Single-line text
  /// carries no such hazard, so refusing it too would cost dictations for
  /// nothing.
  case refusedForMultilineText

  /// Whether `text` may be handed to the other strategy.
  public func permits(_ text: String) -> Bool {
    switch self {
    case .allowed:
      return true
    case .refused:
      return false
    case .refusedForMultilineText:
      return !text.contains(where: \.isNewline)
    }
  }
}

/// How much a rule's behavioural claim is actually worth.
///
/// Recorded per rule so the shipped list can be audited rather than trusted.
/// Every list of "apps where injection misbehaves" on the internet is a mix of
/// measurement, reasoning and hearsay, and once they are in the same array they
/// are indistinguishable — which is how folklore ends up shipping.
public enum InjectionRuleEvidence: Sendable, Equatable, CaseIterable {
  /// Observed on a real machine, with what was observed written in `reason`.
  case observed
  /// Derived from documented behaviour of macOS or of the app, but NOT observed
  /// by us. The claim stands or falls with the mechanism named in `reason`.
  case documentedMechanism
  /// Someone else reported it and we did not verify it. Nothing ships with this
  /// today; it exists so a future entry has an honest place to sit.
  case thirdPartyReport
}

/// One app's entry in the allowlist/denylist (SPEC.md FR-14).
public struct InjectionRule: Sendable, Equatable {
  /// Matched case-insensitively against the frontmost app's bundle identifier.
  /// Case-insensitive because identifiers are frequently written with different
  /// capitalisation than the bundle actually declares, and a silently
  /// non-matching rule is worse than no rule.
  public let bundleIdentifier: String
  public let strategy: InjectionStrategy
  public let fallback: InjectionFallback
  /// Why this rule exists — DEVELOPER-FACING ENGLISH, deliberately not a
  /// user-facing string. Nothing here is shown in the UI; if a rule ever needs
  /// to be explained to the user, that message gets written in pt-BR at the
  /// surface that shows it.
  public let reason: String
  public let evidence: InjectionRuleEvidence

  public init(
    bundleIdentifier: String,
    strategy: InjectionStrategy,
    fallback: InjectionFallback = .allowed,
    evidence: InjectionRuleEvidence,
    reason: String
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.strategy = strategy
    self.fallback = fallback
    self.evidence = evidence
    self.reason = reason
  }
}

// MARK: - Policy

/// What the chooser concluded, and why.
public struct InjectionDecision: Sendable, Equatable {
  public let strategy: InjectionStrategy
  public let fallback: InjectionFallback
  /// The rule that matched, or `nil` when the default applied. Carried so the
  /// decision is explainable in a test and in `doctor` without re-running the
  /// lookup.
  public let matchedRule: InjectionRule?

  public init(
    strategy: InjectionStrategy,
    fallback: InjectionFallback,
    matchedRule: InjectionRule? = nil
  ) {
    self.strategy = strategy
    self.fallback = fallback
    self.matchedRule = matchedRule
  }

  public var isDefault: Bool { matchedRule == nil }
}

/// The per-app allowlist/denylist and the default that applies to everything
/// else (SPEC.md FR-14).
///
/// ## The shipped list is deliberately tiny, and here is why
///
/// FR-14 says "apps where injection is known to misbehave". *Known* is the load-
/// bearing word. Injection here has never been measured against a third-party
/// app, so every candidate entry was judged on whether a MECHANISM could be
/// named. Three popular candidates were considered and REJECTED rather than
/// shipped on reputation:
///
/// - **Virtual machines and remote desktops** (Parallels, VMware, UTM, Microsoft
///   Remote Desktop, Screen Sharing). The clipboard path is genuinely suspect:
///   the guest pastes the GUEST clipboard, which the guest tools sync from the
///   host asynchronously, so a ⌘V 150 ms after the write can paste stale
///   content. But the unicode path is suspect in the same breath: a VM that
///   translates host key events into guest scancodes reads the key CODE and
///   would deliver "a" instead of the payload. Two plausible failures in
///   opposite directions is not a rule, it is a guess — and a wrong guess here
///   silently corrupts text inside someone's VM. Left to the default.
/// - **Electron and Java apps losing the paste race** (the settle-delay
///   argument). Real mechanism, but it is a property of machine load, not of a
///   bundle identifier, and naming the usual suspects would be reputation
///   dressed up as data.
/// - **Emacs with `mac-command-modifier` set to meta**, where ⌘V is `M-v`
///   (scroll) rather than paste. That is a USER SETTING, not an app default, so
///   a bundle-identifier rule would be wrong for every Emacs user who did not
///   change it.
///
/// What remains is one mechanism solid enough to act on — see the terminal
/// rules — and an empty unicode allowlist. That is the honest state of the
/// evidence, not an incomplete implementation: the chooser, the rule shape and
/// the fallback are all here, so adding an entry once something IS measured is
/// a one-line change.
public struct InjectionPolicy: Sendable, Equatable {
  /// Applied to every app without a rule. `.clipboard` per FR-11: it is atomic,
  /// it survives apps that ignore synthetic Unicode payloads, and it is the path
  /// with real mileage on it (T1.10 item 1).
  public let defaultStrategy: InjectionStrategy
  /// Fallback for apps without a rule. `.allowed`, because the case this whole
  /// task exists for — the clipboard holding content that cannot be captured —
  /// happens on the user's clipboard, not in any particular app.
  public let defaultFallback: InjectionFallback
  public let rules: [InjectionRule]

  /// Lower-cased index over `rules`. The FIRST rule for an identifier wins, so
  /// a caller can prepend overrides to the shipped list.
  private let index: [String: InjectionRule]

  public init(
    rules: [InjectionRule],
    defaultStrategy: InjectionStrategy = .clipboard,
    defaultFallback: InjectionFallback = .allowed
  ) {
    self.rules = rules
    self.defaultStrategy = defaultStrategy
    self.defaultFallback = defaultFallback
    var index: [String: InjectionRule] = [:]
    for rule in rules {
      let key = rule.bundleIdentifier.lowercased()
      if index[key] == nil {
        index[key] = rule
      }
    }
    self.index = index
  }

  /// - Parameter app: the frontmost app, as `FrontmostApplicationProviding`
  ///   reports it. `nil`, or an app with no bundle identifier (a bare
  ///   executable, some helpers), takes the default.
  public func decision(for app: DestinationApp?) -> InjectionDecision {
    guard
      let identifier = app?.bundleIdentifier,
      let rule = index[identifier.lowercased()]
    else {
      return InjectionDecision(strategy: defaultStrategy, fallback: defaultFallback)
    }
    return InjectionDecision(
      strategy: rule.strategy, fallback: rule.fallback, matchedRule: rule)
  }

  public func rule(for bundleIdentifier: String) -> InjectionRule? {
    index[bundleIdentifier.lowercased()]
  }

  // MARK: Shipped list

  /// Shared text of the terminal rules, so the two entries cannot drift apart.
  private static let terminalReason = """
    Terminal emulator. Typed events ARE keystrokes, so a newline anywhere in a \
    transcript presses Return at a shell prompt and RUNS the line — while a \
    pasted newline does not, because modern shells put the line editor in \
    bracketed-paste mode and treat the payload as data. The asymmetry is only \
    about newlines, hence refusedForMultilineText rather than a blanket refusal: \
    a single-line transcript typed at a prompt is no worse than a pasted one. \
    Mechanism, not measurement: bracketed-paste support was not verified in \
    either app, and the rule does not depend on it — the load-bearing half \
    (typing Return executes) is unconditional.
    """

  /// The list that ships. Two entries, one mechanism; see the type's note for
  /// what was rejected and why.
  public static let `default` = InjectionPolicy(rules: [
    InjectionRule(
      bundleIdentifier: "com.apple.Terminal",
      strategy: .clipboard,
      fallback: .refusedForMultilineText,
      evidence: .documentedMechanism,
      reason: terminalReason
        + " Identifier read from /System/Applications/Utilities/Terminal.app on the"
        + " development machine (2026-08-02)."
    ),
    InjectionRule(
      bundleIdentifier: "com.googlecode.iterm2",
      strategy: .clipboard,
      fallback: .refusedForMultilineText,
      evidence: .documentedMechanism,
      reason: terminalReason
        + " Identifier NOT verified: iTerm2 is not installed on the development"
        + " machine, so this string is from memory. Matching is case-insensitive,"
        + " which covers the usual iTerm2/iterm2 confusion but not a wrong string."
    ),
  ])
}

// MARK: - Chooser

/// Picks the strategy for the app the user is about to dictate into (FR-14).
///
/// The frontmost-app lookup is NOT redefined here: `FrontmostApplicationProviding`
/// / `SystemFrontmostApplication` already exist for FR-17's history (which
/// records the destination app of every injection) and answer exactly the same
/// question. Two readers of `NSWorkspace.frontmostApplication` in one module
/// could disagree with each other about the same dictation.
///
/// KNOWN LIMIT: Fala is an accessory app that does not take focus during a
/// dictation, so at injection time the frontmost app is the user's target app.
/// With the menu-bar popover open and key, the frontmost app is FALA — harmless
/// today, since no rule matches our own identifier and the default applies.
public struct InjectionStrategyChooser: Sendable {
  private let policy: InjectionPolicy
  private let frontmost: any FrontmostApplicationProviding

  public init(
    policy: InjectionPolicy = .default,
    frontmostApp: any FrontmostApplicationProviding = SystemFrontmostApplication()
  ) {
    self.policy = policy
    self.frontmost = frontmostApp
  }

  /// Sampled per injection rather than cached: the user switches apps between
  /// dictations, and the lookup is one cheap AppKit read.
  public func decide() async -> InjectionDecision {
    policy.decision(for: await frontmost.current())
  }
}
