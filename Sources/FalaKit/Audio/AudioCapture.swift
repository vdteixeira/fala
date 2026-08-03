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

/// A live input level, for the settings window's "Nível de entrada" meter and for
/// anything else that wants to see the microphone.
///
/// Split from `AudioCapturing` on purpose: a surface that only draws a meter has
/// no business being handed `start()`/`stop()`, and the existing coordinator
/// fakes do not have to grow three methods they never call.
public protocol AudioLevelMonitoring: Sendable {
  /// Readings at the refresh interval (~20 Hz), newest first subscriber included.
  ///
  /// OBSERVATION ONLY — this never opens the microphone. It stays quiet until
  /// something else (a dictation, or `startMonitoring()`) does.
  func levels() async -> AsyncStream<AudioLevel>

  /// Opens the microphone purely to measure it — the settings window's live
  /// preview, with no dictation in progress.
  func startMonitoring() async throws

  /// Closes it again. Never throws, and is safe to call when monitoring was
  /// never started.
  func stopMonitoring() async
}

extension AudioLevelMonitoring {
  /// Scoped monitoring: the microphone is open for exactly the duration of
  /// `body`, whether it returns, throws, or its task is cancelled.
  ///
  /// This is what a settings view should use. A `for await` over the stream ends
  /// on cancellation (`AsyncStream` returns `nil`), `body` returns, and the
  /// microphone closes — so dismissing the window cannot leave it open, which no
  /// amount of remembering to call `stopMonitoring()` guarantees.
  ///
  /// Monitoring is ONE global mode, not a reference count: this closes it on the
  /// way out even if something else had asked for it first. There is exactly one
  /// meter in the app, so that is the honest shape; if a second consumer ever
  /// appears, refcount here rather than in every caller.
  public func withLevelMonitoring<T: Sendable>(
    _ body: sending (AsyncStream<AudioLevel>) async throws -> T
  ) async throws -> T {
    try await startMonitoring()
    let stream = await levels()
    do {
      let result = try await body(stream)
      await stopMonitoring()
      return result
    } catch {
      // `defer` cannot `await`, so the two exits are spelled out. Actor calls
      // still run in a cancelled task, so this closes the microphone even when
      // the reason `body` returned was cancellation.
      await stopMonitoring()
      throw error
    }
  }
}

