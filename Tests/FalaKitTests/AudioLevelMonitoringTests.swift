import AVFoundation
import Foundation
import Testing
import os

@testable import FalaKit

// MARK: - Test doubles

/// The `Sendable` control surface for `FakeMicrophoneSession`.
///
/// The session itself is not `Sendable` (neither is the real one — it owns an
/// `AVAudioEngine`) and lives inside the `AudioCapture` actor, so the test keeps
/// this instead. `OSAllocatedUnfairLock` is the one escape hatch this project
/// allows (CLAUDE.md); the alternative, an actor, could not be read from the
/// synchronous tap callback the fake is imitating.
private final class MicrophoneSpy: Sendable {
  private struct State {
    var beginCount = 0
    var endCount = 0
    var isRunning = false
    /// The live tap callback, cleared by `end()` exactly as `removeTap` does.
    var onChunk: (@Sendable (CapturedChunk) -> Void)?
    /// The last callback ever installed, kept AFTER `end()` so a test can fire a
    /// tap that outlived its session.
    var lastCallback: (@Sendable (CapturedChunk) -> Void)?
    var failure: AudioCaptureError?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  var beginCount: Int { state.withLock { $0.beginCount } }
  var endCount: Int { state.withLock { $0.endCount } }
  var isRunning: Bool { state.withLock { $0.isRunning } }
  var lastCallback: (@Sendable (CapturedChunk) -> Void)? { state.withLock { $0.lastCallback } }

  /// Makes the next `begin` fail, once.
  func failNextBegin(with error: AudioCaptureError) {
    state.withLock { $0.failure = error }
  }

  /// Delivers a chunk exactly as the tap would: synchronously, off the actor.
  func emit(_ chunk: CapturedChunk) {
    let callback = state.withLock { $0.onChunk }
    callback?(chunk)
  }

  func begin(_ onChunk: @escaping @Sendable (CapturedChunk) -> Void) throws {
    try state.withLock { current in
      if let failure = current.failure {
        current.failure = nil
        throw failure
      }
      current.beginCount += 1
      current.isRunning = true
      current.onChunk = onChunk
      current.lastCallback = onChunk
    }
  }

  func end() {
    state.withLock { current in
      guard current.isRunning else { return }
      current.endCount += 1
      current.isRunning = false
      current.onChunk = nil
    }
  }
}

private final class FakeMicrophoneSession: MicrophoneSession {
  private let spy: MicrophoneSpy

  init(spy: MicrophoneSpy) { self.spy = spy }

  var isRunning: Bool { spy.isRunning }

  func begin(onChunk: @escaping @Sendable (CapturedChunk) -> Void) throws {
    guard !isRunning else { return }
    try spy.begin(onChunk)
  }

  func end() { spy.end() }
}

// MARK: - Helpers

private enum Tap {
  /// One tap callback's worth of mono audio at the mic's native rate.
  static func chunk(_ samples: [Float], sampleRate: Double = 48_000) throws -> CapturedChunk {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false))
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let data = try #require(buffer.floatChannelData)
    for (index, sample) in samples.enumerated() {
      data[0][index] = sample
    }
    return try #require(CapturedChunk(buffer))
  }

  /// Loud enough to fill the meter, so "did the level move" is unambiguous.
  static func loudChunk(frames: Int = 4_096) throws -> CapturedChunk {
    try chunk((0..<frames).map { index in Float(sin(Double(index) * 0.05)) })
  }

  /// `seconds` of 48 kHz audio, split the way a real tap splits it.
  static func toneChunks(seconds: Double, frames: Int = 4_096) throws -> [CapturedChunk] {
    let total = Int(48_000 * seconds)
    var chunks = [CapturedChunk]()
    var start = 0
    while start < total {
      let count = min(frames, total - start)
      let samples = (0..<count).map { index in
        Float(sin(Double(start + index) * 0.05)) * 0.5
      }
      chunks.append(try chunk(samples))
      start += count
    }
    return chunks
  }
}

/// Polls a condition instead of sleeping a fixed amount: the lifecycle tests are
/// about ordering, not about timing, and a fixed sleep makes them flaky on a
/// loaded machine.
private func waitUntil(
  _ condition: @Sendable () -> Bool,
  within timeout: Duration = .seconds(3)
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(2))
  }
  return condition()
}

private func makeCapture(
  spy: MicrophoneSpy,
  refresh: Duration = .milliseconds(10)
) throws -> AudioCapture {
  try AudioCapture(
    levelRefreshInterval: refresh,
    session: FakeMicrophoneSession(spy: spy))
}

// MARK: - Suites

/// The mode logic on `AudioCapture`: when the microphone may be open, and — the
/// part this project has got wrong twice (docs/architecture.md) — that it always
/// closes again.
@Suite("AudioCapture monitoring")
struct AudioCaptureMonitoringTests {

  @Test("Monitoring opens the microphone; stopping closes it")
  func monitoringLifecycle() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    #expect(spy.isRunning == false)
    try await capture.startMonitoring()
    #expect(spy.beginCount == 1)
    #expect(spy.isRunning)
    #expect(await capture.isMonitoring)
    #expect(await capture.isMicrophoneOpen)

