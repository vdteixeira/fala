import Foundation

/// Mono PCM audio at a known sample rate.
///
/// `TranscriptionEngine` implementations require `Self.requiredSampleRate`
/// (16 kHz); use `Resampler` to convert from the microphone's native format.
public struct AudioBuffer: Sendable, Equatable {
  /// Interleaved-free mono samples, nominally in [-1, 1].
  public let samples: [Float]
  public let sampleRate: Double

  public init(samples: [Float], sampleRate: Double) {
    self.samples = samples
    self.sampleRate = sampleRate
  }

  /// Wall-clock length of the captured audio.
  public var duration: TimeInterval {
    sampleRate > 0 ? TimeInterval(samples.count) / sampleRate : 0
  }

  public var isEmpty: Bool { samples.isEmpty }
}

/// A completed transcription. Carries no audio and no identifying metadata:
/// nothing here may be logged (see CLAUDE.md golden rules).
public struct Transcript: Sendable, Equatable {
  public let text: String
  public let confidence: Float
  public let audioDuration: TimeInterval
  public let processingTime: TimeInterval

  public init(
    text: String,
    confidence: Float = 0,
    audioDuration: TimeInterval = 0,
    processingTime: TimeInterval = 0
  ) {
    self.text = text
    self.confidence = confidence
    self.audioDuration = audioDuration
    self.processingTime = processingTime
  }
}

public enum TranscriptionError: Error, Equatable, Sendable {
  /// `prepare()` was never called, or it failed.
  case notReady
  /// Model files could not be downloaded or loaded.
  case modelUnavailable(reason: String)
  /// Audio was empty, or not at `requiredSampleRate`.
  case invalidAudio(reason: String)
  /// The engine ran but produced nothing usable.
  case transcriptionFailed(reason: String)
}

/// The seam that keeps the ASR engine choice reversible (SPEC.md FR-5).
///
/// GATE S0 did not close: Parakeet TDT v3 lost every English jargon term it was
/// tested on, so WhisperKit remains a live alternative. Nothing outside
/// `Sources/FalaKit/Transcription` may depend on which implementation is in use.
public protocol TranscriptionEngine: Sendable {
  /// All engines consume 16 kHz mono Float32.
  static var requiredSampleRate: Double { get }

  /// Loads models. Expensive and network-dependent on first run; call once at
  /// startup, never on the hotkey path.
  func prepare() async throws

  /// `prepare()`, reporting progress.
  ///
  /// Exists because selecting an engine whose model is not on disk starts a
  /// multi-hundred-megabyte download, and without this the UI had nothing to
  /// show: the user clicked, nothing visibly happened, and the app looked
  /// broken while it was in fact working. `onStage` is called on an unspecified
  /// executor — hop to the main actor inside it if you are driving UI.
  func prepare(onStage: @escaping @Sendable (ModelDownloadStage) -> Void) async throws

  /// Transcribes one complete utterance (batch; v1 has no streaming).
  ///
  /// - Parameter biasTerms: vocabulary the engine should favour, e.g. the jargon
  ///   dictionary's canonical spellings. Deliberately opaque `[String]` — each
  ///   engine translates it into its own mechanism, so neither FluidAudio's
  ///   custom-vocabulary types nor WhisperKit's prompt tokens leak through this
  ///   protocol. Engines with no biasing mechanism ignore it.
  func transcribe(_ audio: AudioBuffer, biasTerms: [String]) async throws -> Transcript
}

extension TranscriptionEngine {
  public static var requiredSampleRate: Double { 16_000 }

  /// Engines that cannot report progress still satisfy the protocol; they simply
  /// never call back. A test double does not have to grow a download story.
  public func prepare(onStage: @escaping @Sendable (ModelDownloadStage) -> Void) async throws {
    try await prepare()
  }

  public func transcribe(_ audio: AudioBuffer) async throws -> Transcript {
    try await transcribe(audio, biasTerms: [])
  }

  /// Shared precondition check so every engine rejects bad audio identically.
  public func validate(_ audio: AudioBuffer) throws {
    guard !audio.isEmpty else {
      throw TranscriptionError.invalidAudio(reason: "empty buffer")
    }
    guard audio.sampleRate == Self.requiredSampleRate else {
      throw TranscriptionError.invalidAudio(
        reason: "expected \(Int(Self.requiredSampleRate)) Hz, got \(Int(audio.sampleRate)) Hz")
    }
  }
}
