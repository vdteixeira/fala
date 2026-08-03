import FluidAudio
import Foundation
import Testing

@testable import FalaKit

/// A loader that never succeeds. `CoherePipeline.LoadedModels` wraps real CoreML
/// models and cannot be built without them, so the success path belongs to the
/// integration test / `FalaSpike`; everything reachable without a 1 GB download
/// is covered here.
private struct FailingCohereLoader: CohereModelLoading {
  let error: any Error
  func loadModels(
    onStage: @escaping @Sendable (ModelDownloadStage) -> Void
  ) async throws -> CoherePipeline.LoadedModels { throw error }
}

/// A loader that parks inside `loadModels` until the test releases it, so the
/// window where `prepare()` is in flight can be observed instead of raced.
private actor BlockingCohereLoader: CohereModelLoading {
  private var entered = false
  private var release: CheckedContinuation<Void, Never>?
  private var waitingForEntry: CheckedContinuation<Void, Never>?

  func loadModels(
    onStage: @escaping @Sendable (ModelDownloadStage) -> Void
  ) async throws -> CoherePipeline.LoadedModels {
    entered = true
    waitingForEntry?.resume()
    waitingForEntry = nil
    await withCheckedContinuation { release = $0 }
    throw URLError(.timedOut)
  }

  /// Returns once `loadModels` has actually been entered.
  func waitForEntry() async {
    if entered { return }
    await withCheckedContinuation { waitingForEntry = $0 }
  }

  func releaseLoad() { release?.resume() }
}

@Suite("CohereEngine")
struct CohereEngineTests {

  /// The reason this engine exists. Parakeet's `language` is a Latin-vs-Cyrillic
  /// script filter and cannot pin Portuguese (SPEC.md FR-7); Cohere forces the
  /// language token in the decoder prefill. If someone flips this to `.english`
  /// while debugging, the engine silently loses its entire justification.
  @Test("Portuguese is forced, not hinted")
  func languageIsPortuguese() {
    #expect(CohereEngine.language == .portuguese)
  }

  /// Above the pipeline's single-shot ceiling the engine must switch to the
  /// chunking path. Calling plain `transcribe` on longer audio truncates at
  /// 35 s — and FR-4 sizes the ring buffer for 60, so long utterances are
  /// expected input, not an edge case.
  @Test("The single-shot ceiling matches the pipeline's own limit")
  func singleShotCeilingTracksThePipeline() {
    #expect(CohereEngine.singleShotSeconds == Double(CohereAsrConfig.maxAudioSeconds))
    #expect(CohereEngine.singleShotSeconds < RingBuffer.defaultHeadroomSeconds)
  }

