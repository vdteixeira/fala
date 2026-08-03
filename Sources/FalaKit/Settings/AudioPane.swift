import Foundation
import Observation

/// Every fixed string of Ajustes › Áudio (mockup: the ÁUDIO section).
///
/// The amber row's own words are NOT here: they belong to `AudioRouteWarning`,
/// which the pill and `doctor` also read, so all three surfaces say the same
/// sentence about the same headset.
public enum AudioPaneStrings {
  public static let deviceTitle = "Dispositivo de entrada"
  public static let devicePickerHelp = "Escolher o microfone usado no ditado"
  public static let levelTitle = "Nível de entrada"

  /// Under the meter when nothing is arriving yet. Not an error: the microphone
  /// is open and quiet, which is what an empty meter should mean.
  public static let meterQuiet = "Fale para ver o nível."

  /// Under the meter when the app has no capture object to measure — the state
  /// of a launch where Accessibility was never granted, so the pipeline stopped
  /// before it built one.
  public static let meterUnavailable =
    "O medidor aparece quando o \(MenuBarStrings.brandName) está pronto para ditar."

  /// The microphone could not be opened for the preview. Prefixed to the
  /// specific reason so the row says what happened and why.
  public static func meterFailure(_ error: any Error) -> String {
    "Não foi possível abrir o microfone — \(reason(for: error))"
  }

  private static func reason(for error: any Error) -> String {
    guard let error = error as? AudioCaptureError else {
      return "erro inesperado."
    }
    switch error {
    case .noInputDevice:
      return "nenhum microfone disponível."
    case .inputDeviceUnavailable:
      return "o microfone escolhido não aceitou a conexão."
    case .voiceProcessingEnabled:
      return "o processamento de voz do sistema está ligado."
    case .engineFailed:
      // The underlying reason is an AVFoundation string in English; it goes to
      // `doctor`, not to a settings row.
      return "o mecanismo de áudio recusou."
    case .alreadyRecording, .notRecording:
      return "o microfone está em uso pelo ditado."
    }
  }
}

/// One row of the device picker.
///
/// `isAvailable` exists for the case the mockup does not draw: the user picked a
/// microphone that is currently unplugged. The option stays in the list, marked,
/// rather than vanishing — a picker that silently jumps to "Padrão do sistema"
/// makes it look as though the choice was never saved, when in fact
/// `InputDeviceResolution` is falling back for exactly this run.
public struct AudioDeviceOption: Sendable, Equatable, Identifiable {
  /// The device UID, or `AudioDeviceOption.systemDefaultID` for the first row.
  public let id: String
  public let label: String
  public let choice: InputDeviceChoice
  public let isAvailable: Bool

  public init(id: String, label: String, choice: InputDeviceChoice, isAvailable: Bool) {
    self.id = id
    self.label = label
    self.choice = choice
    self.isAvailable = isAvailable
  }

  /// Not a UID any device can have: CoreAudio UIDs are never empty, and this
  /// keeps the picker's tag type a plain `String`.
  public static let systemDefaultID = ""

  public static let systemDefault = AudioDeviceOption(
    id: systemDefaultID,
    label: InputDeviceStrings.followSystemDefault,
    choice: .systemDefault,
    isAvailable: true)
}

/// Everything Ajustes › Áudio renders, as one value.
public struct AudioPane: Sendable, Equatable {
  public let options: [AudioDeviceOption]
  public let selectionID: String
  /// The amber row, or `nil`. Present exactly when the route is degraded —
  /// which is the mockup's `showHfp`, generalised past AirPods.
  public let warning: AudioRouteWarning?
  /// "X não está disponível — usando o padrão do sistema.", or `nil`.
  public let substitutionNotice: String?
  public let level: AudioLevel
  /// Non-nil when the preview could not be started.
  public let meterError: String?
  /// False when there is no capture object to measure at all.
  public let isMeterAvailable: Bool

  public init(
    options: [AudioDeviceOption],
    selectionID: String,
    warning: AudioRouteWarning?,
    substitutionNotice: String?,
    level: AudioLevel,
    meterError: String?,
    isMeterAvailable: Bool
  ) {
    self.options = options
    self.selectionID = selectionID
    self.warning = warning
    self.substitutionNotice = substitutionNotice
    self.level = level
    self.meterError = meterError
    self.isMeterAvailable = isMeterAvailable
  }

  // MARK: - The picker

  public var deviceSymbol: String { FalaSymbol.idle }
  public var levelSymbol: String { FalaSymbol.recording }

  /// True when no microphone is attached: every option is either the
  /// system-default row or a saved device that is not here. The picker is then
  /// disabled and the row says so, instead of offering one dead choice.
  public var hasNoDevice: Bool {
    !options.contains { $0.isAvailable && $0.choice != .systemDefault }
  }

  /// Replaces the picker when `hasNoDevice`.
  public var noDeviceMessage: String { InputDeviceStrings.noInputDevice }

