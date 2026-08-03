import FalaKit
import SwiftUI

// The Ajustes window (SPEC.md FR-20/FR-21, TASKS.md T2.11), translated from
// design/mockups/settings-window.dc.html per DESIGN-HANDOFF.md §1.
//
// Visual per mockup: 520pt column, toolbar-style tabs (icon over label) on a
// vibrant strip, inset rows with a leading icon, 200 ms crossfade between tabs.
//
// Behaviour per HIG, where it overrides the mockup (DESIGN.md conflict rule —
// these are also recorded in the report the lead files against
// docs/architecture.md):
//
//  1. **A real NSWindow, not a SwiftUI `Settings` scene.** DESIGN.md's mapping
//     table says "Settings scene / TabView", but this app has no SwiftUI `App`
//     lifecycle at all: `MenuBarApp.swift` runs `NSApplication` with a delegate,
//     and `Settings` only exists inside a `Scene`. So the window is AppKit and
//     the content is SwiftUI, exactly like the pill overlay and the popover.
//
//  2. **The tab strip is custom, and that is the deviation that had to be
//     argued.** `NSTabViewController(tabStyle: .toolbar)` is the native
//     "toolbar-style tabs" and would have been free. It draws the selected tab
//     as AppKit's grey pill; the mockup draws it as the violet
//     `--color-accent-soft` chip with an accent-tinted icon and label, and that
//     violet IS the brand. So the chips are SwiftUI `Button`s styled per the
//     mockup, and everything the native control would have given for free is put
//     back by hand: ⌘1…⌘5, ⌃⇥ / ⌃⇧⇥, the `.isSelected` accessibility trait, and
//     a real focus ring (`.buttonStyle(.plain)` keeps the button semantics).
//
//  3. **Native controls wherever the mockup draws one.** The 36×22 drawn switch
//     is a `Toggle(.switch)`; the `<select>` is a `Picker`; the drawn buttons are
//     `Button`s with token tints. DESIGN.md: do not reinvent controls.
//
//  4. **Reduce Motion**: every animation here comes from `theme.motion`, which
//     returns nil under Reduce Motion — the mockup's own footer says states then
//     change instantly. **Reduce Transparency**: the vibrant tab strip falls back
//     to an OPAQUE token, because a translucent "fallback" would ignore the
//     setting.
//
// No view below names a colour, a size, or a duration: they come from `theme`,
// `SettingsLayout`, or the pane models in FalaKit.

/// What the window needs from the app. A `nil` handler renders its control
/// DISABLED rather than hiding it — the same contract `MenuBarActions` uses.
struct SettingsActions {
  /// Called with the merged dictionary after the user edits Ajustes ›
  /// Dicionário, so a running pipeline can adopt it without a relaunch.
  var dictionaryChanged: ((JargonDictionary) -> Void)?
  /// Called with `true` while the hotkey recorder is listening. MUST be wired:
  /// without it the currently-assigned hotkey is still live and starts a real
  /// dictation while the user is pressing keys at the recorder.
  var hotkeyRecordingChanged: ((Bool) -> Void)?
  /// Called only when the committed hotkey actually changed.
  var hotkeyChanged: ((Hotkey) -> Void)?
  /// Called when "Mostrar overlay durante o ditado" is switched.
  var showOverlayChanged: ((Bool) -> Void)?
  /// Called when the user picks a different transcription engine in Ajustes ›
  /// Modelo. Leaving it nil is a SUPPORTED state, not an oversight — the pane's
  /// caption then tells the user the change lands on the next launch instead of
  /// claiming the running app adopted it. Wiring it is a promise that the
  /// pipeline really does rebuild around the new engine.
  var engineChanged: ((TranscriptionEngineChoice) -> Void)?
  /// Opens a URL in System Settings (the login-item deep link).
  var openURL: ((URL) -> Void)?
  /// Closes the window. Filled in by `SettingsWindowController`; it exists
  /// because this app's minimal main menu has no Close item, so ⌘W would
  /// otherwise do nothing in a window the HIG says it must close.
  var closeWindow: (() -> Void)?
}

struct SettingsView: View {
  @Environment(\.theme) private var theme

  let window: SettingsWindowModel
  let general: GeneralPanePresenter
  let audio: AudioPanePresenter
  let dictionary: DictionaryPanePresenter
  let model: ModelPanePresenter
  var actions = SettingsActions()

  var body: some View {
    VStack(spacing: 0) {
      SettingsTabBarView(window: window)
      content
    }
    .frame(width: SettingsLayout.windowWidth)
    .background(theme.color.bg.surface)
    .background(closeShortcut)
  }

