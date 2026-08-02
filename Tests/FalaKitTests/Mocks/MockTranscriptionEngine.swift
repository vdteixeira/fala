import FalaKit
import Foundation

/// Test double for `TranscriptionEngine` (TASKS.md T1.1).
///
/// It exists so that no test ever needs the real 1.1 GB Parakeet model: it
/// returns canned transcripts, records every call it received (audio *and*
/// `biasTerms`), and can be told to fail with a chosen `TranscriptionError`.
///
/// It is an `actor` because `TranscriptionEngine` is `Sendable` and its methods
/// are non-mutating, so the recorded calls are shared mutable state. An actor is
/// how you make that race-free without `@unchecked Sendable` (CLAUDE.md). The
/// cost is that assertions read state with `await`.
///
/// ```swift
/// let engine = MockTranscriptionEngine(text: "fazer o deploy")
/// _ = try await engine.transcribe(buffer, biasTerms: ["Kubernetes"])
/// let call = await engine.lastCall
/// #expect(call?.biasTerms == ["Kubernetes"])
/// ```
actor MockTranscriptionEngine: TranscriptionEngine {

  /// What a `transcribe` call should do.
  enum Outcome: Sendable, Equatable {
    case success(Transcript)
    case failure(TranscriptionError)

    /// Sugar for the common case: succeed with `text` and no metrics.
    static func text(_ text: String) -> Outcome { .success(Transcript(text: text)) }
  }

  /// One recorded `transcribe` call.
  struct Call: Sendable, Equatable {
    let audio: AudioBuffer
    let biasTerms: [String]
  }

  // MARK: Configuration

  private var defaultOutcome: Outcome
  private var queuedOutcomes: [Outcome] = []
  private var prepareError: TranscriptionError?

  /// When true the mock refuses to transcribe until `prepare()` has run, which
  /// is how `ParakeetEngine` behaves. Off by default so the common test does not
  /// have to care.
  private let requiresPreparation: Bool

  // MARK: Recording

  /// Every call the mock received, in order — including calls it rejected. A
  /// spy records what it was asked to do; filtering is the test's job.
  private(set) var calls: [Call] = []
  private(set) var prepareCallCount = 0
  private var didPrepare = false

  // MARK: Init

  init(
    text: String = "transcrição de teste",
    prepareError: TranscriptionError? = nil,
    requiresPreparation: Bool = false
  ) {
    self.defaultOutcome = .text(text)
    self.prepareError = prepareError
    self.requiresPreparation = requiresPreparation
  }

  init(
    outcome: Outcome,
    prepareError: TranscriptionError? = nil,
    requiresPreparation: Bool = false
  ) {
    self.defaultOutcome = outcome
    self.prepareError = prepareError
    self.requiresPreparation = requiresPreparation
  }

  /// A mock that always succeeds with `text`.
  static func returning(_ text: String) -> MockTranscriptionEngine {
    MockTranscriptionEngine(text: text)
  }

  /// A mock whose every `transcribe` call throws `error`.
  static func failing(_ error: TranscriptionError) -> MockTranscriptionEngine {
    MockTranscriptionEngine(outcome: .failure(error))
  }

  /// A mock whose `prepare()` throws `error` and which then refuses to
  /// transcribe, the way an engine that never loaded its models behaves.
  /// Configured in `init` on purpose: stubbing it afterwards would race with the
  /// code under test calling `prepare()`.
  static func failingPreparation(_ error: TranscriptionError) -> MockTranscriptionEngine {
    MockTranscriptionEngine(prepareError: error, requiresPreparation: true)
  }

  // MARK: Stubbing

  /// Replaces the outcome used once `queue` is exhausted.
  func stub(_ outcome: Outcome) { defaultOutcome = outcome }

  func stub(text: String) { defaultOutcome = .text(text) }

  func stub(error: TranscriptionError) { defaultOutcome = .failure(error) }

  /// Appends a one-shot outcome. Queued outcomes are consumed FIFO, then the
  /// mock falls back to the default — that is how a test scripts a sequence of
  /// dictations without re-stubbing between them.
  func enqueue(_ outcome: Outcome) { queuedOutcomes.append(outcome) }

  func enqueue(text: String) { queuedOutcomes.append(.text(text)) }

  func setPrepareError(_ error: TranscriptionError?) { prepareError = error }

  /// Forgets everything recorded; leaves the stubbing alone.
  func resetRecording() {
    calls = []
    prepareCallCount = 0
    didPrepare = false
  }

  // MARK: Assertions helpers

  var transcribeCallCount: Int { calls.count }
  var lastCall: Call? { calls.last }
  var lastBiasTerms: [String]? { calls.last?.biasTerms }
  var receivedBiasTerms: [[String]] { calls.map(\.biasTerms) }
  /// True only after a `prepare()` that did not throw — a failed preparation
  /// leaves the engine unprepared, which is the whole point of the flag.
  var isPrepared: Bool { didPrepare }

  // MARK: TranscriptionEngine

  func prepare() async throws {
    prepareCallCount += 1
    if let prepareError { throw prepareError }
    didPrepare = true
  }

  func transcribe(_ audio: AudioBuffer, biasTerms: [String]) async throws -> Transcript {
    calls.append(Call(audio: audio, biasTerms: biasTerms))

    // The shared precondition every real engine applies. Running it here is what
    // lets the protocol contract be tested through the mock instead of through
    // the model download.
    try validate(audio)

    if requiresPreparation, !didPrepare {
      throw TranscriptionError.notReady
    }

    let outcome = queuedOutcomes.isEmpty ? defaultOutcome : queuedOutcomes.removeFirst()
    switch outcome {
    case .success(let transcript): return transcript
    case .failure(let error): throw error
    }
  }
}
