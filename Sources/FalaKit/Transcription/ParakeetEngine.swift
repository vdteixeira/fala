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
  func loadManager() async throws -> AsrManager
}

/// Production loader: Parakeet TDT v3 on CoreML/ANE (SPEC.md FR-6).
struct FluidAudioModelLoader: ParakeetModelLoading {
  func loadManager() async throws -> AsrManager {
    let models = try await AsrModels.downloadAndLoad(version: .v3)
    // NOT `.default`. FluidAudio 0.15.5's own documentation on `melChunkContext`
    // (ASR/Parakeet/AsrTypes.swift) says the 80 ms mel-context prepend can shift
    // the encoder's first-frame distribution enough that the TDT decoder "drifts
    // back to its English-biased prior" on v3 multilingual long-form audio, and
    // to "set to false for v3 multilingual long-form batch transcription" —
    // exactly this app. It only affects utterances past the 15 s chunk threshold,
    // which is why Spike 0 (≈7 s fixtures) never exercised it, but FR-4 sizes the
    // ring buffer for 60 s so long utterances are expected input.
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
  private static let languageHint: Language = .portuguese

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
    _ = try await loadedManager()
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

    guard let manager else {
      throw TranscriptionError.notReady
    }

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

  private func loadedManager() async throws -> AsrManager {
    if let manager { return manager }

    if let loadTask {
      // A load is already in flight — join it rather than downloading twice.
      do {
        return try await loadTask.value
      } catch {
        throw Self.mapModelFailure(error)
      }
    }

    let task = Task { [loader] in try await loader.loadManager() }
    loadTask = task
    do {
      let loaded = try await task.value
      manager = loaded
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

  private static func mapModelFailure(_ error: any Error) -> TranscriptionError {
    if let error = error as? TranscriptionError { return error }
    return .modelUnavailable(reason: describe(error))
  }

  private static func mapTranscriptionFailure(_ error: any Error) -> TranscriptionError {
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
