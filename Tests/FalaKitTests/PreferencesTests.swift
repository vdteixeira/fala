import Foundation
import Testing
import os

@testable import FalaKit

// The preferences the Ajustes window owns (SPEC.md FR-1 "configurable hotkey",
// FR-21 `--no-overlay`).
//
// Two things can silently be wrong here and both are pinned below: an ABSENT key
// must not read as `false`/nonsense (the `bool(forKey:)` trap that would ship an
// app with no overlay), and an unrecognised stored hotkey must degrade instead of
// taking push-to-talk away.

// MARK: - Test doubles

/// Counts writes so "setting the same value writes nothing" is assertable.
/// `Sendable` via a lock because `PreferencesStoring` is deliberately not
/// main-actor isolated (the CLI reads it).
private final class MemoryPreferencesStore: PreferencesStoring {
  private struct State {
    var showOverlay: Bool?
    var hotkey: Hotkey?
    var overlayWrites = 0
    var hotkeyWrites = 0
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  init(showOverlay: Bool? = nil, hotkey: Hotkey? = nil) {
    state.withLock {
      $0.showOverlay = showOverlay
      $0.hotkey = hotkey
    }
  }

  var overlayWrites: Int { state.withLock { $0.overlayWrites } }
  var hotkeyWrites: Int { state.withLock { $0.hotkeyWrites } }

  func loadShowOverlay() -> Bool {
    state.withLock { $0.showOverlay } ?? Preferences.defaultShowOverlay
  }

  func saveShowOverlay(_ showOverlay: Bool) {
    state.withLock {
      $0.showOverlay = showOverlay
      $0.overlayWrites += 1
    }
  }

  func loadHotkey() -> Hotkey {
    state.withLock { $0.hotkey } ?? Preferences.defaultHotkey
  }

  func saveHotkey(_ hotkey: Hotkey) {
    state.withLock {
      $0.hotkey = hotkey
      $0.hotkeyWrites += 1
    }
  }
}

/// A `UserDefaults` suite nobody else uses, removed when the test ends.
private func withScratchDefaults(_ body: (String) throws -> Void) rethrows {
  let suite = "fala.tests.preferences.\(UUID().uuidString)"
  defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
  try body(suite)
}

// MARK: - Defaults

@Suite struct PreferencesDefaultsTests {

  /// The trap this exists to prevent: `bool(forKey:)` answers `false` for an
  /// absent key, which would ship an app whose pill never appears until the user
  /// finds a toggle they have no reason to look for.
  @Test("An untouched store shows the overlay")
  func absentOverlayKeyMeansVisible() {
    withScratchDefaults { suite in
      let store = UserDefaultsPreferencesStore(suiteName: suite)
      #expect(store.loadShowOverlay())
      #expect(Preferences.defaultShowOverlay)
    }
  }

  @Test("An untouched store reports the FR-1 default hotkey")
  func absentHotkeyKeyMeansRightOption() {
    withScratchDefaults { suite in
      let store = UserDefaultsPreferencesStore(suiteName: suite)
      #expect(store.loadHotkey() == .rightOption)
    }
  }

  /// `defaults write com.fala.app fala.hotkey rightCommand`, or a future build
  /// that drops a case. Neither may cost the user push-to-talk.
  @Test("An unrecognised stored hotkey falls back instead of failing")
  func unknownHotkeyRawValueFallsBack() {
    withScratchDefaults { suite in
      UserDefaults(suiteName: suite)?
        .set("rightCommand", forKey: UserDefaultsPreferencesStore.hotkeyKey)
      #expect(UserDefaultsPreferencesStore(suiteName: suite).loadHotkey() == .rightOption)
    }
  }

  @Test("A non-boolean value in the overlay key falls back to visible")
  func wrongTypeInOverlayKeyFallsBack() {
    withScratchDefaults { suite in
      UserDefaults(suiteName: suite)?
        .set("talvez", forKey: UserDefaultsPreferencesStore.showOverlayKey)
      #expect(UserDefaultsPreferencesStore(suiteName: suite).loadShowOverlay())
    }
  }
}

// MARK: - Persistence

@Suite struct PreferencesPersistenceTests {

