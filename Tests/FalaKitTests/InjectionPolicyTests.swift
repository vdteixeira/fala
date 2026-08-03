import Foundation
import Testing

@testable import FalaKit

/// Stands in for `NSWorkspace.frontmostApplication`, which a test process does
/// not have.
private struct StubFrontmostApp: FrontmostApplicationProviding {
  let app: DestinationApp?

  func current() async -> DestinationApp? { app }
}

private func app(_ bundleIdentifier: String?) -> DestinationApp {
  DestinationApp(bundleIdentifier: bundleIdentifier, name: nil)
}

@Suite("InjectionPolicy")
struct InjectionPolicyTests {

  // MARK: Lookup

  @Test("Falls back to the default for an app with no rule")
  func defaultsForUnknownApp() {
    let decision = InjectionPolicy.default.decision(for: app("com.apple.Safari"))

    #expect(decision.strategy == .clipboard)
    #expect(decision.fallback == .allowed)
    #expect(decision.matchedRule == nil)
    #expect(decision.isDefault)
  }

  @Test("Falls back to the default when the frontmost app cannot be identified")
  func defaultsForMissingApp() {
    let policy = InjectionPolicy.default

    #expect(policy.decision(for: nil).isDefault)
    // A process with no bundle identifier is not an error, just unmatchable.
    #expect(policy.decision(for: app(nil)).isDefault)
    #expect(policy.decision(for: app("")).isDefault)
  }

  @Test("Applies a matching rule and reports which one it was")
  func appliesMatchingRule() throws {
    let decision = InjectionPolicy.default.decision(for: app("com.apple.Terminal"))
    let rule = try #require(decision.matchedRule)

    #expect(decision.strategy == .clipboard)
    #expect(decision.fallback == .refusedForMultilineText)
    #expect(rule.bundleIdentifier == "com.apple.Terminal")
    #expect(decision.isDefault == false)
  }

  /// Bundle identifiers get written with wildly different capitalisation
  /// (`com.googlecode.iterm2` vs `com.googlecode.iTerm2`), and a rule that
  /// silently fails to match is worse than no rule at all.
  @Test(
    "Matches the identifier case-insensitively",
    arguments: ["com.apple.terminal", "COM.APPLE.TERMINAL", "Com.Apple.Terminal"])
  func matchesCaseInsensitively(identifier: String) {
    #expect(InjectionPolicy.default.decision(for: app(identifier)).matchedRule != nil)
  }

  @Test("The first rule for an identifier wins, so callers can prepend overrides")
  func firstRuleWins() throws {
    let policy = InjectionPolicy(rules: [
      InjectionRule(
        bundleIdentifier: "com.example.app", strategy: .unicode,
        evidence: .observed, reason: "override"),
      InjectionRule(
        bundleIdentifier: "com.example.app", strategy: .clipboard,
        evidence: .observed, reason: "shipped"),
    ])

    let decision = policy.decision(for: app("com.example.app"))
    #expect(decision.strategy == .unicode)
    #expect(decision.matchedRule?.reason == "override")
  }

  @Test("Exposes a rule by identifier")
  func exposesRuleByIdentifier() {
    #expect(InjectionPolicy.default.rule(for: "COM.APPLE.TERMINAL") != nil)
    #expect(InjectionPolicy.default.rule(for: "com.apple.Safari") == nil)
  }

  @Test("A custom default strategy applies to unmatched apps")
  func customDefaultStrategy() {
    let policy = InjectionPolicy(
      rules: [], defaultStrategy: .unicode, defaultFallback: .refused)

    let decision = policy.decision(for: app("com.apple.Safari"))
    #expect(decision.strategy == .unicode)
    #expect(decision.fallback == .refused)
  }

  // MARK: Fallback semantics

  @Test("An allowed fallback permits anything")
  func allowedFallbackPermitsAnything() {
    #expect(InjectionFallback.allowed.permits("uma linha"))
    #expect(InjectionFallback.allowed.permits("duas\nlinhas"))
  }

  @Test("A refused fallback permits nothing")
  func refusedFallbackPermitsNothing() {
    #expect(InjectionFallback.refused.permits("uma linha") == false)
    #expect(InjectionFallback.refused.permits("") == false)
  }

  /// The terminal rule: a typed newline presses Return at a shell prompt. Every
  /// line separator counts, not just `\n` — `\r` alone is what a classic Mac
  /// line ending is, and it submits just the same.
  @Test(
    "A multiline-refused fallback rejects every kind of line break",
    arguments: [
      "sobe\no container",
      "sobe\r\no container",
      "sobe\ro container",
      "sobe\u{2028}o container",
      "sobe\u{0085}o container",
    ])
  func multilineRefusedFallbackRejectsLineBreaks(text: String) {
    #expect(InjectionFallback.refusedForMultilineText.permits(text) == false)
  }

