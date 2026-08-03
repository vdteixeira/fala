import Foundation
import Testing
import os

@testable import FalaKit

/// Ajustes › Áudio (settings-window.dc.html, ÁUDIO section).
@Suite("AudioPane picker")
struct AudioPanePickerTests {

  static func device(
    id: String,
    name: String,
    isDefault: Bool = false,
    transport: AudioTransport = .builtIn,
    nominal: Double = 48_000
  ) -> InputDevice {
    InputDevice(
      id: id,
      name: name,
      isDefault: isDefault,
      transport: transport,
      nominalSampleRate: nominal,
      highestSupportedSampleRate: nominal,
      inputChannelCount: 1,
      hardwareID: 1)
  }

  /// The mockup's picker opens on three hardware rows. The real one opens on
  /// "Padrão do sistema" first: that is what a fresh install uses, and it is the
  /// only row that keeps working when the chosen device is unplugged.
  @Test("System default leads, then the hardware in catalog order")
  func systemDefaultLeads() {
    let devices = [
      Self.device(id: "builtin", name: "Microfone interno", isDefault: true),
      Self.device(id: "usb", name: "Focusrite", transport: .usb),
    ]
    let options = AudioPane.options(devices: devices, choice: .systemDefault)
    let labels = options.map(\.label)
    #expect(labels == ["Padrão do sistema", "Microfone interno (padrão)", "Focusrite"])
    let allAvailable = options.allSatisfy { $0.isAvailable }
    #expect(allAvailable)
    #expect(options[0].id == AudioDeviceOption.systemDefaultID)
  }

  /// THE case the mockup does not draw. The user picked a USB interface, then
  /// unplugged it. Dropping the row would make the picker snap to "Padrão do
  /// sistema" and look as though the choice was never saved — while
  /// `InputDeviceResolution` is in fact still holding it for the next time the
  /// device is attached.
  @Test("A saved device that is unplugged stays in the list, marked unavailable")
  func absentSavedDeviceStaysListed() {
    let devices = [Self.device(id: "builtin", name: "Microfone interno", isDefault: true)]
    let choice = InputDeviceChoice.device(uid: "usb", name: "Focusrite")
    let options = AudioPane.options(devices: devices, choice: choice)
    #expect(options.count == 3)
    #expect(options.last?.label == "Focusrite")
    #expect(options.last?.isAvailable == false)
    #expect(options.last?.id == "usb")
  }

  @Test("A Mac with no microphone offers only the system-default row, and says so")
  func noDeviceIsReported() {
    let pane = AudioPane(
      options: AudioPane.options(devices: [], choice: .systemDefault),
      selectionID: AudioDeviceOption.systemDefaultID,
      warning: nil,
      substitutionNotice: nil,
      level: .silence,
      meterError: nil,
      isMeterAvailable: true)
    #expect(pane.hasNoDevice)
    #expect(pane.noDeviceMessage == "Nenhum microfone disponível.")
  }

  /// A saved-but-absent device is not a microphone you can talk into, so it must
  /// not make the "no microphone" message disappear.
  @Test("An unplugged saved device does not count as a microphone")
  func absentDeviceIsNotAMicrophone() {
    let choice = InputDeviceChoice.device(uid: "usb", name: "Focusrite")
    let pane = AudioPane(
      options: AudioPane.options(devices: [], choice: choice),
      selectionID: "usb",
      warning: nil,
      substitutionNotice: nil,
      level: .silence,
      meterError: nil,
      isMeterAvailable: true)
    #expect(pane.hasNoDevice)
  }
}

@Suite("AudioPane meter")
struct AudioPaneMeterTests {

  private static func pane(
    level: AudioLevel,
    meterError: String? = nil,
    isMeterAvailable: Bool = true
  ) -> AudioPane {
    AudioPane(
      options: [.systemDefault],
      selectionID: AudioDeviceOption.systemDefaultID,
      warning: nil,
      substitutionNotice: nil,
      level: level,
      meterError: meterError,
      isMeterAvailable: isMeterAvailable)
  }

