// GENERATED FROM design/tokens/tokens.json — 156 DTCG tokens, verified against
// design/mockups/fala-tokens.css (same names, same values).
//
// This is the PRIMITIVE layer. Views must never touch it: they consume `Theme`
// (Theme.swift) through `@Environment(\.theme)`. Editing this file by hand means
// editing the design tokens first — tokens.json is the source of truth.
//
// Token mapping (see the `$description` at the top of tokens.json):
//   --fala-<family>-<step>            = color.<family>.<step>       → Palette
//   --space-N / --radius-N            = space.N / radius.N          → Space / Radius
//   --text-<level>-{size,line,weight} = type.<level>.*              → TypeScale
//   --motion-X / --ease-X             = motion.duration|easing.X    → Motion
//   --color-<group>-<name>            = semantic.<mode>.color.*     → Semantic.light/.dark
//   --shadow-N                        = semantic.<mode>.shadow.N    → Semantic.*.shadow
//
// Unit conversions applied here (DESIGN.md "Unit conversions & pitfalls"):
//   - CSS px are taken as points 1:1 (the mockups are authored at @1x density).
//   - CSS `box-shadow` blur is a diameter-like value; SwiftUI's shadow `radius`
//     is roughly half of it, so `ShadowToken.radius` = blur / 2 while `blur`
//     keeps the source value for reference.
//   - Plus Jakarta Sans (fontFamily.display) is NOT bundled and is not licensed
//     here, so the display family falls back to the system face per DESIGN.md.

import CoreGraphics
import SwiftUI

// MARK: - Token value types

/// A color token, stored as sRGB components so it can be compared, round-tripped
/// to hex in tests, and rendered without going through a string at runtime.
public struct TokenColor: Sendable, Equatable {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let opacity: Double

  /// - Parameter hex: `0xRRGGBB`. Alpha is passed separately because the CSS
  ///   source expresses translucency as `rgba(...)`, never as `#RRGGBBAA`.
  public init(hex: UInt32, opacity: Double = 1) {
    self.red = Double((hex >> 16) & 0xFF) / 255
    self.green = Double((hex >> 8) & 0xFF) / 255
    self.blue = Double(hex & 0xFF) / 255
    self.opacity = opacity
  }

  /// The SwiftUI value. Always sRGB: the mockups are authored in sRGB hex, and
  /// letting SwiftUI reinterpret them in Display P3 would shift the brand violet.
  public var color: Color {
    Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
  }

  /// Uppercase `#RRGGBB`, recomputed from the stored components. Tests use it to
  /// prove the hex in tokens.json survived the conversion unchanged.
  public var hexString: String {
    let r = Int((red * 255).rounded())
    let g = Int((green * 255).rounded())
    let b = Int((blue * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
  }
}

/// A duration token. Kept as integer milliseconds (the unit tokens.json uses) so
/// a test can compare against the source without float noise.
public struct DurationToken: Sendable, Equatable {
  public let milliseconds: Int

  public init(milliseconds: Int) {
    self.milliseconds = milliseconds
  }

  public var seconds: TimeInterval { Double(milliseconds) / 1000 }
}

/// A CSS `cubic-bezier` easing. Control points may leave 0...1 — `spring`
/// deliberately overshoots (y = 1.4), which is what gives the pill its character.
public struct EasingToken: Sendable, Equatable {
  public let x1: Double
  public let y1: Double
  public let x2: Double
  public let y2: Double

  public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
    self.x1 = x1
    self.y1 = y1
    self.x2 = x2
    self.y2 = y2
  }

  public func animation(duration: DurationToken) -> Animation {
    .timingCurve(x1, y1, x2, y2, duration: duration.seconds)
  }
}

/// One typographic level. `weight` keeps the CSS numeric value (the source of
/// truth); `fontWeight` is the SwiftUI translation.
public struct TypeToken: Sendable, Equatable {
  public let size: CGFloat
  public let lineHeight: CGFloat
  public let weight: Int
  public let family: DesignSystem.FontFamily

  public init(size: CGFloat, lineHeight: CGFloat, weight: Int, family: DesignSystem.FontFamily) {
    self.size = size
    self.lineHeight = lineHeight
    self.weight = weight
    self.family = family
  }

  public var fontWeight: Font.Weight {
    switch weight {
    case ..<400: return .light
    case 400..<500: return .regular
    case 500..<600: return .medium
    case 600..<700: return .semibold
    default: return .bold
    }
  }

