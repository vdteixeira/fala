import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import FalaKit

/// Guards the translation of design/tokens/tokens.json into Swift (TASKS.md T2.1).
///
/// These tests are pinned to the values DESIGN-HANDOFF.md §8 publishes as the
/// consistency spot-check. They exist because a token drifting silently is the
/// one design bug that no screenshot review catches: every surface stays
/// internally consistent while the whole app walks away from the mockups.
///
/// Hex literals appear here ON PURPOSE. This is the one file allowed to restate
/// the source of truth — that restatement IS the test. Everywhere else, a hex
/// literal is a bug.
@Suite struct ThemeTests {

  // MARK: - The §8 spot-check

  @Test("violet.600 #5341CD is the light accent, #8A78EC the dark one")
  func brandAccentMatchesHandoff() {
    #expect(DesignSystem.Palette.violet600.hexString == "#5341CD")
    #expect(DesignSystem.light.accent.base.hexString == "#5341CD")
    #expect(DesignSystem.Palette.violet400.hexString == "#8A78EC")
    #expect(DesignSystem.dark.accent.base.hexString == "#8A78EC")
  }

  @Test("rose.500 #F43F6E is the light recording tint — and is NOT the error red")
  func recordingIsRoseAndNotError() {
    #expect(DesignSystem.Palette.rose500.hexString == "#F43F6E")
    #expect(DesignSystem.light.state.recording.hexString == "#F43F6E")
    #expect(DesignSystem.light.state.error.hexString == "#E0404C")
    // DESIGN-HANDOFF.md §2: "Recording ≠ error on purpose". Merging them is the
    // exact mistake this line is here to prevent, in both appearances.
    #expect(DesignSystem.light.state.recording != DesignSystem.light.state.error)
    #expect(DesignSystem.dark.state.recording != DesignSystem.dark.state.error)
  }

  @Test("the logo lockup is exposed semantically, identical in both appearances")
  func brandMarkIsAppearanceIndependent() {
    // menubar-popover.dc.html paints the mark with primitives because tokens.json
    // has no alias for it. Views must still not reach into DesignSystem.Palette,
    // so the values live on the theme — and the mark does not flip with the
    // appearance, exactly as in the mockup.
    #expect(Theme.light.color.brand == Theme.dark.color.brand)
    #expect(Theme.light.color.brand.markGradientStart == DesignSystem.Palette.violet500.color)
    #expect(Theme.light.color.brand.markGradientEnd == DesignSystem.Palette.violet700.color)
    #expect(Theme.light.color.brand.markAccentBar == DesignSystem.Palette.amber300.color)
    #expect(Theme.light.color.brand.markGradientAngle == 160)
  }

  @Test("the warm accent is âmbar #F28C26")
  func warmAccentMatchesHandoff() {
    #expect(DesignSystem.Palette.amber500.hexString == "#F28C26")
    #expect(DesignSystem.light.accent.warm.hexString == "#F28C26")
  }

  @Test("spacing is the 8pt grid: 4/8/16/24/32/40/48")
  func spacingMatchesGrid() {
    let space = Theme.light.space
    #expect(space.xxs == 4)
    #expect(space.xs == 8)
    #expect(space.md == 16)
    #expect(space.lg == 24)
    #expect(space.xl == 32)
    #expect(space.xxl == 40)
    #expect(space.xxxl == 48)
    // Everything above 4 sits on the 8pt grid.
    for step in [space.xs, space.md, space.lg, space.xl, space.xxl, space.xxxl] {
      #expect(step.truncatingRemainder(dividingBy: 8) == 0)
    }
  }

  @Test("radii are 6/10/14/20/999")
  func radiiMatchHandoff() {
    let radius = Theme.light.radius
    #expect(radius.sm == 6)
    #expect(radius.md == 10)
    #expect(radius.lg == 14)
    #expect(radius.xl == 20)
    #expect(radius.pill == 999)
  }

  @Test("motion durations are 120/200/320ms")
  func motionDurationsMatchHandoff() {
    let motion = Theme.light.motion
    #expect(motion.fast.milliseconds == 120)
    #expect(motion.base.milliseconds == 200)
    #expect(motion.slow.milliseconds == 320)
    #expect(motion.base.seconds == 0.2)
  }

