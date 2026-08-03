import AppKit
import FalaKit
import SwiftUI

// Ajustes › Dicionário — settings-window.dc.html, DICIONÁRIO section.
//
// The jargon list with a per-row delete, "Adicionar termo" input + button,
// Importar/Exportar JSON.
//
// Deviations, per DESIGN.md's conflict rule:
//  * a row shows `ouvido → escrito` when the two differ. The mockup prints one
//    word per row because it imagined a list of terms; the dictionary is a list
//    of substitutions, and a row reading only "deploy" cannot say whether
//    deleting it stops a correction or removes a word;
//  * the field accepts `ouvido = escrito`, with a hint saying so. Without it the
//    button could only ever add rules where `from == to`, which correct nothing;
//  * there is a "Desfazer". A list of forty rules with one trash icon per row
//    and no way back is a delete the user cannot recover from;
//  * an import that would replace existing terms asks first.
//
// PRIVACY: nothing on this tab touches a transcript. The list is configuration
// the user wrote plus the rules the app ships.

struct SettingsDictionaryTab: View {
  @Environment(\.theme) private var theme

  let presenter: DictionaryPanePresenter
  @State private var pendingImport: URL?

  var body: some View {
    let pane = presenter.pane
    VStack(alignment: .leading, spacing: theme.space.xs) {
      Text(pane.caption)
        .font(theme.type.caption.font)
        .foregroundStyle(theme.color.text.secondary)
      list(pane)
      addField(pane)
      status(pane)
      fileButtons
    }
    .onAppear { presenter.reload() }
    .confirmationDialog(
      DictionaryStrings.replaceTitle,
      isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
      titleVisibility: .visible
    ) {
      Button(DictionaryStrings.replaceConfirm, role: .destructive) {
        if let url = pendingImport { presenter.importOverride(from: url) }
        pendingImport = nil
      }
      Button(SettingsStrings.cancel, role: .cancel) { pendingImport = nil }
    } message: {
      Text(DictionaryStrings.replaceMessage)
    }
  }

  // MARK: - The list

  @ViewBuilder
  private func list(_ pane: DictionaryPane) -> some View {
    let shape = RoundedRectangle(cornerRadius: theme.radius.md, style: .continuous)
    Group {
      if pane.isEmpty {
        Text(DictionaryPaneStrings.empty)
          .font(theme.type.caption.font)
          .foregroundStyle(theme.color.text.tertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(theme.space.xs)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(pane.terms) { term in
              DictionaryRow(term: term, remove: { presenter.remove(term) })
              if term.id != pane.terms.last?.id {
                Rectangle()
                  .fill(theme.color.border.base)
                  .frame(height: SettingsLayout.hairline)
              }
            }
          }
        }
        .frame(maxHeight: SettingsLayout.dictionaryListMaxHeight)
      }
    }
    .background(theme.color.bg.surface, in: shape)
    .overlay(shape.strokeBorder(theme.color.border.base, lineWidth: SettingsLayout.hairline))
    .clipShape(shape)
  }

  // MARK: - Adding

  private func addField(_ pane: DictionaryPane) -> some View {
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      HStack(spacing: theme.space.xs) {
        TextField(
          DictionaryPaneStrings.addPlaceholder,
          text: Binding(get: { presenter.draft }, set: { presenter.draft = $0 })
        )
        .textFieldStyle(.roundedBorder)
        .font(theme.type.caption.font)
        .onSubmit { presenter.addTerm() }
        Button(DictionaryPaneStrings.addButton) { presenter.addTerm() }
          .buttonStyle(.borderedProminent)
          .tint(theme.color.accent.base)
          .controlSize(.small)
          .disabled(!pane.canAdd)
      }
      Text(DictionaryPaneStrings.addHint)
        .font(theme.type.micro.font)
        .foregroundStyle(theme.color.text.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Status + undo

  @ViewBuilder
  private func status(_ pane: DictionaryPane) -> some View {
    if let message = pane.status {
      HStack(spacing: theme.space.xs) {
        Text(message)
          .font(theme.type.caption.font)
          .foregroundStyle(
            pane.isStatusAProblem
              ? theme.style(for: .warning).tint : theme.color.text.secondary
          )
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        if pane.canUndo {
          Button(DictionaryPaneStrings.undo) { presenter.undo() }
            .buttonStyle(.link)
            .font(SettingsType.softButton.font)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain)
    }
  }

  // MARK: - Files

  private var fileButtons: some View {
    HStack(spacing: theme.space.xs) {
      Spacer(minLength: 0)
      SettingsSoftButton(
        title: DictionaryPaneStrings.importButton, symbol: FalaSymbol.importJSON
      ) {
        chooseFileToImport()
      }
      SettingsSoftButton(
        title: DictionaryPaneStrings.exportButton, symbol: FalaSymbol.exportJSON
      ) {
        chooseDestinationAndExport()
      }
    }
  }

  /// `NSOpenPanel` rather than `.fileImporter`: this is an AppKit app, the panel
  /// is the same one every other macOS app opens, and it gives the sandbox
  /// grant for the chosen file directly.
  private func chooseFileToImport() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.prompt = DictionaryPaneStrings.importButton
    guard panel.runModal() == .OK, let url = panel.url else { return }
    // Import REPLACES. Ask before dropping terms the user typed; when there is
    // nothing to lose, do not make them confirm an empty file.
    if presenter.hasUserOverride {
      pendingImport = url
    } else {
      presenter.importOverride(from: url)
    }
  }

  private func chooseDestinationAndExport() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = JargonExport.suggestedFileName
    panel.prompt = DictionaryPaneStrings.exportButton
    guard panel.runModal() == .OK, let url = panel.url else { return }
    presenter.export(to: url)
  }
}