    await capture.stopMonitoring()
    #expect(spy.endCount == 1)
    #expect(spy.isRunning == false)
    #expect(await capture.isMonitoring == false)
    #expect(await capture.isMicrophoneOpen == false)
  }

  @Test("Starting monitoring twice opens one microphone, stopping twice is safe")
  func monitoringIsIdempotent() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    try await capture.startMonitoring()
    try await capture.startMonitoring()
    #expect(spy.beginCount == 1)

    await capture.stopMonitoring()
    await capture.stopMonitoring()
    #expect(spy.endCount == 1)
    #expect(spy.isRunning == false)
  }

  @Test("A microphone that refuses to open leaves no monitoring intent behind")
  func failedStartLeavesNothingRunning() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)
    spy.failNextBegin(with: .noInputDevice)

    await #expect(throws: AudioCaptureError.noInputDevice) {
      try await capture.startMonitoring()
    }
    #expect(await capture.isMonitoring == false)
    #expect(await capture.isMicrophoneOpen == false)
    #expect(spy.isRunning == false)
  }

  @Test("Scoped monitoring closes the microphone when the body returns")
  func scopedMonitoringClosesOnReturn() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    let observed = try await capture.withLevelMonitoring { _ -> Bool in
      spy.isRunning
    }
    #expect(observed)
    #expect(spy.isRunning == false)
    #expect(spy.endCount == 1)
  }

  @Test("Scoped monitoring closes the microphone when the body throws")
  func scopedMonitoringClosesOnThrow() async throws {
    struct Boom: Error {}
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    await #expect(throws: Boom.self) {
      try await capture.withLevelMonitoring { _ -> Void in throw Boom() }
    }
    #expect(spy.isRunning == false)
    #expect(spy.endCount == 1)
    #expect(await capture.isMonitoring == false)
  }

  /// The failure this API exists to make impossible: a settings window that goes
  /// away without anyone remembering to call `stopMonitoring()`.
  @Test("Cancelling the monitoring task closes the microphone")
  func scopedMonitoringClosesOnCancellation() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    let task = Task {
      try await capture.withLevelMonitoring { stream in
        for await _ in stream {}
      }
    }
    #expect(await waitUntil { spy.isRunning })

    task.cancel()
    _ = try? await task.value
    #expect(await waitUntil { !spy.isRunning })
    #expect(await capture.isMonitoring == false)
  }
}

/// How the two reasons to open the microphone interact.
@Suite("AudioCapture monitoring and dictation")
struct AudioCaptureModeInteractionTests {

  @Test("A dictation with no preview leaves the microphone closed")
  func dictationClosesTheMicrophone() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    try await capture.start()
    #expect(spy.isRunning)
    _ = try await capture.stop()
    #expect(spy.isRunning == false)
    #expect(spy.endCount == 1)
  }

  @Test("A dictation borrows the microphone from the preview and hands it back")
  func dictationSuspendsAndResumesMonitoring() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    try await capture.startMonitoring()
    #expect(spy.beginCount == 1)

    try await capture.start()
    #expect(spy.endCount == 1)  // the preview's session was torn down
    #expect(spy.beginCount == 2)  // and the dictation got its own

    _ = try await capture.stop()
    #expect(spy.beginCount == 3)  // the preview came back
    #expect(spy.isRunning)
    #expect(await capture.isMonitoring)
    #expect(await capture.isRecording == false)

    await capture.stopMonitoring()
    #expect(spy.isRunning == false)
  }

  @Test("Stopping the preview mid-dictation neither cuts the recording nor resumes")
  func stoppingPreviewMidDictationKeepsRecording() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    try await capture.startMonitoring()
    try await capture.start()
    await capture.stopMonitoring()
    #expect(spy.isRunning)  // the dictation still owns the device

    for chunk in try Tap.toneChunks(seconds: 0.5) { spy.emit(chunk) }
    let audio = try await capture.stop()

    #expect(audio.samples.count == 8_000)
    #expect(spy.isRunning == false)  // nothing was resumed
  }

  @Test("cancel() is a teardown: it drops the preview too")
  func cancelTearsEverythingDown() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    try await capture.startMonitoring()
    try await capture.start()
    await capture.cancel()

    #expect(spy.isRunning == false)
    #expect(await capture.isMonitoring == false)
    #expect(await capture.isRecording == false)
    #expect(await capture.capturedSampleCount == 0)
  }

  /// The refactor's regression guard: FR-2/FR-4 still hold. This is also the
  /// first time the capture actor's own audio path has ever been exercised by a
  /// test — it used to need a real microphone.
  @Test("A dictation still captures the whole utterance at 16 kHz")
  func dictationRoundTrip() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    try await capture.start()
    for chunk in try Tap.toneChunks(seconds: 1) { spy.emit(chunk) }
    let audio = try await capture.stop()

    #expect(audio.sampleRate == 16_000)
    // One second in, one second out — the tail `Resampler.finish()` releases
    // included. A `resample`-only path would come back ~960 samples short.
    //
    // This also pins the drain: `stop()` is called immediately after the last
    // chunk is yielded, so almost none of it has been ingested yet. Gating
    // `ingest` on `recording` (which `stop()` clears first) made this return
    // 1 365 samples of a 16 000-sample utterance.
    #expect(audio.samples.count == 16_000)
  }

  @Test("Preview audio never lands in the utterance")
  func previewAudioIsNotCaptured() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    try await capture.startMonitoring()
    for chunk in try Tap.toneChunks(seconds: 0.5) { spy.emit(chunk) }

    try await capture.start()
    let audio = try await capture.stop()
    #expect(audio.samples.isEmpty)
  }

  /// The generation guard. A tap callback from a session that has ended must not
  /// be able to splice old audio into a new utterance — out-of-order audio is
  /// the one corruption nothing downstream can detect (`RingBuffer` docs).
  @Test("A tap callback that outlived its session cannot reach the utterance")
  func staleTapCallbackIsDropped() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    try await capture.startMonitoring()
    let stale = try #require(spy.lastCallback)
    await capture.stopMonitoring()

    try await capture.start()
    for chunk in try Tap.toneChunks(seconds: 0.25) { stale(chunk) }
    let audio = try await capture.stop()

    #expect(audio.samples.isEmpty)
  }

  @Test("start() twice and stop() without start() still report themselves")
  func lifecycleErrorsAreUnchanged() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    await #expect(throws: AudioCaptureError.notRecording) {
      _ = try await capture.stop()
    }
    try await capture.start()
    await #expect(throws: AudioCaptureError.alreadyRecording) {
      try await capture.start()
    }
    _ = try await capture.stop()
  }
}

