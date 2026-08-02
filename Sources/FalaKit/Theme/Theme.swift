// The SEMANTIC surface. Everything a view is allowed to see lives here:
// `@Environment(\.theme)` hands out a `Theme`, and a `Theme` hands out SwiftUI
// values (Color, Font, CGFloat, Animation) — never a hex string, never a raw
// number, never a primitive from `DesignSystem.Palette`.
//
// Sources: design/tokens/tokens.json (values), design/DESIGN-HANDOFF.md §2 (the
// six states), §5 (the icon map), §6 (motion). Nothing here is re-derived from
// the mockups: the handoff already did that work.

import CoreGraphics
import SwiftUI

// MARK: - The six states

/// The shared state vocabulary (DESIGN-HANDOFF.md §2). Six cases, one per row of
/// that table — deliberately its own type rather than `DictationState`, because
/// `warning` is not something the dictation flow can be *in*: it is a degraded
/// audio route (AirPods/HFP) that decorates whatever state is current.
public enum StateKind: String, Sendable, CaseIterable {
  case idle
  case recording
  case transcribing
  case success
  case error
  case warning

  /// How the coordinator's states project onto the design vocabulary.
  /// `failure` is `error`; nothing maps to `warning` (see above).
  public init(_ state: DictationState) {
    switch state {
    case .idle: self = .idle
    case .recording: self = .recording
    case .transcribing: self = .transcribing
    case .success: self = .success
    case .failure: self = .error
    }
  }
}

/// Everything a surface needs to render one state: the tint, its soft background
/// companion, and the SF Symbol.
public struct StateStyle: Sendable, Equatable {
  public let kind: StateKind
  /// `--color-state-<kind>`.
  public let tint: Color
  /// `--color-state-<kind>-soft`, the background companion.
  public let soft: Color
  /// The SF Symbol from DESIGN-HANDOFF.md §5.
  public let symbol: String
  /// The cause-specific symbol the handoff lists after a slash: `lock.fill` when
  /// an error was caused by a secure field, `airpods` when a warning is the HFP
  /// route. `nil` for the four states that have exactly one symbol.
  public let alternateSymbol: String?
}

/// The Material glyph → SF Symbol map from DESIGN-HANDOFF.md §5, verbatim. Views
/// use these names instead of inventing their own.
public enum FalaSymbol {
  // State icons (§2).
  public static let idle = "mic.fill"
  public static let recording = "waveform"
  public static let transcribing = "arrow.triangle.2.circlepath"
  public static let success = "checkmark.circle.fill"
  public static let error = "exclamationmark.triangle.fill"
  public static let warning = "exclamationmark.circle"
  /// Cause of an error: focus was a secure text field.
  public static let secureField = "lock.fill"
  /// Cause of a warning: the input route is Bluetooth HFP.
  public static let headphones = "airpods"

  // Chrome and content icons.
  public static let privacyShield = "lock.shield.fill"
  public static let verifiedShield = "checkmark.shield"
  public static let settings = "gearshape.fill"
  public static let history = "clock.arrow.circlepath"
  public static let dictionary = "character.book.closed.fill"
  public static let processor = "cpu"
  public static let download = "arrow.down.circle"
  public static let disk = "internaldrive"
  public static let copy = "doc.on.doc"
  public static let undo = "arrow.uturn.left"
  public static let delete = "trash"
  public static let keyboard = "keyboard"
  public static let power = "power"
  public static let pill = "capsule.fill"
  public static let edit = "pencil"
  public static let offline = "wifi.slash"
  public static let exportJSON = "square.and.arrow.up"
  public static let importJSON = "square.and.arrow.down"
}

// MARK: - Semantic token groups

/// Colors, already resolved for one appearance.
public struct ThemeColors: Sendable, Equatable {
  public struct Background: Sendable, Equatable {
    public let canvas: Color
    public let surface: Color
    public let surfaceHover: Color
    public let inset: Color
    /// Flat fallback only. HIG says a real popover/panel uses a material; this is
    /// what to fall back to when transparency is reduced.
    public let vibrancy: Color
  }

