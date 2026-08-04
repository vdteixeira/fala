import AppKit
import FalaKit
import SwiftUI

// The history window (SPEC.md FR-17/US-5, TASKS.md T2.12, DESIGN-HANDOFF.md §1
// "history-window — Surface 4").
//
// THERE IS NO MOCKUP for this surface. §1 specifies it in prose, and everything
// visual below is taken from the two rendered windows rather than invented:
//  * the row is the popover's "Recentes" row at comfortable density — one text
//    block over a `micro` tertiary meta line, hover fill `bg.surface-hover`,
//    `radius.sm` — with the two extra actions §1 asks for;
//  * the section heading is the popover's "RECENTES" treatment (micro, tertiary,
//    uppercase, letter-spaced) with the day title in it;
//  * the search field is the settings window's inset input (`bg.inset`,
//    `radius.md`, caption);
//  * the privacy band is the popover's fixed footer (`accent.soft`, accent text,
//    `lock.shield.fill`).
// Every decision that the prose left open is listed in the task report so the
// designer can correct it rather than discover it.
//
// Behavior per HIG, where it overrides the prose:
//  * the list is a native `List` with sections and selection (DESIGN.md's
//    component map: "History list → SwiftUI List/Table, native selection,
//    keyboard nav"), so ⌫ deletes the selected row and VoiceOver gets a real
//    table;
//  * "Apagar tudo" opens a native destructive `.alert`, because macOS owns the
//    vocabulary for "this cannot be undone";
//  * `isReleasedWhenClosed = false` — a programmatically created `NSWindow`
//    defaults to true, which over-releases under ARC.
//
// PRIVACY (CLAUDE.md, NFR-1) — the two things this file does NOT do, both
// deliberate:
//  1. **No `.textSelection(.enabled)` on the transcript.** Selectable text hands
//     ⌘C to SwiftUI, which writes the plain general pasteboard — no
//     `.currentHostOnly`, so the transcript syncs to the user's other devices
//     over Universal Clipboard, and no concealed-type marker, so clipboard
//     managers archive it. The row's "Copiar" button goes through
//     `SystemPasteboard.write`, which takes both precautions. One copy path,
//     with the precautions, beats two with different properties.
//  2. **No `.onCopyCommand`.** Same reason: its `[NSItemProvider]` return value
//     is written by SwiftUI, bypassing the same two precautions.
// Nothing in this file logs anything.

// MARK: - Controller

/// Owns the window and its lifetime.
///
/// Held by the app delegate for the process lifetime — the window is created
/// once and reused, so reopening it does not lose the frame the user placed it
/// at, and closing it does not release an object AppKit is still talking to.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
  private let model: HistoryWindowModel
  private var window: NSWindow?

  init(model: HistoryWindowModel) {
    self.model = model
    super.init()
  }

  /// Same window-lifetime care as the settings window: the delegate is cleared
  /// and the window closed, so AppKit is never left holding a dead delegate.
  ///
  /// Isolated `deinit` rather than `MainActor.assumeIsolated`, which TRAPS if
  /// the last release happens off the main thread — same pattern as
  /// `MenuBarController.deinit`.
  @MainActor deinit {
    window?.delegate = nil
    window?.close()
  }

  /// Opens the window, or brings it forward if it is already open.
  func show() {
    let window = self.window ?? makeWindow()
    self.window = window
    // LSUIElement: without activating first, a regular window from an accessory
    // app can open behind whatever the user is looking at.
    NSApplication.shared.activate()
    window.makeKeyAndOrderFront(nil)
    // Read on every open: entries, and the store's own health, can both have
    // changed since the last time this was on screen.
    // beginSession() BEFORE the task: windowWillClose can run before an
    // unstructured task has even started, and the model has to be able to tell
    // that apart from a load it should honour.
    model.beginSession()
    Task { await model.load() }
  }

  private func makeWindow() -> NSWindow {
    let root = HistoryWindowView(model: model).falaTheme()
    let hosting = NSHostingController(rootView: AnyView(root))
    let window = NSWindow(contentViewController: hosting)
    window.title = model.windowTitle
    window.setContentSize(HistoryWindowLayout.defaultSize)
    window.contentMinSize = HistoryWindowLayout.minSize
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    // A programmatically created NSWindow releases itself on close. Under ARC
    // that is an over-release the moment anything still references it — and we
    // do, so the window can be reused.
    window.isReleasedWhenClosed = false
    window.delegate = self
    // Stores a window FRAME in UserDefaults and nothing else: no query, no
    // transcript. `center()` only applies the first time, before the autosaved
    // frame exists.
    window.center()
    window.setFrameAutosaveName(HistoryWindowLayout.frameAutosaveName)
    return window
  }

  /// PRIVACY: closing the window drops every transcript it was holding. A
  /// menu-bar app runs for weeks; without this, opening the history once would
  /// keep up to 500 dictations (and their folded search copies) resident for
  /// the rest of the session.
  func windowWillClose(_ notification: Notification) {
    model.forget()
  }
}

