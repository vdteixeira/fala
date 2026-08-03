import CoreGraphics
import Testing

@testable import FalaKit

// The shortcut recorder in Ajustes › Geral (SPEC.md FR-1 "configurable"; mockup:
// keycap "⌥ direito" + pencil, border pulsing while recording).
//
// The temporary `CGEventTap` that produces these events needs Accessibility and
// a signed bundle and is verified by hand. What is tested here is everything
// that can silently be WRONG: which keys are acceptable, that a MODIFIER RELEASE
// never commits a hotkey the user did not press, that Escape gets out, and that
// an idle recorder is deaf.

@Suite struct HotkeyRecorderTests {

  /// The `.flagsChanged` event macOS delivers while `hotkey` is held down.
  private func pressed(_ hotkey: Hotkey) -> HotkeyRecorderEvent {
    .flagsChanged(keyCode: hotkey.keyCode, flags: hotkey.heldFlags)
  }

  /// Its release: same key code, our bit gone.
  private func released(_ hotkey: Hotkey) -> HotkeyRecorderEvent {
    .flagsChanged(keyCode: hotkey.keyCode, flags: [])
  }

  // MARK: - Idle

  @Test("An idle recorder ignores everything")
  func idleRecorderIsDeaf() {
    var recorder = HotkeyRecorder(hotkey: .rightOption)
    #expect(!recorder.isRecording)
    #expect(recorder.receive(pressed(.fn)) == .ignored)
    #expect(recorder.receive(.keyDown(keyCode: 0x00)) == .ignored)
    #expect(recorder.receive(.keyDown(keyCode: HotkeyRecorder.escapeKeyCode)) == .ignored)
    #expect(recorder.cancel() == .ignored)
    #expect(recorder.hotkey == .rightOption)
  }

  @Test("It starts on the hotkey it was given, and defaults to FR-1's")
  func initialHotkey() {
    #expect(HotkeyRecorder().hotkey == Preferences.defaultHotkey)
    #expect(HotkeyRecorder().hotkey == .rightOption)
    #expect(HotkeyRecorder(hotkey: .fn).hotkey == .fn)
  }

  @Test("begin() is idempotent")
  func beginTwiceKeepsRecording() {
    var recorder = HotkeyRecorder()
    recorder.begin()
    recorder.begin()
    #expect(recorder.isRecording)
    #expect(recorder.cancel() == .cancelled)
    #expect(!recorder.isRecording)
  }

  // MARK: - Capture

  @Test("Pressing a valid key captures it and ends recording")
  func pressCapturesAndEnds() {
    var recorder = HotkeyRecorder(hotkey: .rightOption)
    recorder.begin()
    #expect(recorder.receive(pressed(.leftOption)) == .captured(.leftOption))
    #expect(recorder.hotkey == .leftOption)
    #expect(!recorder.isRecording)
  }

  /// The model's whole point: `Hotkey` is the set of valid targets, so every one
  /// of its cases must be recordable and nothing else may be.
  @Test("Every Hotkey case is capturable")
  func everyHotkeyIsCapturable() {
    for hotkey in Hotkey.allCases {
      var recorder = HotkeyRecorder(hotkey: .rightOption)
      recorder.begin()
      #expect(recorder.receive(pressed(hotkey)) == .captured(hotkey))
      #expect(recorder.hotkey == hotkey)
    }
  }

  /// The user opened the recorder while still holding the current hotkey. Its
  /// RELEASE arrives first — committing on it would assign a key the user never
  /// pressed and close the recorder before they touched anything.
  @Test("A modifier RELEASE never captures")
  func releaseDoesNotCapture() {
    var recorder = HotkeyRecorder(hotkey: .rightOption)
    recorder.begin()
    #expect(recorder.receive(released(.rightOption)) == .ignored)
    #expect(recorder.receive(released(.leftOption)) == .ignored)
    #expect(recorder.isRecording)
    #expect(recorder.hotkey == .rightOption)
  }