  @Test("A multiline-refused fallback still permits single-line text")
  func multilineRefusedFallbackPermitsSingleLine() {
    let single = "faz o deploy no endpoint do Kubernetes"
    #expect(InjectionFallback.refusedForMultilineText.permits(single))
    // Trailing spaces are not line breaks.
    #expect(InjectionFallback.refusedForMultilineText.permits("  olá  "))
  }

  // MARK: The shipped list — honesty tripwires
  //
  // FR-14's list is the kind of thing that accumulates plausible-sounding
  // entries nobody ever checked. These tests pin what the list is ALLOWED to
  // claim, so growing it is a deliberate act with a visible diff, not a drive-by
  // addition.

  @Test("Every shipped rule states a substantive reason")
  func everyRuleStatesAReason() {
    for rule in InjectionPolicy.default.rules {
      #expect(rule.reason.count > 120, "rule for \(rule.bundleIdentifier) explains too little")
    }
  }

  /// Nothing shipped is folklore: no rule may claim third-party hearsay as its
  /// justification. If a future entry genuinely rests on someone else's report,
  /// this test has to be changed on purpose.
  @Test("No shipped rule rests on an unverified third-party report")
  func noShippedRuleIsFolklore() {
    #expect(InjectionPolicy.default.rules.allSatisfy { $0.evidence != .thirdPartyReport })
  }

  /// The other direction, and the more uncomfortable one: nothing in the list
  /// has been MEASURED against a real app either. As of T2.8 every entry is a
  /// named mechanism, and claiming `.observed` requires someone to have actually
  /// observed it — including editing this test.
  @Test("No shipped rule claims to have been observed")
  func noShippedRuleClaimsObservation() {
    #expect(InjectionPolicy.default.rules.allSatisfy { $0.evidence == .documentedMechanism })
  }

  /// The unicode allowlist is EMPTY on purpose (see `InjectionPolicy`'s note on
  /// the candidates that were rejected). `UnicodeInjector` is reached by
  /// fallback, not by app reputation. Adding the first entry must be a conscious
  /// change, because the failure mode of a wrong one is silent text corruption.
  @Test("The shipped list contains no unicode allowlist entry")
  func shippedListHasNoUnicodeEntry() {
    #expect(InjectionPolicy.default.rules.allSatisfy { $0.strategy == .clipboard })
  }

  @Test("Shipped identifiers are plausible reverse-DNS strings")
  func shippedIdentifiersArePlausible() {
    for rule in InjectionPolicy.default.rules {
      let identifier = rule.bundleIdentifier
      #expect(identifier.contains("."))
      #expect(identifier.contains(where: \.isWhitespace) == false)
      #expect(identifier.hasPrefix(".") == false)
      #expect(identifier.hasSuffix(".") == false)
    }
  }

  /// FR-11: clipboard stays the default. The unicode path is not atomic and
  /// fails silently in apps that ignore the payload, so a change of default is
  /// a product decision, not a refactor.
  @Test("Clipboard is the default strategy for every app without a rule")
  func clipboardIsTheDefault() {
    #expect(InjectionPolicy.default.defaultStrategy == .clipboard)
    #expect(InjectionPolicy.default.defaultFallback == .allowed)
  }

  @Test("Ships the two terminal rules and nothing else")
  func shipsExactlyTheTerminalRules() {
    let identifiers = InjectionPolicy.default.rules.map(\.bundleIdentifier)
    #expect(identifiers == ["com.apple.Terminal", "com.googlecode.iterm2"])
    #expect(
      InjectionPolicy.default.rules.allSatisfy {
        $0.fallback == .refusedForMultilineText
      })
  }
}

@Suite("InjectionStrategyChooser")
struct InjectionStrategyChooserTests {
  @Test("Asks the frontmost-app seam and applies the policy to the answer")
  func appliesPolicyToFrontmostApp() async {
    let chooser = InjectionStrategyChooser(
      policy: .default, frontmostApp: StubFrontmostApp(app: app("com.apple.Terminal")))

    let decision = await chooser.decide()

    #expect(decision.matchedRule?.bundleIdentifier == "com.apple.Terminal")
    #expect(decision.fallback == .refusedForMultilineText)
  }

  @Test("Takes the default when nothing is frontmost")
  func defaultsWhenNothingIsFrontmost() async {
    let chooser = InjectionStrategyChooser(
      policy: .default, frontmostApp: StubFrontmostApp(app: nil))

    #expect(await chooser.decide().isDefault)
  }

  @Test("Uses the policy it was given, not the shipped one")
  func usesTheGivenPolicy() async {
    let policy = InjectionPolicy(rules: [
      InjectionRule(
        bundleIdentifier: "com.example.editor", strategy: .unicode,
        fallback: .refused, evidence: .observed,
        reason: "test rule")
    ])
    let chooser = InjectionStrategyChooser(
      policy: policy, frontmostApp: StubFrontmostApp(app: app("com.example.editor")))

    let decision = await chooser.decide()
    #expect(decision.strategy == .unicode)
    #expect(decision.fallback == .refused)
  }
}
