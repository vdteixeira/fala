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

struct SettingsModelTab: View {
  @Environment(\.theme) private var theme

  let presenter: ModelPanePresenter
  @State private var isConfirmingReplace = false

  var body: some View {
    let pane = presenter.pane
    VStack(alignment: .leading, spacing: theme.space.xs) {
      modelRow(pane)
      if let detail = pane.problemDetail {
        SettingsCaption(text: detail, isProblem: true)
      }
      if pane.isDownloading {
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
    .animation(theme.motion.quick, value: pane.isDownloading)
    .confirmationDialog(
      pane.confirmationMessage ?? "",
      isPresented: $isConfirmingReplace,
      titleVisibility: .visible
    ) {
      Button(pane.actionTitle, role: .destructive) { presenter.startDownload() }
      Button(SettingsStrings.cancel, role: .cancel) {}
    }
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
        DownloadPulseIcon()
        Text(pane.downloadTitle ?? "")
          .font(SettingsType.softButton.font)
          .foregroundStyle(theme.color.text.primary)
        if !pane.downloadDetail.isEmpty {
          Text(pane.downloadDetail)
            .font(theme.type.micro.font)
            .foregroundStyle(theme.color.text.tertiary)
        }
        Spacer(minLength: theme.space.xxs)
        Button(pane.cancelTitle) { presenter.cancelDownload() }
          .buttonStyle(.link)
          .font(SettingsType.softButton.font)
          .disabled(!pane.isCancelEnabled)
          .accessibilityHint(pane.cancelUnavailableHint ?? "")
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
private struct DownloadPulseIcon: View {
  @Environment(\.theme) private var theme
  @State private var isDim = false

  var body: some View {
    Image(systemName: FalaSymbol.download)
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
