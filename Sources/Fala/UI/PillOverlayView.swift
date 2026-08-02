// The SwiftUI contents of the pill overlay (TASKS.md T2.3).
//
// Every value here comes from `@Environment(\.theme)` or from `PillMetrics`; there
// is no hex, no font size and no duration written in this file. Every decision —
// which glyph, which pt-BR line, which chrome — was already made by
// `PillPresentation`, so these views only lay things out.
//
// Reduce Motion (DESIGN-HANDOFF.md §6) is honoured in three places: the waveform
// becomes static bars at 60%, the spinner becomes a fixed glyph, and the
// enter/exit transition becomes `.identity`. Nothing about the state's meaning
// lives in the motion — colour, icon and text carry it on their own.

import FalaKit
import SwiftUI

// MARK: - Root

struct PillOverlayView: View {
  let model: PillOverlayModel

  @Environment(\.theme) private var theme

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      content
        .padding(.horizontal, theme.space.md)
        .padding(.bottom, theme.space.xxxl)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
  }

  @ViewBuilder private var content: some View {
    switch model.content {
    case .hidden:
      EmptyView()
    case .collapsed:
      CollapsedSliver().transition(sliverTransition)
    case .pill(let presentation):
      PillBody(presentation: presentation).transition(pillTransition)
    }
  }

  /// `fala-appear` in, `fala-dismiss` out. The durations live on the animation
  /// (chosen by `PillOverlayController`); only the geometry is here.
  private var pillTransition: AnyTransition {
    guard !theme.motion.reduceMotion else { return .identity }
    return .asymmetric(
      insertion: .opacity
        .combined(with: .offset(y: PillMetrics.appearOffset))
        .combined(with: .scale(scale: PillMetrics.appearScale)),
      removal: .opacity
        .combined(with: .offset(y: PillMetrics.dismissOffset))
        .combined(with: .scale(scale: PillMetrics.dismissScale)))
  }

  /// The sliver is already minimal; it just fades.
  private var sliverTransition: AnyTransition {
    theme.motion.reduceMotion ? .identity : .opacity
  }
}

// MARK: - Hidden state

/// "Oculta": a 28×5 trace at 35% opacity that disappears after ~2s of inactivity.
private struct CollapsedSliver: View {
  @Environment(\.theme) private var theme

  var body: some View {
    Capsule(style: .continuous)
      .fill(theme.pill.background)
      .frame(
        width: theme.pill.collapsedSize.width,
        height: theme.pill.collapsedSize.height
      )
      .opacity(theme.pill.collapsedOpacity)
      .falaShadow(theme.shadow.md)
      .accessibilityHidden(true)
  }
}

// MARK: - The pill

private struct PillBody: View {
  let presentation: PillPresentation

  @Environment(\.theme) private var theme

  var body: some View {
    HStack(alignment: .center, spacing: theme.space.xs) {
      if presentation.spinsIcon {
        SpinningIcon(symbol: presentation.symbol, tint: tint)
      } else {
        StateIcon(symbol: presentation.symbol, tint: tint)
      }

      if presentation.showsWaveform {
        WaveformBars()
      }

      Text(presentation.label)
        .font(theme.type.caption.font.weight(.semibold))
        .lineSpacing(theme.type.caption.lineSpacing)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      if let hint = presentation.hotkeyHint {
        Keycap(text: hint)
      }

      if presentation.showsOnDeviceBadge {
        OnDeviceBadge()
      }
    }
    // The only foreground colour valid on the HUD: the regular text tokens flip
    // with the appearance and would go dark-on-dark here.
    .foregroundStyle(theme.pill.text)
    .padding(.vertical, theme.space.xs)
    .padding(.horizontal, theme.space.md)
    .background { PillBackdrop() }
    .falaShadow(theme.pill.shadow)
    // One element, one pt-BR line. The glyphs and bars restate the label and are
    // hidden individually, so VoiceOver does not read the pill three times.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.label)
  }

  private var tint: Color { theme.style(for: presentation.kind).tint }
}