  public struct Foreground: Sendable, Equatable {
    public let primary: Color
    public let secondary: Color
    public let tertiary: Color
    public let onAccent: Color
  }

  public struct Accent: Sendable, Equatable {
    public let base: Color
    public let hover: Color
    public let active: Color
    public let soft: Color
    /// Âmbar — the warm accent (HFP warning, "no dispositivo" badge).
    public let warm: Color
    public let warmSoft: Color
  }

  public struct Border: Sendable, Equatable {
    public let base: Color
    public let strong: Color
  }

  /// The logo lockup — four waveform bars forming a speech quote mark.
  ///
  /// The only place in the design where a component legitimately reaches for
  /// primitives: menubar-popover.dc.html paints the mark with
  /// `linear-gradient(160deg, --fala-violet-500, --fala-violet-700)` and one
  /// amber bar, and tokens.json has no semantic alias for it. Exposed here so
  /// views still never touch `DesignSystem.Palette`. Appearance-independent: the
  /// mark is the same in Light and Dark, exactly as in the mockup.
  public struct Brand: Sendable, Equatable {
    public let markGradientStart: Color
    public let markGradientEnd: Color
    /// The single warm bar in the mark.
    public let markAccentBar: Color
    /// Gradient angle in degrees, CSS convention (0° points up, clockwise).
    public let markGradientAngle: Double
  }

  public struct StatePalette: Sendable, Equatable {
    public let idle: Color
    public let idleSoft: Color
    public let recording: Color
    public let recordingSoft: Color
    public let transcribing: Color
    public let transcribingSoft: Color
    public let success: Color
    public let successSoft: Color
    public let error: Color
    public let errorSoft: Color
    public let warning: Color
    public let warningSoft: Color
  }

  public let bg: Background
  public let text: Foreground
  public let accent: Accent
  public let border: Border
  public let focusRing: Color
  public let state: StatePalette
  public let brand: Brand
}

/// The 8pt grid. There is intentionally no `sm`: the grid steps 4 → 8 → 16, so a
/// 12pt value would be off-grid. `xxs` is the only sub-8 step and exists solely
/// for tight icon/text gaps (design/CLAUDE.md).
public struct ThemeSpace: Sendable, Equatable {
  /// `--space-05` · 4
  public let xxs: CGFloat
  /// `--space-1` · 8
  public let xs: CGFloat
  /// `--space-2` · 16
  public let md: CGFloat
  /// `--space-3` · 24
  public let lg: CGFloat
  /// `--space-4` · 32
  public let xl: CGFloat
  /// `--space-5` · 40
  public let xxl: CGFloat
  /// `--space-6` · 48
  public let xxxl: CGFloat
}

public struct ThemeRadius: Sendable, Equatable {
  public let sm: CGFloat
  public let md: CGFloat
  public let lg: CGFloat
  public let xl: CGFloat
  /// `999` — prefer `Capsule()`; this is here for the rare place that needs a
  /// number instead of a shape.
  public let pill: CGFloat
}

public struct ThemeTypography: Sendable, Equatable {
  public let display: TypeToken
  public let title: TypeToken
  public let headline: TypeToken
  public let body: TypeToken
  public let caption: TypeToken
  public let micro: TypeToken
}

public struct ThemeShadows: Sendable, Equatable {
  public let sm: ShadowToken
  public let md: ShadowToken
  public let lg: ShadowToken
  public let pop: ShadowToken
}

