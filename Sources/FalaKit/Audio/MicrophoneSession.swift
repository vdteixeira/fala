import AVFoundation
import Foundation

/// One open microphone: the chosen device bound, a tap installed, the engine
/// running — or nothing at all.
///
/// This exists as a SEAM, not as an abstraction anyone else needs. `AudioCapture`
/// now decides *when* the microphone may be open (a dictation, the settings
/// window's level preview, or both), and that decision is precisely the thing
/// this project has got wrong twice — see `docs/architecture.md`: the sticky
/// `setDeviceID` that kept recording through a headset the UI said was gone, and
/// the stacked instances that opened two engines on one device. With the
/// AVFoundation half behind this protocol, a test can prove that stopping really
/// stops, with no microphone and no TCC.
///
/// Not `Sendable` on purpose: `AVAudioEngine` is not, and the only owner is the
/// `AudioCapture` actor, which serialises every call.
protocol MicrophoneSession: AnyObject {
  /// Whether the microphone is open right now.
  var isRunning: Bool { get }

  /// Opens the microphone and starts delivering tap audio.
  ///
  /// `onChunk` is called on the audio thread, so it must not block: the only
  /// thing `AudioCapture` does in it is `AsyncStream.Continuation.yield`, which
  /// is synchronous, FIFO and lock-free.
  ///
  /// Idempotent: beginning a session that is already running does nothing.
  func begin(onChunk: @escaping @Sendable (CapturedChunk) -> Void) throws

  /// Closes the microphone. Idempotent, and must never throw: it is the path
  /// every error and teardown takes.
  func end()
}

/// The shipping `MicrophoneSession`: `AVAudioEngine` plus the FR-3 and FR-18
/// guards that used to live inline in `AudioCapture`.
final class AVAudioEngineMicrophoneSession: MicrophoneSession {
  /// The tap's buffer size. At 48 kHz this is one callback every ~85 ms — which
  /// is why the meter is driven by a timer rather than by the tap.
  private static let tapBufferSize: AVAudioFrameCount = 4096

  private let engine = AVAudioEngine()

  /// Which microphone to bind to (SPEC.md FR-18). `nil` keeps the pre-T2.6
  /// behaviour exactly: `AVAudioEngine` follows the system default.
  private let inputDevice: (any InputDeviceSelecting)?

  /// Whether we have ever pinned the engine to a specific device. `setDeviceID`
  /// is sticky, so this is what tells us a `nil` selection now has to be restored
  /// to the system default rather than simply left alone.
  private var hasBoundDevice = false

  private(set) var isRunning = false

  init(inputDevice: (any InputDeviceSelecting)? = nil) {
    self.inputDevice = inputDevice
  }

  /// Last line of defence against the failure this project keeps hitting: if the
  /// owner is dropped while the microphone is open, close it.
  deinit {
    guard isRunning else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }

  func begin(onChunk: @escaping @Sendable (CapturedChunk) -> Void) throws {
    guard !isRunning else { return }

    let input = engine.inputNode
    // FR-18: bind the chosen microphone FIRST. Binding changes the node's
    // format, so anything read before it — including the tap's format — would
    // describe the device the user did not pick.
    try bindSelectedDevice(to: input)

    // FR-3: never turn this on, and refuse to run if it somehow is on.
    guard !input.isVoiceProcessingEnabled else {
      throw AudioCaptureError.voiceProcessingEnabled
    }

    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw AudioCaptureError.noInputDevice
    }

    // `format: nil` means "the node's own format": passing a different one makes
    // the tap throw at install time on some macOS versions.
    input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: nil) { pcmBuffer, _ in
      if let chunk = CapturedChunk(pcmBuffer) {
        onChunk(chunk)
      }
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw AudioCaptureError.engineFailed(reason: String(describing: type(of: error)))
    }
    isRunning = true
  }

  func end() {
    guard isRunning else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    isRunning = false
  }

  /// Points the engine's input node at the user's chosen microphone (FR-18).
  ///
  /// A `nil` answer means "follow the system default", which covers both the
  /// unconfigured app and a chosen device that is currently unplugged — the
  /// missing device is reported through `InputRoute.substitutionNotice`, not by
  /// refusing to dictate. A device that IS attached but rejects the binding is a
  /// real failure and says so.
  private func bindSelectedDevice(to input: AVAudioInputNode) throws {
    let unit = input.auAudioUnit
    let target: AudioDeviceID?

    if let chosen = inputDevice?.currentInputDeviceID() {
      target = chosen
    } else if hasBoundDevice {
      // Returning early here was a real bug: `setDeviceID` is STICKY, and the
      // engine outlives every dictation, so once bound the AUHAL stops following
      // the system default. Switching back to "Padrão do sistema" then kept
      // recording through the old headset while `InputRoute` reported the healthy
      // built-in mic and the pill's HFP warning disappeared — the worst shape of
      // this bug, because the warning goes away while the problem does not.
      target = CoreAudioHAL.defaultInputDeviceID()
    } else {
      // Never bound anything: the engine is already following the default.
      return
    }

    guard let target, unit.deviceID != target else { return }
    do {
      try unit.setDeviceID(target)
      hasBoundDevice = inputDevice?.currentInputDeviceID() != nil
    } catch {
      throw AudioCaptureError.inputDeviceUnavailable
    }
  }
}