/// The dark HUD material, in both system appearances.
///
/// The mockup's `backdrop-filter: blur(20px)` becomes a real SwiftUI material
/// (DESIGN.md: a flat CSS fill that should be vibrancy is a HIG override). The
/// `--color-pill-bg` fill still sits on top of it — at 88–92% opacity it is what
/// gives the HUD its plum, and the material only shows through the remainder.
private struct PillBackdrop: View {
  @Environment(\.theme) private var theme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: theme.pill.cornerRadius, style: .continuous)
    // A 20pt radius on a ~32pt-tall single-line pill clamps to a capsule, and
    // opens up into `--radius-xl` once the label wraps — which is exactly the
    // "one line when it fits, rounded rect when narrow" rule from §1.
    ZStack {
      if reduceTransparency {
        // Reduce Transparency asks for no vibrancy at all. `bg.canvas` resolves
        // to the dark canvas here because the panel forces the dark appearance,
        // so the pill just becomes opaque instead of losing its identity.
        shape.fill(theme.color.bg.canvas)
      } else {
        shape.fill(.ultraThinMaterial)
      }
      shape.fill(theme.pill.background)
    }
  }
}

// MARK: - Pieces

private struct StateIcon: View {
  let symbol: String
  let tint: Color

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: PillMetrics.iconSize))
      .foregroundStyle(tint)
      .accessibilityHidden(true)
  }
}

/// `fala-spin` — 900ms linear, forever. Its own view type so that switching to
/// and from the transcribing state remounts it and restarts the rotation.
private struct SpinningIcon: View {
  let symbol: String
  let tint: Color

  @Environment(\.theme) private var theme
  @State private var spinning = false

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: PillMetrics.iconSize))
      .foregroundStyle(tint)
      .rotationEffect(.degrees(spinning ? 360 : 0))
      // `theme.motion.spin` is nil under Reduce Motion, so the glyph jumps
      // straight to 360° — indistinguishable from never having moved.
      .animation(theme.motion.spin, value: spinning)
      .onAppear { spinning = true }
      .accessibilityHidden(true)
  }
}

/// `fala-wave` — six bars, staggered, forever. Voice level is not wired yet
/// (the coordinator publishes states, not RMS); the mockup's own animation is the
/// placeholder until it is, and the bar geometry is already what a level meter
/// would drive.
private struct WaveformBars: View {
  @Environment(\.theme) private var theme
  @State private var animating = false

  var body: some View {
    HStack(spacing: PillMetrics.waveformBarSpacing) {
      ForEach(0..<PillMetrics.waveformBarCount, id: \.self) { index in
        RoundedRectangle(cornerRadius: PillMetrics.waveformBarRadius, style: .continuous)
          .fill(theme.color.state.recording)
          .frame(width: PillMetrics.waveformBarWidth, height: PillMetrics.waveformBarHeight)
          .scaleEffect(x: 1, y: scale, anchor: .center)
          .animation(theme.motion.wave?.delay(phase(index)), value: animating)
      }
    }
    .frame(height: PillMetrics.waveformBarHeight)
    .onAppear { animating = true }
    .accessibilityHidden(true)
  }

  /// Static bars at 60% under Reduce Motion — still a waveform, just not a moving
  /// one (DESIGN-HANDOFF.md §6).
  private var scale: CGFloat {
    if theme.motion.reduceMotion { return PillMetrics.waveformReducedScale }
    return animating ? 1 : PillMetrics.waveformMinScale
  }

  private func phase(_ index: Int) -> Double {
    let offsets = PillMetrics.waveformPhaseOffsets
    return offsets.isEmpty ? 0 : offsets[index % offsets.count]
  }
}

/// The monospaced hotkey chip that teaches the gesture.
private struct Keycap: View {
  let text: String

  @Environment(\.theme) private var theme

  var body: some View {
    Text(text)
      .font(PillMetrics.monoFont(theme.type.micro))
      .padding(.vertical, PillMetrics.keycapPaddingVertical)
      .padding(.horizontal, PillMetrics.keycapPaddingHorizontal)
      .background(
        RoundedRectangle(cornerRadius: PillMetrics.keycapCornerRadius, style: .continuous)
          .fill(theme.pill.keycapBackground)
      )
      .fixedSize()
  }
}

/// "no dispositivo" — the trust badge that reinforces on-device processing.
private struct OnDeviceBadge: View {
  @Environment(\.theme) private var theme

  var body: some View {
    HStack(spacing: PillMetrics.badgeSpacing) {
      Image(systemName: FalaSymbol.processor)
        .font(.system(size: PillMetrics.badgeIconSize))
      Text(PillStrings.onDevice)
        .font(theme.type.micro.font)
    }
    .foregroundStyle(theme.color.accent.warm)
    .fixedSize()
  }
}

// MARK: - Helpers

extension View {
  /// Applies a design-system shadow. `ShadowToken` already converts the CSS blur
  /// into the radius SwiftUI wants.
  fileprivate func falaShadow(_ token: ShadowToken) -> some View {
    shadow(color: token.color.color, radius: token.radius, x: token.x, y: token.y)
  }
}
