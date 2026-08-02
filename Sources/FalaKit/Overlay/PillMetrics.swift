// The pill's sub-token geometry.
//
// design/CLAUDE.md forbids hardcoded values in components, and tokens.json has no
// entry for any of these — the mockup writes them inline (icon sizes, the six
// waveform bars, the keycap chip) and `fala-tokens.css` writes the rest as
// `@keyframes` numbers. So they get ONE auditable home here instead of being
// scattered through the view, and every constant cites the line it came from.
//
// If the token agent ever absorbs these into `ThemePill`, this file should be
// deleted rather than kept in sync.

import CoreGraphics
import SwiftUI

public enum PillMetrics {
  // MARK: Icons — pill-overlay.dc.html, the `.material-symbols-outlined` spans

  /// The state glyph in a full pill: `font-size: 18px`.
  public static let iconSize: CGFloat = 18
  /// The `cpu` glyph in the "no dispositivo" badge: `font-size: 12px`.
  public static let badgeIconSize: CGFloat = 12
  /// Gap between that glyph and its text: `gap: 3px`.
  public static let badgeSpacing: CGFloat = 3

  // MARK: Waveform — the six `fala-wave` spans

  public static let waveformBarCount = 6
  /// `width: 3px`.
  public static let waveformBarWidth: CGFloat = 3
  /// `height: 16px`.
  public static let waveformBarHeight: CGFloat = 16
  /// `gap: 2px`.
  public static let waveformBarSpacing: CGFloat = 2
  /// `border-radius: 2px`.
  public static let waveformBarRadius: CGFloat = 2
  /// `@keyframes fala-wave { 0%,100% { scaleY(0.35) } 50% { scaleY(1) } }`.
  public static let waveformMinScale: CGFloat = 0.35
  /// Reduce Motion: "waveform vira barras estáticas a 60%" (mockup footer, and
  /// DESIGN-HANDOFF.md §6). A fixed height, not a frozen frame of the animation.
  public static let waveformReducedScale: CGFloat = 0.6
  /// The mockup staggers the six bars with NEGATIVE CSS delays (-0.10s … -0.65s),
  /// which start each bar part-way through its first cycle. SwiftUI has no
  /// negative delay, so these are applied as positive offsets: the steady state
  /// — the only part anyone sees — is identical, and only the first cycle differs.
  public static let waveformPhaseOffsets: [Double] = [0.10, 0.42, 0.65, 0.22, 0.55, 0.33]

  // MARK: Hotkey keycap — the `rgba(255,255,255,0.14)` chip

  /// `border-radius: 4px`.
  public static let keycapCornerRadius: CGFloat = 4
  /// `padding: 2px 6px`.
  public static let keycapPaddingVertical: CGFloat = 2
  public static let keycapPaddingHorizontal: CGFloat = 6

  // MARK: Enter/exit — fala-tokens.css `@keyframes`

  /// `fala-appear`: `from { translateY(12px) scale(0.92) }`.
  public static let appearOffset: CGFloat = 12
  public static let appearScale: CGFloat = 0.92
  /// `fala-dismiss`: `to { translateY(8px) scale(0.95) }`.
  public static let dismissOffset: CGFloat = 8
  public static let dismissScale: CGFloat = 0.95

  /// A type token rendered in SF Mono. `TypeToken.font` always uses the token's
  /// own family, and the keycap is the one place the mockup pairs the micro size
  /// with `--font-family-mono`.
  public static func monoFont(_ token: TypeToken) -> Font {
    .system(size: token.size, weight: token.fontWeight, design: .monospaced)
  }
}