  @Test("easings are the two cubic-beziers, spring overshooting past 1")
  func easingsMatchHandoff() {
    let motion = Theme.light.motion
    #expect(motion.standard == EasingToken(0.2, 0, 0, 1))
    #expect(motion.spring == EasingToken(0.34, 1.4, 0.64, 1))
    // The overshoot is the whole point of the spring curve; a clamped y1 would
    // silently turn the pill entrance into an ordinary ease-out.
    #expect(motion.spring.y1 > 1)
  }

  @Test("keyframe cycles match fala-tokens.css: wave/spin 900ms, pulse 1.6s")
  func keyframeCyclesMatchSource() {
    let motion = Theme.light.motion
    #expect(motion.waveCycle.milliseconds == 900)
    #expect(motion.spinCycle.milliseconds == 900)
    #expect(motion.pulseCycle.milliseconds == 1600)
  }

  // MARK: - Light vs dark

  @Test("every semantic color has a light and a dark value, and they differ")
  func semanticColorsDifferBetweenAppearances() {
    // The only two leaves the source deliberately shares: white on the violet
    // fill, and the pill's text — the pill is a dark HUD in both appearances, so
    // its foreground has no reason to flip.
    let intentionallyShared: Set<String> = ["text.onAccent", "pill.text"]

    let light = DesignSystem.light.allColorTokens
    let dark = DesignSystem.dark.allColorTokens
    #expect(light.count == 32)
    #expect(light.count == dark.count)

    for (lightToken, darkToken) in zip(light, dark) {
      #expect(lightToken.name == darkToken.name)
      if intentionallyShared.contains(lightToken.name) {
        #expect(lightToken.value == darkToken.value, "\(lightToken.name) should be shared")
      } else {
        #expect(lightToken.value != darkToken.value, "\(lightToken.name) is identical in both")
      }
    }
  }

  @Test("the two appearances have opposite polarity (light canvas vs dark canvas)")
  func appearancePolarityIsOpposite() {
    let lightCanvas = DesignSystem.light.bg.canvas
    let darkCanvas = DesignSystem.dark.bg.canvas
    #expect(lightCanvas.hexString == "#F7F6FA")
    #expect(darkCanvas.hexString == "#141019")
    #expect(lightCanvas.red > darkCanvas.red)
    #expect(DesignSystem.light.text.primary.hexString == "#1C1826")
    #expect(DesignSystem.dark.text.primary.hexString == "#F4F2FA")
  }

  @Test("shadows are per-appearance: tinted plum in light, pure black in dark")
  func shadowsDifferBetweenAppearances() {
    #expect(DesignSystem.light.shadow.pop.color.hexString == "#221A52")
    #expect(DesignSystem.dark.shadow.pop.color.hexString == "#000000")
    #expect(DesignSystem.light.shadow.pop.color.opacity == 0.18)
    #expect(DesignSystem.dark.shadow.pop.color.opacity == 0.6)
    // CSS blur → SwiftUI shadow radius is half the blur (DesignSystem header).
    #expect(DesignSystem.light.shadow.pop.blur == 40)
    #expect(DesignSystem.light.shadow.pop.radius == 20)
    #expect(DesignSystem.light.shadow.pop.y == 12)
  }

  // MARK: - The pill is always the dark HUD

  @Test("the pill background is dark in BOTH appearances")
  func pillIsDarkInBothAppearances() {
    let light = DesignSystem.light.pill
    let dark = DesignSystem.dark.pill
    #expect(light.background.hexString == "#1C1826")
    #expect(light.background.opacity == 0.88)
    #expect(dark.background.hexString == "#262130")
    #expect(dark.background.opacity == 0.92)

    // DESIGN-HANDOFF.md §1: the HUD never follows the appearance into a light
    // fill. Both values must stay far darker than their own surface token, and
    // the pill text must stay near-white in both.
    for pill in [light, dark] {
      let luminance = pill.background.red + pill.background.green + pill.background.blue
      #expect(luminance / 3 < 0.2, "pill background must stay a dark HUD")
      let textLuminance = pill.text.red + pill.text.green + pill.text.blue
      #expect(textLuminance / 3 > 0.8, "pill text must stay legible on the dark HUD")
    }
    #expect(light.text == dark.text)
  }

