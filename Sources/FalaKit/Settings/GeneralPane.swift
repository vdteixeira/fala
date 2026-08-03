import Foundation
import Observation

/// Every fixed string of Ajustes › Geral (mockup: the GERAL section).
///
/// "Iniciar no login" is deliberately absent: it belongs to
/// `LaunchAtLoginStrings`, which owns the whole row including the two captions
/// macOS can force on it. Two copies of that title would drift the first time
/// one of them is reworded.
public enum GeneralPaneStrings {
  public static let hotkeyTitle = "Atalho de ditado"
  public static let hotkeySubtitle = "Segure para falar, solte para inserir"
  /// Tooltip and VoiceOver label for the keycap (the mockup draws a pencil).
  public static let hotkeyEditHelp = "Alterar o atalho de ditado"
  /// Said while the recorder is listening, so VoiceOver users get the same
  /// instruction the pulsing border gives sighted ones. Built from
  /// `Hotkey.allCases` rather than written out, so adding a fourth usable key
  /// updates the hint instead of leaving it quietly wrong.
  public static let hotkeyRecordingHint: String = {
    let names = Hotkey.allCases.map(\.displayName).joined(separator: ", ")
    return "Pressione \(names). Esc cancela."
  }()
  public static let overlayTitle = "Mostrar overlay durante o ditado"
  public static let overlaySubtitle = "Pílula flutuante na parte inferior da tela"
  public static let overlayToggleHelp = "Mostrar a pílula flutuante durante o ditado"
}

/// What Ajustes › Geral binds to.
///
/// Owns nothing of its own: the hotkey lives in `HotkeyRecorder` + `Preferences`,
/// autostart in `LaunchAtLoginModel`, the overlay flag in `Preferences`. What it
/// adds is the SEQUENCING those three cannot do separately — suspending the live
/// hotkey while the user shops for a new one, persisting a capture exactly once,
/// and telling the app to rebuild its event tap only when the key really changed.
///
/// ## The two callbacks are not optional extras
///
/// `onRecordingChanged` must be wired, or the currently-assigned hotkey keeps
/// starting real dictations while the user is pressing keys at the recorder.
/// `onHotkeyChanged` must be wired, or the new key is persisted and the running
/// `HotkeyManager` keeps listening for the old one until the next launch. Both
/// are the app's wiring — this type cannot reach an event tap — so both are
/// documented here and repeated in the window controller.
@MainActor
@Observable
public final class GeneralPanePresenter {

  /// The keycap's state machine. A `var` so mutating it re-renders the row.
  public private(set) var recorder: HotkeyRecorder

  /// The last refusal, cleared as soon as anything else happens. Nil most of the
  /// time; non-nil means the user pressed a key Fala cannot use.
  public private(set) var rejection: String?

  public let preferences: Preferences
  public let launch: LaunchAtLoginModel

  /// Called with `true` when recording starts and `false` when it ends, so the
  /// app can suspend push-to-talk for exactly that window.
  @ObservationIgnored public var onRecordingChanged: ((Bool) -> Void)?

  /// Called ONLY when the committed hotkey actually changed — rebuilding the
  /// event tap is not free, and `.captured` fires even when the user pressed the
  /// key that was already assigned.
  @ObservationIgnored public var onHotkeyChanged: ((Hotkey) -> Void)?

  public init(preferences: Preferences, launch: LaunchAtLoginModel) {
    self.preferences = preferences
    self.launch = launch
    self.recorder = HotkeyRecorder(hotkey: preferences.hotkey)
  }

  // MARK: - The hotkey row

  public var hotkeySymbol: String { FalaSymbol.keyboard }
  public var editSymbol: String { FalaSymbol.edit }
  public var hotkeyTitle: String { GeneralPaneStrings.hotkeyTitle }
  public var hotkeySubtitle: String { GeneralPaneStrings.hotkeySubtitle }

  public var isRecording: Bool { recorder.isRecording }

  /// "⌥ direito", or the prompt while recording.
  public var keycapLabel: String { recorder.keycapLabel }

  /// The line under the row: a refusal while recording, otherwise the Fn
  /// conflict warning FR-1 requires, otherwise nothing.
  public var hotkeyCaption: String? { rejection ?? recorder.conflictWarning }

  /// True when `hotkeyCaption` describes something the user must act on, so the
  /// view can tint it as a warning. The view picks the token; this picks the
  /// meaning.
  public var isHotkeyCaptionAProblem: Bool { hotkeyCaption != nil }

  /// Starts listening. Idempotent, and safe to call from a button that may fire
  /// twice.
  public func beginRecording() {
    guard !recorder.isRecording else { return }
    rejection = nil
    recorder.begin()
    onRecordingChanged?(true)
  }

  /// Stops listening without changing anything. The window controller MUST call
  /// this when the window closes or stops being key: a recorder left listening
  /// keeps a key monitor installed over a window the user has walked away from.
  public func cancelRecording() {
    guard recorder.isRecording else { return }
    recorder.cancel()
    rejection = nil
    onRecordingChanged?(false)
  }

  /// Feeds one key event to the recorder and applies its outcome.
  ///
  /// - Returns: the outcome, so a caller can decide whether to swallow the event
  ///   (anything but `.ignored` was consumed by the recorder).
  @discardableResult
  public func receive(_ event: HotkeyRecorderEvent) -> HotkeyRecorderOutcome {
    let outcome = recorder.receive(event)
    switch outcome {
    case .ignored:
      break
    case .rejected(let reason):
      // Still recording on purpose: the user gets to try another key instead of
      // having the recorder close under them.
      rejection = reason
    case .cancelled:
      rejection = nil
      onRecordingChanged?(false)
    case .captured(let hotkey):
      rejection = nil
      onRecordingChanged?(false)
      // `.captured` also fires for the key that was already assigned — pressing
      // it is a legitimate way to leave the recorder. Persisting and rebuilding
      // the tap for that would be a needless teardown of the one thing the user
      // is about to use.
      if hotkey != preferences.hotkey {
        preferences.setHotkey(hotkey)
        onHotkeyChanged?(hotkey)
      }
    }
    return outcome
  }

  // MARK: - The overlay row

  public var overlaySymbol: String { FalaSymbol.pill }
  public var overlayTitle: String { GeneralPaneStrings.overlayTitle }
  public var overlaySubtitle: String { GeneralPaneStrings.overlaySubtitle }
  public var showOverlay: Bool { preferences.showOverlay }

  public func setShowOverlay(_ showOverlay: Bool) {
    preferences.setShowOverlay(showOverlay)
  }

  // MARK: - Lifecycle

  /// Re-reads what another process can have changed. Itens de Início is one
  /// System Settings pane away, so this runs on appear AND on re-activation.
  public func refresh() {
    launch.refresh()
  }
}