  @Test("Both preferences survive a new store instance")
  func valuesRoundTripThroughUserDefaults() {
    withScratchDefaults { suite in
      let writer = UserDefaultsPreferencesStore(suiteName: suite)
      writer.saveShowOverlay(false)
      writer.saveHotkey(.fn)

      let reader = UserDefaultsPreferencesStore(suiteName: suite)
      #expect(!reader.loadShowOverlay())
      #expect(reader.loadHotkey() == .fn)
    }
  }

  /// Per-key writes, so the window can save one row without reading and
  /// rewriting the other.
  @Test("Writing one preference leaves the other alone")
  func preferencesAreIndependent() {
    withScratchDefaults { suite in
      let store = UserDefaultsPreferencesStore(suiteName: suite)
      store.saveHotkey(.leftOption)
      store.saveShowOverlay(false)
      #expect(store.loadHotkey() == .leftOption)

      store.saveShowOverlay(true)
      #expect(store.loadHotkey() == .leftOption)
    }
  }

  @Test("Every hotkey survives the round trip")
  func everyHotkeyRoundTrips() {
    withScratchDefaults { suite in
      let store = UserDefaultsPreferencesStore(suiteName: suite)
      for hotkey in Hotkey.allCases {
        store.saveHotkey(hotkey)
        #expect(UserDefaultsPreferencesStore(suiteName: suite).loadHotkey() == hotkey)
      }
    }
  }

  /// The shipping keys are the ones the app and `defaults read` share, so a
  /// rename is a silent reset of everyone's preferences.
  @Test("The stored keys are namespaced and stable")
  func keysAreStable() {
    #expect(UserDefaultsPreferencesStore.showOverlayKey == "fala.showOverlay")
    #expect(UserDefaultsPreferencesStore.hotkeyKey == "fala.hotkey")
  }
}

// MARK: - The observable façade

@MainActor
@Suite struct PreferencesFacadeTests {

  @Test("It loads from the store at init")
  func initialValuesComeFromTheStore() {
    let store = MemoryPreferencesStore(showOverlay: false, hotkey: .leftOption)
    let preferences = Preferences(store: store)
    #expect(!preferences.showOverlay)
    #expect(preferences.hotkey == .leftOption)
    #expect(store.overlayWrites == 0)
    #expect(store.hotkeyWrites == 0)
  }

  @Test("A change is written through")
  func changesArePersisted() {
    let store = MemoryPreferencesStore()
    let preferences = Preferences(store: store)
    preferences.setShowOverlay(false)
    preferences.setHotkey(.fn)

    #expect(!store.loadShowOverlay())
    #expect(store.loadHotkey() == .fn)
    #expect(store.overlayWrites == 1)
    #expect(store.hotkeyWrites == 1)
  }

  /// A SwiftUI toggle re-applies its binding on every render; writing each time
  /// would hammer the defaults database for nothing.
  @Test("Setting the value it already has writes nothing")
  func idempotentSetsDoNotWrite() {
    let store = MemoryPreferencesStore(showOverlay: true, hotkey: .rightOption)
    let preferences = Preferences(store: store)
    preferences.setShowOverlay(true)
    preferences.setHotkey(.rightOption)
    #expect(store.overlayWrites == 0)
    #expect(store.hotkeyWrites == 0)
  }

  @Test("Toggling flips and persists")
  func toggleFlipsAndPersists() {
    let store = MemoryPreferencesStore()
    let preferences = Preferences(store: store)
    #expect(preferences.showOverlay)
    preferences.toggleShowOverlay()
    #expect(!preferences.showOverlay)
    #expect(!store.loadShowOverlay())
    preferences.toggleShowOverlay()
    #expect(preferences.showOverlay)
    #expect(store.overlayWrites == 2)
  }
}