  @Test("the pill never borrows the surface background token")
  func pillDoesNotFollowSurfaceToken() {
    // In Light Mode `bg.surface` is pure white. If the pill ever resolved from it
    // the HUD would invert, so assert the two are unrelated by construction.
    #expect(DesignSystem.light.pill.background != DesignSystem.light.bg.surface)
    #expect(DesignSystem.light.pill.background != DesignSystem.light.bg.canvas)
    #expect(Theme.light.pill.background == Theme.light.pill.background)
    #expect(Theme.light.pill.background != Theme.dark.pill.background)
  }

  @Test("pill geometry and dismiss timings come from the handoff, not from views")
  func pillMetricsMatchHandoff() {
    let pill = Theme.light.pill
    #expect(pill.collapsedSize == CGSize(width: 28, height: 5))
    #expect(pill.collapsedOpacity == 0.35)
    #expect(pill.cornerRadius == 20)
    #expect(pill.backdropBlur == 20)
    #expect(pill.successDismissDelay == 1.2)
    #expect(pill.errorDismissDelay == 2.5)
    #expect(pill.idleHideDelay == 2.0)
  }

  // MARK: - The six states

  @Test("all six states resolve to a tint, a soft companion and an SF Symbol")
  func everyStateKindHasAStyleAndSymbol() {
    #expect(StateKind.allCases.count == 6)
    for appearance in DesignSystem.Appearance.allCases {
      let theme = Theme(appearance: appearance)
      for kind in StateKind.allCases {
        let style = theme.style(for: kind)
        #expect(style.kind == kind)
        #expect(!style.symbol.isEmpty)
        // A tint that equals its own soft background would render an invisible
        // badge, so the pair must always be two distinct colors.
        #expect(style.tint != style.soft)
      }
    }
  }

  @Test("the SF Symbols are exactly the DESIGN-HANDOFF.md §5 mapping")
  func stateSymbolsMatchIconMap() {
    let theme = Theme.light
    #expect(theme.style(for: .idle).symbol == "mic.fill")
    #expect(theme.style(for: .recording).symbol == "waveform")
    #expect(theme.style(for: .transcribing).symbol == "arrow.triangle.2.circlepath")
    #expect(theme.style(for: .success).symbol == "checkmark.circle.fill")
    #expect(theme.style(for: .error).symbol == "exclamationmark.triangle.fill")
    #expect(theme.style(for: .warning).symbol == "exclamationmark.circle")
    // The cause-specific glyphs the handoff lists after a slash.
    #expect(theme.style(for: .error).alternateSymbol == "lock.fill")
    #expect(theme.style(for: .warning).alternateSymbol == "airpods")
  }

  @Test("no two states share an SF Symbol")
  func stateSymbolsAreDistinct() {
    let symbols = StateKind.allCases.map { Theme.light.style(for: $0).symbol }
    #expect(Set(symbols).count == symbols.count)
  }

  @Test("every DictationState maps to a state style with a color and a symbol")
  func everyDictationStateHasAStyle() {
    let states: [DictationState] = [
      .idle,
      .recording,
      .transcribing(capturedSeconds: 1.5),
      .success,
      .failure(message: "Campo protegido — injeção bloqueada."),
    ]
    let theme = Theme.dark
    for state in states {
      let style = theme.style(for: state.kind)
      #expect(!style.symbol.isEmpty)
      #expect(style.tint != style.soft)
    }

    #expect(DictationState.idle.kind == .idle)
    #expect(DictationState.recording.kind == .recording)
    #expect(DictationState.transcribing(capturedSeconds: 0.1).kind == .transcribing)
    #expect(DictationState.success.kind == .success)
    // The coordinator has no `warning` case: a degraded audio route decorates
    // whatever state is current, so `failure` is the only thing that can be an
    // error and `warning` is reachable only through `StateKind`.
    #expect(DictationState.failure(message: "x").kind == .error)
  }

  @Test("state styles resolve per appearance, never to one hardcoded tint")
  func stateStylesFollowTheAppearance() {
    for kind in StateKind.allCases {
      #expect(Theme.light.style(for: kind).tint != Theme.dark.style(for: kind).tint)
    }
  }

  // MARK: - Typography

  @Test("the type scale matches the --text-* tokens")
  func typeScaleMatchesTokens() {
    let type = Theme.light.type
    #expect(type.display.size == 26)
    #expect(type.display.lineHeight == 32)
    #expect(type.display.weight == 700)
    #expect(type.title.size == 17)
    #expect(type.title.weight == 700)
    #expect(type.headline.size == 13)
    #expect(type.headline.weight == 600)
    #expect(type.body.size == 13)
    #expect(type.body.weight == 400)
    #expect(type.caption.size == 11)
    #expect(type.caption.weight == 500)
    #expect(type.micro.size == 10)
    #expect(type.micro.weight == 600)
  }

