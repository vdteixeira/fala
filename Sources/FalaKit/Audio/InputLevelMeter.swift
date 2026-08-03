// The "Nível de entrada" meter from design/mockups/settings-window.dc.html,
// Áudio tab:
//
//   const levels = [1,1,1,1,1,1,1,1,0,0,0,0];
//   const meterSegs = levels.map((v, i) => ({
//     c: v ? (i > 9 ? 'var(--color-state-warning)' : 'var(--color-state-recording)')
//          : 'var(--color-border)'
//   }));
//
// Twelve segments; the top two are amber; unlit segments are the border colour.
// The mapping lives here, in FalaKit, so it is pure and testable — the view only
// draws the array it is handed, and asks `Theme` for each segment's colour.

import CoreGraphics
import SwiftUI

/// Sample level → twelve drawn segments.
public enum InputLevelMeter {
  /// `hint-placeholder-count="12"` on the mockup's `sc-for`.
  public static let segmentCount = 12

  /// The mockup's `i > 9`: indices 10 and 11 are the warning band.
  public static let firstWarningSegmentIndex = 10

  /// What one segment renders as. Deliberately not a `Color`: the colour is a
  /// theme decision, made by `Theme.meterSegmentColor(_:)`, and this type has to
  /// stay comparable in a test.
  public enum SegmentState: Sendable, Equatable, CaseIterable {
    /// Below the current level — `--color-border`.
    case off
    /// Lit, inside the normal band — `--color-state-recording`.
    case lit
    /// Lit, inside the top-two warning band — `--color-state-warning`.
    case hot
  }

  /// How many of the twelve segments are lit for a `0...1` meter position.
  ///
  /// Rounds UP, so any audible input lights at least one segment: a meter that
  /// reads empty while the user is speaking is indistinguishable from a dead
  /// microphone, which is exactly the diagnosis this row exists to support.
  public static func litSegmentCount(forNormalizedLevel level: Double) -> Int {
    guard level.isFinite, level > 0 else { return 0 }
    let scaled = (min(level, 1) * Double(segmentCount)).rounded(.up)
    guard scaled.isFinite else { return 0 }
    return min(max(Int(scaled), 1), segmentCount)
  }

  /// The state of one segment. Out-of-range indices are `.off` rather than a
  /// trap: this is called from a view's `ForEach` (CLAUDE.md, no `fatalError`).
  public static func segmentState(at index: Int, litSegmentCount: Int) -> SegmentState {
    guard index >= 0, index < segmentCount, index < litSegmentCount else { return .off }
    return index >= firstWarningSegmentIndex ? .hot : .lit
  }

  /// The whole meter, left to right — what a view iterates.
  public static func segments(forNormalizedLevel level: Double) -> [SegmentState] {
    let lit = litSegmentCount(forNormalizedLevel: level)
    return (0..<segmentCount).map { segmentState(at: $0, litSegmentCount: lit) }
  }

  /// The whole meter for a live reading.
  public static func segments(for level: AudioLevel) -> [SegmentState] {
    segments(forNormalizedLevel: level.normalized)
  }
}

/// The meter's sub-token geometry, in the spirit of `PillMetrics`: the mockup
/// writes these inline and `tokens.json` has no entry for them, so they get one
/// auditable home instead of being scattered through a view.
public enum InputLevelMeterMetrics {
  /// `width: 4px`.
  public static let segmentWidth: CGFloat = 4
  /// `height: 12px`.
  public static let segmentHeight: CGFloat = 12
  /// `border-radius: 1.5px`.
  public static let segmentCornerRadius: CGFloat = 1.5
  /// `gap: 2px`.
  public static let segmentSpacing: CGFloat = 2
  /// "medidor (funcional): 12 segmentos, atualiza a cada 50ms **sem transição**".
  /// The meter is redrawn, never animated — so this is a refresh rate, not a
  /// motion token, and Reduce Motion does not change it.
  public static let refreshInterval: Duration = .milliseconds(50)
}

extension Theme {
  /// The token for one meter segment, so the view never names a colour
  /// (DESIGN.md: no raw hex, size or duration in a view).
  public func meterSegmentColor(_ segment: InputLevelMeter.SegmentState) -> Color {
    switch segment {
    case .off: return color.border.base
    case .lit: return color.state.recording
    case .hot: return color.state.warning
    }
  }
}
