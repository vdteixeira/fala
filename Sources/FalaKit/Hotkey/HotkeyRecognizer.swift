import CoreGraphics

/// Keys usable as the push-to-talk trigger (SPEC.md FR-1).
///
/// All options are modifier keys: they arrive as `.flagsChanged` events rather than
/// key-down/key-up pairs, which is why press/release has to be derived from flag
/// transitions rather than read off the event type.
public enum Hotkey: String, Sendable, CaseIterable, Codable {
  /// Default. Chosen because it is rarely bound by other software.
  case rightOption
  case leftOption
  /// Documented alternative. Conflicts with the system emoji picker; the app must
  /// warn the user when this is selected (SPEC.md FR-1).
  case fn

  /// Virtual key codes (Carbon `kVK_*`), stable across keyboard layouts.
  public var keyCode: CGKeyCode {
    switch self {
    case .rightOption: return 0x3D
    case .leftOption: return 0x3A
    case .fn: return 0x3F
    }
  }

  /// The modifier bit that is set while the key is held.
  public var flag: CGEventFlags {
    switch self {
    case .rightOption, .leftOption: return .maskAlternate
    case .fn: return .maskSecondaryFn
    }
  }

  /// User-facing label, pt-BR (SPEC.md FR-1; matches the design mockups).
  public var displayName: String {
    switch self {
    case .rightOption: return "⌥ direito"
    case .leftOption: return "⌥ esquerdo"
    case .fn: return "Fn"
    }
  }

  public var conflictsWithSystemShortcut: Bool { self == .fn }
}

public enum HotkeyPhase: Sendable, Equatable {
  case pressed
  case released
}

/// The push-to-talk decision, isolated from `CGEventTap` so it can be unit-tested
/// (TASKS.md T1.7 DoD). The tap itself needs Accessibility and a signed bundle, and
/// is verified manually — this type is where the logic that can be wrong lives.
///
/// Left and right modifiers of the same kind share one flag bit, so the flag alone
/// cannot distinguish them. Correct detection needs BOTH: the key code identifies
/// which physical key changed, the flag says whether it went down or up.
public struct HotkeyRecognizer: Sendable, Equatable {
  public let hotkey: Hotkey
  public private(set) var isHeld: Bool

  public init(hotkey: Hotkey = .rightOption) {
    self.hotkey = hotkey
    self.isHeld = false
  }

  /// Feeds one `.flagsChanged` event.
  ///
  /// - Returns: the phase transition this event caused, or `nil` when the event is
  ///   about a different key or does not change our state. Returning `nil` for
  ///   repeats matters: the audio pipeline must not restart mid-utterance.
  public mutating func handleFlagsChanged(keyCode: CGKeyCode, flags: CGEventFlags) -> HotkeyPhase? {
    guard keyCode == hotkey.keyCode else { return nil }
    let nowHeld = flags.contains(hotkey.flag)
    guard nowHeld != isHeld else { return nil }
    isHeld = nowHeld
    return nowHeld ? .pressed : .released
  }

  /// Forces the key back up. Used when the tap is disabled or the app loses input
  /// focus, so a stuck-down state cannot leave the microphone recording forever.
  public mutating func reset() -> HotkeyPhase? {
    guard isHeld else { return nil }
    isHeld = false
    return .released
  }
}