/// Durations, easings and the ready-made animations from DESIGN-HANDOFF.md §6.
///
/// Every `Animation` here is optional and is `nil` when Reduce Motion is on:
/// `withAnimation(nil)` and `.animation(nil, value:)` both mean "apply the change
/// instantly", which is exactly the reduced behavior the handoff specifies (state
/// stays legible through color + icon + text).
public struct ThemeMotion: Sendable, Equatable {
  /// 120ms — hovers, toggles, icon swaps.
  public let fast: DurationToken
  /// 200ms — surfaces, badges, focus ring, progress width, dismiss.
  public let base: DurationToken
  /// 320ms — pill/popover enter, theme cross-fade.
  public let slow: DurationToken
  public let standard: EasingToken
  public let spring: EasingToken
  /// `fala-wave` cycle · 900ms.
  public let waveCycle: DurationToken
  /// `fala-pulse` cycle · 1600ms.
  public let pulseCycle: DurationToken
  /// `fala-spin` cycle · 900ms.
  public let spinCycle: DurationToken
  /// Mirrors `accessibilityReduceMotion` / `prefers-reduced-motion`.
  public let reduceMotion: Bool

  /// The only way to build an animation from these tokens. Returns `nil` under
  /// Reduce Motion so callers cannot forget the check.
  public func animation(_ duration: DurationToken, _ easing: EasingToken) -> Animation? {
    reduceMotion ? nil : easing.animation(duration: duration)
  }

  /// `fala-appear` — 320ms spring. Pill and popover entrance.
  public var appear: Animation? { animation(slow, spring) }
  /// `fala-dismiss` — 200ms standard. Pill exit.
  public var dismiss: Animation? { animation(base, standard) }
  /// Hover, toggle knob, icon swap.
  public var quick: Animation? { animation(fast, standard) }
  /// A looping animation for the waveform bars; `nil` renders them static.
  public var wave: Animation? {
    guard let step = animation(waveCycle, standard) else { return nil }
    return step.repeatForever(autoreverses: true)
  }
  /// The transcribing spinner; `nil` renders a fixed icon.
  public var spin: Animation? {
    reduceMotion ? nil : .linear(duration: spinCycle.seconds).repeatForever(autoreverses: false)
  }
  /// The recording halo.
  public var pulse: Animation? {
    guard let step = animation(pulseCycle, standard) else { return nil }
    return step.repeatForever(autoreverses: true)
  }
}

/// The HUD pill.
///
/// Modeled apart from `ThemeColors` on purpose: DESIGN-HANDOFF.md §1 says the
/// pill is the DARK HUD material in BOTH appearances, like the macOS volume HUD.
/// If it read `theme.color.bg.surface` it would turn white in Light Mode, which
/// is the single most likely way to get this surface wrong. Both values below are
/// dark; only how dark differs.
public struct ThemePill: Sendable, Equatable {
  /// `--color-pill-bg`. Translucent plum in both appearances.
  public let background: Color
  /// `--color-pill-text`. The only foreground color valid on the pill: the
  /// regular text tokens flip with the appearance and would go dark-on-dark.
  public let text: Color
  /// The hotkey keycap chip: `rgba(255,255,255,0.14)` in pill-overlay.dc.html.
  public let keycapBackground: Color
  /// `--shadow-pop`. Decorative (DESIGN-HANDOFF.md §4).
  public let shadow: ShadowToken
  /// `--radius-xl` — the wrapped, multi-line pill.
  public let cornerRadius: CGFloat
  /// The CSS `backdrop-filter: blur(20px)` behind the pill.
  public let backdropBlur: CGFloat
  /// Collapsed "hidden" sliver: 28×5 at 35% opacity (DESIGN-HANDOFF.md §1).
  public let collapsedSize: CGSize
  public let collapsedOpacity: Double
  /// Success auto-dismisses after 1.2s.
  public let successDismissDelay: TimeInterval
  /// Error stays 2.5s. (A warning persists while the HFP route is active, so it
  /// has no delay at all.)
  public let errorDismissDelay: TimeInterval
  /// The collapsed sliver disappears after ~2s of inactivity.
  public let idleHideDelay: TimeInterval
}

// MARK: - Theme

/// What views consume. Build one per appearance; it is a value, so it is cheap to
/// pass around and safe to hold.
public struct Theme: Sendable, Equatable {
  public let appearance: DesignSystem.Appearance
  public let color: ThemeColors
  public let space: ThemeSpace
  public let radius: ThemeRadius
  public let type: ThemeTypography
  public let shadow: ThemeShadows
  public let motion: ThemeMotion
  public let pill: ThemePill

