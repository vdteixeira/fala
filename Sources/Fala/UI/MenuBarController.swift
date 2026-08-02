import AppKit
import FalaKit
import Observation
import SwiftUI

/// The status item and its popover (SPEC.md FR-15, TASKS.md T2.2).
///
/// Owns no logic: `MenuBarPresenter` decides what the surface says, this class
/// only draws the template image, opens the popover, and turns the popover's
/// callbacks into AppKit calls.
@MainActor
final class MenuBarController: NSObject {
  private let presenter: MenuBarPresenter
  private let statusItem: NSStatusItem
  private let popover = NSPopover()
  /// One image per variant. Drawing is cheap, but the icon is rebuilt on every
  /// state change and a menu-bar item redraws far more often than it changes.
  private var imageCache: [MenuBarIconVariant: NSImage] = [:]

  init(presenter: MenuBarPresenter, actions: MenuBarActions = MenuBarActions()) {
    self.presenter = presenter
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    super.init()

    configurePopover(actions: resolve(actions))
    configureStatusItem()
    updateIcon()
    trackIconChanges()
  }

  /// The status item outlives its controller otherwise — `NSStatusBar` holds it,
  /// not us — leaving a dead icon in the menu bar that nothing can click.
  ///
  /// Isolated `deinit` rather than `MainActor.assumeIsolated`: the latter TRAPS
  /// if the last release happens off the main thread, turning a leak into a
  /// crash. Same pattern as `HotkeyManager.deinit`.
  @MainActor deinit {
    NSStatusBar.system.removeStatusItem(statusItem)
  }

  // MARK: Wiring

  /// Fills in the handlers this class can implement itself. Anything still `nil`
  /// belongs to a surface that does not exist yet (Ajustes, Histórico) and its
  /// row stays visibly disabled.
  private func resolve(_ actions: MenuBarActions) -> MenuBarActions {
    var resolved = actions
    if resolved.quit == nil {
      resolved.quit = { NSApplication.shared.terminate(nil) }
    }
    if resolved.copyTranscription == nil {
      resolved.copyTranscription = { entry in
        MenuBarController.copyToPasteboard(entry.text)
      }
    }
    if resolved.grantPermissions == nil {
      resolved.grantPermissions = { [weak self] in
        self?.openPermissionSettings()
      }
    }
    return resolved
  }

  private func configureStatusItem() {
    guard let button = statusItem.button else { return }
    button.target = self
    button.action = #selector(togglePopover(_:))
    button.imagePosition = .imageOnly
  }

  private func configurePopover(actions: MenuBarActions) {
    let root = MenuBarPopoverView(presenter: presenter, actions: actions).falaTheme()
    let hosting = NSHostingController(rootView: AnyView(root))
    // Lets the popover take the height SwiftUI computes; the width is pinned to
    // 340pt inside the view (DESIGN-HANDOFF.md §1).
    hosting.sizingOptions = [.preferredContentSize]
    popover.contentViewController = hosting
    // Transient: clicking anywhere else dismisses it, which is what every other
    // menu-bar app does and what the HIG expects of a popover.
    popover.behavior = .transient
  }

  // MARK: Icon

  /// Rebuilds the icon whenever `iconVariant` changes, then re-arms itself —
  /// `withObservationTracking` fires exactly once per registration.
  private func trackIconChanges() {
    withObservationTracking {
      _ = presenter.iconVariant
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.updateIcon()
        self.trackIconChanges()
      }
    }
  }

  private func updateIcon() {
    guard let button = statusItem.button else { return }
    let variant = presenter.iconVariant
    button.image = image(for: variant)
    // The native "this is off" affordance, rather than a second slashed glyph.
    button.appearsDisabled = variant.appearsDisabled
    button.toolTip = variant.accessibilityLabel
    button.setAccessibilityLabel(variant.accessibilityLabel)
  }

  private func image(for variant: MenuBarIconVariant) -> NSImage {
    if let cached = imageCache[variant] { return cached }
    let image = MenuBarController.statusImage(for: variant)
    imageCache[variant] = image
    return image
  }

  /// The menu-bar mark: four waveform bars forming a speech quote mark, drawn in
  /// code as a TEMPLATE image (DESIGN-HANDOFF.md §5).
  ///
  /// Template means AppKit throws the colors away and tints the alpha mask for
  /// the current menu bar — light, dark, and the inverted look while a menu is
  /// open. That is why the fill below is a flat black and why the state is
  /// carried by bar height instead of by the six state tints.
  static func statusImage(for variant: MenuBarIconVariant) -> NSImage {
    let amplitude = variant.amplitude
    let image = NSImage(size: StatusIconMark.statusItemSize, flipped: false) { rect in
      let content = rect.insetBy(
        dx: StatusIconMark.contentInset, dy: StatusIconMark.contentInset)
      let mark = StatusIconMark.geometry(in: content, amplitude: amplitude)
      NSColor.black.setFill()
      for bar in mark.bars {
        NSBezierPath(
          roundedRect: bar, xRadius: mark.cornerRadius, yRadius: mark.cornerRadius
        ).fill()
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = variant.accessibilityLabel
    return image
  }

  // MARK: Actions

  @objc private func togglePopover(_ sender: Any?) {
    if popover.isShown {
      popover.performClose(sender)
    } else {
      showPopover()
    }
  }

  func showPopover() {
    guard let button = statusItem.button else { return }
    // Permissions and the model on disk can both have changed while the popover
    // was closed — a user who just granted Accessibility in System Settings must
    // not reopen this and still see the banner.
    Task { await presenter.refresh() }
    NSApplication.shared.activate()
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
  }

  private func openPermissionSettings() {
    guard let url = presenter.permissionsBanner?.settingsURL else { return }
    NSWorkspace.shared.open(url)
  }

  /// Copies one recent transcription.
  ///
  /// Same two precautions as `ClipboardInjector` (NFR-1): `.currentHostOnly`
  /// keeps the text off Universal Clipboard — i.e. off the user's other iCloud
  /// devices — and the concealed-type marker asks clipboard-history apps not to
  /// archive it. A plain `setString` would quietly ship a dictation to another
  /// machine, which is the one thing this app promises never to do.
  static func copyToPasteboard(_ text: String) {
    guard !text.isEmpty else { return }
    let board = NSPasteboard.general
    board.prepareForNewContents(with: .currentHostOnly)
    guard board.setString(text, forType: .string) else { return }
    board.setData(Data(), forType: NSPasteboard.PasteboardType(concealedType))
  }

  /// The convention password managers use; respected by Maccy, Raycast, Alfred
  /// and Paste.
  private static let concealedType = "org.nspasteboard.ConcealedType"
}
