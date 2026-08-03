import AppKit
import FalaKit
import SwiftUI

/// Owns the Ajustes window (TASKS.md T2.11).
///
/// # Window lifetime, which is where this class earns its keep
///
/// This is an LSUIElement app: there is no Dock icon to click and no document
/// to reopen, so every rule about windows has to be applied by hand.
///
///  * `isReleasedWhenClosed = false`. An `NSWindow` created in code defaults to
///    releasing itself on close; the menu item would then message a deallocated
///    window the second time the user opens Ajustes. That is the classic crash
///    this comment exists to prevent, and the reason the controller itself must
///    be held for the process lifetime by whoever creates it.
///  * `NSApp.activate()` before `makeKeyAndOrderFront`. An accessory app is not
///    active when its status item is clicked, and a window ordered front from an
///    inactive app opens BEHIND whatever the user was typing into and cannot
///    take the keyboard — so the hotkey recorder would never see a key.
///  * The frame is autosaved, and centred only the first time there is nothing
///    saved. A settings window that jumps back to the middle of the screen on
///    every open is a window the user has to move every time.
///  * `[.titled, .closable]` and nothing else. The mockup draws the zoom and
///    minimise buttons dimmed, and the content is a fixed 520pt column whose
///    height is whatever the selected tab needs — which `NSHostingController`'s
///    `.preferredContentSize` sizing supplies.
///
/// # Two things must be switched off when the window goes away
///
/// The hotkey recorder (a key monitor plus a suspended push-to-talk) and the
/// Áudio tab's microphone preview. Both are ended here rather than left to view
/// lifecycle: `windowWillClose` cancels the recorder and removes the monitor,
/// and `SettingsWindowModel.setVisible(false)` is what the Áudio tab's
/// `.task(id:)` keys on.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

  private let window: NSWindow
  private let windowModel = SettingsWindowModel()
  private let general: GeneralPanePresenter
  private let audio: AudioPanePresenter
  private let dictionary: DictionaryPanePresenter
  private let model: ModelPanePresenter

  /// The temporary key monitor the hotkey recorder needs. See `installMonitor`.
  /// `Any?` because that is what `NSEvent.addLocalMonitorForEvents` returns —
  /// an opaque token whose only use is `NSEvent.removeMonitor`.
  private var keyMonitor: Any?

  private static let frameAutosaveName = "FalaSettingsWindow"

  init(
    general: GeneralPanePresenter,
    audio: AudioPanePresenter,
    dictionary: DictionaryPanePresenter,
    model: ModelPanePresenter,
    actions: SettingsActions = SettingsActions()
  ) {
    self.general = general
    self.audio = audio
    self.dictionary = dictionary
    self.model = model

    // The close handler needs the window, which does not exist yet, and `self`
    // is not available until after `super.init`. A one-field box breaks the
    // knot without building the root view twice.
    let box = SettingsWindowBox()
    var resolved = actions
    if resolved.openURL == nil {
      resolved.openURL = { NSWorkspace.shared.open($0) }
    }
    resolved.closeWindow = { box.window?.performClose(nil) }

    let hosting = NSHostingController(
      rootView: AnyView(
        SettingsView(
          window: windowModel,
          general: general,
          audio: audio,
          dictionary: dictionary,
          model: model,
          actions: resolved
        ).falaTheme()))
    // Lets the window take the height SwiftUI computes for the selected tab;
    // the width is pinned to 520pt inside the view.
    hosting.sizingOptions = [.preferredContentSize]

    window = NSWindow(contentViewController: hosting)
    window.styleMask = [.titled, .closable]
    window.title = SettingsStrings.windowTitle
    // THE crash guard — see the type comment.
    window.isReleasedWhenClosed = false
    window.isExcludedFromWindowsMenu = false
    window.identifier = NSUserInterfaceItemIdentifier(Self.frameAutosaveName)

    super.init()

    window.delegate = self
    box.window = window

    // `SettingsActions` is the ONE thing the app fills in; these three
    // callbacks live on the presenters because that is where the sequencing is,
    // and they are connected here so the app never has to know that.
    // Assigned only when non-nil, so passing a partly-filled `SettingsActions`
    // cannot silently clear a handler someone else already set.
    if let handler = resolved.hotkeyRecordingChanged {
      general.onRecordingChanged = handler
    }
    if let handler = resolved.hotkeyChanged {
      general.onHotkeyChanged = handler
    }
    if let handler = resolved.dictionaryChanged {
      dictionary.onDictionaryChanged = handler
    }

    if !window.setFrameUsingName(Self.frameAutosaveName) {
      window.center()
    }
    _ = window.setFrameAutosaveName(Self.frameAutosaveName)
  }

  // MARK: - Showing

  /// Opens the window, or brings it forward if it is already open.
  ///
  /// Everything is re-read first: permissions-adjacent state (the login item),
  /// the dictionary file the user may have edited by hand, the model directory,
  /// and the device list. The window is only ever looked at for a few seconds,
  /// so paying for a refresh on every open is cheaper than being wrong once.
  func show() {
    general.refresh()
    audio.refresh()
    dictionary.reload()
    model.refresh()
    windowModel.setVisible(true)
    installMonitor()
    // Order matters: an accessory app must become active BEFORE the window is
    // ordered front, or it opens behind the frontmost app and never takes key.
    NSApplication.shared.activate()
    window.makeKeyAndOrderFront(nil)
  }

  // MARK: - NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    windowModel.setVisible(false)
    // Resumes push-to-talk. Without this, closing the window mid-recording
    // leaves dictation suspended until the next launch.
    general.cancelRecording()
    removeMonitor()
  }

  /// The user clicked into another app while the recorder was listening. Stop
  /// listening: the keys they press now belong to that app.
  func windowDidResignKey(_ notification: Notification) {
    general.cancelRecording()
  }

  // MARK: - The hotkey recorder's key source

  /// A LOCAL `NSEvent` monitor, not a `CGEventTap`.
  ///
  /// This is a deliberate difference from `HotkeyManager`. A tap needs
  /// Accessibility and sees every keystroke in every app; a local monitor sees
  /// only events already routed to Fala, which — while the settings window is
  /// key — is exactly the keys the user is pressing AT the recorder. It needs no
  /// permission and cannot observe anything typed anywhere else.
  ///
  /// PRIVACY: the handler reads `type`, `keyCode` and modifier flags. It never
  /// touches `event.characters`, so text typed into "Adicionar termo" is never
  /// looked at, let alone kept.
  private func installMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
      [weak self] event in
      guard let self, self.general.isRecording else { return event }
      guard let recorded = Self.recorderEvent(from: event) else { return event }
      // Anything the recorder acted on is swallowed: Escape must cancel the
      // recording rather than close the window, and a rejected key must not be
      // typed into whatever field happens to have focus.
      return self.general.receive(recorded) == .ignored ? event : nil
    }
  }

  private func removeMonitor() {
    guard let keyMonitor else { return }
    NSEvent.removeMonitor(keyMonitor)
    self.keyMonitor = nil
  }

  /// `NSEvent` → the pure event `HotkeyRecorder` understands.
  ///
  /// The flags come from the underlying `CGEvent` because `Hotkey` distinguishes
  /// the two Option keys by the device-dependent `NX_DEVICE*` bits, which
  /// `NSEvent.ModifierFlags` does not name. The fallback keeps those bits too:
  /// `NSEvent.modifierFlags.rawValue` carries them in its low bits, which is
  /// where `.deviceIndependentFlagsMask` exists to strip them from.
  private static func recorderEvent(from event: NSEvent) -> HotkeyRecorderEvent? {
    let keyCode = CGKeyCode(event.keyCode)
    switch event.type {
    case .flagsChanged:
      let flags =
        event.cgEvent?.flags ?? CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
      return .flagsChanged(keyCode: keyCode, flags: flags)
    case .keyDown:
      return .keyDown(keyCode: keyCode)
    default:
      return nil
    }
  }
}

/// A weak handle to the window, so an action closure built before the window
/// exists can still close it. One field, one purpose.
@MainActor
private final class SettingsWindowBox {
  weak var window: NSWindow?
}
