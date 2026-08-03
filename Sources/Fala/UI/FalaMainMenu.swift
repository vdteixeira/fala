import AppKit
import FalaKit

/// The app's main menu, which exists ONLY to bind key equivalents.
///
/// Fala is LSUIElement / `.accessory`: it has no Dock icon and macOS never draws
/// this menu. But `NSApplication` still runs the main menu's
/// `performKeyEquivalent` while the app is active — which is exactly when the
/// popover is open and the user is reading "Sair do Fala ⌘ Q" on a row. Before
/// this, the popover advertised two shortcuts the app had never bound, and ⌘Q
/// (the first thing anyone reaches for in an app with no Dock icon) did nothing.
///
/// Nothing here decides anything: titles, keys and enablement all come from
/// `MenuBarCommand` and from the same `MenuBarActions` the popover rows use, so
/// the menu and the rows cannot disagree.
@MainActor
enum FalaMainMenu {
  /// - Parameters:
  ///   - target: receives `action` for every item. `NSMenuItem.target` is a WEAK
  ///     reference, so the caller must outlive the menu (`MenuBarController`
  ///     does — the app delegate holds it for the process lifetime).
  ///   - isEnabled: whether the app has a handler for that command yet.
  static func make(
    target: AnyObject,
    action: Selector,
    isEnabled: (MenuBarCommand) -> Bool
  ) -> NSMenu {
    let appMenu = NSMenu()
    // Explicit enablement rather than AppKit's automatic pass: the rule is
    // "there is a handler", which is the popover's rule too, and automatic
    // enabling would answer a different question (does anything in the
    // responder chain implement the selector).
    appMenu.autoenablesItems = false

    for command in MenuBarCommand.allCases {
      guard let shortcut = command.shortcut else { continue }
      let item = NSMenuItem(
        title: command.title, action: action, keyEquivalent: shortcut.keyEquivalent)
      item.keyEquivalentModifierMask = .command
      item.target = target
      item.tag = command.menuTag
      item.isEnabled = isEnabled(command)
      appMenu.addItem(item)
    }

    // The first item of a main menu is always the application menu, and its
    // TITLE is what macOS would show; the submenu is where items live.
    let appItem = NSMenuItem()
    appItem.submenu = appMenu
    let mainMenu = NSMenu(title: MenuBarStrings.brandName)
    mainMenu.addItem(appItem)
    return mainMenu
  }
}