  /// The meter mapping belongs to `InputLevelMeter`; what is checked here is
  /// that the pane hands it the reading rather than a number of its own.
  @Test("The pane draws twelve segments through InputLevelMeter")
  func segmentsComeFromTheMeter() {
    let level = AudioLevel(rms: 0.1)
    let pane = Self.pane(level: level)
    #expect(pane.meterSegments.count == InputLevelMeter.segmentCount)
    #expect(pane.meterSegments == InputLevelMeter.segments(for: level))
  }

  /// Twelve unlabelled rectangles are nothing to VoiceOver. It reads a count,
  /// not a percentage: the meter IS twelve segments, and "67%" would send the
  /// user looking for a number that is not on screen.
  @Test("VoiceOver is told how many of the twelve segments are lit")
  func meterHasAnAccessibleValue() {
    #expect(Self.pane(level: .silence).meterAccessibilityValue == "0 de 12")
    #expect(Self.pane(level: AudioLevel(rms: 1)).meterAccessibilityValue == "12 de 12")
  }

  /// An empty meter has three different meanings, and the row has to say which.
  @Test("The caption distinguishes quiet, unavailable and failed")
  func captionDistinguishesTheEmptyStates() {
    let quiet = Self.pane(level: .silence)
    #expect(quiet.meterCaption == AudioPaneStrings.meterQuiet)
    #expect(!quiet.isMeterCaptionAProblem)

    let unavailable = Self.pane(level: .silence, isMeterAvailable: false)
    #expect(unavailable.meterCaption == AudioPaneStrings.meterUnavailable)
    #expect(!unavailable.isMeterCaptionAProblem)

    let failed = Self.pane(
      level: .silence, meterError: AudioPaneStrings.meterFailure(AudioCaptureError.noInputDevice))
    #expect(failed.meterCaption?.contains("nenhum microfone disponível") == true)
    #expect(failed.isMeterCaptionAProblem)
  }

  @Test("A live meter shows no caption at all")
  func liveMeterHasNoCaption() {
    #expect(Self.pane(level: AudioLevel(rms: 0.1)).meterCaption == nil)
  }

  /// The message names the cause. A bare "erro" would send the user to a support
  /// channel for something the row already knows.
  @Test("Every capture failure has a pt-BR reason")
  func failureMessagesAreSpecific() {
    let cases: [AudioCaptureError] = [
      .noInputDevice, .inputDeviceUnavailable, .voiceProcessingEnabled,
      .engineFailed(reason: "internal"), .alreadyRecording,
    ]
    for error in cases {
      let message = AudioPaneStrings.meterFailure(error)
      #expect(message.hasPrefix("Não foi possível abrir o microfone — "))
      #expect(message.hasSuffix("."))
      // The AVFoundation reason string is English and belongs in `doctor`.
      #expect(!message.contains("internal"))
    }
  }
}

@Suite("AudioPanePresenter")
@MainActor
struct AudioPanePresenterTests {

  private static func makeCenter(
    devices: [InputDevice] = [],
    choice: InputDeviceChoice = .systemDefault
  ) -> InputDeviceCenter {
    let center = InputDeviceCenter(
      catalog: FakeInputCatalog(devices: devices),
      watcher: SilentInputWatcher(),
      store: MemoryChoiceStore(choice: choice))
    center.refresh()
    return center
  }