  public var font: Font {
    .system(size: size, weight: fontWeight, design: family.design)
  }

  /// SwiftUI adds `lineSpacing` BETWEEN lines, so the CSS line-height has to be
  /// expressed as the leftover space above the glyph box.
  public var lineSpacing: CGFloat { max(0, lineHeight - size) }
}

/// A single-layer CSS `box-shadow`.
public struct ShadowToken: Sendable, Equatable {
  public let color: TokenColor
  public let x: CGFloat
  public let y: CGFloat
  /// The CSS blur value, kept verbatim for traceability.
  public let blur: CGFloat

  public init(color: TokenColor, x: CGFloat, y: CGFloat, blur: CGFloat) {
    self.color = color
    self.x = x
    self.y = y
    self.blur = blur
  }

  /// What `.shadow(color:radius:x:y:)` wants — see the header note on blur.
  public var radius: CGFloat { blur / 2 }
}

// MARK: - DesignSystem

/// The generated token set. Namespaced, never instantiated.
public enum DesignSystem {

  /// Which of the two `data-theme` blocks in fala-tokens.css to resolve.
  public enum Appearance: String, Sendable, CaseIterable {
    case light
    case dark
  }

  // MARK: Primitives · palette (46 tokens)

  /// Raw brand ramps. Components must never reference these — see design/CLAUDE.md.
  public enum Palette {
    // Violeta — brand, trust/vault.
    public static let violet50 = TokenColor(hex: 0xF2F0FD)
    public static let violet100 = TokenColor(hex: 0xE5E0FB)
    public static let violet200 = TokenColor(hex: 0xCDC4F6)
    public static let violet300 = TokenColor(hex: 0xAB9DF0)
    public static let violet400 = TokenColor(hex: 0x8A78EC)
    public static let violet500 = TokenColor(hex: 0x6C5CE7)
    public static let violet600 = TokenColor(hex: 0x5341CD)
    public static let violet700 = TokenColor(hex: 0x4233A6)
    public static let violet800 = TokenColor(hex: 0x322579)
    public static let violet900 = TokenColor(hex: 0x221A52)

    // Âmbar — warm accent.
    public static let amber50 = TokenColor(hex: 0xFFF6EA)
    public static let amber100 = TokenColor(hex: 0xFFEAD0)
    public static let amber200 = TokenColor(hex: 0xFFD9A8)
    public static let amber300 = TokenColor(hex: 0xFFC077)
    public static let amber400 = TokenColor(hex: 0xFCA64E)
    public static let amber500 = TokenColor(hex: 0xF28C26)
    public static let amber600 = TokenColor(hex: 0xD0731A)
    public static let amber700 = TokenColor(hex: 0xA55A12)

    // Neutros — plum-tinted greys.
    public static let neutral0 = TokenColor(hex: 0xFFFFFF)
    public static let neutral50 = TokenColor(hex: 0xF7F6FA)
    public static let neutral100 = TokenColor(hex: 0xEFEDF4)
    public static let neutral200 = TokenColor(hex: 0xE3E0EA)
    public static let neutral300 = TokenColor(hex: 0xCBC7D6)
    public static let neutral400 = TokenColor(hex: 0xA5A0B1)
    public static let neutral500 = TokenColor(hex: 0x7D7889)
    public static let neutral600 = TokenColor(hex: 0x5E5969)
    public static let neutral700 = TokenColor(hex: 0x46414F)
    public static let neutral800 = TokenColor(hex: 0x302B3A)
    public static let neutral850 = TokenColor(hex: 0x262130)
    public static let neutral900 = TokenColor(hex: 0x1C1826)
    public static let neutral950 = TokenColor(hex: 0x141019)

    // Verde — success.
    public static let green100 = TokenColor(hex: 0xD9F4E5)
    public static let green300 = TokenColor(hex: 0x6FD8A3)
    public static let green400 = TokenColor(hex: 0x43C583)
    public static let green500 = TokenColor(hex: 0x27B06B)
    public static let green600 = TokenColor(hex: 0x1E9159)

    // Rosa — recording (live), deliberately NOT the error red.
    public static let rose100 = TokenColor(hex: 0xFFE0EA)
    public static let rose300 = TokenColor(hex: 0xFF9AB8)
    public static let rose400 = TokenColor(hex: 0xFF6B93)
    public static let rose500 = TokenColor(hex: 0xF43F6E)
    public static let rose600 = TokenColor(hex: 0xD02A58)

