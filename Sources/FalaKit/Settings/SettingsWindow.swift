// The Ajustes window's shell: which tabs exist, in what order, what they are
// called, and the sub-token geometry the mockup writes inline.
//
// Translated from design/mockups/settings-window.dc.html (Surface 3) and
// DESIGN-HANDOFF.md §1. Nothing here draws; the SwiftUI views in Sources/Fala/UI
// read these values so no view ever names a size or a pt-BR string of its own.

import CoreGraphics
import Observation

/// The five tabs, in the mockup's order (`tabDefs` in its script block).
///
/// An enum rather than an array of structs so a tab can never be added to the
/// bar and forgotten in the content switch: `SettingsTabContent` in the view
/// layer switches over this exhaustively.
public enum SettingsTab: String, Sendable, Equatable, CaseIterable, Identifiable {
  case general
  case audio
  case dictionary
  case model
  case privacy

  public var id: String { rawValue }

  /// The tab bar's label (mockup: `label` on each `tabDefs` entry).
  public var title: String {
    switch self {
    case .general: return "Geral"
    case .audio: return "Áudio"
    case .dictionary: return "Dicionário"
    case .model: return "Modelo"
    case .privacy: return "Privacidade"
    }
  }

  /// The SF Symbol the handoff's icon map (§5) substitutes for the mockup's
  /// Material glyph. Read from `FalaSymbol` rather than written out, so a change
  /// to the map moves the tab bar with it.
  public var symbol: String {
    switch self {
    case .general: return FalaSymbol.settings
    case .audio: return FalaSymbol.idle
    case .dictionary: return FalaSymbol.dictionary
    case .model: return FalaSymbol.processor
    case .privacy: return FalaSymbol.privacyShield
    }
  }

  /// ⌘1…⌘5, the shortcut every tabbed macOS settings window binds.
  ///
  /// The mockup has no vocabulary for a keyboard shortcut; the HIG does, and a
  /// settings window that can only be navigated with the mouse fails it. Derived
  /// from the position so the sixth tab, if there ever is one, gets ⌘6 for free
  /// — and returns `nil` past ⌘9, which is not a digit key.
  public var shortcutKey: Character? {
    guard let index = Self.allCases.firstIndex(of: self), index < 9 else { return nil }
    return Character("\(index + 1)")
  }

  /// What VoiceOver reads for the tab button. The visible label alone would be
  /// announced as a plain button; this names the role the chip is playing.
  public var accessibilityLabel: String {
    "\(title), aba \(orderLabel) de \(Self.allCases.count)"
  }

  private var orderLabel: String {
    guard let index = Self.allCases.firstIndex(of: self) else { return "" }
    return "\(index + 1)"
  }
}

/// The tab bar as a value: the ordered items plus which one is on.
///
/// Pure so the bar's whole behaviour — selection, wrap-around for ⌃⇥, the
/// selected flag each chip renders — is assertable without a window.
public struct SettingsTabBar: Sendable, Equatable {

  public struct Item: Sendable, Equatable, Identifiable {
    public let tab: SettingsTab
    public let isSelected: Bool

    public var id: String { tab.id }
    public var title: String { tab.title }
    public var symbol: String { tab.symbol }
    public var shortcutKey: Character? { tab.shortcutKey }
    public var accessibilityLabel: String { tab.accessibilityLabel }
  }

  public private(set) var selected: SettingsTab

  public init(selected: SettingsTab = .general) {
    self.selected = selected
  }

  public var items: [Item] {
    SettingsTab.allCases.map { Item(tab: $0, isSelected: $0 == selected) }
  }

  /// - Returns: whether the selection actually moved. The view only animates a
  ///   real change, so re-clicking the current tab does not re-run the crossfade.
  @discardableResult
  public mutating func select(_ tab: SettingsTab) -> Bool {
    guard tab != selected else { return false }
    selected = tab
    return true
  }

  /// ⌃⇥ / ⌃⇧⇥ — wraps, like every macOS tab strip.
  public mutating func advance(by offset: Int) {
    let tabs = SettingsTab.allCases
    guard !tabs.isEmpty, let index = tabs.firstIndex(of: selected) else { return }
    let count = tabs.count
    let next = ((index + offset) % count + count) % count
    selected = tabs[next]
  }
}

