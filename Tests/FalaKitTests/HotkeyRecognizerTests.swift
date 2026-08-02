import CoreGraphics
import Testing

@testable import FalaKit

@Suite("HotkeyRecognizer")
struct HotkeyRecognizerTests {

  @Test("Pressing and releasing the bound key yields exactly one transition each")
  func pressThenRelease() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)

    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: .maskAlternate) == .pressed)
    #expect(recognizer.isHeld)
    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: []) == .released)
    #expect(!recognizer.isHeld)
  }

  @Test("Repeated press events do not restart an in-progress utterance")
  func repeatedPressIsIgnored() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)

    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: .maskAlternate) == .pressed)
    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: .maskAlternate) == nil)
    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: .maskAlternate) == nil)
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

    #expect(recognizer.handleFlagsChanged(keyCode: 0x3A, flags: .maskAlternate) == nil)
    #expect(!recognizer.isHeld)
  }

  @Test("An unrelated modifier is ignored even while the hotkey is held")
  func unrelatedKeyIgnoredWhileHeld() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)
    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: .maskAlternate) == .pressed)

    // Shift pressed while dictating: different key code, must not change our state.
    let shifted: CGEventFlags = [.maskAlternate, .maskShift]
    #expect(recognizer.handleFlagsChanged(keyCode: 0x38, flags: shifted) == nil)
    #expect(recognizer.isHeld)

    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: .maskShift) == .released)
  }

  @Test("Other modifiers held alongside the hotkey do not block detection")
  func hotkeyDetectedAlongsideOtherModifiers() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)
    let combined: CGEventFlags = [.maskAlternate, .maskCommand, .maskShift]

    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: combined) == .pressed)
  }

  @Test("reset() releases a stuck key so the microphone cannot run forever")
  func resetReleasesHeldKey() {
    var recognizer = HotkeyRecognizer(hotkey: .rightOption)
    #expect(recognizer.handleFlagsChanged(keyCode: 0x3D, flags: .maskAlternate) == .pressed)

    #expect(recognizer.reset() == .released)
    #expect(!recognizer.isHeld)
    // Idempotent: nothing to release the second time.
    #expect(recognizer.reset() == nil)
  }

  @Test("Fn binding works and is flagged as conflicting with the emoji picker")
  func fnBinding() {
    var recognizer = HotkeyRecognizer(hotkey: .fn)
    #expect(recognizer.handleFlagsChanged(keyCode: 0x3F, flags: .maskSecondaryFn) == .pressed)
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
}
