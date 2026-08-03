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
    var engine: TranscriptionEngineChoice?
    var overlayWrites = 0
    var hotkeyWrites = 0
    var engineWrites = 0
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  init(
    showOverlay: Bool? = nil,
    hotkey: Hotkey? = nil,
    engine: TranscriptionEngineChoice? = nil
  ) {
    state.withLock {
      $0.showOverlay = showOverlay
      $0.hotkey = hotkey
      $0.engine = engine
    }
  }

  var overlayWrites: Int { state.withLock { $0.overlayWrites } }
  var hotkeyWrites: Int { state.withLock { $0.hotkeyWrites } }
  var engineWrites: Int { state.withLock { $0.engineWrites } }

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

  func loadEngine() -> TranscriptionEngineChoice {
    state.withLock { $0.engine } ?? Preferences.defaultEngine
  }

  func saveEngine(_ engine: TranscriptionEngineChoice) {
    state.withLock {
      $0.engine = engine
      $0.engineWrites += 1
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

  /// SPEC.md §2 is [CONFIRMED] on one engine for v1. The picker in Ajustes ›
  /// Modelo exists so the user can COMPARE, and a build that shipped with
  /// `.cohere` as the untouched default would be a silent architectural change
  /// wearing a preference's clothes — plus a model download on every fresh
  /// install that nobody agreed to.
  @Test("An untouched store reports Parakeet, the confirmed v1 engine")
  func absentEngineKeyMeansParakeet() {
    withScratchDefaults { suite in
      #expect(UserDefaultsPreferencesStore(suiteName: suite).loadEngine() == .parakeet)
    }
    #expect(Preferences.defaultEngine == .parakeet)
    // The enum's own idea of the default and the preference's must not drift.
    #expect(TranscriptionEngineChoice.default == Preferences.defaultEngine)
    #expect(TranscriptionEngineChoice.parakeet.isDefault)
    #expect(!TranscriptionEngineChoice.cohere.isDefault)
  }

  /// `defaults write com.fala.app fala.engine whisper`, or a build that dropped
  /// an engine. Neither may start dictation on an engine the user never picked —
  /// falling back to the documented default is the only safe answer.
  @Test("An unrecognised stored engine falls back to the default")
  func unknownEngineRawValueFallsBack() {
    withScratchDefaults { suite in
      UserDefaults(suiteName: suite)?
        .set("whisper", forKey: UserDefaultsPreferencesStore.engineKey)
      #expect(UserDefaultsPreferencesStore(suiteName: suite).loadEngine() == .parakeet)
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

  @Test("Every engine survives the round trip")
  func everyEngineRoundTrips() {
    withScratchDefaults { suite in
      let store = UserDefaultsPreferencesStore(suiteName: suite)
      for engine in TranscriptionEngineChoice.allCases {
        store.saveEngine(engine)
        #expect(UserDefaultsPreferencesStore(suiteName: suite).loadEngine() == engine)
      }
    }
  }

  /// A user who compared the two engines and preferred Cohere must not be put
  /// back on Parakeet by a relaunch — and the write must not disturb the two
  /// preferences that were already there.
  @Test("Choosing an engine survives a relaunch without touching the others")
  func engineIsIndependentAndPersistent() {
    withScratchDefaults { suite in
      let writer = UserDefaultsPreferencesStore(suiteName: suite)
      writer.saveHotkey(.fn)
      writer.saveShowOverlay(false)
      writer.saveEngine(.cohere)

      let reader = UserDefaultsPreferencesStore(suiteName: suite)
      #expect(reader.loadEngine() == .cohere)
      #expect(reader.loadHotkey() == .fn)
      #expect(!reader.loadShowOverlay())
    }
  }

  /// The shipping keys are the ones the app and `defaults read` share, so a
  /// rename is a silent reset of everyone's preferences.
  @Test("The stored keys are namespaced and stable")
  func keysAreStable() {
    #expect(UserDefaultsPreferencesStore.showOverlayKey == "fala.showOverlay")
    #expect(UserDefaultsPreferencesStore.hotkeyKey == "fala.hotkey")
    #expect(UserDefaultsPreferencesStore.engineKey == "fala.engine")
  }
}

// MARK: - The observable façade

@MainActor
@Suite struct PreferencesFacadeTests {

  @Test("It loads from the store at init")
  func initialValuesComeFromTheStore() {
    let store = MemoryPreferencesStore(showOverlay: false, hotkey: .leftOption, engine: .cohere)
    let preferences = Preferences(store: store)
    #expect(!preferences.showOverlay)
    #expect(preferences.hotkey == .leftOption)
    #expect(preferences.engine == .cohere)
    #expect(store.overlayWrites == 0)
    #expect(store.hotkeyWrites == 0)
    #expect(store.engineWrites == 0)
  }

  @Test("An untouched façade starts on the confirmed default engine")
  func facadeDefaultsToParakeet() {
    #expect(Preferences(store: MemoryPreferencesStore()).engine == .parakeet)
  }

  @Test("A change is written through")
  func changesArePersisted() {
    let store = MemoryPreferencesStore()
    let preferences = Preferences(store: store)
    preferences.setShowOverlay(false)
    preferences.setHotkey(.fn)
    preferences.setEngine(.cohere)

    #expect(!store.loadShowOverlay())
    #expect(store.loadHotkey() == .fn)
    #expect(store.loadEngine() == .cohere)
    #expect(store.overlayWrites == 1)
    #expect(store.hotkeyWrites == 1)
    #expect(store.engineWrites == 1)
  }

  /// A SwiftUI toggle re-applies its binding on every render; writing each time
  /// would hammer the defaults database for nothing.
  @Test("Setting the value it already has writes nothing")
  func idempotentSetsDoNotWrite() {
    let store = MemoryPreferencesStore(showOverlay: true, hotkey: .rightOption, engine: .parakeet)
    let preferences = Preferences(store: store)
    preferences.setShowOverlay(true)
    preferences.setHotkey(.rightOption)
    preferences.setEngine(.parakeet)
    #expect(store.overlayWrites == 0)
    #expect(store.hotkeyWrites == 0)
    #expect(store.engineWrites == 0)
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
