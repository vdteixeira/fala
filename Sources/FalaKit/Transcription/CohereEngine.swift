import CoreML
import FluidAudio
import Foundation

/// Seam over Cohere model acquisition, mirroring `ParakeetModelLoading` so both
/// engines can be exercised without a download.
protocol CohereModelLoading: Sendable {
  func loadModels(
    onStage: @escaping @Sendable (ModelDownloadStage) -> Void
  ) async throws -> CoherePipeline.LoadedModels
}

/// Production loader: downloads (first run) and loads the q8 CoreML bundle.
struct FluidAudioCohereLoader: CohereModelLoading {
  func loadModels(
    onStage: @escaping @Sendable (ModelDownloadStage) -> Void
  ) async throws -> CoherePipeline.LoadedModels {
    let directory = CohereEngine.modelDirectory
    // `to:` is the CACHE ROOT, not the model directory: `ModelHub.download`
    // appends `repo.folderName` itself. Passing the model directory's parent
    // made it write to `…/Models/cohere-transcribe-03-2026-coreml/
    // cohere-transcribe/q8` while the loader below opened
    // `…/Models/cohere-transcribe-03-2026-coreml/q8`, so every first run
    // downloaded the model successfully and then failed to find it.
    try await ModelHub.download(
      .cohereTranscribeCoreml,
      to: CohereEngine.modelsRoot,
      variant: CohereEngine.variant,
      progressHandler: { progress in onStage(ModelDownloadStage(progress)) })

    // Bytes are down; CoreML now opens the compiled bundles, which is seconds of
    // apparent silence if nothing says so.
    onStage(.installing)

    // Encoder, decoder and vocab all come from the same directory here. The
    // pipeline takes them separately because it supports mixed precision
    // (INT8 encoder + FP16 decoder); we ship the uniform q8 bundle.
    return try await CoherePipeline.loadModels(
      encoderDir: directory,
      decoderDir: directory,
      vocabDir: directory,
      // v2 has a fixed attention-mask shape and is the ANE-friendly one; v1
      // falls back to CPU/GPU, which is the opposite of what this app wants.
      decoderVariant: .v2,
      computeUnits: .all)
  }
}