  /// Builds the picker's rows.
  ///
  /// Order: "Padrão do sistema" first (it is what a fresh install uses), then the
  /// hardware in catalog order, then — only if needed — the saved-but-absent
  /// device.
  public static func options(
    devices: [InputDevice],
    choice: InputDeviceChoice
  ) -> [AudioDeviceOption] {
    var options = [AudioDeviceOption.systemDefault]
    options += devices.map {
      AudioDeviceOption(
        id: $0.id, label: $0.pickerLabel, choice: InputDeviceChoice($0), isAvailable: true)
    }
    if let uid = choice.uid, !devices.contains(where: { $0.id == uid }) {
      options.append(
        AudioDeviceOption(
          id: uid,
          label: choice.name ?? InputDeviceStrings.followSystemDefault,
          choice: choice,
          isAvailable: false))
    }
    return options
  }

  // MARK: - The meter

  /// The twelve drawn segments (`InputLevelMeter` owns the mapping).
  public var meterSegments: [InputLevelMeter.SegmentState] {
    InputLevelMeter.segments(for: level)
  }

  public var litSegmentCount: Int {
    InputLevelMeter.litSegmentCount(forNormalizedLevel: level.normalized)
  }

  /// What VoiceOver reads instead of twelve unlabelled rectangles.
  ///
  /// A count, not a percentage: the meter IS twelve segments, and reading "67%"
  /// for something drawn as 8 of 12 invites the user to look for a number that
  /// is not on screen.
  public var meterAccessibilityValue: String {
    "\(litSegmentCount) de \(InputLevelMeter.segmentCount)"
  }

  /// The line under the meter: a failure, the "no capture object" explanation,
  /// or the quiet hint. Never two of them.
  public var meterCaption: String? {
    if let meterError { return meterError }
    guard isMeterAvailable else { return AudioPaneStrings.meterUnavailable }
    return litSegmentCount == 0 ? AudioPaneStrings.meterQuiet : nil
  }

  public var isMeterCaptionAProblem: Bool { meterError != nil }
}

/// Assembles `AudioPane` from the live sources and owns the level subscription.
///
/// ## The microphone is open only while this tab is on screen
///
/// `observeLevels()` is meant to be driven by the tab view's `.task`, which
/// SwiftUI cancels when the tab is swapped or the window closes. Cancellation
/// ends the `for await` and the `stopMonitoring()` after it still runs — actor
/// calls execute in a cancelled task — so leaving the tab closes the device and
/// puts out macOS's orange microphone indicator. Nothing here relies on anyone
/// remembering to call a stop method.
@MainActor
@Observable
public final class AudioPanePresenter {

  public private(set) var level: AudioLevel = .silence
  public private(set) var meterError: String?

  public let devices: InputDeviceCenter

  /// `nil` when the app has no capture object — the launch where Accessibility
  /// was refused, so the pipeline never built one. The tab still shows the
  /// picker and the HFP row; only the meter is explained away.
  @ObservationIgnored private let monitor: (any AudioLevelMonitoring)?

  public init(devices: InputDeviceCenter, monitor: (any AudioLevelMonitoring)? = nil) {
    self.devices = devices
    self.monitor = monitor
  }

  public var isMeterAvailable: Bool { monitor != nil }

  public var pane: AudioPane {
    AudioPane(
      options: AudioPane.options(devices: devices.devices, choice: devices.choice),
      selectionID: devices.choice.uid ?? AudioDeviceOption.systemDefaultID,
      warning: devices.warning,
      substitutionNotice: devices.route.substitutionNotice,
      level: level,
      meterError: meterError,
      isMeterAvailable: isMeterAvailable)
  }

  /// Re-reads the hardware. Called when the tab appears; `InputDeviceCenter`
  /// follows the HAL on its own after that.
  public func refresh() {
    devices.refresh()
  }

  /// Picks a microphone by picker row id.
  ///
  /// Takes effect on the NEXT dictation, by `InputDeviceCenter`'s contract:
  /// `AudioCapture` binds the device when it starts an engine, and swapping it
  /// mid-utterance would truncate the recording in progress. The live meter is a
  /// separate session and does pick it up on the next preview.
  public func select(optionID: String) {
    let options = AudioPane.options(devices: devices.devices, choice: devices.choice)
    guard let option = options.first(where: { $0.id == optionID }) else { return }
    devices.select(option.choice)
  }

  /// Opens the microphone for the preview and publishes readings until the task
  /// is cancelled. Safe to call again after it returns.
  public func observeLevels() async {
    guard let monitor else { return }
    meterError = nil
    do {
      try await monitor.startMonitoring()
    } catch {
      meterError = AudioPaneStrings.meterFailure(error)
      level = .silence
      return
    }
    let stream = await monitor.levels()
    for await reading in stream {
      level = reading
      if Task.isCancelled { break }
    }
    await monitor.stopMonitoring()
    // Never leave a reading on screen implying the device is still open.
    level = .silence
  }
}
