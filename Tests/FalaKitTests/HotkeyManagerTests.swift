import CoreGraphics
import Testing

@testable import FalaKit

/// Covers everything about the hotkey tap that can be tested without TCC.
///
/// What is NOT here, by nature: `CGEvent.tapCreate` itself, the real run-loop
/// source, and whether macOS actually leaves a `.listenOnly` tap out of the
/// event delivery path. Those need Accessibility and a signed .app bundle and
/// are verified by hand (TASKS.md T1.10).
@Suite("HotkeyManager")
@MainActor
struct HotkeyManagerTests {

  /// Closes the stream and drains everything it buffered.
  ///
  /// Deterministic and hang-free: `AsyncStream` buffers without bound, `yield`
  /// is synchronous, and `finish()` lets the `for await` loop end after the
  /// buffered elements — so this never waits on an event that will not come.
  private func drainPhases(_ manager: HotkeyManager) async -> [HotkeyPhase] {
    manager.shutdown()
    var phases: [HotkeyPhase] = []
    for await phase in manager.phases {
      phases.append(phase)
    }
    return phases
  }

  // MARK: Happy path

  @Test("A press and a release are published in order, exactly once each")
  func pressAndReleaseArePublished() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(hotkey: .rightOption, tap: tap)

    try manager.start()
    #expect(tap.isInstalled)
    tap.press(.rightOption)
    #expect(manager.isHotkeyHeld)
    tap.release(.rightOption)
    #expect(!manager.isHotkeyHeld)