  /// ⌘W. This app's main menu has no Close item, so without this the standard
  /// close shortcut does nothing in a window the HIG says it must close. A
  /// zero-opacity `Button` is the SwiftUI way to register a shortcut with no
  /// visible control; it is hidden from VoiceOver, which reaches the real close
  /// button in the title bar.
  private var closeShortcut: some View {
    Button("") { actions.closeWindow?() }
      .keyboardShortcut("w", modifiers: .command)
      .disabled(actions.closeWindow == nil)
      .opacity(0)
      .accessibilityHidden(true)
  }

  /// The mockup's content column: `padding: var(--space-2)`, `gap:
  /// var(--space-2)`, `min-height: 240px`.
  ///
  /// The crossfade is a `.transition(.opacity)` on an `.id`-keyed subtree, so
  /// the outgoing and incoming tabs overlap for exactly one 200 ms standard
  /// curve — and for no time at all under Reduce Motion, where
  /// `theme.motion.animation` is nil.
  private var content: some View {
    ZStack(alignment: .top) {
      tab(window.selected)
        .id(window.selected)
        .transition(.opacity)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(minHeight: SettingsLayout.contentMinHeight, alignment: .top)
    .padding(theme.space.md)
    .animation(
      theme.motion.animation(theme.motion.base, theme.motion.standard),
      value: window.selected)
  }

  @ViewBuilder
  private func tab(_ tab: SettingsTab) -> some View {
    switch tab {
    case .general:
      SettingsGeneralTab(presenter: general, actions: actions)
    case .audio:
      SettingsAudioTab(presenter: audio, window: window)
    case .dictionary:
      SettingsDictionaryTab(presenter: dictionary)
    case .model:
      SettingsModelTab(presenter: model)
    case .privacy:
      SettingsPrivacyTab()
    }
  }
}

// MARK: - Tab strip

private struct SettingsTabBarView: View {
  @Environment(\.theme) private var theme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  let window: SettingsWindowModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: theme.space.xxs) {
        ForEach(window.tabs.items) { item in
          SettingsTabChip(item: item) { window.select(item.tab) }
        }
      }
      .padding(.horizontal, theme.space.xs)
      .padding(.vertical, theme.space.xxs)
      .frame(maxWidth: .infinity)
      Rectangle()
        .fill(theme.color.border.base)
        .frame(height: SettingsLayout.hairline)
    }
    .background(stripBackground)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(SettingsStrings.tabBarLabel)
    // ⌃⇥ / ⌃⇧⇥, the standard macOS tab walk. Hidden buttons rather than a
    // key-event monitor, so they are disabled with the rest of the window.
    .background {
      Group {
        Button("") { window.advance(by: 1) }
          .keyboardShortcut(.tab, modifiers: .control)
        Button("") { window.advance(by: -1) }
          .keyboardShortcut(.tab, modifiers: [.control, .shift])
      }
      .opacity(0)
      .accessibilityHidden(true)
    }
  }

  /// HIG over mockup: the mockup paints a flat `--color-bg-vibrancy`; a native
  /// toolbar area is a material. When the user has asked for LESS transparency
  /// an opaque token takes over — `bg.vibrancy` carries the material's own
  /// alpha, so it is the one token that cannot serve as the fallback.
  @ViewBuilder private var stripBackground: some View {
    if reduceTransparency {
      theme.reduceTransparencyFill
    } else {
      Rectangle().fill(.bar)
    }
  }
}

private struct SettingsTabChip: View {
  @Environment(\.theme) private var theme

  let item: SettingsTabBar.Item
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      VStack(spacing: SettingsLayout.tabChipSpacing) {
        Image(systemName: item.symbol)
          .font(.system(size: SettingsLayout.tabIconSize))
        Text(item.title)
          .font(theme.type.micro.font)
      }
      .foregroundStyle(item.isSelected ? theme.color.accent.base : theme.color.text.secondary)
      .padding(.vertical, theme.space.xxs)
      .padding(.horizontal, SettingsLayout.tabChipHorizontalPadding)
      .background(chipFill, in: shape)
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .keyboardShortcut(shortcut)
    .accessibilityLabel(item.accessibilityLabel)
    .accessibilityAddTraits(item.isSelected ? [.isSelected] : [])
    .animation(theme.motion.quick, value: item.isSelected)
  }

  private var chipFill: Color {
    item.isSelected ? theme.color.accent.soft : .clear
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: theme.radius.sm, style: .continuous)
  }

  private var shortcut: KeyboardShortcut? {
    guard let key = item.shortcutKey else { return nil }
    return KeyboardShortcut(KeyEquivalent(key), modifiers: .command)
  }
}

