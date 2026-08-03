// The floating HUD window (SPEC.md FR-16, TASKS.md T2.3, DESIGN-HANDOFF.md §1).
//
// Visual per mockup: dark plum pill, bottom-centre, state icon + waveform/spinner
// + short pt-BR label + hotkey keycap, `--shadow-pop`, 20pt radius.
//
// Behaviour per HIG (these override the mockup, DESIGN.md conflict rule):
//   1. The panel NEVER becomes key or main. The user is dictating into another
//      app; a HUD that takes key window moves their caret, dismisses their menu,
//      and breaks the product. Hence `.nonactivatingPanel`, both `canBecome*`
//      overrides, `becomesKeyOnlyIfNeeded`, and `orderFrontRegardless()` instead
//      of `makeKeyAndOrderFront(_:)`.
//   2. It is click-through (`ignoresMouseEvents`). The mockup has no interaction
//      and a transparent band that swallowed clicks would be a bug the user could
//      not explain.
//   3. `backdrop-filter: blur(20px)` becomes a real SwiftUI material, per DESIGN.md.
//   4. The panel forces the dark appearance in both system appearances, because
//      the pill is the dark HUD material in both (§1) and the theme's content
//      tokens must resolve against it, not against the system's Light Mode.
//
// Requires the app to be an accessory/LSUIElement app (TASKS.md T2.2). Ordering
// this panel front from a regular app would put a Dock-visible app in front of
// whatever the user is typing into.

import AppKit
import FalaKit
import Observation
import SwiftUI

// MARK: - Panel

final class PillOverlayPanel: NSPanel {
  init(contentView: NSView) {
    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)

    isFloatingPanel = true
    becomesKeyOnlyIfNeeded = true
    level = .floating
    // Follows the user across Spaces and sits over full-screen apps, without
    // joining the window cycle or Exposé.
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    // SwiftUI draws `--shadow-pop` around the pill shape; an AppKit window shadow
    // would trace the transparent band instead.
    hasShadow = false
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    isMovable = false
    isMovableByWindowBackground = false
    isExcludedFromWindowsMenu = true
    isReleasedWhenClosed = false
    // Motion is the theme's job, gated on Reduce Motion. AppKit must not add its
    // own ungated fade on top.
    animationBehavior = .none
    appearance = NSAppearance(named: .darkAqua)

    self.contentView = contentView
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

// MARK: - Model

/// The one mutable thing the SwiftUI view observes.
@MainActor @Observable
final class PillOverlayModel {
  var content: PillOverlayContent = .hidden
}

// MARK: - Controller

/// Owns the panel, drives it from `DictationCoordinator.states()`, and applies the
/// auto-dismiss policy. All the decisions it makes are made by the pure types in
/// `FalaKit/Overlay`; what is left here is AppKit and timers.
@MainActor
final class PillOverlayController {
  private let model = PillOverlayModel()
  private let geometry: PillOverlayGeometry
  private let policy: PillDismissPolicy
  private let panel: PillOverlayPanel

  private var input: PillInput
  /// FR-21 "Mostrar overlay durante o ditado". Presentation-only: dictation keeps
  /// working while this is true, the user just does not see the pill.
  private var isSuppressed = false
  private var stateTask: Task<Void, Never>?
  private var dismissTask: Task<Void, Never>?
  private var orderOutTask: Task<Void, Never>?
  private var screenObserver: (any NSObjectProtocol)?

  init(
    hotkey: Hotkey = .rightOption,
    geometry: PillOverlayGeometry = .standard,
    policy: PillDismissPolicy = .standard
  ) {
    self.geometry = geometry
    self.policy = policy
    self.input = PillInput(hotkey: hotkey)

    let model = self.model
    let root =
      PillOverlayView(model: model)
      .falaTheme()
      // Outermost on purpose: `falaTheme()` reads `\.colorScheme` from ABOVE it,
      // so this is what makes the pill dark in Light Mode too.
      .environment(\.colorScheme, .dark)

    let hosting = NSHostingView(rootView: root)
    hosting.autoresizingMask = [.width, .height]
    self.panel = PillOverlayPanel(contentView: hosting)

    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // `queue: .main` guarantees the main thread, which is what the main actor
      // is. Displays being added, removed or rearranged must not crash the HUD.
      MainActor.assumeIsolated { self?.reposition() }
    }
  }

  // No `deinit`: a nonisolated deinit cannot touch main-actor state under Swift 6
  // strict concurrency, and the workarounds for that are exactly the unchecked
  // escapes this project bans. The observer's block captures `self` weakly, so
  // failing to call `stop()` orphans one closure — it does not retain the
  // controller and cannot resurrect the panel.

  // MARK: Wiring

  /// Follows a coordinator for as long as the controller lives. The stream yields
  /// the current state immediately, so the overlay is never out of sync with a
  /// dictation that started before it was attached.
  func attach(to coordinator: DictationCoordinator) {
    stateTask?.cancel()
    stateTask = Task { [weak self] in
      let states = await coordinator.states()
      for await state in states {
        guard let self else { return }
        self.update { $0.state = state }
      }
    }
  }

