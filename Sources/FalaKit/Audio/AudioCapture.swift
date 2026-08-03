import AVFoundation
import Foundation

/// A tap callback's payload, copied into `Sendable` storage.
///
/// `AVAudioPCMBuffer` is not `Sendable`, and the tap block runs outside any actor,
/// so the samples are copied out there and the buffer is rebuilt inside
/// `AudioCapture`. The copy is one memcpy per callback — cheap next to the
/// conversion — and it is what lets the whole pipeline stay Swift 6 clean without
/// `@unchecked Sendable`.
struct CapturedChunk: Sendable {
  /// One array per channel, non-interleaved.
  let channels: [[Float]]
  let sampleRate: Double

  init?(_ buffer: AVAudioPCMBuffer) {
    let frames = Int(buffer.frameLength)
    guard frames > 0, let data = buffer.floatChannelData else { return nil }
    let channelCount = Int(buffer.format.channelCount)
    var channels = [[Float]]()
    channels.reserveCapacity(channelCount)
    for channel in 0..<channelCount {
      channels.append(Array(UnsafeBufferPointer(start: data[channel], count: frames)))
    }
    self.channels = channels
    self.sampleRate = buffer.format.sampleRate
  }

  /// Rebuilds an `AVAudioPCMBuffer` so the chunk can be handed to `Resampler`.
  func makeBuffer() -> AVAudioPCMBuffer? {
    guard let first = channels.first else { return nil }
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels.count),
        interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(first.count)),
      let destination = buffer.floatChannelData
    else { return nil }

    buffer.frameLength = AVAudioFrameCount(first.count)
    for (index, samples) in channels.enumerated() {
      samples.withUnsafeBufferPointer { source in
        guard let base = source.baseAddress else { return }
        destination[index].update(from: base, count: samples.count)
      }
    }
    return buffer
  }
}

public enum AudioCaptureError: Error, Equatable, Sendable {
  /// `start()` called while already recording.
  case alreadyRecording
  /// `stop()` called without a matching `start()`.
  case notRecording
  /// No usable input device (sample rate 0 usually means none is selected).
  case noInputDevice
  /// The chosen input device is attached but the engine refused to bind to it
  /// (SPEC.md FR-18). Distinct from `noInputDevice`: a device that is simply gone
  /// falls back to the system default instead of failing.
  case inputDeviceUnavailable
  /// `AVAudioEngine` refused to start.
  case engineFailed(reason: String)
  /// Voice processing is on, which reshapes the mic format and breaks conversion.
  case voiceProcessingEnabled
}

/// Microphone capture, behind a protocol so `DictationCoordinator` can be tested
/// without a microphone or TCC.
public protocol AudioCapturing: Sendable {
  func start() async throws
  /// Ends the utterance and returns it as 16 kHz mono Float32.
  func stop() async throws -> AudioBuffer
  /// Aborts without producing audio (error paths, teardown).
  func cancel() async
}

/// Microphone capture for one push-to-talk utterance (SPEC.md FR-2, FR-3, FR-4).
///
/// `start()` on hotkey down, `stop()` on hotkey up; `stop()` returns the whole
/// utterance as 16 kHz mono Float32, ready for `TranscriptionEngine`.
///
/// Three constraints drive the design:
/// - **Voice processing stays OFF** (FR-3). `setVoiceProcessingEnabled(true)`
///   silently reshapes the mic to 5–9 channels and makes `AVAudioConverter` emit
///   silence or crash. This type never enables it and refuses to start if
///   something else did.
/// - **Native format in, 16 kHz out** (FR-2). The mic is tapped at whatever it
///   offers; `Resampler` does the conversion and the down-mix.
/// - **~60 s of headroom** (FR-4), so a long utterance is never truncated.
public actor AudioCapture: AudioCapturing {
  private let engine = AVAudioEngine()
  private let resampler: Resampler
  /// Which microphone to bind to (SPEC.md FR-18). `nil` keeps the pre-T2.6
  /// behaviour exactly: `AVAudioEngine` follows the system default.
  private let inputDevice: (any InputDeviceSelecting)?
  private var buffer: RingBuffer
  private var consumer: Task<Void, Never>?
  private var continuation: AsyncStream<CapturedChunk>.Continuation?
  private var recording = false
  /// Whether we have ever pinned the engine to a specific device. `setDeviceID`
  /// is sticky, so this is what tells us a `nil` selection now has to be restored
  /// to the system default rather than simply left alone.
  private var hasBoundDevice = false

  public var isRecording: Bool { recording }

  /// Samples held so far, at the target rate. Drives the overlay's level meter
  /// later; also lets `stop()` report what it captured.
  public var capturedSampleCount: Int { buffer.count }

  public init(
    headroomSeconds: TimeInterval = RingBuffer.defaultHeadroomSeconds,
    targetSampleRate: Double = 16_000,
    inputDevice: (any InputDeviceSelecting)? = nil
  ) throws {
    self.resampler = try Resampler(targetSampleRate: targetSampleRate)
    self.buffer = RingBuffer(seconds: headroomSeconds, sampleRate: targetSampleRate)
    self.inputDevice = inputDevice
  }

  /// Begins capturing. Requires microphone permission to have been granted
  /// already — this does not prompt.
  public func start() throws {
    guard !recording else { throw AudioCaptureError.alreadyRecording }

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

    buffer.removeAll()
    resampler.reset()

    // FIFO by construction, so chunks reach the resampler in capture order —
    // which matters because the converter's filter state is order-sensitive.
    let (stream, continuation) = AsyncStream<CapturedChunk>.makeStream()
    self.continuation = continuation

    // `format: nil` means "the node's own format": passing a different one makes
    // the tap throw at install time on some macOS versions.
    input.installTap(onBus: 0, bufferSize: 4096, format: nil) { pcmBuffer, _ in
      if let chunk = CapturedChunk(pcmBuffer) {
        continuation.yield(chunk)
      }
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      continuation.finish()
      self.continuation = nil
      throw AudioCaptureError.engineFailed(reason: String(describing: type(of: error)))
    }

    consumer = Task { [weak self] in
      for await chunk in stream {
        await self?.ingest(chunk)
      }
    }
    recording = true
  }

  /// Ends the utterance and returns everything captured, at the target rate.
  ///
  /// Always goes through `Resampler.finish()`: `resample(_:)` alone withholds
  /// roughly a filter length (~60 ms), which is precisely the tail-end truncation
  /// FR-4 exists to prevent.
  @discardableResult
  public func stop() async throws -> AudioBuffer {
    guard recording else { throw AudioCaptureError.notRecording }
    recording = false

    engine.inputNode.removeTap(onBus: 0)
    engine.stop()

    // Close the stream and let the consumer drain what the tap already yielded
    // before flushing — otherwise the tail is flushed ahead of buffered chunks.
    continuation?.finish()
    continuation = nil
    await consumer?.value
    consumer = nil

    let tail = try resampler.finish()
    buffer.append(contentsOf: tail.samples)

    return AudioBuffer(samples: buffer.drain(), sampleRate: resampler.targetSampleRate)
  }

  /// Stops without returning audio, for error paths and app teardown.
  public func cancel() async {
    guard recording else { return }
    _ = try? await stop()
    buffer.removeAll()
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

  private func ingest(_ chunk: CapturedChunk) {
    guard let pcmBuffer = chunk.makeBuffer() else { return }
    // A failed conversion drops one chunk rather than the utterance: the error
    // carries no audio, and there is nowhere useful to surface it mid-capture.
    guard let converted = try? resampler.resample(pcmBuffer) else { return }
    buffer.append(contentsOf: converted.samples)
  }
}
