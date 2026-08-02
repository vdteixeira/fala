import CoreGraphics
import FalaKit

/// Test double for `EventTapControlling` (TASKS.md T1.7).
///
/// It exists so the whole hotkey state machine — including the disabled-tap
/// recovery that prevents a microphone recording forever — can be driven without
/// Accessibility, without a signed .app bundle, and without a human pressing a
/// key. The real `SystemEventTap` is not unit-testable (see the `swift-testing`
/// skill); this is the seam that keeps that untestable surface tiny.
///
/// `@MainActor` because `EventTapControlling` is: the production tap runs its
/// callback on the main run loop, so the protocol is main-actor isolated and
/// conformances must be too.
///
/// ```swift
/// let tap = MockEventTap()
/// let manager = HotkeyManager(tap: tap)
/// try manager.start()
/// tap.press(.rightOption)
/// tap.disableTap()          // macOS kills the tap mid-utterance
/// #expect(tap.reenableCount == 1)
/// ```
@MainActor
final class MockEventTap: EventTapControlling {

  // MARK: Configuration

  /// When set, every `install(handler:)` throws it. Models `CGEvent.tapCreate`
  /// returning nil because Accessibility was never granted.
  var installError: HotkeyError?

  // MARK: Recording

  private(set) var installCount = 0
  private(set) var uninstallCount = 0
  private(set) var reenableCount = 0

  /// Deliberately NOT cleared by `uninstall()`. A mock that forgets its handler
  /// would let "no events after stop()" pass for the wrong reason — the mock's
  /// bookkeeping instead of the manager's. Keeping it alive means `emit` after
  /// `stop()` really does reach `HotkeyManager`, so the guard there is what the
  /// test actually proves.
  private var handler: (@MainActor @Sendable (EventTapSignal) -> Void)?

  var isInstalled: Bool { installCount > uninstallCount }

  // MARK: EventTapControlling

  func install(handler: @escaping @MainActor @Sendable (EventTapSignal) -> Void) throws {
    if let installError { throw installError }
    self.handler = handler
    installCount += 1
  }

  func reenable() {
    reenableCount += 1
  }

  func uninstall() {
    uninstallCount += 1
  }

  // MARK: Driving the manager

  /// Simulates macOS delivering one event to the C callback.
  func emit(_ signal: EventTapSignal) {
    handler?(signal)
  }

  /// Presses `hotkey`. `alongside` adds other modifiers the user is holding,
  /// which a real `.flagsChanged` event always reports too.
  ///
  /// Uses `heldFlags` (generic bit + device-specific bit), because that is what
  /// macOS actually reports. Emitting only the generic `.maskAlternate` here
  /// would hide the class of bug where the recogniser cannot tell left Option
  /// from right Option — the one that left the microphone recording forever.
  func press(_ hotkey: Hotkey, alongside extra: CGEventFlags = []) {
    emit(.flagsChanged(keyCode: hotkey.keyCode, flags: hotkey.heldFlags.union(extra)))
  }

  /// Releases `hotkey`. `remaining` is whatever the user is still holding.
  func release(_ hotkey: Hotkey, remaining: CGEventFlags = []) {
    emit(.flagsChanged(keyCode: hotkey.keyCode, flags: remaining))
  }

  /// macOS switching the tap off (`.tapDisabledByTimeout` /
  /// `.tapDisabledByUserInput`). Both arrive as the same signal.
  func disableTap() {
    emit(.tapDisabled)
  }
}