  /// FR-21 / Ajustes › Geral: "Mostrar overlay durante o ditado".
  ///
  /// Suppression is presentation-only — the coordinator keeps running and the
  /// user keeps dictating, they simply see nothing. Turning it back on picks up
  /// the current state from the stream, which is already live.
  /// Follows a hotkey change (Ajustes › Geral).
  ///
  /// The keycap the pill draws is the user's instruction for how to dictate, so
  /// leaving it on the old key after a rebind tells them to press something that
  /// no longer works.
  func setHotkey(_ hotkey: Hotkey) {
    guard input.hotkey != hotkey else { return }
    update { $0.hotkey = hotkey }
  }

  func setSuppressed(_ suppressed: Bool) {
    guard isSuppressed != suppressed else { return }
    isSuppressed = suppressed
    // Re-apply so turning it off hides an already-visible pill immediately, and
    // turning it back on picks up whatever the current state is.
    apply(PillOverlayContent.initial(for: input))
  }

  /// Told by the audio layer (TASKS.md T2.6) that the input route is Bluetooth
  /// HFP. Shows the persistent amber warning; never blocks dictation.
  func setAudioRouteDegraded(_ degraded: Bool) {
    guard input.audioRouteDegraded != degraded else { return }
    update { $0.audioRouteDegraded = degraded }
  }

  /// Stops following the coordinator, releases the screen observer, and takes the
  /// panel off screen.
  func stop() {
    stateTask?.cancel()
    dismissTask?.cancel()
    orderOutTask?.cancel()
    stateTask = nil
    dismissTask = nil
    orderOutTask = nil
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
      self.screenObserver = nil
    }
    model.content = .hidden
    panel.orderOut(nil)
  }

  // MARK: State

  private func update(_ mutate: (inout PillInput) -> Void) {
    mutate(&input)
    apply(PillOverlayContent.initial(for: input))
  }

  private func apply(_ next: PillOverlayContent) {
    setContent(next)
    scheduleDismissal(of: next)
  }

  private func setContent(_ content: PillOverlayContent) {
    // FR-21: the user asked not to see the overlay. Everything upstream keeps
    // running — this hides the panel, it does not stop the dictation.
    let next: PillOverlayContent = isSuppressed ? .hidden : content
    let previous = model.content
    guard previous != next else { return }

    if next.isVisible {
      orderOutTask?.cancel()
      orderOutTask = nil
      reposition()
      // Never `makeKeyAndOrderFront`: see the header note.
      panel.orderFrontRegardless()
    }

    let theme = currentTheme()
    let role = PillOverlayContent.motion(from: previous, to: next)
    withAnimation(animation(for: role, theme: theme)) { model.content = next }

    if !next.isVisible {
      scheduleOrderOut(after: theme.motion.dismiss == nil ? 0 : theme.motion.base.seconds)
    }
  }

  private func scheduleDismissal(of content: PillOverlayContent) {
    dismissTask?.cancel()
    dismissTask = nil
    guard let delay = policy.dismissal(for: content).delay else { return }

    dismissTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.dismissTask = nil
      // Forget the dictation state along with its pill. Without this the input
      // still says `.success` after the confirmation has gone, and the next
      // unrelated change — an audio route flipping to HFP, say — would rebuild
      // content from it and resurrect a "Texto inserido" pill minutes later.
      self.input = self.input.atRest
      // Not necessarily `.hidden`: a still-degraded route brings the warning
      // back and keeps it.
      self.apply(PillOverlayContent.resting(for: self.input))
    }
  }

  /// Takes the window off screen only after the exit animation has played, so the
  /// pill is not cut off mid-dismiss.
  private func scheduleOrderOut(after delay: TimeInterval) {
    orderOutTask?.cancel()
    orderOutTask = Task { [weak self] in
      if delay > 0 {
        try? await Task.sleep(for: .seconds(delay))
      }
      guard !Task.isCancelled, let self, !self.model.content.isVisible else { return }
      self.panel.orderOut(nil)
    }
  }

  // MARK: Placement

  /// The screen the user is on. `NSScreen.main` is the screen with the active
  /// window, which is exactly where a dictation HUD belongs; it changes as the
  /// user moves between displays, so this is re-read on every appearance.
  private var activeVisibleFrame: CGRect? {
    (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
  }

  private func reposition() {
    guard let visibleFrame = activeVisibleFrame else { return }
    let frame = geometry.panelFrame(in: visibleFrame)
    guard frame.width > 0, frame.height > 0 else { return }
    panel.setFrame(frame, display: false)
  }

  // MARK: Motion

  /// Built per transition rather than cached: Reduce Motion can be toggled while
  /// the app runs, and reading it late is the only way to honour that without
  /// observing yet another notification.
  private func currentTheme() -> Theme {
    Theme(
      appearance: .dark,
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
  }

  /// Every one of these is `nil` under Reduce Motion, and `withAnimation(nil)`
  /// means "apply instantly" — which is the specified reduced behaviour.
  private func animation(for role: PillMotionRole, theme: Theme) -> Animation? {
    switch role {
    case .enter: return theme.motion.appear
    case .exit: return theme.motion.dismiss
    case .change: return theme.motion.quick
    }
  }
}