/// Microphone capture for one push-to-talk utterance (SPEC.md FR-2, FR-3, FR-4),
/// plus the live input level the Áudio settings tab draws (TASKS.md T2.11).
///
/// `start()` on hotkey down, `stop()` on hotkey up; `stop()` returns the whole
/// utterance as 16 kHz mono Float32, ready for `TranscriptionEngine`.
///
/// Three constraints drive the design:
/// - **Voice processing stays OFF** (FR-3). `setVoiceProcessingEnabled(true)`
///   silently reshapes the mic to 5–9 channels and makes `AVAudioConverter` emit
///   silence or crash. This type never enables it and refuses to start if
///   something else did. (Enforced in `AVAudioEngineMicrophoneSession`.)
/// - **Native format in, 16 kHz out** (FR-2). The mic is tapped at whatever it
///   offers; `Resampler` does the conversion and the down-mix.
/// - **~60 s of headroom** (FR-4), so a long utterance is never truncated.
///
/// ## The microphone has two possible reasons to be open
/// A dictation, and the settings window's level preview. They are deliberately
/// NOT concurrent: a dictation tears the preview's session down, runs on its own
/// session, and resumes the preview afterwards. That keeps `stop()`'s
/// drain-then-flush — the thing FR-4 depends on — operating on a session that
/// begins and ends with the utterance, which is the only shape it has ever been
/// verified in. The cost is one engine restart per keypress while the settings
/// window happens to be open; the benefit is that there is exactly one owner of
/// the open microphone at any moment.
public actor AudioCapture: AudioCapturing, AudioLevelMonitoring {
  /// "medidor … atualiza a cada 50ms" (settings-window.dc.html) — 20 Hz.
  public static let defaultLevelRefreshInterval: Duration =
    InputLevelMeterMetrics.refreshInterval

  private let resampler: Resampler
  private let session: any MicrophoneSession
  private let levelRefreshInterval: Duration

  private var buffer: RingBuffer
  private var consumer: Task<Void, Never>?
  private var continuation: AsyncStream<CapturedChunk>.Continuation?
  private var recording = false

  /// The user's intent, not the hardware's state: true from `startMonitoring()`
  /// until `stopMonitoring()`, even across a dictation that borrows the device.
  private var monitoringRequested = false

  /// Bumped whenever a session ends. `ingest` drops anything stamped with an
  /// older generation, so a chunk still in flight when the preview gives way to a
  /// dictation can never land in the utterance — or land in it out of order,
  /// which is the failure `RingBuffer`'s documentation warns nothing downstream
  /// can detect.
  private var sessionGeneration = 0

  /// Whether the CURRENT session's audio belongs in the utterance.
  ///
  /// Deliberately not `recording`: `stop()` clears `recording` before it drains,
  /// and gating the drain on it silently threw away every chunk the tap had
  /// already queued — a ~1 s truncation at the end of a 1 s utterance, which is
  /// precisely the FR-4 failure this pipeline is built to avoid. A session's
  /// purpose is fixed when it begins and outlives the flag.
  private var sessionCapturesAudio = false

  private var levelAccumulator = AudioLevelAccumulator()
  private var lastLevel = AudioLevel.silence
  private var levelSubscribers: [UUID: AsyncStream<AudioLevel>.Continuation] = [:]
  private var levelTicker: Task<Void, Never>?

  public var isRecording: Bool { recording }

  /// Whether the settings window's live preview is currently requested.
  public var isMonitoring: Bool { monitoringRequested }

  /// Whether the microphone is actually open, for either reason. The one thing
  /// worth asserting in a manual check: it must be false whenever the app is
  /// idle and no settings window is showing the meter.
  public var isMicrophoneOpen: Bool { session.isRunning }

  /// The most recent reading, for a surface that polls instead of subscribing.
  public var currentLevel: AudioLevel { lastLevel }

  /// Samples held so far, at the target rate. Also lets `stop()` report what it
  /// captured.
  public var capturedSampleCount: Int { buffer.count }

  public init(
    headroomSeconds: TimeInterval = RingBuffer.defaultHeadroomSeconds,
    targetSampleRate: Double = 16_000,
    inputDevice: (any InputDeviceSelecting)? = nil,
    levelRefreshInterval: Duration = AudioCapture.defaultLevelRefreshInterval
  ) throws {
    try self.init(
      headroomSeconds: headroomSeconds,
      targetSampleRate: targetSampleRate,
      levelRefreshInterval: levelRefreshInterval,
      session: AVAudioEngineMicrophoneSession(inputDevice: inputDevice))
  }

  /// The seam. Internal because `MicrophoneSession` is: a test injects a fake to
  /// exercise the mode logic without a microphone or TCC.
  init(
    headroomSeconds: TimeInterval = RingBuffer.defaultHeadroomSeconds,
    targetSampleRate: Double = 16_000,
    levelRefreshInterval: Duration = AudioCapture.defaultLevelRefreshInterval,
    session: sending any MicrophoneSession
  ) throws {
    self.resampler = try Resampler(targetSampleRate: targetSampleRate)
    self.buffer = RingBuffer(seconds: headroomSeconds, sampleRate: targetSampleRate)
    self.session = session
    self.levelRefreshInterval = levelRefreshInterval
  }

  // MARK: - Dictation

  /// Begins capturing. Requires microphone permission to have been granted
  /// already — this does not prompt.
  public func start() throws {
    guard !recording else { throw AudioCaptureError.alreadyRecording }

    // A preview session is torn down rather than reused; see the type comment.
    endSessionDiscarding()
    do {
      try beginSession(capturingAudio: true)
    } catch {
      // The microphone could not be opened at all, so the preview cannot be
      // resumed either. Fail closed: nothing is left running, and the meter says
      // so instead of freezing on its last reading.
      monitoringRequested = false
      publishSilence()
      throw error
    }

    buffer.removeAll()
    resampler.reset()
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

    // Close the stream and let the consumer drain what the tap already yielded
    // before flushing — otherwise the tail is flushed ahead of buffered chunks.
    await endSessionDraining()
    resumeMonitoringIfRequested()

    let tail = try resampler.finish()
    buffer.append(contentsOf: tail.samples)

    return AudioBuffer(samples: buffer.drain(), sampleRate: resampler.targetSampleRate)
  }

  /// Stops without returning audio, for error paths and app teardown.
  ///
  /// Teardown means teardown: this also drops the level preview. Leaving the
  /// settings window holding the microphone open after an aborted dictation is
  /// exactly the failure `docs/architecture.md` records twice, and the safe
  /// default is a closed microphone plus a dead meter, not the reverse.
  public func cancel() async {
    monitoringRequested = false
    if recording {
      recording = false
      await endSessionDraining()
      _ = try? resampler.finish()
    } else {
      endSessionDiscarding()
    }
    buffer.removeAll()
    resampler.reset()
  }

  // MARK: - Level monitoring

  /// Readings at `levelRefreshInterval`. Each subscriber gets the current level
  /// immediately, so a meter that appears mid-dictation is never blank.
  public func levels() -> AsyncStream<AudioLevel> {
    AsyncStream { continuation in
      let id = UUID()
      levelSubscribers[id] = continuation
      continuation.yield(lastLevel)
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeLevelSubscriber(id) }
      }
      updateLevelTicker()
    }
  }

  /// Opens the microphone for the settings window's live preview.
  ///
  /// Idempotent, and a no-op on the hardware while a dictation already owns the
  /// device — it only records the intent, so the preview resumes when the
  /// dictation ends.
  public func startMonitoring() throws {
    guard !monitoringRequested else { return }
    monitoringRequested = true
    guard !session.isRunning else {
      updateLevelTicker()
      return
    }
    do {
      try beginSession()
    } catch {
      monitoringRequested = false
      throw error
    }
  }

  /// Closes the preview. If a dictation is in flight it keeps the microphone —
  /// the preview simply will not be resumed when that dictation ends.
  public func stopMonitoring() {
    guard monitoringRequested else { return }
    monitoringRequested = false
    guard !recording else { return }
    endSessionDiscarding()
  }

  // MARK: - Session lifecycle

  private func beginSession(capturingAudio: Bool = false) throws {
    guard !session.isRunning else { return }

    // FIFO by construction, so chunks reach the resampler in capture order —
    // which matters because the converter's filter state is order-sensitive.
    let (stream, continuation) = AsyncStream<CapturedChunk>.makeStream()
    let generation = sessionGeneration
    do {
      try session.begin { continuation.yield($0) }
    } catch {
      continuation.finish()
      throw error
    }

    self.continuation = continuation
    sessionCapturesAudio = capturingAudio
    consumer = Task { [weak self] in
      for await chunk in stream {
        await self?.ingest(chunk, generation: generation)
      }
    }
    levelAccumulator.reset()
    updateLevelTicker()
  }

  /// Ends the session and waits for everything the tap already yielded to be
  /// ingested. FR-4: the drain has to complete BEFORE `Resampler.finish()`, or
  /// the tail is flushed ahead of audio that is still queued.
  private func endSessionDraining() async {
    session.end()
    continuation?.finish()
    continuation = nil
    // Everything the tap already yielded is still part of the utterance: the
    // drain has to finish before the session's purpose is cleared.
    await consumer?.value
    consumer = nil
    sessionCapturesAudio = false
    sessionGeneration &+= 1
    publishSilence()
    updateLevelTicker()
  }

  /// Ends the session now, discarding whatever the tap had queued. Used where
  /// the queued audio belongs to a different purpose than what comes next — a
  /// preview giving way to a dictation — and on teardown.
  private func endSessionDiscarding() {
    guard session.isRunning || continuation != nil else { return }
    session.end()
    continuation?.finish()
    continuation = nil
    consumer?.cancel()
    consumer = nil
    sessionCapturesAudio = false
    sessionGeneration &+= 1
    publishSilence()
    updateLevelTicker()
  }

  private func resumeMonitoringIfRequested() {
    guard monitoringRequested, !recording, !session.isRunning else { return }
    do {
      try beginSession()
    } catch {
      // Never leave the intent set with no session behind it: the meter goes
      // quiet rather than the app believing the microphone is open.
      monitoringRequested = false
      publishSilence()
    }
  }

  // MARK: - The audio path

  private func ingest(_ chunk: CapturedChunk, generation: Int) {
    // A chunk that outlived its session is dropped: appending it would put older
    // audio after newer audio, and nothing downstream can detect that.
    guard generation == sessionGeneration else { return }

    // The level is measured on the RAW tap audio, before the 16 kHz conversion.
    // Two reasons: it is what the DEVICE is hearing, which is what "Nível de
    // entrada" means; and it costs one multiply-add per sample, so the settings
    // preview never pays for a resample it has no use for. Nothing accumulates
    // while nobody is looking — the capture path does not pay for the UI.
    if !levelSubscribers.isEmpty {
      for channel in chunk.channels {
        levelAccumulator.add(channel)
      }
    }

    guard sessionCapturesAudio else { return }
    guard let pcmBuffer = chunk.makeBuffer() else { return }
    // A failed conversion drops one chunk rather than the utterance: the error
    // carries no audio, and there is nowhere useful to surface it mid-capture.
    guard let converted = try? resampler.resample(pcmBuffer) else { return }
    buffer.append(contentsOf: converted.samples)
  }

  // MARK: - Publishing

  /// The ticker exists only while somebody is listening AND the microphone is
  /// open. No subscribers, no timer; no microphone, no timer.
  private func updateLevelTicker() {
    let wanted = !levelSubscribers.isEmpty && session.isRunning
    if wanted {
      guard levelTicker == nil else { return }
      let interval = levelRefreshInterval
      levelTicker = Task { [weak self] in
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: interval)
          } catch {
            return
          }
          guard let self else { return }
          await self.publishTick()
        }
      }
    } else {
      levelTicker?.cancel()
      levelTicker = nil
    }
  }

  private func publishTick() {
    // No new audio since the last tick is NORMAL (the tap wakes ~12×/s at
    // 48 kHz). Publishing nothing keeps the last reading on screen instead of
    // flickering it to empty.
    guard let level = levelAccumulator.take() else { return }
    lastLevel = level
    for continuation in levelSubscribers.values {
      continuation.yield(level)
    }
  }

  /// Empties the meter. Called on every session end, so a closed microphone can
  /// never be represented by a stale non-zero reading.
  private func publishSilence() {
    levelAccumulator.reset()
    guard lastLevel != .silence else { return }
    lastLevel = .silence
    for continuation in levelSubscribers.values {
      continuation.yield(.silence)
    }
  }

  private func removeLevelSubscriber(_ id: UUID) {
    levelSubscribers[id] = nil
    if levelSubscribers.isEmpty {
      levelAccumulator.reset()
    }
    updateLevelTicker()
  }
}
