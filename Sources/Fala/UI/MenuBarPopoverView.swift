import FalaKit
import SwiftUI

// The menu-bar popover (SPEC.md FR-15, TASKS.md T2.2), translated from
// design/mockups/menubar-popover.dc.html per DESIGN-HANDOFF.md §1.
//
// Visual per mockup: 340pt column, header lockup + on/off toggle, conditional
// permissions banner, model status block, "Recentes", quick actions, fixed
// privacy footer.
//
// Behavior per HIG, where it overrides the mockup:
//  * the popover's vibrancy is `NSPopover`'s own material, not a flat fill; the
//    `--color-bg-vibrancy` token is the Reduce-Transparency fallback (DESIGN.md).
//  * the 36×22 custom switch is a native `Toggle(.switch)` tinted with the accent
//    token — DESIGN.md says not to reinvent controls.
//  * "Conceder"/"Tentar novamente" are native buttons with a token tint, so they
//    inherit focus rings, pressed states and disabled styling for free.
//
// Every value comes from `theme` or from `MenuBarLayout`; there are no raw
// numbers, no hex, and no pt-BR string that is not in `MenuBarStrings` or on the
// model it belongs to.

/// The callbacks the popover needs from the app.
///
/// A `nil` handler renders its control DISABLED rather than hiding it: a menu
/// whose rows appear and disappear is harder to learn than one where a row is
/// visibly not ready yet. It is also how the surfaces this task does not own —
/// Ajustes (T2.6…), Histórico (T2.5) — are represented honestly.
struct MenuBarActions {
  var grantPermissions: (() -> Void)?
  var retryModelDownload: (() -> Void)?
  var openSettings: (() -> Void)?
  var openHistory: (() -> Void)?
  var copyTranscription: ((RecentTranscription) -> Void)?
  var quit: (() -> Void)?
}

struct MenuBarPopoverView: View {
  @Environment(\.theme) private var theme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  let presenter: MenuBarPresenter
  var actions = MenuBarActions()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      banner
      ModelBlockView(block: presenter.model, retry: actions.retryModelDownload)
        .padding(.horizontal, theme.space.md)
        .padding(.bottom, theme.space.xs)
      recentsSection
      Divider()
        .padding(.horizontal, theme.space.md)
        .padding(.vertical, theme.space.xxs)
      quickActions
      privacyFooter
    }
    .frame(width: MenuBarLayout.popoverWidth)
    .background(surfaceBackground)
  }

  /// HIG over mockup: `NSPopover` already paints a vibrant material, so the
  /// content stays transparent and lets it through. When the user has asked for
  /// less transparency, the flat token takes over — that is exactly what
  /// `--color-bg-vibrancy` is for.
  @ViewBuilder private var surfaceBackground: some View {
    if reduceTransparency {
      theme.color.bg.vibrancy
    } else {
      Color.clear
    }
  }

  private var header: some View {
    HStack(spacing: theme.space.xs) {
      BrandMarkView()
      VStack(alignment: .leading, spacing: 0) {
        Text(MenuBarStrings.brandName)
          .font(theme.type.headline.font.weight(.bold))
          .foregroundStyle(theme.color.text.primary)
        Text(presenter.dictation.statusLabel)
          .font(theme.type.micro.font)
          .foregroundStyle(dictationLabelColor)
      }
      Spacer(minLength: theme.space.xs)
      Toggle(MenuBarStrings.dictationToggleHelp, isOn: dictationBinding)
        .toggleStyle(.switch)
        .labelsHidden()
        .tint(theme.color.accent.base)
        .help(MenuBarStrings.dictationToggleHelp)
    }
    .padding(.horizontal, theme.space.md)
    .padding(.top, theme.space.md)
    .padding(.bottom, theme.space.xs)
    .animation(theme.motion.quick, value: presenter.dictation.isEnabled)
  }

  private var dictationBinding: Binding<Bool> {
    Binding(
      get: { presenter.dictation.isEnabled },
      set: { presenter.dictation.setEnabled($0) })
  }

  private var dictationLabelColor: Color {
    presenter.dictation.isEnabled
      ? theme.style(for: .success).tint
      : theme.color.text.tertiary
  }

  /// Present ONLY while something is pending (DESIGN-HANDOFF.md §3: the healthy
  /// state hides it entirely, it does not grey it out).
  @ViewBuilder private var banner: some View {
    if let banner = presenter.permissionsBanner {
      PermissionsBannerView(banner: banner, action: actions.grantPermissions)
        .padding(.horizontal, theme.space.md)
        .padding(.top, theme.space.xxs)
        .padding(.bottom, theme.space.xs)
        .transition(.opacity)
    }
  }

  private var recentsSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(MenuBarStrings.recentsTitle)
        .font(theme.type.micro.font)
        .textCase(.uppercase)
        .foregroundStyle(theme.color.text.tertiary)
        .padding(.horizontal, theme.space.xs)
        .padding(.vertical, theme.space.xxs)
      if presenter.recents.isEmpty {
        Text(MenuBarStrings.recentsEmpty)
          .font(theme.type.caption.font)
          .foregroundStyle(theme.color.text.tertiary)
          .padding(.horizontal, theme.space.xs)
          .padding(.bottom, theme.space.xxs)
      } else {
        ForEach(presenter.recents) { entry in
          RecentRowView(entry: entry, now: presenter.now, copy: actions.copyTranscription)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, theme.space.xs)
    .padding(.vertical, theme.space.xxs)
  }

  private var quickActions: some View {
    VStack(spacing: 0) {
      QuickActionRowView(
        symbol: FalaSymbol.settings,
        title: MenuBarStrings.openSettings,
        shortcut: MenuBarStrings.openSettingsShortcut,
        action: actions.openSettings)
      QuickActionRowView(
        symbol: FalaSymbol.history,
        title: MenuBarStrings.openHistory,
        shortcut: nil,
        action: actions.openHistory)
      QuickActionRowView(
        symbol: FalaSymbol.power,
        title: MenuBarStrings.quit,
        shortcut: MenuBarStrings.quitShortcut,
        action: actions.quit)
    }
    .padding(.horizontal, theme.space.xs)
    .padding(.bottom, theme.space.xxs)
  }

  /// Fixed, always visible, in every variant (DESIGN-HANDOFF.md §1 and §4). This
  /// is the brand's core claim, so it is functional copy, not decoration.
  private var privacyFooter: some View {
    HStack(spacing: theme.space.xxs) {
      Image(systemName: FalaSymbol.privacyShield)
        .imageScale(.small)
      Text(MenuBarStrings.privacyFooter)
    }
    .font(theme.type.micro.font)
    .foregroundStyle(theme.color.accent.base)
    .frame(maxWidth: .infinity)
    .padding(theme.space.xs)
    .background(theme.color.accent.soft)
  }
}

