import FalaKit
import SwiftUI

// Ajustes › Modelo — settings-window.dc.html, MODELO section.
//
// Readiness + the size MEASURED on disk, "Baixar novamente", the in-progress
// variant with a progress bar and Cancelar, and the free-disk line.
//
// Deviations, per DESIGN.md's conflict rule (all of them owned by `ModelPane`,
// which documents each in full):
//  * "1,1 GB em disco" is the upstream repository size across every precision
//    variant. This reports `ModelStatus.formattedSize` — what is on THIS disk;
//  * "verificado hoje" is dropped. `ModelStatus.current()` re-runs the whole
//    integrity check on every read, so a stored date could only ever be older
//    than the check that just ran;
//  * "Baixar novamente" deletes the working model before it fetches a byte, so
//    it asks first;
//  * Cancelar stays visible and DISABLED during install, which cannot be
//    interrupted, and carries a VoiceOver hint saying why.
//
// ADDITION the mockup has no vocabulary for: the engine picker at the top.
// `settings-window.dc.html` predates `CohereEngine`, so it draws exactly one
// engine and no mutually-exclusive choice anywhere in the window. The rows
// therefore reuse the mockup's own inset-row language (inset fill, md radius,
// accent-soft + accent border for the selected one) rather than inventing a
// look, and HIG supplies the behaviour the mockup cannot:
//  * radio semantics, not a menu — two options, each needing a two-line
//    explanation and its OWN disk status, which a `Picker(.menu)` cannot show;
//  * built from `Button`s with the `.isSelected` trait, the same deviation
//    `SettingsView`'s tab chips already argue for and document;
//  * the switch is confirmed first whenever the target engine's model is not on
//    disk, because agreeing to compare an engine is not agreeing to a download.

struct SettingsModelTab: View {
  @Environment(\.theme) private var theme

  let presenter: ModelPanePresenter
  @State private var isConfirmingReplace = false
  /// The engine the user asked for and has not yet paid for — non-nil exactly
  /// while the download warning is on screen.
  @State private var pendingEngine: TranscriptionEngineChoice?

  var body: some View {
    let pane = presenter.pane
    VStack(alignment: .leading, spacing: theme.space.xs) {
      engineSection(presenter.engines)
      modelRow(pane)
      if let detail = pane.problemDetail {
        SettingsCaption(text: detail, isProblem: true)
      }
      if pane.isBusy {
        downloadRow(pane)
      }
      if let outcome = pane.outcomeMessage {
        SettingsCaption(text: outcome, isProblem: true)
      }
      diskLine(pane)
    }
    // On appear only: `ModelStatus.current()` enumerates the whole model
    // directory, and a view body would run it on every progress tick.
    .onAppear { presenter.refresh() }
    .animation(theme.motion.quick, value: pane.isBusy)
    .confirmationDialog(
      pane.confirmationMessage ?? "",
      isPresented: $isConfirmingReplace,
      titleVisibility: .visible
    ) {
      Button(pane.actionTitle, role: .destructive) { presenter.startDownload() }
      Button(SettingsStrings.cancel, role: .cancel) {}
    }
    // Confirms the COST of a switch, never the switch itself: an engine whose
    // model is already on disk changes with one click and no dialog.
    .confirmationDialog(
      presenter.engines.confirmationTitle,
      isPresented: isConfirmingEngine,
      titleVisibility: .visible,
      presenting: pendingEngine
    ) { choice in
      Button(presenter.engines.confirmTitle) {
        presenter.selectEngine(choice)
        pendingEngine = nil
      }
      Button(presenter.engines.cancelTitle, role: .cancel) { pendingEngine = nil }
    } message: { choice in
      Text(presenter.engines.downloadWarning(for: choice) ?? "")
    }
  }

  // MARK: - The engine picker

  private func engineSection(_ picker: EnginePicker) -> some View {
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      Text(picker.title)
        .font(SettingsType.rowTitle.font)
        .foregroundStyle(theme.color.text.primary)
        .padding(.horizontal, theme.space.md)
      ForEach(picker.options) { option in
        engineRow(option, in: picker)
      }
      SettingsCaption(text: picker.caption)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(picker.help)
  }

