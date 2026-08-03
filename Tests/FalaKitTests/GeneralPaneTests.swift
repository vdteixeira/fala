import CoreGraphics
import Foundation
import Testing
import os

@testable import FalaKit

/// Ajustes › Geral (settings-window.dc.html, GERAL section).
///
/// The three rows each have a model of their own already; what is tested here is
/// the SEQUENCING only this presenter does — suspending push-to-talk while the
/// user is choosing a key, persisting a capture exactly once, and rebuilding the
/// event tap only when the key really changed.
@Suite("GeneralPane")
@MainActor
struct GeneralPaneTests {

  private static func makePresenter(
    hotkey: Hotkey = .rightOption,
    showOverlay: Bool = true,
    loginStatus: LoginItemStatus = .notRegistered
  ) -> (GeneralPanePresenter, RecordingPreferencesStore, FakeLoginItemRegistration) {
    let store = RecordingPreferencesStore(hotkey: hotkey, showOverlay: showOverlay)
    let registration = FakeLoginItemRegistration(status: loginStatus)
    let presenter = GeneralPanePresenter(
      preferences: Preferences(store: store),
      launch: LaunchAtLoginModel(item: makeBundledController(registration)))
    return (presenter, store, registration)
  }

  private static func press(_ hotkey: Hotkey) -> HotkeyRecorderEvent {
    .flagsChanged(keyCode: hotkey.keyCode, flags: hotkey.heldFlags)
  }

  // MARK: - The row, before anything is pressed

  @Test("The keycap shows the persisted hotkey, not the default")
  func keycapShowsThePersistedHotkey() {
    let (presenter, _, _) = Self.makePresenter(hotkey: .leftOption)
    #expect(presenter.keycapLabel == "⌥ esquerdo")
    #expect(!presenter.isRecording)
    #expect(presenter.hotkeyCaption == nil)
  }

  /// The mockup's own labels and the handoff's icon substitutions.
  @Test("The row copy and icons are the mockup's")
  func rowCopyMatchesTheMockup() {
    let (presenter, _, _) = Self.makePresenter()
    #expect(presenter.hotkeyTitle == "Atalho de ditado")
    #expect(presenter.hotkeySubtitle == "Segure para falar, solte para inserir")
    #expect(presenter.overlayTitle == "Mostrar overlay durante o ditado")
    #expect(presenter.overlaySubtitle == "Pílula flutuante na parte inferior da tela")
    #expect(presenter.hotkeySymbol == FalaSymbol.keyboard)
    #expect(presenter.overlaySymbol == FalaSymbol.pill)
    #expect(presenter.editSymbol == FalaSymbol.edit)
  }

  /// FR-1 requires a warning for Fn, and it must be visible whenever Fn is the
  /// committed key — not only in the instant it is captured.
  @Test("Fn carries its emoji-picker warning while it is the committed hotkey")
  func fnWarningIsPersistent() {
    let (presenter, _, _) = Self.makePresenter(hotkey: .fn)
    #expect(presenter.hotkeyCaption?.contains("emoji") == true)
    #expect(presenter.isHotkeyCaptionAProblem)
  }

  // MARK: - Suspending push-to-talk

  /// THE reason this presenter exists. While the recorder is listening, the key
  /// that is currently assigned is still a live global hotkey: without a
  /// suspension the user pressing ⌥ direito to re-record it starts a real
  /// dictation, opens the microphone, and injects text into whatever is behind
  /// the settings window.
  @Test("Recording is announced on both edges, exactly once each")
  func recordingIsAnnouncedOnBothEdges() {
    let (presenter, _, _) = Self.makePresenter()
    let log = OSAllocatedUnfairLock(initialState: [Bool]())
    presenter.onRecordingChanged = { value in log.withLock { $0.append(value) } }

    presenter.beginRecording()
    presenter.beginRecording()  // idempotent: a double click is one recording
    #expect(log.withLock { $0 } == [true])

    _ = presenter.receive(Self.press(.leftOption))
    #expect(log.withLock { $0 } == [true, false])
    #expect(!presenter.isRecording)
  }