    // Vermelho — error (firm).
    public static let red100 = TokenColor(hex: 0xFFDFDF)
    public static let red300 = TokenColor(hex: 0xFF8F8F)
    public static let red400 = TokenColor(hex: 0xFF6B78)
    public static let red500 = TokenColor(hex: 0xE0404C)
    public static let red600 = TokenColor(hex: 0xC22C3C)
  }

  // MARK: Primitives · spacing (7 tokens)

  /// The 8pt grid. `s05` (4pt) exists only for tight icon/text gaps.
  public enum Space {
    public static let s05: CGFloat = 4
    public static let s1: CGFloat = 8
    public static let s2: CGFloat = 16
    public static let s3: CGFloat = 24
    public static let s4: CGFloat = 32
    public static let s5: CGFloat = 40
    public static let s6: CGFloat = 48
  }

  // MARK: Primitives · radii (5 tokens)

  public enum Radius {
    public static let sm: CGFloat = 6
    public static let md: CGFloat = 10
    public static let lg: CGFloat = 14
    public static let xl: CGFloat = 20
    /// `999px` in CSS: "fully rounded". Kept as the source value; views should
    /// prefer `Capsule()` over feeding this to a corner radius.
    public static let pill: CGFloat = 999
  }

  // MARK: Primitives · typography (3 families + 18 tokens)

  /// The three CSS font stacks, resolved to what macOS actually has.
  public enum FontFamily: String, Sendable, CaseIterable {
    /// `-apple-system` → SF Pro Text. The default for every UI string.
    case ui
    /// Plus Jakarta Sans in the mockups. Not bundled and not licensed for
    /// redistribution here, so it resolves to the system face; recorded as an
    /// intentional substitution (DESIGN.md → docs/architecture.md).
    case display
    /// `ui-monospace` → SF Mono. Shortcuts, keycaps, code.
    case mono

    public var design: Font.Design {
      switch self {
      case .ui, .display: return .default
      case .mono: return .monospaced
      }
    }

    /// The CSS stack, first entry first — kept so the substitution above stays
    /// auditable against the mockups.
    public var cssStack: [String] {
      switch self {
      case .ui:
        return ["-apple-system", "BlinkMacSystemFont", "SF Pro Text", "system-ui", "sans-serif"]
      case .display:
        return [
          "Plus Jakarta Sans", "-apple-system", "BlinkMacSystemFont", "system-ui", "sans-serif",
        ]
      case .mono:
        return ["ui-monospace", "SF Mono", "Menlo", "monospace"]
      }
    }
  }

  public enum TypeScale {
    public static let display = TypeToken(size: 26, lineHeight: 32, weight: 700, family: .display)
    public static let title = TypeToken(size: 17, lineHeight: 22, weight: 700, family: .ui)
    public static let headline = TypeToken(size: 13, lineHeight: 18, weight: 600, family: .ui)
    public static let body = TypeToken(size: 13, lineHeight: 18, weight: 400, family: .ui)
    public static let caption = TypeToken(size: 11, lineHeight: 14, weight: 500, family: .ui)
    public static let micro = TypeToken(size: 10, lineHeight: 12, weight: 600, family: .ui)
  }

  // MARK: Primitives · motion (5 tokens + keyframe durations)

  public enum Motion {
    /// Hovers, toggles, icon swaps.
    public static let fast = DurationToken(milliseconds: 120)
    /// Surfaces, badges, focus ring, progress width, dismiss.
    public static let base = DurationToken(milliseconds: 200)
    /// Pill/popover enter, theme cross-fade.
    public static let slow = DurationToken(milliseconds: 320)

    public static let standard = EasingToken(0.2, 0, 0, 1)
    public static let spring = EasingToken(0.34, 1.4, 0.64, 1)

    // Loop durations from the @keyframes in fala-tokens.css. Not DTCG tokens —
    // the CSS keyframes are their only source, and DESIGN-HANDOFF.md §6 repeats
    // them. Needed so the waveform/spinner never hardcode a duration.
    /// `fala-wave` — waveform bars.
    public static let waveCycle = DurationToken(milliseconds: 900)
    /// `fala-pulse` — recording halo.
    public static let pulseCycle = DurationToken(milliseconds: 1600)
    /// `fala-spin` — transcribing spinner (linear).
    public static let spinCycle = DurationToken(milliseconds: 900)
  }

  // MARK: Semantic aliases (72 tokens: 36 per appearance)