/// What reaches the meter, and what it costs when nobody is looking.
@Suite("AudioCapture levels")
struct AudioCaptureLevelStreamTests {

  @Test("Subscribing does not open the microphone")
  func subscribingIsObservationOnly() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    let stream = await capture.levels()
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first == AudioLevel.silence)
    #expect(spy.isRunning == false)
    #expect(spy.beginCount == 0)
  }

  @Test("A live reading reaches the meter and lights segments")
  func levelsReachTheMeter() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    let stream = await capture.levels()
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first == AudioLevel.silence)

    try await capture.startMonitoring()
    spy.emit(try Tap.loudChunk())

    let live = try #require(await iterator.next())
    #expect(live.normalized > 0)
    #expect(InputLevelMeter.segments(for: live).contains(.lit))
  }

  /// "Stopping monitoring really stops it", from the meter's side: the reading
  /// goes to silence, and a tap that fires afterwards changes nothing.
  @Test("Stopping monitoring empties the meter and keeps it empty")
  func levelsStopWithMonitoring() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    let stream = await capture.levels()
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first == AudioLevel.silence)

    try await capture.startMonitoring()
    let stale = try #require(spy.lastCallback)
    spy.emit(try Tap.loudChunk())
    let live = try #require(await iterator.next())
    #expect(live.normalized > 0)

    await capture.stopMonitoring()
    let emptied = await iterator.next()
    #expect(emptied == AudioLevel.silence)

    // The old session's tap firing late must not revive the meter.
    stale(try Tap.loudChunk())
    try await Task.sleep(for: .milliseconds(60))
    #expect(await capture.currentLevel == AudioLevel.silence)
  }

  /// The capture path must not pay for a UI that is not there: with no
  /// subscriber, nothing is measured at all.
  @Test("Nothing is measured while nobody is subscribed")
  func nothingAccumulatesWithoutSubscribers() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    try await capture.startMonitoring()
    for chunk in try Tap.toneChunks(seconds: 0.5) { spy.emit(chunk) }
    try await Task.sleep(for: .milliseconds(40))
    #expect(await capture.currentLevel == AudioLevel.silence)

    // Subscribing starts the measurement — and only then.
    let stream = await capture.levels()
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first == AudioLevel.silence)
    spy.emit(try Tap.loudChunk())
    let live = try #require(await iterator.next())
    #expect(live.normalized > 0)
  }

  @Test("The meter also runs during a dictation")
  func levelsFlowWhileRecording() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    let stream = await capture.levels()
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first == AudioLevel.silence)

    try await capture.start()
    spy.emit(try Tap.loudChunk())
    let live = try #require(await iterator.next())
    #expect(live.normalized > 0)

    _ = try await capture.stop()
    let emptied = await iterator.next()
    #expect(emptied == AudioLevel.silence)
  }

  @Test("A late subscriber sees the current reading immediately")
  func lateSubscriberIsNotBlank() async throws {
    let spy = MicrophoneSpy()
    let capture = try makeCapture(spy: spy)

    let first = await capture.levels()
    var iterator = first.makeAsyncIterator()
    _ = await iterator.next()
    try await capture.startMonitoring()
    spy.emit(try Tap.loudChunk())
    let live = try #require(await iterator.next())

    let second = await capture.levels()
    var lateIterator = second.makeAsyncIterator()
    let lateFirst = await lateIterator.next()
    #expect(lateFirst == live)

    await capture.stopMonitoring()
  }
}