/// One rule. The trash icon is the mockup's; what it writes depends on where the
/// rule came from, and `DictionaryPanePresenter` decides that.
private struct DictionaryRow: View {
  @Environment(\.theme) private var theme
  @State private var isHovered = false

  let term: DictionaryTerm
  let remove: () -> Void

  var body: some View {
    HStack(spacing: theme.space.xs) {
      Image(systemName: FalaSymbol.dictionary)
        .font(.system(size: SettingsLayout.smallIconSize))
        .foregroundStyle(theme.color.accent.base)
        .accessibilityHidden(true)
      Text(term.displayText)
        .font(SettingsType.mono.font)
        .foregroundStyle(theme.color.text.primary)
        .lineLimit(1)
        .truncationMode(.middle)
      if term.isBundled {
        Text(DictionaryPaneStrings.bundledBadge)
          .font(theme.type.micro.font)
          .foregroundStyle(theme.color.text.tertiary)
      }
      Spacer(minLength: theme.space.xxs)
      Button(action: remove) {
        Image(systemName: FalaSymbol.delete)
          .font(.system(size: SettingsLayout.smallIconSize))
          .foregroundStyle(isHovered ? theme.style(for: .error).tint : theme.color.text.tertiary)
      }
      .buttonStyle(.plain)
      .help(DictionaryPaneStrings.removeHelp)
      .accessibilityLabel("\(DictionaryPaneStrings.removeHelp): \(term.accessibilityLabel)")
    }
    .padding(.vertical, theme.space.xxs)
    .padding(.horizontal, theme.space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(isHovered ? theme.color.bg.surfaceHover : theme.color.bg.surface)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(theme.motion.quick, value: isHovered)
  }
}

/// The confirmation the mockup has no vocabulary for.
private enum DictionaryStrings {
  static let replaceTitle = "Substituir seus termos?"
  static let replaceMessage =
    "Importar troca o seu dicionário inteiro pelo arquivo escolhido. Os termos "
    + "que você já tem serão perdidos."
  static let replaceConfirm = "Substituir"
}