  @Test("The release AFTER a capture is ignored")
  func trailingReleaseIsIgnored() {
    var recorder = HotkeyRecorder(hotkey: .rightOption)
    recorder.begin()
    #expect(recorder.receive(pressed(.fn)) == .captured(.fn))
    #expect(recorder.receive(released(.fn)) == .ignored)
    #expect(recorder.hotkey == .fn)
  }

  /// Both Option keys share `.maskAlternate`, so a recorder that looked at the
  /// generic bit would record "left" when the user pressed right.
  @Test("Left and right Option are told apart by the device bit")
  func optionKeysAreDistinguished() {
    var recorder = HotkeyRecorder(hotkey: .fn)
    recorder.begin()
    // The generic Option bit alone, on the right-Option key code: this is what
    // the OTHER Option key being held looks like, not a press of this one.
    #expect(
      recorder.receive(.flagsChanged(keyCode: Hotkey.rightOption.keyCode, flags: .maskAlternate))
        == .ignored)
    #expect(recorder.isRecording)
    #expect(recorder.receive(pressed(.rightOption)) == .captured(.rightOption))
  }

  /// Legitimate: it is how a user leaves the recorder without changing anything.
  /// The caller compares before/after rather than assuming a change.
  @Test("Re-pressing the current hotkey captures it unchanged")
  func recapturingTheSameKeyIsAllowed() {
    var recorder = HotkeyRecorder(hotkey: .rightOption)
    recorder.begin()
    #expect(recorder.receive(pressed(.rightOption)) == .captured(.rightOption))
    #expect(recorder.hotkey == .rightOption)
    #expect(!recorder.isRecording)
  }

  // MARK: - Cancelling

  @Test("Escape cancels and leaves the hotkey alone")
  func escapeCancels() {
    var recorder = HotkeyRecorder(hotkey: .leftOption)
    recorder.begin()
    #expect(recorder.receive(.keyDown(keyCode: HotkeyRecorder.escapeKeyCode)) == .cancelled)
    #expect(!recorder.isRecording)
    #expect(recorder.hotkey == .leftOption)
  }

  @Test("cancel() ends recording without a change")
  func explicitCancel() {
    var recorder = HotkeyRecorder(hotkey: .leftOption)
    recorder.begin()
    #expect(recorder.cancel() == .cancelled)
    #expect(!recorder.isRecording)
    #expect(recorder.hotkey == .leftOption)
  }

  @Test("Recording can be restarted after a cancel")
  func restartAfterCancel() {
    var recorder = HotkeyRecorder(hotkey: .rightOption)
    recorder.begin()
    #expect(recorder.cancel() == .cancelled)
    recorder.begin()
    #expect(recorder.receive(pressed(.fn)) == .captured(.fn))
  }

  // MARK: - Refusal

  @Test("An ordinary key is refused, and recording continues")
  func letterKeyIsRejected() {
    var recorder = HotkeyRecorder(hotkey: .rightOption)
    recorder.begin()
    // kVK_ANSI_A.
    let outcome = recorder.receive(.keyDown(keyCode: 0x00))
    #expect(outcome == .rejected(reason: HotkeyRecorder.unsupportedKeyMessage))
    #expect(recorder.isRecording)
    #expect(recorder.hotkey == .rightOption)
    // Still usable afterwards.
    #expect(recorder.receive(pressed(.leftOption)) == .captured(.leftOption))
  }

  /// Command, Shift and Control are modifiers, so they arrive as `.flagsChanged`
  /// like a valid key would. They are not in `Hotkey`, so they are refused —
  /// this is the model saying "no arbitrary chords" out loud.
  @Test("An unsupported modifier is refused, not captured")
  func unsupportedModifierIsRejected() {
    // kVK_Command, kVK_Shift, kVK_Control.
    for keyCode in [CGKeyCode(0x37), CGKeyCode(0x38), CGKeyCode(0x3B)] {
      var recorder = HotkeyRecorder(hotkey: .rightOption)
      recorder.begin()
      let outcome = recorder.receive(
        .flagsChanged(keyCode: keyCode, flags: [.maskCommand, .maskShift]))
      #expect(outcome == .rejected(reason: HotkeyRecorder.unsupportedKeyMessage))
      #expect(recorder.isRecording)
      #expect(recorder.hotkey == .rightOption)
    }
  }

  /// One press of an unusable key is one refusal: its release, and key repeat
  /// while it is held, must not flicker the same message three times.
  @Test("The same refused key only complains once")
  func repeatedRefusalIsSilent() {
    var recorder = HotkeyRecorder(hotkey: .rightOption)
    recorder.begin()
    #expect(recorder.receive(.keyDown(keyCode: 0x00)) != .ignored)
    #expect(recorder.receive(.keyDown(keyCode: 0x00)) == .ignored)
    #expect(recorder.receive(.keyDown(keyCode: 0x00)) == .ignored)
    // A DIFFERENT key is new information.
    #expect(recorder.receive(.keyDown(keyCode: 0x01)) != .ignored)
  }

  @Test("A refused modifier does not complain again on release")
  func modifierReleaseDoesNotRepeatTheRefusal() {
    var recorder = HotkeyRecorder(hotkey: .rightOption)
    recorder.begin()
    let down = CGKeyCode(0x37)
    #expect(recorder.receive(.flagsChanged(keyCode: down, flags: .maskCommand)) != .ignored)
    #expect(recorder.receive(.flagsChanged(keyCode: down, flags: [])) == .ignored)
  }

  @Test("Restarting recording clears the refusal memory")
  func refusalMemoryResetsOnBegin() {
    var recorder = HotkeyRecorder()
    recorder.begin()
    #expect(recorder.receive(.keyDown(keyCode: 0x00)) != .ignored)
    recorder.cancel()
    recorder.begin()
    #expect(recorder.receive(.keyDown(keyCode: 0x00)) != .ignored)
  }

  // MARK: - Copy (pt-BR)

  /// Built from `Hotkey.allCases`, so a fourth key updates the message instead
  /// of leaving it quietly wrong.
  @Test("The refusal names every key that does work")
  func refusalMessageNamesTheValidKeys() {
    let message = HotkeyRecorder.unsupportedKeyMessage
    for hotkey in Hotkey.allCases {
      #expect(message.contains(hotkey.displayName))
    }
    #expect(message.contains(" ou "))
    #expect(message.hasSuffix("."))
  }

  @Test("The keycap shows the hotkey, and a prompt while recording")
  func keycapLabelFollowsTheState() {
    var recorder = HotkeyRecorder(hotkey: .rightOption)
    #expect(recorder.keycapLabel == "⌥ direito")
    recorder.begin()
    #expect(recorder.keycapLabel == HotkeyRecorder.recordingPrompt)
    #expect(recorder.receive(pressed(.fn)) == .captured(.fn))
    #expect(recorder.keycapLabel == "Fn")
  }

  /// SPEC.md FR-1: the app must warn about Fn, which also opens the system emoji
  /// picker.
  @Test("Only Fn carries a conflict warning")
  func fnWarnsAboutTheEmojiPicker() {
    var recorder = HotkeyRecorder(hotkey: .rightOption)
    #expect(recorder.conflictWarning == nil)
    recorder.begin()
    #expect(recorder.receive(pressed(.fn)) == .captured(.fn))
    let warning = recorder.conflictWarning
    #expect(warning != nil)
    #expect(warning?.contains("emoji") == true)

    recorder.begin()
    #expect(recorder.receive(pressed(.leftOption)) == .captured(.leftOption))
    #expect(recorder.conflictWarning == nil)
  }
}