  public init(appearance: DesignSystem.Appearance, reduceMotion: Bool = false) {
    let palette = DesignSystem.palette(for: appearance)
    self.appearance = appearance
    self.color = ThemeColors(
      bg: .init(
        canvas: palette.bg.canvas.color,
        surface: palette.bg.surface.color,
        surfaceHover: palette.bg.surfaceHover.color,
        inset: palette.bg.inset.color,
        vibrancy: palette.bg.vibrancy.color
      ),
      text: .init(
        primary: palette.text.primary.color,
        secondary: palette.text.secondary.color,
        tertiary: palette.text.tertiary.color,
        onAccent: palette.text.onAccent.color
      ),
      accent: .init(
        base: palette.accent.base.color,
        hover: palette.accent.hover.color,
        active: palette.accent.active.color,
        soft: palette.accent.soft.color,
        warm: palette.accent.warm.color,
        warmSoft: palette.accent.warmSoft.color
      ),
      border: .init(base: palette.border.base.color, strong: palette.border.strong.color),
      focusRing: palette.focusRing.color,
      state: .init(
        idle: palette.state.idle.color,
        idleSoft: palette.state.idleSoft.color,
        recording: palette.state.recording.color,
        recordingSoft: palette.state.recordingSoft.color,
        transcribing: palette.state.transcribing.color,
        transcribingSoft: palette.state.transcribingSoft.color,
        success: palette.state.success.color,
        successSoft: palette.state.successSoft.color,
        error: palette.state.error.color,
        errorSoft: palette.state.errorSoft.color,
        warning: palette.state.warning.color,
        warningSoft: palette.state.warningSoft.color
      ),
      brand: .init(
        markGradientStart: DesignSystem.Palette.violet500.color,
        markGradientEnd: DesignSystem.Palette.violet700.color,
        markAccentBar: DesignSystem.Palette.amber300.color,
        markGradientAngle: 160
      )
    )
    self.space = ThemeSpace(
      xxs: DesignSystem.Space.s05,
      xs: DesignSystem.Space.s1,
      md: DesignSystem.Space.s2,
      lg: DesignSystem.Space.s3,
      xl: DesignSystem.Space.s4,
      xxl: DesignSystem.Space.s5,
      xxxl: DesignSystem.Space.s6
    )
    self.radius = ThemeRadius(
      sm: DesignSystem.Radius.sm,
      md: DesignSystem.Radius.md,
      lg: DesignSystem.Radius.lg,
      xl: DesignSystem.Radius.xl,
      pill: DesignSystem.Radius.pill
    )
    self.type = ThemeTypography(
      display: DesignSystem.TypeScale.display,
      title: DesignSystem.TypeScale.title,
      headline: DesignSystem.TypeScale.headline,
      body: DesignSystem.TypeScale.body,
      caption: DesignSystem.TypeScale.caption,
      micro: DesignSystem.TypeScale.micro
    )
    self.shadow = ThemeShadows(
      sm: palette.shadow.sm,
      md: palette.shadow.md,
      lg: palette.shadow.lg,
      pop: palette.shadow.pop
    )
    self.motion = ThemeMotion(
      fast: DesignSystem.Motion.fast,
      base: DesignSystem.Motion.base,
      slow: DesignSystem.Motion.slow,
      standard: DesignSystem.Motion.standard,
      spring: DesignSystem.Motion.spring,
      waveCycle: DesignSystem.Motion.waveCycle,
      pulseCycle: DesignSystem.Motion.pulseCycle,
      spinCycle: DesignSystem.Motion.spinCycle,
      reduceMotion: reduceMotion
    )
    self.pill = ThemePill(
      background: palette.pill.background.color,
      text: palette.pill.text.color,
      keycapBackground: Color(.sRGB, white: 1, opacity: 0.14),
      shadow: palette.shadow.pop,
      cornerRadius: DesignSystem.Radius.xl,
      backdropBlur: 20,
      collapsedSize: CGSize(width: 28, height: 5),
      collapsedOpacity: 0.35,
      successDismissDelay: 1.2,
      errorDismissDelay: 2.5,
      idleHideDelay: 2.0
    )
  }

