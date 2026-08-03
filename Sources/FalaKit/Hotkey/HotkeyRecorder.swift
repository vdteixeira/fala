import CoreGraphics

/// One thing the recorder saw while it was listening.
///
/// Two cases because the two things it must react to arrive as different event
/// types: every valid hotkey is a MODIFIER, so it shows up as `.flagsChanged`
/// with no key-down at all, while Escape is an ordinary key and shows up as
/// `.keyDown`. A recorder fed only `.flagsChanged` could never be cancelled from
/// the keyboard.
public enum HotkeyRecorderEvent: Sendable, Equatable {
  /// A modifier changed. `flags` is the WHOLE modifier state, not just the key
  /// named by `keyCode` — the same shape `EventTapSignal.flagsChanged` delivers.
  case flagsChanged(keyCode: CGKeyCode, flags: CGEventFlags)
  /// An ordinary key went down.
  case keyDown(keyCode: CGKeyCode)
}

/// What an event did to the recorder. The caller acts on `.captured` (persist,
/// rebuild the event tap) and can ignore the rest.
public enum HotkeyRecorderOutcome: Sendable, Equatable {
  /// Nothing changed: the recorder was idle, or this was the release half of a
  /// modifier, or a key already refused once.
  case ignored
  /// Recording ended and this is the hotkey now. May carry the SAME hotkey as
  /// before — pressing the key that is already assigned is a legitimate way to
  /// leave the recorder without changing anything, so compare against the
  /// previous value before doing expensive work.
  case captured(Hotkey)
  /// Recording ended without a change (Escape, or `cancel()`).
  case cancelled
  /// The key is not one Fala can use. STILL RECORDING — the user gets to try
  /// again instead of having the recorder close under them. `reason` is pt-BR.
  case rejected(reason: String)
}

/// The keycap in Ajustes › Geral (mockup: "⌥ direito" + pencil, border pulsing
/// while recording) as a state machine, with no event tap in it.
///
/// A value type for the same reason `CaptureGate` is one: the whole thing is a
/// two-state machine, and a value can be driven through a complete
/// begin → reject → capture sequence in a test. Installing the temporary
/// `CGEventTap` that produces `HotkeyRecorderEvent`s needs Accessibility and a
/// signed bundle and is verified by hand; everything that can silently be WRONG
/// lives here.
///
/// # Only three keys are valid, and this type says so
///
/// Fala's hotkey is `Hotkey`, an enum of three modifier keys (SPEC.md FR-1). It
/// is NOT an arbitrary chord: push-to-talk needs a key whose press and release
/// both arrive as flag transitions, held for seconds at a time, and the pipeline
/// below this (`HotkeyRecognizer`, `HotkeyManager`) is built on exactly that.
/// So the recorder refuses everything else with a message naming the three that
/// work, rather than accepting ⌘⇧D and silently never firing.
///
/// ```swift
/// var recorder = HotkeyRecorder(hotkey: preferences.hotkey)
/// recorder.begin()
/// switch recorder.receive(.flagsChanged(keyCode: code, flags: flags)) {
/// case .captured(let hotkey): preferences.setHotkey(hotkey)
/// case .cancelled, .ignored: break
/// case .rejected(let reason): message = reason
/// }
/// ```
public struct HotkeyRecorder: Sendable, Equatable {

  /// `kVK_Escape`. Cancelling with Escape is standard macOS shortcut-recorder
  /// behaviour and the mockup gives the keycap no visible cancel affordance.
  public static let escapeKeyCode: CGKeyCode = 0x35

  /// The committed hotkey — what the keycap shows when it is not recording.
  public private(set) var hotkey: Hotkey

  /// True between `begin()` and the outcome that ends it. The view maps this to
  /// the pulsing border (`fala-pulse`, DESIGN-HANDOFF.md §6).
  public private(set) var isRecording: Bool

  /// The last key refused, so that press-then-release of one unusable key — and
  /// key repeat while it is held — produce ONE refusal instead of a flicker of
  /// identical messages.
  private var lastRejectedKeyCode: CGKeyCode?

  public init(hotkey: Hotkey = Preferences.defaultHotkey) {
    self.hotkey = hotkey
    self.isRecording = false
    self.lastRejectedKeyCode = nil
  }

  // MARK: - Driving it

  /// Starts listening. Idempotent: clicking the keycap twice does not restart
  /// anything, it just keeps recording.
  public mutating func begin() {
    guard !isRecording else { return }
    isRecording = true
    lastRejectedKeyCode = nil
  }

  /// Stops listening without changing the hotkey.
  ///
  /// The lead must call this when the window closes or loses key focus: a
  /// recorder left in `.recording` keeps a temporary event tap alive over every
  /// keystroke the user types into other apps.
  @discardableResult
  public mutating func cancel() -> HotkeyRecorderOutcome {
    guard isRecording else { return .ignored }
    isRecording = false
    lastRejectedKeyCode = nil
    return .cancelled
  }

  /// Feeds one event.
  public mutating func receive(_ event: HotkeyRecorderEvent) -> HotkeyRecorderOutcome {
    guard isRecording else { return .ignored }
    switch event {
    case .keyDown(let keyCode):
      guard keyCode != Self.escapeKeyCode else { return cancel() }
      return reject(keyCode)
    case .flagsChanged(let keyCode, let flags):
      guard let candidate = Hotkey.allCases.first(where: { $0.keyCode == keyCode }) else {
        return reject(keyCode)
      }
      // Commit on the way DOWN only. The release of the key the user was already
      // holding when they opened the recorder arrives here too, and committing on
      // it would assign a hotkey the user never pressed.
      guard flags.contains(candidate.deviceFlag) else { return .ignored }
      isRecording = false
      lastRejectedKeyCode = nil
      hotkey = candidate
      return .captured(candidate)
    }
  }

  private mutating func reject(_ keyCode: CGKeyCode) -> HotkeyRecorderOutcome {
    guard keyCode != lastRejectedKeyCode else { return .ignored }
    lastRejectedKeyCode = keyCode
    return .rejected(reason: Self.unsupportedKeyMessage)
  }

  // MARK: - What the view shows

  /// The keycap's text: the current hotkey, or the prompt while recording.
  public var keycapLabel: String {
    isRecording ? Self.recordingPrompt : hotkey.displayName
  }

  /// pt-BR warning about the committed hotkey, or `nil`. Non-nil only for Fn,
  /// which SPEC.md FR-1 requires the app to warn about because it also opens the
  /// system emoji picker.
  public var conflictWarning: String? {
    guard hotkey.conflictsWithSystemShortcut else { return nil }
    return Self.fnConflictMessage
  }

  // MARK: - Copy (pt-BR)

  static let recordingPrompt = "Pressione a tecla"

  /// Built from `Hotkey.allCases` rather than written out, so adding a fourth
  /// key updates the message instead of leaving it quietly wrong.
  static let unsupportedKeyMessage: String = {
    let names = Hotkey.allCases.map(\.displayName)
    return "Essa tecla não funciona como push-to-talk. Use \(list(names))."
  }()

  static let fnConflictMessage =
    "Fn também abre o seletor de emoji do sistema — os dois vão disputar a tecla."

  /// "a, b ou c" — the pt-BR list separator, which is not a comma before the
  /// last item.
  private static func list(_ items: [String]) -> String {
    guard let last = items.last else { return "" }
    guard items.count > 1 else { return last }
    return items.dropLast().joined(separator: ", ") + " ou " + last
  }
}
