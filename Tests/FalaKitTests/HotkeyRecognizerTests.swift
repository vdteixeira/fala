import CoreGraphics
import Testing

@testable import FalaKit

@Suite("HotkeyRecognizer")
struct HotkeyRecognizerTests {

  @Test("Pressing and releasing the bound key yields exactly one transition each")
  func pressThenRelease() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)

    #expect(
      recognizer.handleFlagsChanged(keyCode: 0x3D, flags: Hotkey.rightOption.heldFlags) == .pressed)
    #expect(recognizer.isHeld)
    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: []) == .released)
    #expect(!recognizer.isHeld)
  }

  @Test("Repeated press events do not restart an in-progress utterance")
  func repeatedPressIsIgnored() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)

    #expect(
      recognizer.handleFlagsChanged(keyCode: 0x3D, flags: Hotkey.rightOption.heldFlags) == .pressed)
    #expect(
      recognizer.handleFlagsChanged(keyCode: 0x3D, flags: Hotkey.rightOption.heldFlags) == nil)
    #expect(
      recognizer.handleFlagsChanged(keyCode: 0x3D, flags: Hotkey.rightOption.heldFlags) == nil)
    #expect(recognizer.isHeld)
  }

  @Test("A release with no matching press is ignored")
  func unmatchedReleaseIsIgnored() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)
    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: []) == nil)
    #expect(!recognizer.isHeld)
  }

  /// The regression this whole type exists to prevent: both Option keys set
  /// `.maskAlternate`, so a flag-only check would fire on the wrong key.
  @Test("The left Option key does not trigger a right-Option binding")
  func leftOptionDoesNotTriggerRightOption() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)

    #expect(recognizer.handleFlagsChanged(keyCode: 0x3A, flags: Hotkey.leftOption.heldFlags) == nil)
    #expect(!recognizer.isHeld)
  }

  @Test("An unrelated modifier is ignored even while the hotkey is held")
  func unrelatedKeyIgnoredWhileHeld() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)
    #expect(
      recognizer.handleFlagsChanged(keyCode: 0x3D, flags: Hotkey.rightOption.heldFlags) == .pressed)

    // Shift pressed while dictating: different key code, must not change our state.
    let shifted: CGEventFlags = Hotkey.rightOption.heldFlags.union(.maskShift)
    #expect(recognizer.handleFlagsChanged(keyCode: 0x38, flags: shifted) == nil)
    #expect(recognizer.isHeld)

    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: .maskShift) == .released)
  }

  @Test("Other modifiers held alongside the hotkey do not block detection")
  func hotkeyDetectedAlongsideOtherModifiers() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)
    let combined: CGEventFlags = Hotkey.rightOption.heldFlags
      .union([.maskCommand, .maskShift])

    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: combined) == .pressed)
  }

  @Test("reset() releases a stuck key so the microphone cannot run forever")
  func resetReleasesHeldKey() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)
    #expect(
      recognizer.handleFlagsChanged(keyCode: 0x3D, flags: Hotkey.rightOption.heldFlags) == .pressed)

    #expect(recognizer.reset() == .released)
    #expect(!recognizer.isHeld)
    // Idempotent: nothing to release the second time.
    #expect(recognizer.reset() == nil)
  }

  @Test("Fn binding works and is flagged as conflicting with the emoji picker")
  func fnBinding() {
    var recognizer = HotkeyRecognizer(hotkey: .fn)
    #expect(recognizer.handleFlagsChanged(keyCode: 0x3F, flags: Hotkey.fn.heldFlags) == .pressed)
    #expect(Hotkey.fn.conflictsWithSystemShortcut)
    #expect(!Hotkey.rightOption.conflictsWithSystemShortcut)
  }

  @Test("Every hotkey has a distinct key code and a pt-BR label")
  func bindingsAreDistinctAndLabelled() {
    let codes = Hotkey.allCases.map(\.keyCode)
    #expect(Set(codes).count == codes.count)
    #expect(Hotkey.allCases.allSatisfy { !$0.displayName.isEmpty })
    #expect(Hotkey.rightOption.displayName == "⌥ direito")
  }

  /// THE regression that leaves the microphone recording forever.
  ///
  /// Both Option keys set `.maskAlternate`, so a recogniser that reads only that
  /// shared bit never sees the release when the OTHER Option key is still held —
  /// `isHeld` stays true, no `.released` is ever published, and capture never
  /// stops. Trigger: hold both Option keys, lift the right one first (a coin
  /// flip in practice). Verified to fail before the `deviceFlag` fix.
  @Test("Releasing the bound Option key while the other one is held still releases")
  func releaseDetectedWhileOtherOptionKeyHeld() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)
    let leftOnly = Hotkey.leftOption.heldFlags
    let bothHeld = leftOnly.union(Hotkey.rightOption.heldFlags)

    #expect(recognizer.handleFlagsChanged(keyCode: 0x3A, flags: leftOnly) == nil)
    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: bothHeld) == .pressed)

    // Right Option up, left still down: `.maskAlternate` remains SET.
    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: leftOnly) == .released)
    #expect(!recognizer.isHeld)
  }

  @Test("Pressing the bound key while the other Option key is already held is detected")
  func pressDetectedWhileOtherOptionKeyHeld() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)
    let leftOnly = Hotkey.leftOption.heldFlags

    // `.maskAlternate` is ALREADY set before our key goes down.
    #expect(recognizer.handleFlagsChanged(keyCode: 0x3A, flags: leftOnly) == nil)
    let both = leftOnly.union(Hotkey.rightOption.heldFlags)
    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: both) == .pressed)
  }

  @Test("Left and right variants of the same modifier use distinct device bits")
  func deviceFlagsAreDistinct() {
    #expect(Hotkey.leftOption.deviceFlag != Hotkey.rightOption.deviceFlag)
    #expect(Hotkey.leftOption.flag == Hotkey.rightOption.flag)
  }
}