  /// One resolved `data-theme` block. Every leaf here has both a light and a dark
  /// value in the source; nothing is shared between appearances by accident.
  public struct SemanticPalette: Sendable, Equatable {
    public struct BackgroundColors: Sendable, Equatable {
      public let canvas: TokenColor
      public let surface: TokenColor
      public let surfaceHover: TokenColor
      public let inset: TokenColor
      /// The flat stand-in for `NSVisualEffectView`. HIG wins on behavior: real
      /// surfaces use a material and keep this only as the fallback fill.
      public let vibrancy: TokenColor
    }

    public struct TextColors: Sendable, Equatable {
      public let primary: TokenColor
      public let secondary: TokenColor
      public let tertiary: TokenColor
      /// `#FFFFFF` in both appearances — intentional, it sits on the violet fill.
      public let onAccent: TokenColor
    }

    public struct AccentColors: Sendable, Equatable {
      /// `--color-accent`.
      public let base: TokenColor
      public let hover: TokenColor
      public let active: TokenColor
      public let soft: TokenColor
      public let warm: TokenColor
      public let warmSoft: TokenColor
    }

    public struct BorderColors: Sendable, Equatable {
      /// `--color-border`.
      public let base: TokenColor
      public let strong: TokenColor
    }

    /// The six-state vocabulary, each with its `-soft` background companion.
    public struct StateColors: Sendable, Equatable {
      public let idle: TokenColor
      public let idleSoft: TokenColor
      public let recording: TokenColor
      public let recordingSoft: TokenColor
      public let transcribing: TokenColor
      public let transcribingSoft: TokenColor
      public let success: TokenColor
      public let successSoft: TokenColor
      public let error: TokenColor
      public let errorSoft: TokenColor
      public let warning: TokenColor
      public let warningSoft: TokenColor
    }

    /// The HUD. Dark in BOTH appearances by design (DESIGN-HANDOFF.md §1) — the
    /// two values differ only in how dark, never in polarity.
    public struct PillColors: Sendable, Equatable {
      public let background: TokenColor
      public let text: TokenColor
    }

    public struct Shadows: Sendable, Equatable {
      public let sm: ShadowToken
      public let md: ShadowToken
      public let lg: ShadowToken
      /// Decorative (DESIGN-HANDOFF.md §4): the pill's drop shadow.
      public let pop: ShadowToken
    }

    public let bg: BackgroundColors
    public let text: TextColors
    public let accent: AccentColors
    public let border: BorderColors
    public let focusRing: TokenColor
    public let state: StateColors
    public let pill: PillColors
    public let shadow: Shadows

    /// Every semantic COLOR leaf, keyed by its dotted token path. Exists so the
    /// tests can compare the two appearances leaf by leaf without reflection.
    public var allColorTokens: [(name: String, value: TokenColor)] {
      [
        ("bg.canvas", bg.canvas),
        ("bg.surface", bg.surface),
        ("bg.surfaceHover", bg.surfaceHover),
        ("bg.inset", bg.inset),
        ("bg.vibrancy", bg.vibrancy),
        ("text.primary", text.primary),
        ("text.secondary", text.secondary),
        ("text.tertiary", text.tertiary),
        ("text.onAccent", text.onAccent),
        ("accent.base", accent.base),
        ("accent.hover", accent.hover),
        ("accent.active", accent.active),
        ("accent.soft", accent.soft),
        ("accent.warm", accent.warm),
        ("accent.warmSoft", accent.warmSoft),
        ("border.base", border.base),
        ("border.strong", border.strong),
        ("focusRing", focusRing),
        ("state.idle", state.idle),
        ("state.idleSoft", state.idleSoft),
        ("state.recording", state.recording),
        ("state.recordingSoft", state.recordingSoft),
        ("state.transcribing", state.transcribing),
        ("state.transcribingSoft", state.transcribingSoft),
        ("state.success", state.success),
        ("state.successSoft", state.successSoft),
        ("state.error", state.error),
        ("state.errorSoft", state.errorSoft),
        ("state.warning", state.warning),
        ("state.warningSoft", state.warningSoft),
        ("pill.background", pill.background),
        ("pill.text", pill.text),
      ]
    }
  }

