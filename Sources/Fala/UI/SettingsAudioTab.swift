import FalaKit
import SwiftUI

// Ajustes › Áudio — settings-window.dc.html, ÁUDIO section.
//
// Device picker, the amber HFP row that springs in only for a degraded route,
// and the 12-segment level meter.
//
// Deviation, per DESIGN.md's conflict rule: the mockup's `<select>` becomes a
// native `Picker`, and the amber row names the ACTUAL device rather than always
// saying "AirPods" (`AudioRouteWarning` owns that sentence, and the pill and
// `doctor` print the same one).

struct SettingsAudioTab: View {
  @Environment(\.theme) private var theme

  let presenter: AudioPanePresenter
  let window: SettingsWindowModel

  var body: some View {
    let pane = presenter.pane
    VStack(alignment: .leading, spacing: theme.space.xs) {
      deviceRow(pane)
      if let notice = pane.substitutionNotice {
        SettingsCaption(text: notice, isProblem: false)
      }
      warningRow(pane)
      meterRow(pane)
    }
    .onAppear { presenter.refresh() }
    // Keyed on the window's own visibility rather than on view lifecycle: the
    // microphone is open while this runs, and "when does a hosted SwiftUI view
    // disappear" is not a question worth betting an open microphone on. Leaving
    // the tab cancels the task too, because the tab subtree is `.id`-keyed.
    .task(id: window.isVisible) {
      guard window.isVisible else { return }
      await presenter.observeLevels()
    }
  }

  // MARK: - Device

  private func deviceRow(_ pane: AudioPane) -> some View {
    SettingsRow {
      SettingsRowIcon(symbol: pane.deviceSymbol)
      SettingsRowLabel(title: AudioPaneStrings.deviceTitle)
      if pane.hasNoDevice {
        Text(pane.noDeviceMessage)
          .font(theme.type.caption.font)
          .foregroundStyle(theme.style(for: .warning).tint)
      } else {
        Picker(AudioPaneStrings.deviceTitle, selection: selection(pane)) {
          ForEach(pane.options) { option in
            Text(option.label).tag(option.id)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .help(AudioPaneStrings.devicePickerHelp)
      }
    }
  }

  private func selection(_ pane: AudioPane) -> Binding<String> {
    Binding(
      get: { pane.selectionID },
      set: { presenter.select(optionID: $0) })
  }

  // MARK: - The amber HFP row

  /// "aparece fala-appear 320ms --ease-spring quando dispositivo Bluetooth/HFP".
  /// `theme.motion.appear` IS that token, and it is nil under Reduce Motion —
  /// the row then simply appears, which the mockup's footer asks for.
  @ViewBuilder
  private func warningRow(_ pane: AudioPane) -> some View {
    ZStack(alignment: .top) {
      if let warning = pane.warning {
        let style = theme.style(for: .warning)
        HStack(alignment: .top, spacing: theme.space.xs) {
          SettingsRowIcon(symbol: warning.symbol, tint: style.tint)
          Text(warning.message)
            .font(theme.type.caption.font)
            .lineSpacing(theme.type.caption.lineSpacing)
            .foregroundStyle(theme.color.text.primary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
        .padding(.vertical, theme.space.xs)
        .padding(.horizontal, theme.space.md)
        .background(style.soft, in: shape)
        .overlay(shape.strokeBorder(style.tint, lineWidth: SettingsLayout.hairline))
        .transition(
          .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
            removal: .opacity)
        )
        .accessibilityElement(children: .combine)
      }
    }
    .animation(theme.motion.appear, value: pane.warning)
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: theme.radius.md, style: .continuous)
  }

  // MARK: - Level meter

  private func meterRow(_ pane: AudioPane) -> some View {
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      SettingsRow {
        SettingsRowIcon(symbol: pane.levelSymbol, tint: theme.color.state.recording)
        SettingsRowLabel(title: AudioPaneStrings.levelTitle)
        InputLevelMeterView(segments: pane.meterSegments)
          .accessibilityElement()
          .accessibilityLabel(AudioPaneStrings.levelTitle)
          .accessibilityValue(pane.meterAccessibilityValue)
      }
      if let caption = pane.meterCaption {
        SettingsCaption(text: caption, isProblem: pane.isMeterCaptionAProblem)
      }
    }
  }
}

/// The twelve segments. "atualiza a cada 50ms **sem transição**" — so this is
/// redrawn, never animated, and Reduce Motion changes nothing about it.
private struct InputLevelMeterView: View {
  @Environment(\.theme) private var theme

  let segments: [InputLevelMeter.SegmentState]

  var body: some View {
    HStack(spacing: InputLevelMeterMetrics.segmentSpacing) {
      ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
        RoundedRectangle(
          cornerRadius: InputLevelMeterMetrics.segmentCornerRadius, style: .continuous
        )
        .fill(theme.meterSegmentColor(segment))
        .frame(
          width: InputLevelMeterMetrics.segmentWidth,
          height: InputLevelMeterMetrics.segmentHeight)
      }
    }
  }
}