  public static let light = Theme(appearance: .light)
  public static let dark = Theme(appearance: .dark)

  public init(colorScheme: ColorScheme, reduceMotion: Bool = false) {
    self.init(appearance: colorScheme == .dark ? .dark : .light, reduceMotion: reduceMotion)
  }

  // MARK: State styles

  /// Tint, soft companion and SF Symbol for one of the six states.
  public func style(for kind: StateKind) -> StateStyle {
    switch kind {
    case .idle:
      return StateStyle(
        kind: kind, tint: color.state.idle, soft: color.state.idleSoft,
        symbol: FalaSymbol.idle, alternateSymbol: nil)
    case .recording:
      return StateStyle(
        kind: kind, tint: color.state.recording, soft: color.state.recordingSoft,
        symbol: FalaSymbol.recording, alternateSymbol: nil)
    case .transcribing:
      return StateStyle(
        kind: kind, tint: color.state.transcribing, soft: color.state.transcribingSoft,
        symbol: FalaSymbol.transcribing, alternateSymbol: nil)
    case .success:
      return StateStyle(
        kind: kind, tint: color.state.success, soft: color.state.successSoft,
        symbol: FalaSymbol.success, alternateSymbol: nil)
    case .error:
      return StateStyle(
        kind: kind, tint: color.state.error, soft: color.state.errorSoft,
        symbol: FalaSymbol.error, alternateSymbol: FalaSymbol.secureField)
    case .warning:
      return StateStyle(
        kind: kind, tint: color.state.warning, soft: color.state.warningSoft,
        symbol: FalaSymbol.warning, alternateSymbol: FalaSymbol.headphones)
    }
  }

}

extension DictationState {
  /// Which of the six design states this renders as (DESIGN-HANDOFF.md §2), so a
  /// view writes `theme.style(for: state.kind)`.
  ///
  /// There is deliberately no `theme.style(for: DictationState)` overload: the
  /// two enums share four case names, and overloading on them would make every
  /// `theme.style(for: .success)` at a call site ambiguous.
  ///
  /// `failure` renders as `error`. A view that knows the failure was a secure
  /// field should swap in `StateStyle.alternateSymbol` rather than matching on
  /// the pt-BR message.
  public var kind: StateKind { StateKind(self) }
}

// MARK: - Environment

private struct ThemeEnvironmentKey: EnvironmentKey {
  /// Light is the default only so previews and detached views have something to
  /// render. Real surfaces get the right one from `.falaTheme()`.
  static let defaultValue = Theme.light
}

extension EnvironmentValues {
  /// The only supported way for a view to reach design values.
  public var theme: Theme {
    get { self[ThemeEnvironmentKey.self] }
    set { self[ThemeEnvironmentKey.self] = newValue }
  }
}

/// Rebuilds the theme whenever the appearance or Reduce Motion changes, and puts
/// it in the environment. Apply once per window/scene root.
private struct FalaThemeModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.environment(
      \.theme, Theme(colorScheme: colorScheme, reduceMotion: reduceMotion))
  }
}

extension View {
  /// Installs the Fala theme for this subtree.
  public func falaTheme() -> some View {
    modifier(FalaThemeModifier())
  }

  /// Forces one appearance regardless of the system setting. The pill overlay
  /// needs this: its HUD material is dark in both appearances, but any *content*
  /// tokens it uses must still resolve consistently.
  public func falaTheme(_ appearance: DesignSystem.Appearance, reduceMotion: Bool = false)
    -> some View
  {
    environment(\.theme, Theme(appearance: appearance, reduceMotion: reduceMotion))
  }
}
