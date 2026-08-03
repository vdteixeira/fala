import FluidAudio
import Foundation

/// Seam over FluidAudio's model acquisition (~1.1 GB download on first run), so
/// `ParakeetEngine`'s preparation and error mapping can be exercised without a
/// network round trip or a gigabyte of CoreML (CLAUDE.md: every expensive or
/// environment-dependent dependency is constructor-injected).
///
/// Deliberately internal: `AsrManager` is a FluidAudio type and must not cross
/// into FalaKit's public API, or the `TranscriptionEngine` seam that keeps the
/// WhisperKit fallback alive (SPEC.md FR-5) would leak.
protocol ParakeetModelLoading: Sendable {
  func loadManager(
    onStage: @escaping @Sendable (ModelDownloadStage) -> Void
  ) async throws -> AsrManager
}

/// Production loader: Parakeet TDT v3 on CoreML/ANE (SPEC.md FR-6).
struct FluidAudioModelLoader: ParakeetModelLoading {
  func loadManager(
    onStage: @escaping @Sendable (ModelDownloadStage) -> Void
  ) async throws -> AsrManager {
    let models = try await AsrModels.downloadAndLoad(
      version: .v3,
      progressHandler: { progress in onStage(ModelDownloadStage(progress)) })
    // NOT `.default`. FluidAudio 0.15.5's own documentation on `melChunkContext`
    // (ASR/Parakeet/AsrTypes.swift) says the 80 ms mel-context prepend can shift
    // the encoder's first-frame distribution enough that the TDT decoder "drifts
    // back to its English-biased prior" on v3 multilingual long-form audio, and
    // to "set to false for v3 multilingual long-form batch transcription" —
    // exactly this app. It only affects utterances past the 15 s chunk threshold,
    // which is why Spike 0 (≈7 s fixtures) never exercised it, but FR-4 sizes the
    // ring buffer for 60 s so long utterances are expected input.
    //
    // Re-verified against the pinned 0.15.5 checkout (2026-08-02): the flag is
    // read only by `ChunkProcessor`, and `transcribeWithState` reaches that at
    // all only when `samples.count > ASRConstants.maxModelSamples` (240_000 =
    // 15.0 s at 16 kHz) — below it, audio takes the single-shot path and this
    // setting is inert. Also note FluidAudio's doc oversells the `false` branch:
    // in 0.15.5 it drops the 1280-sample prepend and switches to silence-aligned
    // chunk starts, but `noMelWarmupPrefixFrames` is 0, so the "acoustic warmup"
    // it mentions only exists under the opt-in `dualDecodeArbitration`, which
    // stays off (it costs ≈1.1–1.5× and NFR-3 was measured without it).
    let manager = AsrManager(config: ASRConfig(melChunkContext: false))
    try await manager.loadModels(models)
    return manager
  }
}