// MARK: - Header lockup

/// The logo: four waveform bars forming a speech quote mark, on the violet
/// gradient tile. Geometry and gradient angle both come from tokens/`StatusIconMark`,
/// so the menu-bar template image and this tile can never drift apart.
private struct BrandMarkView: View {
  @Environment(\.theme) private var theme

  var body: some View {
    let brand = theme.color.brand
    let points = CSSGradientAngle.unitPoints(degrees: brand.markGradientAngle)
    RoundedRectangle(cornerRadius: theme.radius.sm, style: .continuous)
      .fill(
        LinearGradient(
          colors: [brand.markGradientStart, brand.markGradientEnd],
          startPoint: UnitPoint(x: points.start.x, y: points.start.y),
          endPoint: UnitPoint(x: points.end.x, y: points.end.y))
      )
      .frame(width: MenuBarLayout.logoSize, height: MenuBarLayout.logoSize)
      .overlay(BrandBarsView())
      .accessibilityHidden(true)
  }
}

private struct BrandBarsView: View {
  @Environment(\.theme) private var theme

  var body: some View {
    let size = StatusIconMark.naturalSize
    let mark = StatusIconMark.geometry(
      in: CGRect(origin: .zero, size: size), amplitude: 0)
    Canvas { context, _ in
      for (index, bar) in mark.bars.enumerated() {
        // The third bar is the warm one (menubar-popover.dc.html:60).
        let color =
          index == BrandBarsView.accentBarIndex
          ? theme.color.brand.markAccentBar
          : theme.color.text.onAccent
        context.fill(
          Path(roundedRect: bar, cornerRadius: mark.cornerRadius), with: .color(color))
      }
    }
    .frame(width: size.width, height: size.height)
  }

  private static let accentBarIndex = 2
}

// MARK: - Permissions banner

private struct PermissionsBannerView: View {
  @Environment(\.theme) private var theme

  let banner: PermissionsBanner
  let action: (() -> Void)?

  var body: some View {
    let style = theme.style(for: banner.stateKind)
    HStack(spacing: theme.space.xs) {
      Image(systemName: banner.symbol)
        .imageScale(.medium)
        .foregroundStyle(style.tint)
      (Text(banner.prefix) + Text(banner.names).bold())
        .font(theme.type.caption.font)
        .lineSpacing(theme.type.caption.lineSpacing)
        .foregroundStyle(theme.color.text.primary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: theme.space.xxs)
      Button(banner.actionTitle) { action?() }
        .buttonStyle(.borderedProminent)
        .tint(theme.color.accent.base)
        .controlSize(.small)
        .disabled(action == nil)
    }
    .padding(theme.space.xs)
    .background(style.soft, in: shape)
    .overlay(shape.strokeBorder(style.tint, lineWidth: MenuBarLayout.hairline))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(banner.message)
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: theme.radius.md, style: .continuous)
  }
}

// MARK: - Model status block

private struct ModelBlockView: View {
  @Environment(\.theme) private var theme

  let block: ModelBlock
  let retry: (() -> Void)?