/// The window's own observable state: which tab is showing, and whether the
/// window is on screen at all.
///
/// ## Why visibility is modelled explicitly
///
/// The Áudio tab holds the microphone open while it is showing. Relying on
/// SwiftUI to cancel its `.task` when an AppKit window closes means relying on
/// exactly when a hosted view is considered to have disappeared — and the cost
/// of being wrong is a microphone left open, with macOS's orange indicator lit,
/// over an app the user believes they closed. So the window controller states it
/// instead: `setVisible(false)` is a value change the tab's `.task(id:)` reacts
/// to, and nothing about it depends on view-lifecycle timing.
@MainActor
@Observable
public final class SettingsWindowModel {

  public private(set) var tabs: SettingsTabBar
  public private(set) var isVisible = false

  public init(selected: SettingsTab = .general) {
    self.tabs = SettingsTabBar(selected: selected)
  }

  public var selected: SettingsTab { tabs.selected }

  /// - Returns: whether the selection moved, so the caller can skip work that
  ///   only matters on a real change.
  @discardableResult
  public func select(_ tab: SettingsTab) -> Bool {
    tabs.select(tab)
  }

  public func advance(by offset: Int) {
    tabs.advance(by: offset)
  }

  public func setVisible(_ visible: Bool) {
    guard visible != isVisible else { return }
    isVisible = visible
  }
}

/// Sub-token geometry the mockup writes inline, in the spirit of `PillMetrics`
/// and `InputLevelMeterMetrics`: `tokens.json` has no entry for any of it, so it
/// gets one auditable home instead of being scattered through five views.
public enum SettingsLayout {
  /// "janela macOS 520px" (mockup header, DESIGN-HANDOFF.md §1).
  public static let windowWidth: CGFloat = 520

  /// `min-height: 240px` on the content column. A floor, not a fixed height:
  /// Privacidade is taller, and the window resizes to whatever the tab needs.
  public static let contentMinHeight: CGFloat = 240

  /// The 1px strokes the mockup draws around the list and under the tab bar.
  /// Same value and same reasoning as `MenuBarLayout.hairline`.
  public static let hairline: CGFloat = 1

  /// `font-size: 18px` on the tab glyphs and on every row's leading icon.
  public static let tabIconSize: CGFloat = 18
  /// `padding: var(--space-05) 10px` on a tab chip. The 10 is off the 8pt grid
  /// and has no token; it is named here rather than typed into the view.
  public static let tabChipHorizontalPadding: CGFloat = 10
  /// `gap: 2px` between a tab's icon and its label.
  public static let tabChipSpacing: CGFloat = 2
  /// `font-size: 20px` — the Modelo row's icon is one step larger.
  public static let rowIconSizeLarge: CGFloat = 20
  /// `font-size: 14px` — the icons inside list rows and small buttons.
  public static let smallIconSize: CGFloat = 14

  /// `height: 4px` on the download progress track.
  public static let progressTrackHeight: CGFloat = 4

  /// The Privacidade mark: a 72pt circle with a 34pt shield in it.
  public static let privacyMarkSize: CGFloat = 72
  public static let privacyMarkGlyphSize: CGFloat = 34
  /// `max-width: 380px` on the body copy and the reassurance rows.
  public static let privacyColumnWidth: CGFloat = 380
  /// The three bars of the contained waveform under the shield: 3px wide, 5/9/6
  /// tall, 2px apart, sitting 6px from the bottom of the circle.
  public static let privacyWaveformBarWidth: CGFloat = 3
  public static let privacyWaveformBarHeights: [CGFloat] = [5, 9, 6]
  public static let privacyWaveformBarSpacing: CGFloat = 2
  public static let privacyWaveformBottomInset: CGFloat = 6
  public static let privacyWaveformBarRadius: CGFloat = 1

  /// The jargon list gets its own scroller once it is taller than this; the
  /// bundled dictionary alone is ~43 rows, which would otherwise make the window
  /// taller than most screens.
  public static let dictionaryListMaxHeight: CGFloat = 220
}

/// Copy shared by the whole window (pt-BR by project rule).
public enum SettingsStrings {
  /// DESIGN-HANDOFF.md §7: the brand name appears in the window title, and comes
  /// from the one constant, so renaming the app renames this too.
  public static var windowTitle: String { "Ajustes — \(MenuBarStrings.brandName)" }

  /// VoiceOver name for the tab strip itself.
  public static let tabBarLabel = "Seções dos ajustes"

  /// Used wherever a destructive or irreversible action needs a plain "no".
  public static let cancel = "Cancelar"
}
