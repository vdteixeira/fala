// Where the overlay window sits (TASKS.md T2.3).
//
// The panel is NOT sized to the pill. It is a fixed, click-through band across
// the bottom of the active screen, and SwiftUI centres the pill inside it. That
// is deliberate: a window that resizes with the label would have to be re-framed
// and re-centred on every state change, in step with a SwiftUI animation it
// cannot see, and the two would visibly disagree. A fixed band moves the whole
// layout problem into SwiftUI, where it belongs.
//
// Pure `CGRect` arithmetic, so multi-display placement is unit-testable without a
// screen — which matters, because the failure modes here (a pill off-screen on a
// secondary display, a NaN frame on a display that reports nothing) only ever
// show up on someone else's desk.

import CoreGraphics

public struct PillOverlayGeometry: Sendable, Equatable {
  /// How much of the screen's width the band may take. A HUD that runs edge to
  /// edge reads as a system alert rather than as a status pill; the mockup caps
  /// its pill at `calc(100% - var(--space-3))` of a narrow cell, which taken
  /// literally on a 27" display would be a 2500pt-wide pill.
  public let maxWidthFraction: CGFloat
  /// Never narrower than this, so the longest label
  /// ("Microfone dos AirPods em baixa qualidade (HFP)") wraps to two lines at
  /// most. Wrapping is allowed — DESIGN-HANDOFF.md §1 specifies the wrapped form.
  public let minimumWidth: CGFloat
  /// Breathing room from the screen edges when the screen is too narrow for
  /// `minimumWidth`.
  public let horizontalMargin: CGFloat
  /// Height of the band, from the bottom of the visible frame upwards.
  ///
  /// Derived, not guessed: a wrapped two-line pill is 2×14 (caption line height)
  /// + 2×8 (vertical padding) ≈ 44pt; `--shadow-pop` needs y 12 + radius 20 = 32pt
  /// of clearance; `fala-appear` travels 12pt; and the pill is lifted 48pt off the
  /// bottom of the visible area. 136pt, rounded up onto the 8pt grid.
  public let bandHeight: CGFloat

  public init(
    maxWidthFraction: CGFloat,
    minimumWidth: CGFloat,
    horizontalMargin: CGFloat,
    bandHeight: CGFloat
  ) {
    self.maxWidthFraction = maxWidthFraction
    self.minimumWidth = minimumWidth
    self.horizontalMargin = horizontalMargin
    self.bandHeight = bandHeight
  }

  /// Built from the spacing tokens rather than from literals.
  public init(space: ThemeSpace) {
    self.init(
      maxWidthFraction: 0.5,
      minimumWidth: space.xxxl * 6,
      horizontalMargin: space.lg,
      bandHeight: space.xxxl * 3)
  }

  /// The geometry the app ships with. Spacing tokens are appearance-independent.
  public static let standard = PillOverlayGeometry(space: Theme.dark.space)

  /// The panel frame for a screen's `visibleFrame`, in AppKit screen coordinates
  /// (origin bottom-left, and negative on displays left of or below the main one).
  ///
  /// Returns `.zero` for a degenerate frame instead of producing a NaN or a
  /// negative size: a screen list can legitimately be empty or stale while the
  /// user is re-arranging displays, and the overlay must survive that.
  public func panelFrame(in visibleFrame: CGRect) -> CGRect {
    guard
      visibleFrame.width.isFinite, visibleFrame.height.isFinite,
      visibleFrame.width > 0, visibleFrame.height > 0
    else { return .zero }

    let inset = max(0, visibleFrame.width - horizontalMargin * 2)
    let preferred = max(minimumWidth, visibleFrame.width * maxWidthFraction)
    let width = min(visibleFrame.width, min(preferred, max(inset, minimumWidth)))
    let height = min(bandHeight, visibleFrame.height)
    let x = visibleFrame.minX + (visibleFrame.width - width) / 2

    return CGRect(x: x, y: visibleFrame.minY, width: width, height: height)
  }
}