    #expect(await drainPhases(manager) == [.pressed, .released])
  }

  @Test("Other modifiers held alongside the hotkey do not block detection")
  func otherModifiersDoNotBlockDetection() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(hotkey: .rightOption, tap: tap)

    try manager.start()
    // Shift stays down across the whole utterance, as it would while dictating
    // into a field the user had shift-selected in.
    tap.press(.rightOption, alongside: .maskShift)
    tap.release(.rightOption, remaining: .maskShift)

    #expect(await drainPhases(manager) == [.pressed, .released])
  }

  @Test("The configured hotkey is the one that fires, not the default")
  func configuredHotkeyIsHonoured() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(hotkey: .fn, tap: tap)

    try manager.start()
    // The default binding must be inert on this manager.
    tap.press(.rightOption)
    #expect(!manager.isHotkeyHeld)
    tap.press(.fn)
    tap.release(.fn)

    #expect(manager.hotkey == .fn)
    #expect(await drainPhases(manager) == [.pressed, .released])
  }

  /// Guards the wiring, not the recogniser: it proves the manager forwards the
  /// KEY CODE and not just the flag. Both Option keys set `.maskAlternate`, so a
  /// manager that dropped the key code would fire on the wrong physical key.
  @Test("The left Option key does not trigger a right-Option binding")
  func leftOptionDoesNotTriggerRightOption() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(hotkey: .rightOption, tap: tap)

    try manager.start()
    tap.press(.leftOption)

    #expect(!manager.isHotkeyHeld)
    #expect(await drainPhases(manager).isEmpty)
  }

  // MARK: Permissions

  @Test("A tap that cannot be created surfaces as a typed error, not a no-op")
  func tapCreationFailureThrows() async throws {
    let tap = MockEventTap()
    tap.installError = .accessibilityDenied
    let manager = HotkeyManager(tap: tap)

    #expect(throws: HotkeyError.accessibilityDenied) { try manager.start() }
    #expect(!manager.isRunning)
    #expect(tap.installCount == 0)
  }

  // MARK: Lifecycle

  @Test("start() twice is rejected and does not install a second tap")
  func startingTwiceIsRejected() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(tap: tap)

    try manager.start()
    #expect(throws: HotkeyError.alreadyRunning) { try manager.start() }
    #expect(tap.installCount == 1)
  }

  @Test("stop() removes the tap and a second start() reinstalls it")
  func stopThenStartWorks() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(tap: tap)

    try manager.start()
    manager.stop()
    #expect(!manager.isRunning)
    #expect(tap.uninstallCount == 1)
    #expect(!tap.isInstalled)

    try manager.start()
    #expect(tap.installCount == 2)
    tap.press(.rightOption)
    tap.release(.rightOption)

    #expect(await drainPhases(manager) == [.pressed, .released])
  }

  @Test("stop() is idempotent")
  func stopIsIdempotent() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(tap: tap)

    try manager.start()
    manager.stop()
    manager.stop()
    #expect(tap.uninstallCount == 1)
  }

  @Test("Signals arriving after stop() are ignored")
  func signalsAfterStopAreIgnored() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(tap: tap)

    try manager.start()
    manager.stop()
    // The mock keeps the handler alive on purpose, so these really do reach
    // HotkeyManager — a real invalidated tap could not deliver them.
    tap.press(.rightOption)
    tap.disableTap()

    #expect(!manager.isHotkeyHeld)
    #expect(tap.reenableCount == 0)
    #expect(await drainPhases(manager).isEmpty)
  }

  @Test("A new run never inherits a key held during the previous one")
  func newRunDoesNotInheritHeldKey() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(tap: tap)

    try manager.start()
    tap.press(.rightOption)
    manager.stop()
    try manager.start()
    #expect(!manager.isHotkeyHeld)

    // A stale key-up from the previous run must not register as a release.
    tap.release(.rightOption)

    #expect(await drainPhases(manager) == [.pressed, .released])
  }

  @Test("shutdown() is terminal and start() afterwards is refused")
  func shutdownIsTerminal() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(tap: tap)

    try manager.start()
    manager.shutdown()

    #expect(!manager.isRunning)
    #expect(tap.uninstallCount == 1)
    #expect(throws: HotkeyError.shutDown) { try manager.start() }
    #expect(tap.installCount == 1)
  }

  // MARK: The microphone-forever cases

  /// The single most important behaviour in this type. macOS disables a tap that
  /// was too slow, and the key-up of an in-flight utterance is then never
  /// delivered. Without the forced release the owner would record until the
  /// process died.
  @Test("A tap disabled mid-utterance is re-armed AND releases the held key")
  func disabledTapReleasesHeldKey() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(tap: tap)

    try manager.start()
    tap.press(.rightOption)
    #expect(manager.isHotkeyHeld)

    tap.disableTap()

    #expect(tap.reenableCount == 1)
    #expect(!manager.isHotkeyHeld)
    #expect(manager.tapDisabledRecoveries == 1)
    #expect(await drainPhases(manager) == [.pressed, .released])
  }

  @Test("A tap disabled while idle is re-armed without fabricating a release")
  func disabledTapWhileIdleIsSilent() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(tap: tap)

    try manager.start()
    tap.disableTap()
    tap.disableTap()

    #expect(tap.reenableCount == 2)
    #expect(manager.tapDisabledRecoveries == 2)
    #expect(await drainPhases(manager).isEmpty)
  }

  /// After a recovery the physical key is still down, so its key-up eventually
  /// arrives on the re-armed tap. It must not produce a second release: the
  /// owner would stop an utterance it never started.
  @Test("The real key-up after a recovery does not duplicate the release")
  func lateKeyUpAfterRecoveryIsSwallowed() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(tap: tap)

    try manager.start()
    tap.press(.rightOption)
    tap.disableTap()
    tap.release(.rightOption)

    #expect(await drainPhases(manager) == [.pressed, .released])
  }

  /// Same failure mode, different trigger: quitting or rebinding while the user
  /// still holds the key.
  @Test("stop() while the key is held publishes the release")
  func stopReleasesHeldKey() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(tap: tap)

    try manager.start()
    tap.press(.rightOption)
    manager.stop()

    #expect(!manager.isHotkeyHeld)
    #expect(await drainPhases(manager) == [.pressed, .released])
  }

  // MARK: Delivery

  @Test("Phases buffered before a consumer arrives are not dropped")
  func phasesAreBufferedForALateConsumer() async throws {
    let tap = MockEventTap()
    let manager = HotkeyManager(tap: tap)

    try manager.start()
    // Three full utterances with nobody reading the stream yet. Unbounded
    // buffering is what stops a `.released` from being dropped here.
    for _ in 0..<3 {
      tap.press(.rightOption)
      tap.release(.rightOption)
    }

    let phases = await drainPhases(manager)
    #expect(phases == [.pressed, .released, .pressed, .released, .pressed, .released])
  }
}