  var body: some View {
    let style = theme.style(for: block.stateKind)
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      HStack(spacing: theme.space.xs) {
        Image(systemName: block.symbol)
          .imageScale(.medium)
          .foregroundStyle(style.tint)
        Text(block.title)
          .font(theme.type.caption.font.weight(.semibold))
          .foregroundStyle(theme.color.text.primary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: theme.space.xxs)
        if !block.detail.isEmpty {
          Text(block.detail)
            .font(theme.type.micro.font)
            .foregroundStyle(theme.color.text.tertiary)
        }
        if let actionTitle = block.actionTitle {
          Button(actionTitle) { retry?() }
            .buttonStyle(.bordered)
            .tint(style.tint)
            .controlSize(.small)
            .disabled(retry == nil)
        }
      }
      if let fraction = block.progressFraction {
        ProgressTrackView(fraction: fraction, tint: style.tint)
      } else if block.isDownloading {
        // Size not known yet. The native indeterminate bar is the HIG answer and
        // stops animating under Reduce Motion on its own.
        ProgressView()
          .progressViewStyle(.linear)
          .controlSize(.small)
          .tint(style.tint)
          .accessibilityHidden(true)
      }
    }
    .padding(theme.space.xs)
    .background(theme.color.bg.surface, in: shape)
    .overlay(shape.strokeBorder(borderColor, lineWidth: MenuBarLayout.hairline))
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: theme.radius.md, style: .continuous)
  }

  /// The error variant is outlined in red (mockup: "erro" replaces the block).
  private var borderColor: Color {
    block == .failed ? theme.style(for: .error).tint : theme.color.border.base
  }
}

private struct ProgressTrackView: View {
  @Environment(\.theme) private var theme

  let fraction: Double
  let tint: Color

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(theme.color.bg.inset)
        Capsule().fill(tint).frame(width: proxy.size.width * fraction)
      }
    }
    .frame(height: MenuBarLayout.progressHeight)
    // Motion §6: 200ms standard on every width update, and nothing at all under
    // Reduce Motion — `theme.motion.animation` returns nil there.
    .animation(
      theme.motion.animation(theme.motion.base, theme.motion.standard), value: fraction
    )
    // The percentage is already in the block title, so the bar is decoration for
    // VoiceOver and would only repeat it.
    .accessibilityHidden(true)
  }
}

// MARK: - Rows

private struct RecentRowView: View {
  @Environment(\.theme) private var theme
  @State private var isHovered = false

  let entry: RecentTranscription
  let now: Date
  let copy: ((RecentTranscription) -> Void)?

  var body: some View {
    HStack(spacing: theme.space.xs) {
      VStack(alignment: .leading, spacing: 0) {
        Text(entry.previewText())
          .font(theme.type.caption.font)
          .foregroundStyle(theme.color.text.primary)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(entry.metaLine(relativeTo: now))
          .font(theme.type.micro.font)
          .foregroundStyle(theme.color.text.tertiary)
      }
      Spacer(minLength: theme.space.xxs)
      Button {
        copy?(entry)
      } label: {
        Image(systemName: FalaSymbol.copy)
          .imageScale(.small)
          .foregroundStyle(theme.color.text.tertiary)
      }
      .buttonStyle(.plain)
      .help(MenuBarStrings.copy)
      .accessibilityLabel(MenuBarStrings.copy)
      .disabled(copy == nil)
    }
    .padding(.horizontal, theme.space.xs)
    .padding(.vertical, theme.space.xxs)
    .background(hoverBackground, in: shape)
    .contentShape(shape)
    .onHover { isHovered = $0 }
    .animation(theme.motion.quick, value: isHovered)
  }

  private var hoverBackground: Color {
    isHovered ? theme.color.bg.surfaceHover : .clear
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: theme.radius.sm, style: .continuous)
  }
}

private struct QuickActionRowView: View {
  @Environment(\.theme) private var theme
  @State private var isHovered = false

  let symbol: String
  let title: String
  let shortcut: String?
  let action: (() -> Void)?

  var body: some View {
    Button {
      action?()
    } label: {
      HStack(spacing: theme.space.xs) {
        Image(systemName: symbol)
          .imageScale(.small)
          .foregroundStyle(theme.color.text.secondary)
        Text(title)
          .font(theme.type.body.font)
          .foregroundStyle(theme.color.text.primary)
        Spacer(minLength: theme.space.xxs)
        if let shortcut {
          Text(shortcut)
            .font(theme.type.micro.font.monospaced())
            .foregroundStyle(theme.color.text.tertiary)
        }
      }
      .padding(.horizontal, theme.space.xs)
      .padding(.vertical, theme.space.xxs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(hoverBackground, in: shape)
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .disabled(action == nil)
    .onHover { isHovered = $0 }
    .animation(theme.motion.quick, value: isHovered)
  }

  private var hoverBackground: Color {
    isHovered && action != nil ? theme.color.bg.surfaceHover : .clear
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: theme.radius.sm, style: .continuous)
  }
}