/// The alternative engine: Cohere Transcribe via FluidAudio (SPEC.md FR-5's
/// "future fallback" slot, filled 2026-08-03).
///
/// ## Why this exists
/// `ParakeetEngine` cannot pin Portuguese. FluidAudio's `language` parameter on
/// the Parakeet path is a Latin-vs-Cyrillic SCRIPT filter — it cannot separate
/// pt from en or fr, which is why SPEC.md FR-7 was downgraded from [CONFIRMED]
/// to [REVISED] and why English jargon inside Portuguese speech degrades the way
/// GATE S0 measured.
///
/// Cohere Transcribe forces the language in the decoder's prefill: its
/// `promptSequence` injects the `<|pt|>` token TWICE into the prompt, the same
/// mechanism Whisper uses. That is a real language lock, not a hint.
///
/// It also costs no new dependency — it ships inside the FluidAudio version this
/// project already pins and audits.
///
/// ## Not the default
/// Parakeet stays the default (SPEC.md §2 is [CONFIRMED] on one engine for v1).
/// This is offered in Ajustes › Modelo so the user can compare on their own
/// voice, which is what GATE S0 needs and what `FalaSpike` measures.
public actor CohereEngine: TranscriptionEngine {

  /// Forced, not hinted — the entire reason this engine is here.
  static let language: CohereAsrConfig.Language = .portuguese

  /// Above this, the pipeline chunks with a sliding window internally.
  /// `transcribeLong` handles it; calling plain `transcribe` on longer audio
  /// would silently truncate at 35 s, and FR-4 sizes the ring buffer for 60.
  static let singleShotSeconds = Double(CohereAsrConfig.maxAudioSeconds)

  static let variant = "q8"

  /// FluidAudio's shared model cache — the directory `ModelHub` appends a
  /// repository's own folder name to.
  static var modelsRoot: URL {
    FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/FluidAudio/Models")
  }

  /// Where FluidAudio caches this bundle.
  ///
  /// DERIVED from `Repo.folderName` rather than spelled out, because that is
  /// the value `ModelHub.download` uses to decide where the bytes land — and
  /// the hand-written copy this replaced said
  /// `cohere-transcribe-03-2026-coreml/q8` (the REMOTE path) where FluidAudio
  /// 0.15.5 writes `cohere-transcribe/q8` (the LOCAL folder name). Those two
  /// disagree by design upstream, and a settings row reporting "não baixado"
  /// over a model that downloaded fine is the same class of lie as the "pronto"
  /// over a missing one that `ModelReadiness` exists to prevent.
  ///
  /// Re-check on a version bump — the `fluidaudio-asr` skill's checklist covers
  /// it, and `CohereModelLayoutTests` fails if the two ever diverge again.
  public static var modelDirectory: URL {
    modelsRoot.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName)
  }

  private let loader: any CohereModelLoading
  private let pipeline = CoherePipeline()
  private var models: CoherePipeline.LoadedModels?
  private var loadTask: Task<CoherePipeline.LoadedModels, any Error>?

  public init() {
    self.loader = FluidAudioCohereLoader()
  }

  init(loader: any CohereModelLoading) {
    self.loader = loader
  }

  /// Downloads on first run and loads into the ANE. Idempotent; callers arriving
  /// mid-load join it rather than starting a second download.
  public func prepare() async throws {
    _ = try await loadedModels(onStage: { _ in })
  }

  public func prepare(
    onStage: @escaping @Sendable (ModelDownloadStage) -> Void
  ) async throws {
    _ = try await loadedModels(onStage: onStage)
  }

  public func transcribe(_ audio: AudioBuffer, biasTerms: [String]) async throws -> Transcript {
    try validate(audio)

    // Accepted and ignored, exactly as `ParakeetEngine` does: this pipeline has
    // no vocabulary-biasing hook either. Pretending otherwise would hide that
    // FR-9's dictionary is still the whole mitigation budget.
    _ = biasTerms

    let models = try await readyModels()

    do {
      let result =
        audio.duration > Self.singleShotSeconds
        ? try await pipeline.transcribeLong(
          audio: audio.samples, models: models, language: Self.language)
        : try await pipeline.transcribe(
          audio: audio.samples, models: models, language: Self.language)

      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        throw TranscriptionError.transcriptionFailed(reason: "engine returned no text")
      }
      return Transcript(
        text: text,
        // The pipeline reports no confidence, and inventing one would be worse
        // than admitting there is none.
        confidence: 0,
        audioDuration: audio.duration,
        processingTime: result.totalSeconds)
    } catch let error as TranscriptionError {
      throw error
    } catch {
      throw Self.mapFailure(error)
    }
  }

  // MARK: - Loading

  /// The loaded models, WAITING for an in-flight `prepare()` rather than failing.
  ///
  /// MEASURED (2026-08-03): `prepare()` takes 97 s for this engine on a machine
  /// that already holds the 4,98 GB model — 88 s of it is the ANE warm-up, and
  /// it is paid at EVERY launch, not once. Throwing `.notReady` inside that
  /// window meant a user who opened the app and immediately dictated lost the
  /// utterance to an error message, having done nothing wrong. That is what
  /// "aparece uma mensagem de erro depois da transcrição" was.
  ///
  /// Waiting is legible where failing is not: the pill is already showing
  /// "transcrevendo", so the utterance arrives late instead of not at all.
  ///
  /// A load that was NEVER started still throws. That is a wiring bug in the
  /// app, and turning the hotkey path into a lazy 4,98 GB download is exactly
  /// what `prepare()` exists to prevent.
  private func readyModels() async throws -> CoherePipeline.LoadedModels {
    if let models { return models }
    guard loadTask != nil else { throw TranscriptionError.notReady }
    return try await loadedModels(onStage: { _ in })
  }

  private func loadedModels(
    onStage: @escaping @Sendable (ModelDownloadStage) -> Void
  ) async throws -> CoherePipeline.LoadedModels {
    if let models { return models }

    if let loadTask {
      do {
        let loaded = try await loadTask.value
        // Cache it here too. Only the caller that CREATED the task used to
        // store the result, so a joiner returned models the actor promptly
        // forgot — and the next `transcribe` started the wait all over again.
        models = loaded
        return loaded
      } catch {
        throw Self.mapFailure(error)
      }
    }

    let task = Task { [loader, pipeline] in
      let loaded = try await loader.loadModels(onStage: onStage)

      // MEASURED (2026-08-03, M3 Pro, spike over the same six fixtures, three
      // separate runs): the FIRST transcription in a process costs ~92 s, every
      // subsequent one ~3.4 s. It is a per-process cost, not a one-time compile
      // — a fresh run pays it again. Without this warm-up the user selects
      // Cohere, waits through the download, then holds the hotkey and watches a
      // pill sit in "transcrevendo" for a minute and a half. That is
      // indistinguishable from a hang, and it lands on the ONE path FR-3 says
      // must feel immediate.
      //
      // So it is paid here, while the settings pane is still showing progress
      // and the user already expects to wait. One second of silence is enough:
      // the cost is warming the ANE, not the content.
      onStage(.installing)
      let silence = [Float](repeating: 0, count: Int(Self.requiredSampleRate))
      // Best-effort. A warm-up that fails must not fail the load — the engine is
      // loaded and usable; the user would just pay the cost on the first real
      // utterance, which is exactly the status quo this improves on.
      _ = try? await pipeline.transcribe(
        audio: silence, models: loaded, language: Self.language)
      return loaded
    }
    loadTask = task
    do {
      let loaded = try await task.value
      models = loaded
      loadTask = nil
      return loaded
    } catch {
      // A failed load must stay retryable: the usual cause is a transient
      // network failure on the first run.
      loadTask = nil
      throw Self.mapFailure(error)
    }
  }

  /// Maps FluidAudio's errors onto ours without letting a third-party English
  /// string escape as a user-facing message.
  static func mapFailure(_ error: any Error) -> TranscriptionError {
    if let cohere = error as? CohereAsrError {
      switch cohere {
      case .invalidInput:
        return .invalidAudio(reason: "audio too short for this engine")
      default:
        return .transcriptionFailed(reason: "cohere pipeline failed")
      }
    }
    if error is URLError {
      return .modelUnavailable(reason: "model download failed")
    }
    return .transcriptionFailed(reason: "cohere pipeline failed")
  }
}