// MARK: - Root view

/// The callbacks a row can run. A `nil` handler renders its control DISABLED
/// rather than hiding it — the same convention `MenuBarActions` uses.
private struct HistoryRowActions {
  var copy: (HistoryRow) -> Void
  var reinject: ((HistoryRow) -> Void)?
  var delete: (HistoryRow) -> Void
}

struct HistoryWindowView: View {
  @Environment(\.theme) private var theme
  @FocusState private var isSearchFocused: Bool
  @State private var selection: UUID?

  let model: HistoryWindowModel

  var body: some View {
    VStack(spacing: 0) {
      searchBar
      hairline
      content
      notice
      footer
    }
    .background(theme.color.bg.canvas)
    .onAppear { isSearchFocused = true }
    .alert(
      model.eraseConfirmation?.title ?? DictationHistoryStrings.eraseAllConfirm,
      isPresented: eraseBinding,
      presenting: model.eraseConfirmation
    ) { confirmation in
      Button(confirmation.confirmTitle, role: .destructive) {
        // The confirmation is passed BY VALUE, and the call is synchronous.
        // Wrapping this in a `Task` and letting the model re-read its own
        // `eraseConfirmation` is what made "Apagar tudo" erase nothing: SwiftUI
        // runs `eraseBinding`'s setter — `cancelEraseAll()` — as soon as any
        // alert button is tapped, so the state was gone before the task ran.
        model.eraseAllConfirmed(confirmation)
      }
      Button(confirmation.cancelTitle, role: .cancel) { model.cancelEraseAll() }
    } message: { confirmation in
      Text(confirmation.message)
    }
  }

  private var actions: HistoryRowActions {
    HistoryRowActions(
      copy: { row in Task { await model.copy(row) } },
      reinject: { row in Task { await model.reinject(row) } },
      delete: { row in Task { await model.delete(row) } })
  }

  /// The mockups' 1px rules. A `Divider()` would paint AppKit's separator color
  /// instead of the token.
  private var hairline: some View {
    Rectangle()
      .fill(theme.color.border.base)
      .frame(height: HistoryWindowLayout.hairline)
      .accessibilityHidden(true)
  }

  // MARK: Search

  private var searchBinding: Binding<String> {
    Binding(get: { model.searchText }, set: { model.setSearchText($0) })
  }

  private var eraseBinding: Binding<Bool> {
    Binding(
      get: { model.eraseConfirmation != nil },
      set: { if !$0 { model.cancelEraseAll() } })
  }

  /// The settings window's inset input, with the count line beside it.
  ///
  /// A plain `TextField` rather than `.searchable`: `NSSearchField` carries a
  /// recent-searches list, and the one thing this window must never do is write
  /// what the user searched for to disk. A `TextField` has nowhere to put it.
  private var searchBar: some View {
    HStack(spacing: theme.space.xs) {
      HStack(spacing: theme.space.xs) {
        Image(systemName: "magnifyingglass")
          .imageScale(.small)
          .foregroundStyle(theme.color.text.secondary)
        TextField(HistoryWindowStrings.searchPlaceholder, text: searchBinding)
          .textFieldStyle(.plain)
          .font(theme.type.caption.font)
          .foregroundStyle(theme.color.text.primary)
          .focused($isSearchFocused)
          // Esc clears the filter instead of closing the window — the window is
          // not a dialog, and losing it because a search came up empty is the
          // wrong outcome.
          .onExitCommand { model.clearSearch() }
        if model.isSearching {
          Button {
            model.clearSearch()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .imageScale(.small)
              .foregroundStyle(theme.color.text.tertiary)
          }
          .buttonStyle(.plain)
          .help(HistoryWindowStrings.clearSearch)
          .accessibilityLabel(HistoryWindowStrings.clearSearch)
        }
      }
      .padding(.horizontal, theme.space.xs)
      .padding(.vertical, theme.space.xxs)
      .background(theme.color.bg.inset, in: inputShape)
      .overlay(inputShape.strokeBorder(theme.color.border.base, lineWidth: hairlineWidth))

      Text(model.countLine)
        .font(theme.type.micro.font)
        .foregroundStyle(theme.color.text.tertiary)
        .fixedSize()
        .accessibilityHidden(!model.isLoaded)
    }
    .padding(.horizontal, theme.space.md)
    .padding(.vertical, theme.space.xs)
  }

  private var hairlineWidth: CGFloat { HistoryWindowLayout.hairline }