  @Test("Transcribing before prepare() reports not ready")
  func transcribeBeforePrepareIsNotReady() async {
    let engine = CohereEngine(loader: FailingCohereLoader(error: URLError(.notConnectedToInternet)))
    let audio = AudioBuffer(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000)

    await #expect(throws: TranscriptionError.notReady) {
      _ = try await engine.transcribe(audio, biasTerms: [])
    }
  }

  @Test("Empty audio is rejected before the engine is touched")
  func emptyAudioIsRejected() async {
    let engine = CohereEngine(loader: FailingCohereLoader(error: URLError(.badURL)))
    let audio = AudioBuffer(samples: [], sampleRate: 16_000)

    await #expect(throws: TranscriptionError.self) {
      _ = try await engine.transcribe(audio, biasTerms: [])
    }
  }

  @Test("Audio at the wrong sample rate is rejected")
  func wrongSampleRateIsRejected() async {
    let engine = CohereEngine(loader: FailingCohereLoader(error: URLError(.badURL)))
    let audio = AudioBuffer(samples: [0.1, 0.2], sampleRate: 44_100)

    await #expect(throws: TranscriptionError.self) {
      _ = try await engine.transcribe(audio, biasTerms: [])
    }
  }

  @Test("A network failure during prepare is a model problem, not a crash")
  func networkFailureMapsToModelUnavailable() async {
    let engine = CohereEngine(loader: FailingCohereLoader(error: URLError(.timedOut)))

    await #expect(throws: TranscriptionError.self) {
      try await engine.prepare()
    }
  }

  /// A failed load must not poison the engine: the usual cause is a transient
  /// network failure on first run, so `prepare()` has to stay retryable.
  @Test("A failed prepare can be retried")
  func failedPrepareIsRetryable() async {
    let engine = CohereEngine(loader: FailingCohereLoader(error: URLError(.timedOut)))

    for _ in 0..<3 {
      await #expect(throws: TranscriptionError.self) {
        try await engine.prepare()
      }
    }
  }

  /// No third-party English string may reach a user-facing message.
  @Test("FluidAudio errors are mapped, never passed through")
  func failuresAreMappedToTypedErrors() {
    let network = CohereEngine.mapFailure(URLError(.notConnectedToInternet))
    #expect(network == .modelUnavailable(reason: "model download failed"))

    let unknown = CohereEngine.mapFailure(
      NSError(domain: "Whatever", code: 1, userInfo: [NSLocalizedDescriptionKey: "Some English"]))
    if case .transcriptionFailed(let reason) = unknown {
      #expect(!reason.contains("Some English"))
    } else {
      Issue.record("expected .transcriptionFailed")
    }
  }

  /// Both engines answer the same protocol, so the coordinator can hold either
  /// without knowing which — that is what makes the choice reversible.
  @Test("Both engines satisfy the same contract")
  func bothEnginesShareTheContract() {
    #expect(CohereEngine.requiredSampleRate == ParakeetEngine.requiredSampleRate)
    #expect(CohereEngine.requiredSampleRate == 16_000)
  }

  /// `biasTerms` is accepted and ignored on BOTH engines. Silently accepting
  /// terms that do nothing would hide that FR-9's dictionary is still the whole
  /// mitigation budget for the jargon losses GATE S0 measured.
  @Test("biasTerms is accepted without changing the outcome")
  func biasTermsAreAcceptedAndIgnored() async {
    let engine = CohereEngine(loader: FailingCohereLoader(error: URLError(.badURL)))
    let audio = AudioBuffer(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000)

    await #expect(throws: TranscriptionError.notReady) {
      _ = try await engine.transcribe(audio, biasTerms: ["Postgres", "Kubernetes"])
    }
  }

  /// The defect behind "aparece uma mensagem de erro depois da transcrição".
  ///
  /// `prepare()` takes 97 s on a machine that already holds the model (88 s of
  /// it is the ANE warm-up, paid at every launch). A hotkey press inside that
  /// window used to throw `.notReady` and the user lost the utterance. It must
  /// WAIT for the load in flight and then report what that load actually did —
  /// here, a network failure — never `.notReady`.
  @Test("Transcribing during an in-flight prepare waits instead of failing fast")
  func transcribeJoinsAnInFlightPreparation() async throws {
    let loader = BlockingCohereLoader()
    let engine = CohereEngine(loader: loader)
    let audio = AudioBuffer(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000)

    let preparation = Task { try await engine.prepare() }
    await loader.waitForEntry()

    let transcription = Task { try await engine.transcribe(audio, biasTerms: []) }
    await loader.releaseLoad()

    do {
      _ = try await transcription.value
      Issue.record("expected the joined load's failure")
    } catch let error as TranscriptionError {
      #expect(error != .notReady, "still failing fast instead of waiting")
      #expect(error == .modelUnavailable(reason: "model download failed"))
    }
    _ = try? await preparation.value
  }

  /// But a transcription with no preparation EVER started still fails fast.
  /// Turning the hotkey path into a lazy 4,98 GB download is the thing
  /// `prepare()` exists to prevent.
  @Test("Transcribing with no preparation started still reports not ready")
  func transcribeWithoutAnyPreparationFailsFast() async {
    let engine = CohereEngine(loader: FailingCohereLoader(error: URLError(.timedOut)))
    let audio = AudioBuffer(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000)

    await #expect(throws: TranscriptionError.notReady) {
      _ = try await engine.transcribe(audio, biasTerms: [])
    }
  }
}