  /// `[data-theme="light"]`.
  public static let light = SemanticPalette(
    bg: .init(
      canvas: Palette.neutral50,
      surface: Palette.neutral0,
      surfaceHover: Palette.neutral100,
      inset: Palette.neutral100,
      vibrancy: TokenColor(hex: 0xF7F6FA, opacity: 0.78)
    ),
    text: .init(
      primary: Palette.neutral900,
      secondary: Palette.neutral600,
      tertiary: Palette.neutral400,
      onAccent: TokenColor(hex: 0xFFFFFF)
    ),
    accent: .init(
      base: Palette.violet600,
      hover: Palette.violet700,
      active: Palette.violet800,
      soft: Palette.violet100,
      warm: Palette.amber500,
      warmSoft: Palette.amber100
    ),
    border: .init(base: Palette.neutral200, strong: Palette.neutral300),
    focusRing: TokenColor(hex: 0x5341CD, opacity: 0.4),
    state: .init(
      idle: Palette.neutral500,
      idleSoft: Palette.neutral100,
      recording: Palette.rose500,
      recordingSoft: Palette.rose100,
      transcribing: Palette.violet500,
      transcribingSoft: Palette.violet100,
      success: Palette.green600,
      successSoft: Palette.green100,
      error: Palette.red500,
      errorSoft: Palette.red100,
      warning: Palette.amber600,
      warningSoft: Palette.amber100
    ),
    pill: .init(
      background: TokenColor(hex: 0x1C1826, opacity: 0.88),
      text: TokenColor(hex: 0xF4F2FA)
    ),
    shadow: .init(
      sm: ShadowToken(color: TokenColor(hex: 0x1C1826, opacity: 0.06), x: 0, y: 1, blur: 2),
      md: ShadowToken(color: TokenColor(hex: 0x1C1826, opacity: 0.08), x: 0, y: 2, blur: 8),
      lg: ShadowToken(color: TokenColor(hex: 0x1C1826, opacity: 0.12), x: 0, y: 8, blur: 24),
      pop: ShadowToken(color: TokenColor(hex: 0x221A52, opacity: 0.18), x: 0, y: 12, blur: 40)
    )
  )

  /// `[data-theme="dark"]`.
  public static let dark = SemanticPalette(
    bg: .init(
      canvas: Palette.neutral950,
      surface: Palette.neutral900,
      surfaceHover: Palette.neutral850,
      inset: Palette.neutral950,
      vibrancy: TokenColor(hex: 0x1C1826, opacity: 0.72)
    ),
    text: .init(
      primary: TokenColor(hex: 0xF4F2FA),
      secondary: Palette.neutral400,
      tertiary: Palette.neutral500,
      onAccent: TokenColor(hex: 0xFFFFFF)
    ),
    accent: .init(
      base: Palette.violet400,
      hover: Palette.violet300,
      active: Palette.violet200,
      soft: TokenColor(hex: 0x8A78EC, opacity: 0.18),
      warm: Palette.amber400,
      warmSoft: TokenColor(hex: 0xFCA64E, opacity: 0.16)
    ),
    border: .init(base: Palette.neutral800, strong: Palette.neutral700),
    focusRing: TokenColor(hex: 0x8A78EC, opacity: 0.45),
    state: .init(
      idle: Palette.neutral400,
      idleSoft: Palette.neutral850,
      recording: Palette.rose400,
      recordingSoft: TokenColor(hex: 0xFF6B93, opacity: 0.16),
      transcribing: Palette.violet300,
      transcribingSoft: TokenColor(hex: 0xAB9DF0, opacity: 0.16),
      success: Palette.green400,
      successSoft: TokenColor(hex: 0x43C583, opacity: 0.16),
      error: Palette.red400,
      errorSoft: TokenColor(hex: 0xFF6B78, opacity: 0.16),
      warning: Palette.amber300,
      warningSoft: TokenColor(hex: 0xFFC077, opacity: 0.14)
    ),
    pill: .init(
      background: TokenColor(hex: 0x262130, opacity: 0.92),
      text: TokenColor(hex: 0xF4F2FA)
    ),
    shadow: .init(
      sm: ShadowToken(color: TokenColor(hex: 0x000000, opacity: 0.3), x: 0, y: 1, blur: 2),
      md: ShadowToken(color: TokenColor(hex: 0x000000, opacity: 0.4), x: 0, y: 2, blur: 8),
      lg: ShadowToken(color: TokenColor(hex: 0x000000, opacity: 0.5), x: 0, y: 8, blur: 24),
      pop: ShadowToken(color: TokenColor(hex: 0x000000, opacity: 0.6), x: 0, y: 12, blur: 40)
    )
  )

  public static func palette(for appearance: Appearance) -> SemanticPalette {
    switch appearance {
    case .light: return light
    case .dark: return dark
    }
  }
}