  private var inputShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: theme.radius.md, style: .continuous)
  }

  // MARK: List

  @ViewBuilder private var content: some View {
    if let message = model.emptyMessage {
      emptyState(message)
    } else {
      list
    }
  }

  /// DESIGN.md's component map: a native `List`, so selection, keyboard
  /// navigation and the VoiceOver table come from AppKit rather than from a
  /// hand-rolled `ScrollView`.
  ///
  /// `.onCopyCommand` is deliberately NOT wired — see this file's header.
  private var list: some View {
    List(selection: $selection) {
      ForEach(model.days) { day in
        Section {
          ForEach(day.rows) { row in
            HistoryRowView(row: row, actions: actions)
              .listRowInsets(EdgeInsets())
              .listRowSeparator(.hidden)
              .listRowBackground(Color.clear)
              .tag(row.id)
          }
        } header: {
          HistoryDayHeaderView(day: day)
        }
      }
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .onDeleteCommand(perform: deleteSelection)
  }

  /// ⌫ on the selected row. The per-row `trash` has no confirmation either —
  /// one row is visible and recoverable by dictating again; the destructive
  /// alert is reserved for "Apagar tudo", which is not.
  private func deleteSelection() {
    guard let selection,
      let row = model.days.lazy.flatMap(\.rows).first(where: { $0.id == selection })
    else { return }
    self.selection = nil
    Task { await model.delete(row) }
  }

  private func emptyState(_ message: String) -> some View {
    VStack(spacing: theme.space.xs) {
      Image(systemName: FalaSymbol.history)
        .font(theme.type.title.font)
        .foregroundStyle(theme.color.text.tertiary)
      Text(message)
        .font(theme.type.caption.font)
        .foregroundStyle(theme.color.text.secondary)
        .multilineTextAlignment(.center)
      if model.isFilteredEmpty {
        Button(HistoryWindowStrings.clearSearch) { model.clearSearch() }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(theme.color.accent.base)
      }
    }
    .padding(theme.space.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Notice

  @ViewBuilder private var notice: some View {
    if let notice = model.notice {
      HistoryNoticeView(notice: notice, dismiss: { model.dismissNotice() })
        .padding(.horizontal, theme.space.md)
        .padding(.bottom, theme.space.xs)
        .transition(.opacity)
    }
  }

  // MARK: Footer

  /// DESIGN-HANDOFF.md §1: "Privacy note: history is stored locally only; offer
  /// 'Apagar tudo'." The band is the popover's privacy footer, which is the
  /// brand's core claim and functional copy rather than decoration (§4).
  private var footer: some View {
    VStack(spacing: 0) {
      hairline
      HStack(alignment: .firstTextBaseline, spacing: theme.space.xs) {
        Image(systemName: model.privacySymbol)
          .imageScale(.small)
        VStack(alignment: .leading, spacing: 0) {
          Text(model.privacyNote)
          if let path = model.storagePath {
            Text(path)
              .font(theme.type.micro.font)
              .foregroundStyle(theme.color.text.tertiary)
              .textSelection(.enabled)
          }
          if let problem = model.storageProblem {
            Text(problem)
              .font(theme.type.micro.font)
              .foregroundStyle(theme.style(for: .warning).tint)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: theme.space.xs)
        Button(DictationHistoryStrings.eraseAll) { model.requestEraseAll() }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(theme.style(for: .error).tint)
          .disabled(!model.canEraseAll)
      }
      .font(theme.type.micro.font)
      .foregroundStyle(theme.color.accent.base)
      .padding(.horizontal, theme.space.md)
      .padding(.vertical, theme.space.xs)
      .background(theme.color.accent.soft)
    }
  }
}

// MARK: - Section header

/// The popover's "RECENTES" treatment, with the day in it.
private struct HistoryDayHeaderView: View {
  @Environment(\.theme) private var theme

  let day: HistoryDay

  var body: some View {
    HStack(spacing: theme.space.xs) {
      Text(day.title)
        .textCase(.uppercase)
      Spacer(minLength: theme.space.xxs)
      Text(day.countLabel)
        .textCase(.uppercase)
    }
    .font(theme.type.micro.font)
    .foregroundStyle(theme.color.text.tertiary)
    .padding(.vertical, theme.space.xxs)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Row

/// The popover's recents row at comfortable density, with the three actions
/// DESIGN-HANDOFF.md §1 specifies: copy (`doc.on.doc`), re-inject
/// (`arrow.uturn.left`), delete (`trash`).
private struct HistoryRowView: View {
  @Environment(\.theme) private var theme
  @State private var isHovered = false
  @State private var isExpanded = false

  let row: HistoryRow
  let actions: HistoryRowActions

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      Text(displayText)
        .font(theme.type.caption.font)
        .lineSpacing(theme.type.caption.lineSpacing)
        .foregroundStyle(theme.color.text.primary)
        .lineLimit(isExpanded ? nil : HistoryWindowLayout.collapsedLineLimit)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: theme.space.xs) {
        Text(row.metaLine)
          .font(theme.type.micro.font)
          .foregroundStyle(theme.color.text.tertiary)
        if row.needsExpansion {
          Button(isExpanded ? HistoryWindowStrings.showLess : HistoryWindowStrings.showMore) {
            isExpanded.toggle()
          }
          .buttonStyle(.plain)
          .font(theme.type.micro.font)
          .foregroundStyle(theme.color.accent.base)
        }
        Spacer(minLength: theme.space.xxs)
        rowActions
      }
    }
    .padding(.horizontal, theme.space.md)
    .padding(.vertical, theme.space.xs)
    .background(hoverBackground, in: shape)
    .contentShape(shape)
    .onHover { isHovered = $0 }
    .animation(theme.motion.quick, value: isHovered)
    .contextMenu { contextMenu }
    .accessibilityElement(children: .contain)
  }

  /// Expanded shows the transcript verbatim, including its line breaks.
  /// Collapsed flattens them, because a line break inside a `lineLimit` hides
  /// the rest of the sentence with no ellipsis to show that it did.
  private var displayText: String {
    isExpanded ? row.fullText : row.collapsedText
  }

  private var rowActions: some View {
    HStack(spacing: theme.space.xxs) {
      actionButton(
        symbol: FalaSymbol.copy,
        label: DictationHistoryStrings.copy,
        hint: nil,
        isEnabled: true,
        hoverTint: theme.color.accent.base
      ) { actions.copy(row) }

      actionButton(
        symbol: FalaSymbol.undo,
        label: row.reinjectTitle,
        hint: row.reinjectUnavailableHint,
        isEnabled: row.canReinject && actions.reinject != nil,
        hoverTint: theme.color.accent.base
      ) { actions.reinject?(row) }

      actionButton(
        symbol: FalaSymbol.delete,
        label: DictationHistoryStrings.delete,
        hint: nil,
        isEnabled: true,
        hoverTint: theme.style(for: .error).tint
      ) { actions.delete(row) }
    }
  }

  /// One icon button.
  ///
  /// The foreground is resolved HERE and nowhere else: an explicit
  /// `.foregroundStyle` inside a `Button`'s label overrides the dimming
  /// `.buttonStyle(.plain)` derives from `isEnabled`, which is exactly how two
  /// dead rows shipped looking alive in the popover.
  private func actionButton(
    symbol: String,
    label: String,
    hint: String?,
    isEnabled: Bool,
    hoverTint: Color,
    run: @escaping () -> Void
  ) -> some View {
    Button(action: run) {
      Image(systemName: symbol)
        .imageScale(.small)
        .foregroundStyle(isEnabled ? tint(hoverTint) : theme.color.text.tertiary)
        .padding(theme.space.xxs)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .help(label)
    .accessibilityLabel(label)
    .accessibilityHint(hint ?? "")
  }

  /// Icons rest at the lowest emphasis and take their own tint once the row is
  /// hovered — the mockup's dictionary row behaviour, where `trash` turns red.
  private func tint(_ hovered: Color) -> Color {
    isHovered ? hovered : theme.color.text.tertiary
  }

  @ViewBuilder private var contextMenu: some View {
    Button(DictationHistoryStrings.copy) { actions.copy(row) }
    Button(row.reinjectTitle) { actions.reinject?(row) }
      .disabled(!row.canReinject || actions.reinject == nil)
    Divider()
    Button(DictationHistoryStrings.delete, role: .destructive) { actions.delete(row) }
  }

  private var hoverBackground: Color {
    isHovered ? theme.color.bg.surfaceHover : .clear
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: theme.radius.sm, style: .continuous)
  }
}

// MARK: - Notice

/// The result of the last row action, in the popover's notice chrome: soft fill
/// plus a 1px stroke, tinted by one of the six states.
private struct HistoryNoticeView: View {
  @Environment(\.theme) private var theme

  let notice: HistoryNotice
  let dismiss: () -> Void

  var body: some View {
    let style = theme.style(for: notice.kind)
    let shape = RoundedRectangle(cornerRadius: theme.radius.md, style: .continuous)
    HStack(spacing: theme.space.xs) {
      Image(systemName: style.symbol)
        .imageScale(.small)
        .foregroundStyle(style.tint)
      Text(notice.message)
        .font(theme.type.caption.font)
        .foregroundStyle(theme.color.text.primary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: theme.space.xxs)
      Button(notice.dismissTitle) { dismiss() }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(style.tint)
    }
    .padding(theme.space.xs)
    .background(style.soft, in: shape)
    .overlay(shape.strokeBorder(style.tint, lineWidth: HistoryWindowLayout.hairline))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(notice.message)
  }
}
