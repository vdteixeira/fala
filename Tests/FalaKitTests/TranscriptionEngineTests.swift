import FalaKit
import Foundation
import Testing

/// Contract tests for `TranscriptionEngine` (TASKS.md T1.1).
///
/// These exercise the protocol and its shared extension — `validate(_:)`, the
/// convenience `transcribe(_:)` overload, error propagation — through
/// `MockTranscriptionEngine`. Nothing here touches Parakeet: the real engine
/// needs a 1.1 GB download, so it is verified by a flagged integration test
/// (TASKS.md T1.4 DoD), never by this suite.
@Suite("TranscriptionEngine contract")
struct TranscriptionEngineTests {

  // MARK: Shared preconditions

  @Test("Every engine consumes 16 kHz audio")
  func requiredSampleRateIs16k() {
    #expect(MockTranscriptionEngine.requiredSampleRate == 16_000)
  }

  @Test("validate() rejects an empty buffer")
  func rejectsEmptyBuffer() async {
    let engine = MockTranscriptionEngine()
    let empty = AudioBuffer(samples: [], sampleRate: 16_000)

    let error = await #expect(throws: TranscriptionError.self) {
      _ = try await engine.transcribe(empty)
    }

    #expect(invalidAudioReason(error) != nil)
  }

  @Test(
    "validate() rejects anything that is not the required sample rate",
    arguments: [8_000.0, 22_050.0, 44_100.0, 48_000.0])
  func rejectsWrongSampleRate(sampleRate: Double) async {
    let engine = MockTranscriptionEngine()
    let audio = makeTestAudio(sampleRate: sampleRate)

    let error = await #expect(throws: TranscriptionError.self) {
      _ = try await engine.transcribe(audio)
    }

    let reason = invalidAudioReason(error)
    #expect(reason != nil)
    // The reason names the rate the engine wanted, so a mismatch is diagnosable
    // without re-running with a debugger attached.
    let expected = String(Int(MockTranscriptionEngine.requiredSampleRate))
    #expect(reason?.contains(expected) == true)
  }

  @Test("A well-formed 16 kHz buffer is accepted")
  func acceptsRequiredSampleRate() async throws {
    let engine = MockTranscriptionEngine.returning("fazer o deploy na sexta")

    let transcript = try await engine.transcribe(makeTestAudio())

    #expect(transcript.text == "fazer o deploy na sexta")
  }

  // MARK: biasTerms plumbing

  @Test("The convenience overload forwards empty biasTerms")
  func convenienceOverloadForwardsEmptyBiasTerms() async throws {
    let engine = MockTranscriptionEngine()

    _ = try await engine.transcribe(makeTestAudio())

    let call = await engine.lastCall
    #expect(call?.biasTerms == [])
  }

  @Test("biasTerms reach the engine verbatim, in order")
  func biasTermsArriveVerbatim() async throws {
    let engine = MockTranscriptionEngine()
    let terms = ["Kubernetes", "endpoint", "pull request"]

    _ = try await engine.transcribe(makeTestAudio(), biasTerms: terms)

    let received = await engine.lastBiasTerms
    #expect(received == terms)
  }

  @Test("Each call records its own biasTerms")
  func biasTermsAreRecordedPerCall() async throws {
    let engine = MockTranscriptionEngine()

    _ = try await engine.transcribe(makeTestAudio(), biasTerms: ["merge"])
    _ = try await engine.transcribe(makeTestAudio())
    _ = try await engine.transcribe(makeTestAudio(), biasTerms: ["branch", "commit"])

    let received = await engine.receivedBiasTerms
    #expect(received == [["merge"], [], ["branch", "commit"]])
  }

  @Test("The audio handed to the engine is the audio it received")
  func audioIsForwardedUnchanged() async throws {
    let engine = MockTranscriptionEngine()
    let audio = makeTestAudio(seconds: 0.25)

    _ = try await engine.transcribe(audio)

    let call = await engine.lastCall
    #expect(call?.audio == audio)
  }

  // MARK: Error propagation

  @Test("A transcription failure reaches the caller unchanged")
  func transcriptionFailurePropagates() async {
    let failure = TranscriptionError.transcriptionFailed(reason: "engine returned no text")
    let engine = MockTranscriptionEngine.failing(failure)

    let error = await #expect(throws: TranscriptionError.self) {
      _ = try await engine.transcribe(makeTestAudio())
    }

    #expect(error == failure)
  }

  @Test("A model failure reaches the caller unchanged")
  func modelFailurePropagates() async {
    let failure = TranscriptionError.modelUnavailable(reason: "download interrupted")
    let engine = MockTranscriptionEngine.failing(failure)

    let error = await #expect(throws: TranscriptionError.self) {
      _ = try await engine.transcribe(makeTestAudio())
    }

    #expect(error == failure)
  }

  @Test("prepare() failures propagate and leave the engine unprepared")
  func preparationFailurePropagates() async {
    let failure = TranscriptionError.modelUnavailable(reason: "no network")
    let engine = MockTranscriptionEngine.failingPreparation(failure)

    let prepareError = await #expect(throws: TranscriptionError.self) {
      try await engine.prepare()
    }
    #expect(prepareError == failure)

    let prepared = await engine.isPrepared
    #expect(prepared == false)
  }

  @Test("An engine that never prepared refuses to transcribe")
  func unpreparedEngineIsNotReady() async {
    let engine = MockTranscriptionEngine(requiresPreparation: true)

    await #expect(throws: TranscriptionError.notReady) {
      _ = try await engine.transcribe(makeTestAudio())
    }
  }

  @Test("A prepared engine transcribes")
  func preparedEngineTranscribes() async throws {
    let engine = MockTranscriptionEngine(text: "olá mundo", requiresPreparation: true)

    try await engine.prepare()
    let transcript = try await engine.transcribe(makeTestAudio())

    #expect(transcript.text == "olá mundo")
    let prepareCallCount = await engine.prepareCallCount
    #expect(prepareCallCount == 1)
  }

  // MARK: Mock behaviour the rest of the suite relies on

  @Test("Queued outcomes are consumed in order, then the default takes over")
  func queuedOutcomesAreConsumedInOrder() async throws {
    let engine = MockTranscriptionEngine(text: "padrão")
    await engine.enqueue(text: "primeiro")
    await engine.enqueue(text: "segundo")

    let first = try await engine.transcribe(makeTestAudio())
    let second = try await engine.transcribe(makeTestAudio())
    let third = try await engine.transcribe(makeTestAudio())

    #expect(first.text == "primeiro")
    #expect(second.text == "segundo")
    #expect(third.text == "padrão")
  }

  @Test("Rejected calls are still recorded, so 'was it called at all?' is answerable")
  func rejectedCallsAreRecorded() async {
    let engine = MockTranscriptionEngine()
    let empty = AudioBuffer(samples: [], sampleRate: 16_000)

    _ = try? await engine.transcribe(empty)

    let count = await engine.transcribeCallCount
    #expect(count == 1)
  }

  @Test("The engine is usable through the existential the pipeline will hold")
  func worksAsAnExistential() async throws {
    let engine: any TranscriptionEngine = MockTranscriptionEngine.returning("via protocolo")

    try await engine.prepare()
    let transcript = try await engine.transcribe(makeTestAudio())

    #expect(transcript.text == "via protocolo")
  }

  // MARK: AudioBuffer

  @Test("AudioBuffer reports its own duration")
  func audioBufferDuration() {
    let audio = makeTestAudio(seconds: 1.5)

    #expect(audio.duration == 1.5)
    #expect(audio.isEmpty == false)
  }

  @Test("A zero sample rate cannot produce a divide-by-zero duration")
  func audioBufferDurationWithZeroSampleRate() {
    let audio = AudioBuffer(samples: [0, 0, 0], sampleRate: 0)

    #expect(audio.duration == 0)
  }
}

// MARK: - Fixtures

/// A deterministic, synthetic buffer. Recorded speech is never committed to the
/// repo (see the `swift-testing` skill), and the samples' content is irrelevant
/// here — only the shape and the sample rate are.
private func makeTestAudio(seconds: Double = 0.5, sampleRate: Double = 16_000) -> AudioBuffer {
  let count = Int(seconds * sampleRate)
  let samples = (0..<count).map { Float(sin(Double($0) * 0.05)) }
  return AudioBuffer(samples: samples, sampleRate: sampleRate)
}

/// Extracts the reason from `.invalidAudio`, or nil for any other error. Lets a
/// test assert the *case* without pinning the exact wording of the message.
private func invalidAudioReason(_ error: TranscriptionError?) -> String? {
  if case .invalidAudio(let reason)? = error { return reason }
  return nil
}