  @Test("Cancelling a recording that never started announces nothing")
  func cancellingWhenIdleIsSilent() {
    let (presenter, _, _) = Self.makePresenter()
    let log = OSAllocatedUnfairLock(initialState: [Bool]())
    presenter.onRecordingChanged = { value in log.withLock { $0.append(value) } }
    presenter.cancelRecording()
    #expect(log.withLock { $0 }.isEmpty)
  }

  /// The window controller calls this on close and on resigning key. If it did
  /// not resume push-to-talk, closing the window mid-recording would leave
  /// dictation dead until the next launch.
  @Test("Cancelling while recording resumes push-to-talk")
  func cancellingWhileRecordingResumes() {
    let (presenter, _, _) = Self.makePresenter()
    let log = OSAllocatedUnfairLock(initialState: [Bool]())
    presenter.onRecordingChanged = { value in log.withLock { $0.append(value) } }
    presenter.beginRecording()
    presenter.cancelRecording()
    #expect(log.withLock { $0 } == [true, false])
  }

  // MARK: - Capturing

  @Test("A captured key is persisted and the app is told to rebuild the tap")
  func capturePersistsAndNotifies() {
    let (presenter, store, _) = Self.makePresenter(hotkey: .rightOption)
    let changes = OSAllocatedUnfairLock(initialState: [Hotkey]())
    presenter.onHotkeyChanged = { hotkey in changes.withLock { $0.append(hotkey) } }

    presenter.beginRecording()
    #expect(presenter.receive(Self.press(.fn)) == .captured(.fn))
    #expect(presenter.preferences.hotkey == .fn)
    #expect(store.savedHotkeys == [.fn])
    #expect(changes.withLock { $0 } == [.fn])
    #expect(presenter.keycapLabel == "Fn")
    // The conflict warning follows the newly committed key immediately.
    #expect(presenter.hotkeyCaption?.contains("emoji") == true)
  }

  /// `.captured` fires for the key that was ALREADY assigned — pressing it is a
  /// legitimate way to leave the recorder. Tearing down and rebuilding the event
  /// tap for that would momentarily kill the one thing the user is about to use.
  @Test("Re-pressing the assigned key ends recording without rebuilding anything")
  func recapturingTheSameKeyChangesNothing() {
    let (presenter, store, _) = Self.makePresenter(hotkey: .rightOption)
    let changes = OSAllocatedUnfairLock(initialState: [Hotkey]())
    presenter.onHotkeyChanged = { hotkey in changes.withLock { $0.append(hotkey) } }

    presenter.beginRecording()
    #expect(presenter.receive(Self.press(.rightOption)) == .captured(.rightOption))
    #expect(!presenter.isRecording)
    #expect(changes.withLock { $0 }.isEmpty)
    #expect(store.savedHotkeys.isEmpty)
  }

  @Test("Events arriving while the recorder is idle change nothing")
  func idlePresenterIsDeaf() {
    let (presenter, store, _) = Self.makePresenter(hotkey: .rightOption)
    #expect(presenter.receive(Self.press(.fn)) == .ignored)
    #expect(presenter.preferences.hotkey == .rightOption)
    #expect(store.savedHotkeys.isEmpty)
  }

  // MARK: - Refusals

  /// The recorder keeps listening after a refusal, so the message has to clear
  /// itself the moment something else happens — otherwise "essa tecla não
  /// funciona" stays under a keycap that now shows a perfectly good key.
  @Test("A refusal keeps recording, then clears when a usable key arrives")
  func refusalKeepsRecordingAndThenClears() {
    let (presenter, _, _) = Self.makePresenter()
    presenter.beginRecording()

    let shift = HotkeyRecorderEvent.flagsChanged(keyCode: 0x38, flags: .maskShift)
    guard case .rejected(let reason) = presenter.receive(shift) else {
      Issue.record("Shift should be refused")
      return
    }
    #expect(reason.contains("push-to-talk"))
    #expect(presenter.rejection == reason)
    #expect(presenter.isRecording)
    #expect(presenter.isHotkeyCaptionAProblem)

    _ = presenter.receive(Self.press(.leftOption))
    #expect(presenter.rejection == nil)
    #expect(presenter.hotkeyCaption == nil)
  }