/// v1's only `TranscriptionEngine`: Parakeet TDT v3 through FluidAudio 0.15.5,
/// batch-only — transcription fires once, on hotkey release (SPEC.md FR-5/FR-6).
///
/// An `actor` because the loaded CoreML models are expensive, shared, mutable
/// state: one instance is created at startup and reused by every dictation, and
/// two concurrent dictations must not race on it.
public actor ParakeetEngine: TranscriptionEngine {

  /// Script filter, NOT a language lock. In FluidAudio 0.15.5 this only skips
  /// top-K candidates whose script does not match (Latin vs Cyrillic); it does
  /// not condition the decoder, so it cannot pin PT-BR against EN or FR, which
  /// are all Latin. SPEC.md FR-7 revised the requirement for exactly this
  /// reason — treat it as best-effort mitigation, never as a guarantee.
  static let languageHint: Language = .portuguese

  private let loader: any ParakeetModelLoading
  private var manager: AsrManager?
  private var loadTask: Task<AsrManager, any Error>?

  public init() {
    self.loader = FluidAudioModelLoader()
  }

  init(loader: any ParakeetModelLoading) {
    self.loader = loader
  }

  /// Downloads (first run only) and loads the CoreML models.
  ///
  /// Idempotent: after the first success it returns immediately, and callers
  /// arriving while a load is in flight join that load instead of starting a
  /// second 1.1 GB download. Call it once at startup — never from the hotkey
  /// path, which is why `transcribe` throws `.notReady` rather than loading
  /// lazily.
  public func prepare() async throws {
    _ = try await loadedManager(onStage: { _ in })
  }

  public func prepare(
    onStage: @escaping @Sendable (ModelDownloadStage) -> Void
  ) async throws {
    _ = try await loadedManager(onStage: onStage)
  }

  public func transcribe(_ audio: AudioBuffer, biasTerms: [String]) async throws -> Transcript {
    try validate(audio)

    // `biasTerms` is accepted and deliberately ignored (SPEC.md FR-20 [AT RISK]).
    //
    // FluidAudio 0.15.5 does ship vocabulary boosting, but not on this path:
    // `VocabularyRescorer` is referenced only by `SlidingWindowAsrManager`
    // (via `configureVocabularyBoosting(vocabulary:ctcModels:config:)`) and by
    // FluidAudio's own CLI. Nothing under ASR/Parakeet/SlidingWindow/TDT/ —
    // where the `AsrManager` this engine uses lives — mentions it, so the batch
    // `transcribe(_:decoderState:language:)` call below simply has no hook for
    // biasing. Verified against the pinned checkout.
    //
    // Adopting it means switching manager class AND downloading a second (CTC)
    // model, which changes the latency profile NFR-3 was measured against. That
    // is a deliberate decision for whoever takes FR-20, not something to fake
    // here: silently accepting terms that do nothing would hide that FR-9's
    // deterministic jargon dictionary is currently the entire mitigation budget
    // for the English-jargon losses GATE S0 measured.
    _ = biasTerms

    let manager = try await readyManager()

    // Fresh decoder state per utterance: v1 is batch and every hotkey press is
    // an independent utterance, so carrying state over would bleed the previous
    // dictation's context into this one. `TdtDecoderState.make()` is the
    // documented shorthand but it `fatalError`s when the ANE-aligned allocation
    // fails; library code must not kill the host app (CLAUDE.md), so this uses
    // the throwing initializer that `make()` wraps.
    let decoderLayers = await manager.decoderLayerCount
    var decoderState: TdtDecoderState
    do {
      decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
    } catch {
      throw TranscriptionError.transcriptionFailed(reason: "decoder state allocation failed")
    }

    do {
      let result = try await manager.transcribe(
        audio.samples, decoderState: &decoderState, language: Self.languageHint)
      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        // "Ran but produced nothing usable" per `TranscriptionError`. Surfacing
        // it as an error keeps an empty paste out of the injection path, where
        // it would fail later as `InjectionError.emptyText`.
        throw TranscriptionError.transcriptionFailed(reason: "engine returned no text")
      }
      return Transcript(
        text: text,
        confidence: result.confidence,
        audioDuration: result.duration,
        processingTime: result.processingTime)
    } catch let error as TranscriptionError {
      throw error
    } catch {
      throw Self.mapTranscriptionFailure(error)
    }
  }

  // MARK: - Loading

  /// The manager, WAITING for an in-flight `prepare()` rather than failing.
  ///
  /// Loading is fast here once the model is on disk (~1 s), so the window is
  /// narrow — but on a first run it is a 461 MB download, and a user who
  /// launches the app and immediately dictates should get their utterance late
  /// rather than lose it to an error. `CohereEngine` has the same rule for the
  /// same reason, where the window is 97 s.
  ///
  /// A load that was NEVER started still throws: `prepare()` exists precisely so
  /// the hotkey path never triggers a download.
  private func readyManager() async throws -> AsrManager {
    if let manager { return manager }
    guard loadTask != nil else { throw TranscriptionError.notReady }
    return try await loadedManager(onStage: { _ in })
  }

  private func loadedManager(
    onStage: @escaping @Sendable (ModelDownloadStage) -> Void
  ) async throws -> AsrManager {
    if let manager { return manager }

    if let loadTask {
      // A load is already in flight — join it rather than downloading twice.
      do {
        let loaded = try await loadTask.value
        // Cache it here too: only the caller that CREATED the task stored the
        // result, so a joiner returned a manager the actor immediately forgot.
        manager = loaded
        return loaded
      } catch {
        throw Self.mapModelFailure(error)
      }
    }

    let task = Task { [loader] in try await loader.loadManager(onStage: onStage) }
    loadTask = task
    do {
      let loaded = try await task.value
      manager = loaded
      // Drop the completed task: `manager` is the cache from here on, and a
      // retained finished Task would keep a second strong reference to the
      // loaded models alive for the life of the engine. It also made
      // `prepareIsIdempotent` pass for the wrong reason — a second `prepare()`
      // hit the cached TASK, so the test could not tell whether `manager` had
      // actually been populated.
      loadTask = nil
      return loaded
    } catch {
      // A failed load must not poison the engine: the usual cause is a
      // transient network failure on first run, so `prepare()` stays retryable.
      loadTask = nil
      throw Self.mapModelFailure(error)
    }
  }

  // MARK: - Error mapping

  // No FluidAudio error is ever rethrown raw: callers outside
  // Sources/FalaKit/Transcription must only ever see `TranscriptionError`, or
  // swapping in WhisperKit (SPEC.md FR-5) would break them.
  //
  // PRIVACY: these `reason` strings are third-party text that may reach a log or
  // the UI. Every message reachable from `ASRError` and `AsrModelsError` was read
  // in the pinned 0.15.5 and carries only model names, file paths, tensor shapes
  // and indices — never audio samples and never decoded text. That invariant is
  // part of what a version bump must re-verify (see the `fluidaudio-asr` skill).

  // `internal` rather than `private` only so `ParakeetEngineTests` can call them
  // directly: both are pure functions, and the switch below is the one piece of
  // logic here that neither a fake loader nor the flagged integration test can
  // reach (every case except `.notInitialized` requires loaded CoreML models to
  // provoke). Still invisible outside FalaKit, so the public API is unchanged.
  static func mapModelFailure(_ error: any Error) -> TranscriptionError {
    if let error = error as? TranscriptionError { return error }
    return .modelUnavailable(reason: describe(error))
  }

  static func mapTranscriptionFailure(_ error: any Error) -> TranscriptionError {
    if let error = error as? TranscriptionError { return error }
    guard let error = error as? ASRError else {
      return .transcriptionFailed(reason: describe(error))
    }
    // Exhaustive on purpose, with no `default`: if a version bump adds a case,
    // this must fail to compile and force someone to classify it.
    switch error {
    case .notInitialized:
      return .notReady
    case .invalidAudioData:
      return .invalidAudio(reason: describe(error))
    case .modelLoadFailed, .modelCompilationFailed, .unsupportedPlatform,
      .encoderInstantiationFailed:
      return .modelUnavailable(reason: describe(error))
    case .processingFailed, .streamingConversionFailed, .fileAccessFailed:
      return .transcriptionFailed(reason: describe(error))
    }
  }

  private static func describe(_ error: any Error) -> String {
    if error is CancellationError { return "cancelled" }
    if let error = error as? any LocalizedError, let description = error.errorDescription {
      return description
    }
    return (error as NSError).localizedDescription
  }
}