// MARK: - Shared chrome

/// The mockup's inset row: `background: var(--color-bg-inset); border-radius:
/// var(--radius-md); padding: var(--space-1) var(--space-2); gap:
/// var(--space-1)`. Written once so five tabs cannot drift apart.
struct SettingsRow<Content: View>: View {
  @Environment(\.theme) private var theme

  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: theme.space.xs) {
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, theme.space.xs)
    .padding(.horizontal, theme.space.md)
    .background(
      theme.color.bg.inset,
      in: RoundedRectangle(cornerRadius: theme.radius.md, style: .continuous))
  }
}

/// A row's leading glyph, at the mockup's 18px.
struct SettingsRowIcon: View {
  @Environment(\.theme) private var theme

  let symbol: String
  var tint: Color?
  var size: CGFloat = SettingsLayout.tabIconSize

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size))
      .foregroundStyle(tint ?? theme.color.text.secondary)
      .accessibilityHidden(true)
  }
}

/// Title over optional subtitle — the mockup's `600`-weight body line with a
/// caption under it.
struct SettingsRowLabel: View {
  @Environment(\.theme) private var theme

  let title: String
  var subtitle: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(SettingsType.rowTitle.font)
        .foregroundStyle(theme.color.text.primary)
        .fixedSize(horizontal: false, vertical: true)
      if let subtitle {
        Text(subtitle)
          .font(theme.type.caption.font)
          .foregroundStyle(theme.color.text.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The caption under a row: a hint in the tertiary token, a problem in the
/// warning tint. One place, so "why is this red" is always the same question.
struct SettingsCaption: View {
  @Environment(\.theme) private var theme

  let text: String
  var isProblem: Bool = false

  var body: some View {
    Text(text)
      .font(theme.type.caption.font)
      .lineSpacing(theme.type.caption.lineSpacing)
      .foregroundStyle(isProblem ? theme.style(for: .warning).tint : theme.color.text.tertiary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, theme.space.md)
  }
}

/// The mockup's small accent-soft button ("Baixar novamente", "Importar JSON").
/// A real `Button`, so it keeps focus rings, pressed states and disabled styling.
struct SettingsSoftButton: View {
  @Environment(\.theme) private var theme

  let title: String
  var symbol: String?
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: theme.space.xxs) {
        if let symbol {
          Image(systemName: symbol)
            .font(.system(size: SettingsLayout.smallIconSize))
        }
        Text(title)
          .font(SettingsType.softButton.font)
      }
    }
    .buttonStyle(.bordered)
    .tint(theme.color.accent.base)
    .controlSize(.small)
  }
}

/// The download progress track, shared by the Modelo tab and nothing else yet.
struct SettingsProgressTrack: View {
  @Environment(\.theme) private var theme

  /// `nil` renders the native indeterminate bar, which stops animating under
  /// Reduce Motion on its own.
  let fraction: Double?
  let tint: Color

  var body: some View {
    Group {
      if let fraction {
        GeometryReader { proxy in
          ZStack(alignment: .leading) {
            Capsule().fill(theme.color.bg.surface)
            Capsule().fill(tint).frame(width: proxy.size.width * min(max(fraction, 0), 1))
          }
        }
        .frame(height: SettingsLayout.progressTrackHeight)
        .animation(
          theme.motion.animation(theme.motion.base, theme.motion.standard), value: fraction)
      } else {
        ProgressView()
          .progressViewStyle(.linear)
          .controlSize(.small)
          .tint(tint)
      }
    }
    // The percentage is already in the row's title, so the bar would only
    // repeat it.
    .accessibilityHidden(true)
  }
}

/// The two places this window overrides a type token, named once — the same
/// pattern (and the same reason) as `MenuBarType`.
enum SettingsType {
  /// The mockup's row title: `font-weight: 600` over the body size.
  static let rowTitle = derived(from: DesignSystem.TypeScale.body, weight: 600, family: .ui)
  /// The mockup's small buttons: `font-weight: 600` over the caption size.
  static let softButton = derived(
    from: DesignSystem.TypeScale.caption, weight: 600, family: .ui)
  /// The hotkey keycap and the dictionary list: `--font-family-mono`.
  static let mono = derived(
    from: DesignSystem.TypeScale.caption, weight: 600, family: .mono)

  private static func derived(
    from token: TypeToken,
    weight: Int,
    family: DesignSystem.FontFamily
  ) -> TypeToken {
    TypeToken(size: token.size, lineHeight: token.lineHeight, weight: weight, family: family)
  }
}
