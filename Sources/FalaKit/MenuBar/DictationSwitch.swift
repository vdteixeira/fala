import Foundation
import Observation

/// Where the popover's on/off choice survives a relaunch.
///
/// Behind a protocol so the switch can be tested without writing to the user's
/// real `UserDefaults` — a test that flipped the shipping key would silently turn
/// the developer's own dictation off.
@MainActor
public protocol DictationEnabledStoring {
  func loadDictationEnabled() -> Bool
  func saveDictationEnabled(_ enabled: Bool)
}

@MainActor
public struct UserDefaultsDictationStore: DictationEnabledStoring {
  private static let key = "fala.dictationEnabled"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func loadDictationEnabled() -> Bool {
    // Absent means first run. `bool(forKey:)` would answer `false` there and ship
    // an app whose dictation is off until the user finds the toggle, so the
    // absent case is read explicitly and defaults to ON (mockup: "Ditado
    // ativado").
    defaults.object(forKey: Self.key) as? Bool ?? true
  }

  public func saveDictationEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: Self.key)
  }
}

/// The header toggle (DESIGN-HANDOFF.md §3: "disables capture globally").
///
/// It holds only the user's intent. What makes it real is `CaptureGate`, which
/// every hotkey phase has to pass through before it can reach the coordinator —
/// so "disabled" means `AudioCapture.start()` is never called, not that some view
/// hides a button.
@MainActor
@Observable
public final class DictationSwitch {
  public private(set) var isEnabled: Bool

  @ObservationIgnored private let store: any DictationEnabledStoring

  public init(store: any DictationEnabledStoring = UserDefaultsDictationStore()) {
    self.store = store
    self.isEnabled = store.loadDictationEnabled()
  }

  public func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    store.saveDictationEnabled(enabled)
  }

  public func toggle() {
    setEnabled(!isEnabled)
  }

  /// Header subtitle, pt-BR (mockup `dictLabel`).
  public var statusLabel: String {
    isEnabled ? "Ditado ativado" : "Ditado desativado"
  }
}

/// The one place a hotkey phase can be refused.
///
/// A value type on purpose: the whole policy is a two-case state machine, and a
/// value can be driven through a whole press/release sequence in a test.
///
/// The rule that matters is the RELEASE rule. Dropping a release because the
/// switch flipped mid-utterance would leave `AudioCapture` running with no event
/// left to stop it — the microphone stays open forever. That is exactly the class
/// of bug T1.7 already shipped once (both Option keys sharing `.maskAlternate`
/// lost the release), so this gate refuses presses and always lets a release
/// through when a capture is actually in flight.
public struct CaptureGate: Sendable, Equatable {
  /// True between an admitted press and its release.
  public private(set) var isCaptureInFlight: Bool

  public init() {
    self.isCaptureInFlight = false
  }

  /// The phase to forward to `DictationCoordinator`, or `nil` to drop it.
  public mutating func admit(_ phase: HotkeyPhase, dictationEnabled: Bool) -> HotkeyPhase? {
    switch phase {
    case .pressed:
      guard dictationEnabled else { return nil }
      isCaptureInFlight = true
      return .pressed
    case .released:
      // A release with nothing in flight is noise: the key was already down when
      // the app started, or its press was refused. Forwarding it would be
      // harmless today (the coordinator ignores it) but the drop is explicit so
      // it stays harmless.
      guard isCaptureInFlight else { return nil }
      isCaptureInFlight = false
      return .released
    }
  }
}