  @Test("Escape cancels, clears the refusal and resumes push-to-talk")
  func escapeCancels() {
    let (presenter, _, _) = Self.makePresenter()
    let log = OSAllocatedUnfairLock(initialState: [Bool]())
    presenter.onRecordingChanged = { value in log.withLock { $0.append(value) } }
    presenter.beginRecording()
    _ = presenter.receive(.keyDown(keyCode: 0x38))
    #expect(presenter.rejection != nil)

    #expect(presenter.receive(.keyDown(keyCode: HotkeyRecorder.escapeKeyCode)) == .cancelled)
    #expect(!presenter.isRecording)
    #expect(presenter.rejection == nil)
    #expect(log.withLock { $0 } == [true, false])
  }

  @Test("Starting a new recording clears the previous refusal")
  func beginningAgainClearsTheRefusal() {
    let (presenter, _, _) = Self.makePresenter()
    presenter.beginRecording()
    _ = presenter.receive(.keyDown(keyCode: 0x38))
    #expect(presenter.rejection != nil)
    presenter.cancelRecording()
    presenter.beginRecording()
    #expect(presenter.rejection == nil)
  }

  // MARK: - The overlay row

  @Test("The overlay toggle writes through, and an unchanged set writes nothing")
  func overlayTogglePersists() {
    let (presenter, store, _) = Self.makePresenter(showOverlay: true)
    #expect(presenter.showOverlay)
    presenter.setShowOverlay(true)
    #expect(store.savedOverlay.isEmpty)
    presenter.setShowOverlay(false)
    #expect(!presenter.showOverlay)
    #expect(store.savedOverlay == [false])
  }

  // MARK: - The login row

  /// The switch has to reflect the SYSTEM, and Itens de Início is one System
  /// Settings pane away. `refresh()` is what the window calls on appear and on
  /// re-activation; without it the row keeps showing the state from launch.
  @Test("Refresh picks up a login item disabled behind the window's back")
  func refreshRereadsTheSystem() {
    let (presenter, _, registration) = Self.makePresenter(loginStatus: .enabled)
    #expect(presenter.launch.isOn)
    registration.currentStatus = .notRegistered
    presenter.refresh()
    #expect(!presenter.launch.isOn)
  }
}

/// A `PreferencesStoring` that records writes instead of touching the shipping
/// keys — a test that wrote them would change the developer's own hotkey.
private final class RecordingPreferencesStore: PreferencesStoring {
  private struct State {
    var hotkey: Hotkey
    var showOverlay: Bool
    var engine = Preferences.defaultEngine
    var savedHotkeys: [Hotkey] = []
    var savedOverlay: [Bool] = []
    var savedEngines: [TranscriptionEngineChoice] = []
  }

  private let state: OSAllocatedUnfairLock<State>

  init(hotkey: Hotkey = .rightOption, showOverlay: Bool = true) {
    self.state = OSAllocatedUnfairLock(
      initialState: State(hotkey: hotkey, showOverlay: showOverlay))
  }

  func loadShowOverlay() -> Bool { state.withLock { $0.showOverlay } }

  func saveShowOverlay(_ showOverlay: Bool) {
    state.withLock {
      $0.showOverlay = showOverlay
      $0.savedOverlay.append(showOverlay)
    }
  }

  func loadHotkey() -> Hotkey { state.withLock { $0.hotkey } }

  func saveHotkey(_ hotkey: Hotkey) {
    state.withLock {
      $0.hotkey = hotkey
      $0.savedHotkeys.append(hotkey)
    }
  }

  func loadEngine() -> TranscriptionEngineChoice { state.withLock { $0.engine } }

  /// Recorded like the others, so a future Geral change that touched the engine
  /// choice would be visible here instead of silent.
  func saveEngine(_ engine: TranscriptionEngineChoice) {
    state.withLock {
      $0.engine = engine
      $0.savedEngines.append(engine)
    }
  }

  var savedHotkeys: [Hotkey] { state.withLock { $0.savedHotkeys } }
  var savedOverlay: [Bool] { state.withLock { $0.savedOverlay } }
  var savedEngines: [TranscriptionEngineChoice] { state.withLock { $0.savedEngines } }
}
