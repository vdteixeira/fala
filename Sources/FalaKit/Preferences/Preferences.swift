import Foundation
import Observation

/// Where the Ajustes window's two own settings survive a relaunch.
///
/// Behind a protocol for the same reason `DictationEnabledStoring` and
/// `InputDeviceSelectionStoring` are: a test that wrote the shipping keys would
/// silently change the developer's own hotkey and hide their overlay.
///
/// # Why only two settings
///
/// This is not "the settings bag". Two preferences already have stores of their
/// own — dictation on/off (`DictationEnabledStoring`) and the chosen microphone
/// (`InputDeviceSelectionStoring`) — and re-declaring them here would give each
/// of them two sources of truth that drift the first time one writer forgets the
/// other. What lands here is exactly what had NO home:
///
/// - `showOverlay` — SPEC.md FR-21's `--no-overlay`. The pill is unconditional
///   today, so the mockup's "Mostrar overlay durante o ditado" toggle had nothing
///   to bind to.
/// - `hotkey` — SPEC.md FR-1 says the hotkey is configurable, but it was a
///   constructor parameter with no persistence, so every launch went back to
///   right-Option regardless of what the user picked.
///
/// `Sendable` rather than `@MainActor` (the shape `DictationEnabledStoring` uses)
/// because the CLI reads these outside any actor, and `Fala doctor` must be able
/// to report the hotkey the user actually configured.
public protocol PreferencesStoring: Sendable {
  func loadShowOverlay() -> Bool
  func saveShowOverlay(_ showOverlay: Bool)
  func loadHotkey() -> Hotkey
  func saveHotkey(_ hotkey: Hotkey)
}

/// The shipping store: `UserDefaults`, one key per preference.
///
/// Per key rather than one encoded blob so that writing one preference can never
/// clobber another that changed in between — and so a support answer can be
/// `defaults read com.fala.app fala.showOverlay` instead of a base64 dump.
public struct UserDefaultsPreferencesStore: PreferencesStoring {
  static let showOverlayKey = "fala.showOverlay"
  static let hotkeyKey = "fala.hotkey"

  /// Stored as a suite NAME rather than as a `UserDefaults` instance, for the
  /// reason `UserDefaultsInputDeviceStore` documents: `UserDefaults` is not
  /// `Sendable`, and this store has to be readable from outside the main actor.
  private let suiteName: String?

  /// - Parameter suiteName: overridable so tests never write the shipping keys.
  public init(suiteName: String? = nil) {
    self.suiteName = suiteName
  }

  private var defaults: UserDefaults {
    guard let suiteName, let suite = UserDefaults(suiteName: suiteName) else {
      return .standard
    }
    return suite
  }

  public func loadShowOverlay() -> Bool {
    // `object(forKey:)` rather than `bool(forKey:)`: the latter answers `false`
    // for an ABSENT key, which would ship an app whose overlay is invisible until
    // the user finds a toggle they have no reason to look for. Absent means first
    // run, and the first run shows the pill (FR-16).
    defaults.object(forKey: Self.showOverlayKey) as? Bool ?? Preferences.defaultShowOverlay
  }

  public func saveShowOverlay(_ showOverlay: Bool) {
    defaults.set(showOverlay, forKey: Self.showOverlayKey)
  }

  public func loadHotkey() -> Hotkey {
    // An unrecognised raw value is NOT an error to report: it is what a user gets
    // after `defaults write` with a typo, or after a future build drops a case.
    // Falling back keeps push-to-talk working; failing here would take dictation
    // away over a preference.
    guard
      let raw = defaults.string(forKey: Self.hotkeyKey),
      let hotkey = Hotkey(rawValue: raw)
    else { return Preferences.defaultHotkey }
    return hotkey
  }

  public func saveHotkey(_ hotkey: Hotkey) {
    defaults.set(hotkey.rawValue, forKey: Self.hotkeyKey)
  }
}

/// The observable façade the Ajustes window binds to (mockup: Ajustes › Geral).
///
/// Same shape as `DictationSwitch`: it holds the value, the store makes it
/// survive a relaunch, and a set that changes nothing writes nothing — so
/// re-rendering a toggle cannot spam the defaults database.
///
/// Holding the value does NOT make it true. `showOverlay` only means something
/// once the pipeline consults it before creating `PillOverlayController`, and
/// `hotkey` only means something once `HotkeyManager` is constructed with it;
/// both are the lead's wiring, not this type's.
@MainActor
@Observable
public final class Preferences {

  /// First run shows the pill: the overlay is the only surface a blocked or
  /// failed dictation has (US-3).
  ///
  /// `nonisolated` because the shipping store reads it, and that store is
  /// deliberately usable outside the main actor.
  public nonisolated static let defaultShowOverlay = true

  /// SPEC.md FR-1's default. Rarely bound by other software, and — unlike Fn —
  /// it does not collide with a system shortcut.
  public nonisolated static let defaultHotkey: Hotkey = .rightOption

  public private(set) var showOverlay: Bool
  public private(set) var hotkey: Hotkey

  @ObservationIgnored private let store: any PreferencesStoring

  public init(store: any PreferencesStoring = UserDefaultsPreferencesStore()) {
    self.store = store
    self.showOverlay = store.loadShowOverlay()
    self.hotkey = store.loadHotkey()
  }

  public func setShowOverlay(_ showOverlay: Bool) {
    guard showOverlay != self.showOverlay else { return }
    self.showOverlay = showOverlay
    store.saveShowOverlay(showOverlay)
  }

  public func toggleShowOverlay() {
    setShowOverlay(!showOverlay)
  }

  public func setHotkey(_ hotkey: Hotkey) {
    guard hotkey != self.hotkey else { return }
    self.hotkey = hotkey
    store.saveHotkey(hotkey)
  }
}
