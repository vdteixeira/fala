import Foundation

// The popover's quick actions and the app's key equivalents, as ONE vocabulary.
//
// The Phase 2 review caught the popover advertising "⌘ Q" and "⌘ ," while
// nothing in the app bound either key: the hints were literal strings in the
// view and no `NSMenu` existed. Both facts now come from `MenuBarCommand`, so a
// row cannot print a shortcut the main menu does not carry — and a row with no
// handler prints no shortcut at all.

/// A ⌘-based key equivalent, in the one form both AppKit and the popover need.
public struct MenuBarShortcut: Sendable, Equatable {
  /// Lowercase, exactly what `NSMenuItem.keyEquivalent` wants.
  public let key: Character

  public init(_ key: Character) {
    // `lowercased()` on a Character can widen (İ → i̇), so a multi-scalar result
    // is rejected rather than force-converted. Every shortcut here is ASCII.
    let lowered = key.lowercased()
    self.key = lowered.count == 1 ? Character(lowered) : key
  }

  /// `NSMenuItem.keyEquivalent`. The ⌘ modifier is implicit: every command here
  /// is a Command-key shortcut, and a modifier-less item would fire mid-typing.
  public var keyEquivalent: String { String(key) }

  /// What the popover prints, spaced as the mockup writes it ("⌘ Q", "⌘ ,").
  public var display: String { "⌘ " + String(key).uppercased() }
}

/// The three things the popover's quick-action list can do.
///
/// `allCases` is also the render order (Ajustes, Histórico, Sair) — the mockup's
/// order, with Sair appended because an LSUIElement app has no Dock icon and no
/// other way out.
public enum MenuBarCommand: String, Sendable, CaseIterable, Identifiable {
  case openSettings
  case openHistory
  case quit

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .openSettings: return MenuBarStrings.openSettings
    case .openHistory: return MenuBarStrings.openHistory
    case .quit: return MenuBarStrings.quit
    }
  }

  public var symbol: String {
    switch self {
    case .openSettings: return FalaSymbol.settings
    case .openHistory: return FalaSymbol.history
    case .quit: return FalaSymbol.power
    }
  }

  /// `nil` for a command with no key equivalent. Histórico has none in the
  /// mockup, and inventing one would put a third shortcut in the user's head.
  public var shortcut: MenuBarShortcut? {
    switch self {
    case .openSettings: return MenuBarShortcut(",")
    case .openHistory: return nil
    case .quit: return MenuBarShortcut("q")
    }
  }

  /// Identifies the command inside an `NSMenuItem.tag`, which is the only
  /// payload an AppKit menu item can carry back to a single `@objc` action.
  ///
  /// The values are written out rather than derived from `allCases.firstIndex`
  /// so that reordering the cases cannot silently re-point a menu item, and they
  /// start at 1: `tag` defaults to 0, so an item nobody configured can never be
  /// mistaken for a command.
  public var menuTag: Int {
    switch self {
    case .openSettings: return 1
    case .openHistory: return 2
    case .quit: return 3
    }
  }

  public static func command(forMenuTag tag: Int) -> MenuBarCommand? {
    allCases.first { $0.menuTag == tag }
  }
}

/// One resolved quick-action row.
///
/// `isEnabled` is the app's answer to "do I have a handler for this yet?" — the
/// surfaces that do not exist (Ajustes T2.6, Histórico T2.5) are represented
/// honestly as visibly dead rows rather than silently doing nothing.
public struct MenuBarQuickAction: Sendable, Equatable, Identifiable {
  public let command: MenuBarCommand
  public let isEnabled: Bool

  public init(command: MenuBarCommand, isEnabled: Bool) {
    self.command = command
    self.isEnabled = isEnabled
  }

  public var id: String { command.id }
  public var title: String { command.title }
  public var symbol: String { command.symbol }

  /// The ⌘ hint, shown ONLY while the row can actually run. A hint on a dead row
  /// is an advertisement for a key that does nothing — the review's finding.
  public var shortcutHint: String? {
    isEnabled ? command.shortcut?.display : nil
  }

  /// VoiceOver never sees the dimming, so the same fact is said in words.
  public var accessibilityHint: String? {
    isEnabled ? nil : MenuBarStrings.unavailableAction
  }

  /// Every row, in render order, with the app deciding which ones are live.
  public static func all(
    isEnabled: (MenuBarCommand) -> Bool
  ) -> [MenuBarQuickAction] {
    MenuBarCommand.allCases.map {
      MenuBarQuickAction(command: $0, isEnabled: isEnabled($0))
    }
  }
}
