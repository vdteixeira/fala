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
  /// `AVAudioEngine` refused to start.
  case engineFailed(reason: String)
  /// Voice processing is on, which reshapes the mic format and breaks conversion.
  case voiceProcessingEnabled
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
public actor AudioCapture {
  private let engine = AVAudioEngine()
  private let resampler: Resampler
  private var buffer: RingBuffer
  private var consumer: Task<Void, Never>?
  private var continuation: AsyncStream<CapturedChunk>.Continuation?
  private var recording = false

  public var isRecording: Bool { recording }

  /// Samples held so far, at the target rate. Drives the overlay's level meter
  /// later; also lets `stop()` report what it captured.
  public var capturedSampleCount: Int { buffer.count }

  public init(
    headroomSeconds: TimeInterval = RingBuffer.defaultHeadroomSeconds,
    targetSampleRate: Double = 16_000
  ) throws {
    self.resampler = try Resampler(targetSampleRate: targetSampleRate)
    self.buffer = RingBuffer(seconds: headroomSeconds, sampleRate: targetSampleRate)
  }

  /// Begins capturing. Requires microphone permission to have been granted
  /// already — this does not prompt.
  public func start() throws {
    guard !recording else { throw AudioCaptureError.alreadyRecording }

    let input = engine.inputNode
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

  private func ingest(_ chunk: CapturedChunk) {
    guard let pcmBuffer = chunk.makeBuffer() else { return }
    // A failed conversion drops one chunk rather than the utterance: the error
    // carries no audio, and there is nowhere useful to surface it mid-capture.
    guard let converted = try? resampler.resample(pcmBuffer) else { return }
    buffer.append(contentsOf: converted.samples)
  }
}
