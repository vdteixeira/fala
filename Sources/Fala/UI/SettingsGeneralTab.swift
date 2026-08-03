import FalaKit
import SwiftUI

// Ajustes › Geral — settings-window.dc.html, GERAL section.
//
// Three inset rows: the hotkey recorder (keycap + pencil, border pulsing while
// it listens), "Iniciar no login", "Mostrar overlay durante o ditado".
//
// Deviation, per DESIGN.md's conflict rule:
//  * the mockup's 36×22 drawn switch is a native `Toggle(.switch)` tinted with
//    the accent token — the same call the popover's header already makes;
//  * "Iniciar no login" grows a caption and an "Abrir Ajustes do Sistema" button
//    in the states macOS can force on it (approval pending, not in a bundle).
//    The mockup has no vocabulary for those, and the alternative is a switch
//    that silently refuses to move.

struct SettingsGeneralTab: View {
  @Environment(\.theme) private var theme

  let presenter: GeneralPanePresenter
  var actions = SettingsActions()

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      hotkeyRow
      launchRow
      overlayRow
    }
    .onAppear { presenter.refresh() }
    // Itens de Início is one System Settings pane away, so the switch is
    // re-read whenever the user comes back to the app.
    .onReceive(Self.didBecomeActive) { _ in presenter.refresh() }
  }

  private static let didBecomeActive = NotificationCenter.default.publisher(
    for: NSApplication.didBecomeActiveNotification)

  // MARK: - Hotkey

  private var hotkeyRow: some View {
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      SettingsRow {
        SettingsRowIcon(symbol: presenter.hotkeySymbol)
        SettingsRowLabel(
          title: presenter.hotkeyTitle, subtitle: presenter.hotkeySubtitle)
        HotkeyKeycap(presenter: presenter)
      }
      if let caption = presenter.hotkeyCaption {
        SettingsCaption(text: caption, isProblem: presenter.isHotkeyCaptionAProblem)
      }
    }
  }

  // MARK: - Iniciar no login

  private var launchRow: some View {
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      SettingsRow {
        SettingsRowIcon(symbol: presenter.launch.symbol)
        SettingsRowLabel(title: LaunchAtLoginStrings.title)
        Toggle(LaunchAtLoginStrings.toggleHelp, isOn: launchBinding)
          .toggleStyle(.switch)
          .labelsHidden()
          .tint(theme.color.accent.base)
          .help(LaunchAtLoginStrings.toggleHelp)
      }
      if let caption = presenter.launch.caption {
        SettingsCaption(text: caption, isProblem: presenter.launch.isCaptionAProblem)
      }
      if let url = presenter.launch.settingsURL {
        SettingsSoftButton(title: LaunchAtLoginStrings.openSystemSettings) {
          actions.openURL?(url)
        }
        .disabled(actions.openURL == nil)
        .padding(.horizontal, theme.space.md)
      }
    }
    .animation(theme.motion.quick, value: presenter.launch.status)
  }

  /// Straight through to the model: it writes to macOS and then adopts whatever
  /// macOS reports, which may not be what was asked for. A `@State` mirror here
  /// would show "ligado" for an app that will never start.
  private var launchBinding: Binding<Bool> {
    Binding(
      get: { presenter.launch.isOn },
      set: { presenter.launch.setOn($0) })
  }

  // MARK: - Mostrar overlay

  private var overlayRow: some View {
    SettingsRow {
      SettingsRowIcon(symbol: presenter.overlaySymbol)
      SettingsRowLabel(title: presenter.overlayTitle, subtitle: presenter.overlaySubtitle)
      Toggle(GeneralPaneStrings.overlayToggleHelp, isOn: overlayBinding)
        .toggleStyle(.switch)
        .labelsHidden()
        .tint(theme.color.accent.base)
        .help(GeneralPaneStrings.overlayToggleHelp)
    }
  }

  private var overlayBinding: Binding<Bool> {
    Binding(
      get: { presenter.showOverlay },
      set: {
        presenter.setShowOverlay($0)
        actions.showOverlayChanged?($0)
      })
  }
}

// MARK: - The keycap

/// The mockup's `⌥ direito` chip with a pencil, which becomes a prompt with a
/// pulsing border while the recorder is listening.
///
/// A `Button`, not a tappable `HStack`: it has to be reachable by keyboard and
/// announced as a control. The pulse is `fala-pulse` (1.6 s, standard) applied
/// to the border colour, and `theme.motion.pulse` is nil under Reduce Motion —
/// where the prompt text alone already says the recorder is listening.
private struct HotkeyKeycap: View {
  @Environment(\.theme) private var theme

  let presenter: GeneralPanePresenter
  @State private var isPulsing = false

  var body: some View {
    Button {
      if presenter.isRecording {
        presenter.cancelRecording()
      } else {
        presenter.beginRecording()
      }
    } label: {
      HStack(spacing: theme.space.xxs) {
        Text(presenter.keycapLabel)
          .font(SettingsType.mono.font)
          .foregroundStyle(theme.color.text.primary)
        Image(systemName: presenter.editSymbol)
          .font(.system(size: SettingsLayout.smallIconSize))
          .foregroundStyle(theme.color.text.tertiary)
      }
      .padding(.vertical, theme.space.xxs)
      .padding(.horizontal, theme.space.xs)
      .background(theme.color.bg.surface, in: shape)
      .overlay(shape.strokeBorder(borderColor, lineWidth: SettingsLayout.hairline))
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .help(GeneralPaneStrings.hotkeyEditHelp)
    .accessibilityLabel(GeneralPaneStrings.hotkeyEditHelp)
    .accessibilityValue(presenter.keycapLabel)
    .accessibilityHint(presenter.isRecording ? GeneralPaneStrings.hotkeyRecordingHint : "")
    .onChange(of: presenter.isRecording) { _, isRecording in
      guard theme.motion.pulse != nil else {
        isPulsing = false
        return
      }
      withAnimation(isRecording ? theme.motion.pulse : nil) { isPulsing = isRecording }
    }
  }

  private var borderColor: Color {
    guard presenter.isRecording else { return theme.color.border.strong }
    return isPulsing ? theme.color.accent.soft : theme.color.accent.base
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: theme.radius.sm, style: .continuous)
  }
}