  @Test("CSS numeric weights translate to the matching Font.Weight")
  func fontWeightsTranslate() {
    let type = Theme.light.type
    #expect(type.body.fontWeight == .regular)
    #expect(type.caption.fontWeight == .medium)
    #expect(type.headline.fontWeight == .semibold)
    #expect(type.title.fontWeight == .bold)
  }

  @Test("line-height becomes SwiftUI line spacing, never a negative value")
  func lineSpacingIsDerivedFromLineHeight() {
    #expect(Theme.light.type.body.lineSpacing == 5)  // 18 - 13
    #expect(Theme.light.type.display.lineSpacing == 6)  // 32 - 26
    for token in [Theme.light.type.micro, Theme.light.type.caption] {
      #expect(token.lineSpacing >= 0)
    }
  }

  @Test("the display family is the documented system substitution")
  func displayFamilyFallsBackToSystem() {
    // Plus Jakarta Sans is not bundled; DESIGN.md allows the system face and
    // requires the substitution to be recorded. The CSS stack is kept so the
    // decision stays auditable.
    #expect(Theme.light.type.display.family == .display)
    #expect(DesignSystem.FontFamily.display.cssStack.first == "Plus Jakarta Sans")
    #expect(DesignSystem.FontFamily.display.design == .default)
    #expect(DesignSystem.FontFamily.mono.design == .monospaced)
  }

  // MARK: - Reduce Motion

  @Test("Reduce Motion turns every animation into an instant change")
  func reduceMotionDisablesAnimations() {
    let reduced = Theme(appearance: .light, reduceMotion: true)
    #expect(reduced.motion.appear == nil)
    #expect(reduced.motion.dismiss == nil)
    #expect(reduced.motion.quick == nil)
    #expect(reduced.motion.wave == nil)
    #expect(reduced.motion.spin == nil)
    #expect(reduced.motion.pulse == nil)
    #expect(reduced.motion.animation(reduced.motion.slow, reduced.motion.spring) == nil)
    // The durations themselves stay readable: only the animations vanish, so a
    // view can still use them for non-motion timing (auto-dismiss delays).
    #expect(reduced.motion.slow.milliseconds == 320)
  }

  @Test("without Reduce Motion the animations exist")
  func animationsExistByDefault() {
    let theme = Theme.light
    #expect(theme.motion.appear != nil)
    #expect(theme.motion.dismiss != nil)
    #expect(theme.motion.wave != nil)
    #expect(theme.motion.spin != nil)
    #expect(theme.motion.pulse != nil)
  }

  // MARK: - Conversions

  @Test("hex round-trips through the sRGB components unchanged")
  func hexRoundTripsThroughComponents() {
    let violet = TokenColor(hex: 0x5341CD)
    #expect(violet.red == Double(0x53) / 255)
    #expect(violet.green == Double(0x41) / 255)
    #expect(violet.blue == Double(0xCD) / 255)
    #expect(violet.opacity == 1)
    #expect(violet.hexString == "#5341CD")
    #expect(TokenColor(hex: 0x000000).hexString == "#000000")
    #expect(TokenColor(hex: 0xFFFFFF).hexString == "#FFFFFF")
  }

  @Test("translucent tokens keep their rgba() alpha")
  func translucentTokensKeepAlpha() {
    #expect(DesignSystem.light.focusRing.opacity == 0.4)
    #expect(DesignSystem.dark.focusRing.opacity == 0.45)
    #expect(DesignSystem.light.bg.vibrancy.opacity == 0.78)
    #expect(DesignSystem.dark.bg.vibrancy.opacity == 0.72)
    #expect(DesignSystem.dark.state.warningSoft.opacity == 0.14)
  }

  // MARK: - Environment plumbing

  @Test("the environment default is a real theme, and appearance is carried")
  func environmentExposesATheme() {
    var values = EnvironmentValues()
    #expect(values.theme.appearance == .light)
    values.theme = Theme.dark
    #expect(values.theme.appearance == .dark)
    #expect(values.theme.color.accent.base == Theme.dark.color.accent.base)
    #expect(Theme(colorScheme: .dark).appearance == .dark)
    #expect(Theme(colorScheme: .light).appearance == .light)
  }
}
