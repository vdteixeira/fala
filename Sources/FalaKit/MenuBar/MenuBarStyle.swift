import SwiftUI

// The menu bar's two style decisions that a SwiftUI view cannot be trusted to
// make on its own, pulled down into FalaKit so they are assertable.
//
// Both are Phase 2 review findings:
//  * a quick-action row with no handler did not LOOK disabled, because the view
//    painted an explicit `.foregroundStyle` over whatever dimming
//    `.buttonStyle(.plain)` derives from the `isEnabled` environment;
//  * the Reduce-Transparency fallback was `bg.vibrancy`, which is 78% / 72%
//    alpha — still translucent, which is the opposite of what the setting asks
//    for.

/// The foreground tokens of one quick-action row.
///
/// A struct rather than three loose properties so a test can pin the WHOLE row
/// appearance for a state, and so the view has exactly one thing to read.
public struct MenuBarRowStyle: Sendable, Equatable {
  public let symbol: Color
  public let title: Color
  public let shortcut: Color

  public init(symbol: Color, title: Color, shortcut: Color) {
    self.symbol = symbol
    self.title = title
    self.shortcut = shortcut
  }
}

extension Theme {
  /// Colors for a quick-action row, with the disabled case decided HERE.
  ///
  /// The view must not set a foreground style of its own on top of this: an
  /// explicit `.foregroundStyle` inside a `Button`'s label overrides the dimming
  /// the plain button style applies through `isEnabled`, which is exactly how
  /// two dead rows shipped looking alive.
  public func quickActionStyle(isEnabled: Bool) -> MenuBarRowStyle {
    guard isEnabled else {
      // Everything drops to the lowest-emphasis text token, so the row reads as
      // present-but-not-ready at a glance, in both appearances.
      return MenuBarRowStyle(
        symbol: color.text.tertiary,
        title: color.text.tertiary,
        shortcut: color.text.tertiary)
    }
    return MenuBarRowStyle(
      symbol: color.text.secondary,
      title: color.text.primary,
      shortcut: color.text.tertiary)
  }

  /// What the popover paints behind itself when Reduce Transparency is on.
  ///
  /// HIG: the fallback for a material must be OPAQUE — that is the whole point
  /// of the setting. `bg.vibrancy` is the flat stand-in for the material itself
  /// and keeps the material's alpha, so it cannot be the fallback. `bg.canvas`
  /// is the app's opaque base, and the cards inside the popover already use
  /// `bg.surface` on top of it, so the hierarchy stays the one the mockup draws.
  public var reduceTransparencyFill: Color { color.bg.canvas }
}

/// The two places the mockup overrides a type token, named once.
///
/// DESIGN.md forbids raw values in views, and these were being written inline as
/// `.font(theme.type.headline.font.weight(.bold))`. They are not new tokens: each
/// one is a token from the scale with the weight (or family) the mockup asks for
/// at that spot, so a change to the scale still moves them.
public enum MenuBarType {
  /// menubar-popover.dc.html:64 — the lockup is `font-weight: 700` over the
  /// headline size, in the display family.
  public static let brandName = derived(
    from: DesignSystem.TypeScale.headline, weight: 700, family: .display)

  /// menubar-popover.dc.html:85 — the model block title is `font-weight: 600`
  /// over the caption size (the caption token itself is 500).
  public static let blockTitle = derived(
    from: DesignSystem.TypeScale.caption, weight: 600, family: .ui)

  /// menubar-popover.dc.html:122 — the ⌘ hint is the micro token in the mono
  /// family (`--font-family-mono`).
  public static let shortcutHint = derived(
    from: DesignSystem.TypeScale.micro,
    weight: DesignSystem.TypeScale.micro.weight,
    family: .mono)

  private static func derived(
    from token: TypeToken,
    weight: Int,
    family: DesignSystem.FontFamily
  ) -> TypeToken {
    TypeToken(
      size: token.size, lineHeight: token.lineHeight, weight: weight, family: family)
  }
}