  /// The mockup's `showHfp` — generalised past AirPods, because the sentence
  /// names the real device.
  @Test("The amber row appears only for a degraded route, and names the device")
  func warningTracksTheRoute() {
    let airpods = AudioPanePickerTests.device(
      id: "bt", name: "AirPods do Pedro", isDefault: true, transport: .bluetooth,
      nominal: 16_000)
    let degraded = AudioPanePresenter(devices: Self.makeCenter(devices: [airpods]))
    #expect(degraded.pane.warning?.message.contains("AirPods do Pedro") == true)
    #expect(degraded.pane.warning?.symbol == FalaSymbol.headphones)

    let builtIn = AudioPanePickerTests.device(
      id: "builtin", name: "Microfone interno", isDefault: true)
    let healthy = AudioPanePresenter(devices: Self.makeCenter(devices: [builtIn]))
    #expect(healthy.pane.warning == nil)
  }

  @Test("Selecting a row persists the choice through InputDeviceCenter")
  func selectingPersists() {
    let builtIn = AudioPanePickerTests.device(
      id: "builtin", name: "Microfone interno", isDefault: true)
    let usb = AudioPanePickerTests.device(id: "usb", name: "Focusrite", transport: .usb)
    let presenter = AudioPanePresenter(devices: Self.makeCenter(devices: [builtIn, usb]))

    presenter.select(optionID: "usb")
    #expect(presenter.pane.selectionID == "usb")
    presenter.select(optionID: AudioDeviceOption.systemDefaultID)
    #expect(presenter.devices.choice == .systemDefault)
  }

  @Test("An unknown row id is ignored rather than clearing the choice")
  func unknownSelectionIsIgnored() {
    let usb = AudioPanePickerTests.device(id: "usb", name: "Focusrite", transport: .usb)
    let presenter = AudioPanePresenter(
      devices: Self.makeCenter(devices: [usb], choice: .device(uid: "usb", name: "Focusrite")))
    presenter.select(optionID: "not-a-device")
    #expect(presenter.pane.selectionID == "usb")
  }

  /// Without a capture object there is nothing to measure. The tab still shows
  /// the picker and the HFP row; only the meter is explained away.
  @Test("With no capture object the meter says so and opens nothing")
  func meterIsExplainedWhenUnavailable() async {
    let presenter = AudioPanePresenter(devices: Self.makeCenter())
    #expect(!presenter.isMeterAvailable)
    await presenter.observeLevels()
    #expect(presenter.pane.meterCaption == AudioPaneStrings.meterUnavailable)
  }

  /// THE lifetime guarantee. The microphone opens when the tab appears and
  /// closes when the stream ends — no stop method anyone has to remember.
  @Test("The microphone opens for the preview and closes when the stream ends")
  func previewOpensAndCloses() async {
    let monitor = FakeLevelMonitor()
    let presenter = AudioPanePresenter(devices: Self.makeCenter(), monitor: monitor)
    let task = Task { await presenter.observeLevels() }

    // `isOpen` flips inside `startMonitoring()`, which is BEFORE the presenter
    // has subscribed. Waiting for the subscription instead is what makes this
    // test about the presenter rather than about scheduling luck.
    try? await Self.until { monitor.subscriberCount > 0 }
    #expect(monitor.isOpen)
    #expect(monitor.openCount == 1)

    monitor.emit(AudioLevel(rms: 0.1))
    try? await Self.until { presenter.level.rms > 0 }
    #expect(presenter.pane.litSegmentCount > 0)

    monitor.finish()
    await task.value
    #expect(!monitor.isOpen)
    #expect(monitor.closeCount == 1)
    // A stale reading left on screen would imply the device is still open.
    #expect(presenter.level == .silence)
  }

  /// What actually happens when the user closes the window or switches tabs:
  /// SwiftUI cancels the `.task`. Cancellation must still close the device —
  /// macOS's orange microphone indicator is the user's evidence either way.
  @Test("Cancelling the task closes the microphone")
  func cancellationClosesTheMicrophone() async {
    let monitor = FakeLevelMonitor()
    let presenter = AudioPanePresenter(devices: Self.makeCenter(), monitor: monitor)
    let task = Task { await presenter.observeLevels() }
    try? await Self.until { monitor.isOpen }

    task.cancel()
    await task.value
    #expect(!monitor.isOpen)
    #expect(monitor.closeCount == 1)
    #expect(presenter.level == .silence)
  }