  private func engineRow(_ option: EngineOption, in picker: EnginePicker) -> some View {
    let style = theme.style(for: option.stateKind)
    return Button {
      select(option, in: picker)
    } label: {
      HStack(alignment: .top, spacing: theme.space.xs) {
        Image(systemName: radioSymbol(option))
          .font(.system(size: SettingsLayout.tabIconSize))
          .foregroundStyle(option.isSelected ? theme.color.accent.base : theme.color.text.tertiary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: theme.space.xxs) {
          Text(option.title)
            .font(SettingsType.rowTitle.font)
            .foregroundStyle(theme.color.text.primary)
          Text(option.summary)
            .font(theme.type.caption.font)
            .lineSpacing(theme.type.caption.lineSpacing)
            .foregroundStyle(theme.color.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
          statusLine(option, tint: style.tint)
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, theme.space.xs)
      .padding(.horizontal, theme.space.md)
      .background(option.isSelected ? theme.color.accent.soft : theme.color.bg.inset, in: shape)
      .overlay(
        shape.strokeBorder(
          option.isSelected ? theme.color.accent.base : .clear,
          lineWidth: SettingsLayout.hairline)
      )
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .help(picker.help)
    // Spelled out rather than `children: .combine`, which on a `Button` can cost
    // the button role itself. The disk status is the VALUE — a row whose model
    // is missing has to say so to VoiceOver, not only to the eye.
    .accessibilityLabel(option.title)
    .accessibilityValue(option.statusLine)
    .accessibilityHint(option.summary)
    .accessibilityAddTraits(option.isSelected ? [.isSelected] : [])
    .animation(theme.motion.quick, value: option.isSelected)
  }

  /// Whether THIS engine's model is on disk — read from its own directory, never
  /// inferred from the other's.
  private func statusLine(_ option: EngineOption, tint: Color) -> some View {
    HStack(spacing: theme.space.xxs) {
      Image(systemName: option.symbol)
        .font(.system(size: SettingsLayout.smallIconSize))
        .accessibilityHidden(true)
      Text(option.statusLine)
        .font(theme.type.micro.font)
    }
    .foregroundStyle(tint)
  }

  private func radioSymbol(_ option: EngineOption) -> String {
    option.isSelected ? FalaSymbol.radioSelected : FalaSymbol.radioUnselected
  }

  /// One click when the model is there, a confirmation when it is not.
  private func select(_ option: EngineOption, in picker: EnginePicker) {
    guard !option.isSelected else { return }
    if picker.downloadWarning(for: option.choice) == nil {
      presenter.selectEngine(option.choice)
    } else {
      pendingEngine = option.choice
    }
  }

  private var isConfirmingEngine: Binding<Bool> {
    Binding(
      get: { pendingEngine != nil },
      set: { if !$0 { pendingEngine = nil } })
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: theme.radius.md, style: .continuous)
  }

  // MARK: - The model row

  private func modelRow(_ pane: ModelPane) -> some View {
    let style = theme.style(for: pane.stateKind)
    return SettingsRow {
      SettingsRowIcon(
        symbol: pane.symbol, tint: style.tint, size: SettingsLayout.rowIconSizeLarge)
      SettingsRowLabel(title: pane.title, subtitle: pane.subtitle)
      SettingsSoftButton(title: pane.actionTitle) {
        if pane.confirmationMessage == nil {
          presenter.startDownload()
        } else {
          isConfirmingReplace = true
        }
      }
      .disabled(!pane.isActionEnabled)
    }
  }

  // MARK: - The in-progress row

  private func downloadRow(_ pane: ModelPane) -> some View {
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      HStack(spacing: theme.space.xs) {
        ProgressPulseIcon(symbol: pane.progressSymbol)
        Text(pane.downloadTitle ?? "")
          .font(SettingsType.softButton.font)
          .foregroundStyle(theme.color.text.primary)
        if !pane.downloadDetail.isEmpty {
          Text(pane.downloadDetail)
            .font(theme.type.micro.font)
            .foregroundStyle(theme.color.text.tertiary)
        }
        Spacer(minLength: theme.space.xxs)
        // Offered only for a real transfer. There is nothing to stop during a
        // load, and a dead control beside a moving bar reads as a download the
        // user may not cancel.
        if pane.isCancelOffered {
          Button(pane.cancelTitle) { presenter.cancelDownload() }
            .buttonStyle(.link)
            .font(SettingsType.softButton.font)
            .disabled(!pane.isCancelEnabled)
            .accessibilityHint(pane.cancelUnavailableHint ?? "")
        }
      }
      SettingsProgressTrack(
        fraction: pane.progressFraction, tint: theme.color.state.transcribing)
    }
    .padding(.vertical, theme.space.xs)
    .padding(.horizontal, theme.space.md)
    .background(
      theme.color.bg.inset,
      in: RoundedRectangle(cornerRadius: theme.radius.md, style: .continuous)
    )
    .transition(.opacity)
  }

  // MARK: - Free disk

  @ViewBuilder
  private func diskLine(_ pane: ModelPane) -> some View {
    if let warning = pane.insufficientSpaceWarning {
      SettingsCaption(text: warning, isProblem: true)
    }
    if let line = pane.diskLine {
      HStack(spacing: theme.space.xs) {
        Image(systemName: pane.diskSymbol)
          .font(.system(size: SettingsLayout.smallIconSize))
          .accessibilityHidden(true)
        Text(line)
          .font(theme.type.caption.font)
      }
      .foregroundStyle(theme.color.text.tertiary)
      .padding(.horizontal, theme.space.md)
      .accessibilityElement(children: .combine)
    }
  }
}

/// "animation: fala-pulse 1.6s infinite" on the download glyph. Decorative per
/// the mockup's own footer, so it is hidden from VoiceOver — and it does not
/// animate at all under Reduce Motion, where `theme.motion.pulse` is nil.
private struct ProgressPulseIcon: View {
  @Environment(\.theme) private var theme
  @State private var isDim = false

  /// The download arrow only when bytes move — see `ModelPane.progressSymbol`.
  let symbol: String

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: SettingsLayout.tabIconSize))
      .foregroundStyle(theme.color.state.transcribing)
      .opacity(isDim ? 0.5 : 1)
      .accessibilityHidden(true)
      .onAppear {
        guard let pulse = theme.motion.pulse else { return }
        withAnimation(pulse) { isDim = true }
      }
  }
}
