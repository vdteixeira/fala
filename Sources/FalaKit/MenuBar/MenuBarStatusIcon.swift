import CoreGraphics
import Foundation

/// What the `NSStatusItem` draws right now.
///
/// A menu-bar image is a TEMPLATE image: macOS discards its colors and tints it
/// for the current menu-bar appearance. So the state cannot be carried by the
/// six state tints the way the pill carries them — it has to be carried by the
/// SHAPE. Here that is the bar amplitude: the mark grows as the app gets louder.
public enum MenuBarIconVariant: String, Sendable, CaseIterable {
  /// Resting, dictation enabled.
  case idle
  /// The microphone is live.
  case recording
  /// On-device transcription is running.
  case working
  /// The user turned dictation off in the popover header.
  case disabled

  /// How far the bars are pushed from their resting heights toward the full box.
  public var amplitude: Double {
    switch self {
    case .idle, .disabled: return 0
    case .working: return 0.5
    case .recording: return 1
    }
  }

  /// `disabled` is drawn at rest and dimmed by AppKit (`appearsDisabled`), which
  /// is the native way to say "this control is off" — inventing a slashed glyph
  /// would be a second, non-standard vocabulary for the same thing.
  public var appearsDisabled: Bool { self == .disabled }

  /// pt-BR VoiceOver label. The status item is the whole UI for a keyboard-only
  /// user, so this is functional, not decoration.
  public var accessibilityLabel: String {
    switch self {
    case .idle: return "Fala — pronto para ditar"
    case .recording: return "Fala — gravando"
    case .working: return "Fala — transcrevendo"
    case .disabled: return "Fala — ditado desativado"
    }
  }

  /// How `DictationState` (+ the on/off switch) projects onto the menu bar.
  ///
  /// Two deliberate rules:
  ///
  /// 1. `recording` beats `disabled`. Turning dictation off does not abort a
  ///    capture that is already running (see `CaptureGate`), and an icon that
  ///    said "off" while the microphone was still open would be a lie about the
  ///    one thing this app must never lie about.
  /// 2. `success` and `failure` read as `idle`. Both are transient — the pill
  ///    owns them and dismisses after 1.2 s / 2.5 s (DESIGN-HANDOFF.md §1) — and
  ///    a menu-bar icon has no dismissal timer, so encoding them here would leave
  ///    the last outcome frozen in the menu bar until the next dictation.
  public static func variant(
    for state: DictationState,
    dictationEnabled: Bool
  ) -> MenuBarIconVariant {
    switch state {
    case .recording:
      return .recording
    case .transcribing:
      return .working
    case .idle, .success, .failure:
      return dictationEnabled ? .idle : .disabled
    }
  }
}

/// Where the four bars go. Pure geometry, so the one part of the status icon that
/// can silently be wrong — proportions, centering, clipping — is unit-testable
/// without a screen.
public struct StatusIconGeometry: Sendable, Equatable {
  /// Left to right, in the coordinate space of the rect passed in.
  public let bars: [CGRect]
  /// Bar corner radius, scaled with everything else.
  public let cornerRadius: CGFloat
}

/// The logo mark: four waveform bars forming a speech quote mark
/// (design/CLAUDE.md, DESIGN-HANDOFF.md §5).
///
/// The numbers below are the mark's own proportions, taken verbatim from
/// menubar-popover.dc.html:44-47 (`width: 2.5px; height: 6/12/9/5px; gap: 2px;
/// border-radius: 1px`). They are not design tokens — tokens.json has no
/// geometry for the lockup — so this enum is where they live, once, instead of
/// being retyped inside a drawing routine.
public enum StatusIconMark {
  /// Resting heights, left to right.
  public static let barHeights: [CGFloat] = [6, 12, 9, 5]
  public static let barWidth: CGFloat = 2.5
  public static let barGap: CGFloat = 2
  public static let barCornerRadius: CGFloat = 1

  /// 2.5×4 + 2×3 = 16. At full amplitude the tallest bar also reaches 16, so the
  /// mark grows vertically inside a square and never changes width — a menu-bar
  /// item that resized while recording would shove every icon to its left.
  public static let naturalSize = CGSize(width: 16, height: 16)

  /// Apple's menu-bar template size, with the mark inset by `contentInset` so it
  /// does not touch the menu bar's edges.
  public static let statusItemSize = CGSize(width: 18, height: 18)
  public static let contentInset: CGFloat = 1

  /// Bars laid out inside `rect`, scaled uniformly and centered on both axes.
  ///
  /// `amplitude` is clamped to 0...1: 0 is the resting mark from the mockup, 1
  /// scales every bar by the same factor so the tallest one fills the box.
  public static func geometry(in rect: CGRect, amplitude: Double) -> StatusIconGeometry {
    guard rect.width > 0, rect.height > 0, let tallest = barHeights.max(), tallest > 0 else {
      return StatusIconGeometry(bars: [], cornerRadius: 0)
    }
    let level = CGFloat(min(max(amplitude, 0), 1))
    let scale = min(rect.width / naturalSize.width, rect.height / naturalSize.height)
    // Everything is driven by ONE factor, so the peak mark is the resting mark
    // stretched — not a second set of hand-picked heights that could drift.
    let peakFactor = naturalSize.height / tallest

    let width = barWidth * scale
    let gap = barGap * scale
    let count = CGFloat(barHeights.count)
    let totalWidth = width * count + gap * (count - 1)
    let originX = rect.minX + (rect.width - totalWidth) / 2

    let bars = barHeights.enumerated().map { index, resting -> CGRect in
      let height = (resting + (resting * peakFactor - resting) * level) * scale
      return CGRect(
        x: originX + CGFloat(index) * (width + gap),
        y: rect.minY + (rect.height - height) / 2,
        width: width,
        height: height)
    }
    return StatusIconGeometry(bars: bars, cornerRadius: barCornerRadius * scale)
  }
}

/// CSS `linear-gradient(<angle>deg, …)` → the two unit points SwiftUI's
/// `LinearGradient` wants.
///
/// The header lockup is the only gradient in the app, and its angle arrives as a
/// token (`theme.color.brand.markGradientAngle` = 160°). Converting it here means
/// the view never writes a `UnitPoint` literal, and the conversion — which is
/// easy to get backwards — is testable.
///
/// CSS measures the angle CLOCKWISE FROM "to top": 0° paints upward, 180°
/// downward. Approximation: the line is drawn through the box centre with a
/// half-length of 0.5 in unit space, which is exact for a square box (the lockup
/// is 26×26) and slightly under-extends the ramp on a non-square one.
public enum CSSGradientAngle {
  public static func unitPoints(degrees: Double) -> (start: CGPoint, end: CGPoint) {
    let radians = degrees * .pi / 180
    // Screen coordinates: x grows right, y grows DOWN — hence the negated cosine.
    let dx = sin(radians) / 2
    let dy = -cos(radians) / 2
    return (
      start: CGPoint(x: 0.5 - dx, y: 0.5 - dy),
      end: CGPoint(x: 0.5 + dx, y: 0.5 + dy)
    )
  }
}