  @Test("A refused microphone reports the reason and leaves nothing open")
  func failureIsReported() async {
    let monitor = FakeLevelMonitor(failure: .noInputDevice)
    let presenter = AudioPanePresenter(devices: Self.makeCenter(), monitor: monitor)
    await presenter.observeLevels()
    #expect(presenter.pane.isMeterCaptionAProblem)
    #expect(presenter.pane.meterCaption?.contains("nenhum microfone") == true)
    #expect(!monitor.isOpen)
    #expect(monitor.closeCount == 0)
  }

  /// Bounded spin: a broken presenter must fail the test, not hang the suite.
  private static func until(
    _ condition: @MainActor () -> Bool,
    attempts: Int = 2_000
  ) async throws {
    for _ in 0..<attempts {
      if condition() { return }
      await Task.yield()
    }
    Issue.record("condition never became true")
  }
}

// MARK: - Fakes

/// Stands in for `AudioCapture` as the meter sees it: it records whether the
/// microphone is open, and lets the test push readings.
private final class FakeLevelMonitor: AudioLevelMonitoring {
  private struct State {
    var isOpen = false
    var openCount = 0
    var closeCount = 0
    var continuations: [AsyncStream<AudioLevel>.Continuation] = []
    var lastLevel = AudioLevel.silence
    var failure: AudioCaptureError?
  }

  private let state: OSAllocatedUnfairLock<State>

  init(failure: AudioCaptureError? = nil) {
    self.state = OSAllocatedUnfairLock(initialState: State(failure: failure))
  }

  /// Replays the last reading to a new subscriber, exactly as
  /// `AudioCapture.levels()` does ("a meter that appears mid-dictation is never
  /// blank"). Without it this fake had a race the real thing does not: a test
  /// that emitted between `startMonitoring()` and the subscription would lose
  /// the value, and the meter would look broken when it was the fake that was.
  func levels() async -> AsyncStream<AudioLevel> {
    AsyncStream { continuation in
      state.withLock {
        $0.continuations.append(continuation)
        continuation.yield($0.lastLevel)
      }
    }
  }

  func startMonitoring() async throws {
    if let failure = state.withLock({ $0.failure }) { throw failure }
    state.withLock {
      $0.isOpen = true
      $0.openCount += 1
    }
  }

  func stopMonitoring() async {
    state.withLock {
      guard $0.isOpen else { return }
      $0.isOpen = false
      $0.closeCount += 1
    }
  }

  var isOpen: Bool { state.withLock { $0.isOpen } }
  var openCount: Int { state.withLock { $0.openCount } }
  var closeCount: Int { state.withLock { $0.closeCount } }

  var subscriberCount: Int { state.withLock { $0.continuations.count } }

  func emit(_ level: AudioLevel) {
    let continuations = state.withLock {
      $0.lastLevel = level
      return $0.continuations
    }
    for continuation in continuations { continuation.yield(level) }
  }

  func finish() {
    for continuation in state.withLock({ $0.continuations }) { continuation.finish() }
  }
}

private struct FakeInputCatalog: InputDeviceCataloging {
  let devices: [InputDevice]
  func inputDevices() throws -> [InputDevice] { devices }
}

/// The HAL never says anything in these tests; device changes have their own
/// suite in `InputDeviceTests`.
private struct SilentInputWatcher: InputDeviceChangeWatching {
  func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

private final class MemoryChoiceStore: InputDeviceSelectionStoring {
  private let state: OSAllocatedUnfairLock<InputDeviceChoice>

  init(choice: InputDeviceChoice) {
    self.state = OSAllocatedUnfairLock(initialState: choice)
  }

  func loadChoice() -> InputDeviceChoice { state.withLock { $0 } }
  func save(_ choice: InputDeviceChoice) { state.withLock { $0 = choice } }
}
