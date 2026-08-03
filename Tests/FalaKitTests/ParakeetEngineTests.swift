import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import FalaKit

// `@testable` is required: `ParakeetModelLoading` and `ParakeetEngine.init(loader:)`
// are deliberately internal so `AsrManager` never reaches FalaKit's public API.
// `import FluidAudio` is required for the same reason — a fake loader has to name
// `AsrManager` in its signature.

/// Unit tests for `ParakeetEngine` (TASKS.md T1.4).
///
/// Everything here runs against a fake `ParakeetModelLoading`, so no CoreML model
/// is downloaded and nothing touches the ANE. Two things make that possible:
///
/// 1. `AsrManager(config:)` is cheap and does NOT load models, so a fake loader
///    can hand back a real-but-empty manager. Calling into it then throws
///    `ASRError.notInitialized`, which is how the FluidAudio → `TranscriptionError`
///    mapping gets exercised for real without a gigabyte of weights.
/// 2. `mapTranscriptionFailure`/`mapModelFailure` are pure functions, so the
///    exhaustive `ASRError` switch is tested directly.
///
/// Real inference lives in `ParakeetEngineIntegrationTests` below, skipped by
/// default.
@Suite("ParakeetEngine")
struct ParakeetEngineTests {

  // MARK: Preconditions

  @Test("Parakeet consumes 16 kHz audio like every other engine")
  func requiredSampleRateIs16k() {
    #expect(ParakeetEngine.requiredSampleRate == 16_000)
  }

  // MARK: prepare()

  @Test("prepare() loads once, no matter how often it is called")
  func prepareIsIdempotent() async throws {
    let loader = FakeModelLoader()
    let engine = ParakeetEngine(loader: loader)

    try await engine.prepare()
    try await engine.prepare()
    try await engine.prepare()

    let loadCount = await loader.loadCount
    #expect(loadCount == 1)
  }

  @Test("Concurrent prepare() callers never start a second 1.1 GB load")
  func concurrentPrepareSharesOneLoad() async throws {
    // The load is held open so the first caller is still in flight when the
    // others arrive, which is the only moment the "join the in-flight task"
    // branch is reachable. The assertion is a `<= 1` invariant and therefore
    // cannot flake: a straggler that arrives after the load completed finds the
    // manager cached and also does not re-load. What would fail is the bug this
    // guards — every caller kicking off its own download.
    let loader = FakeModelLoader(holdsLoadUntilReleased: true)
    let engine = ParakeetEngine(loader: loader)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask { try await engine.prepare() }
      }
      await loader.waitUntilCalled()
      await loader.releaseLoad()
      try await group.waitForAll()
    }

    let loadCount = await loader.loadCount
    #expect(loadCount == 1)
  }

  @Test("A load failure surfaces as a typed TranscriptionError, never raw")
  func loadFailureIsTyped() async {
    let loader = FakeModelLoader(failuresBeforeSuccess: 1)
    let engine = ParakeetEngine(loader: loader)

    let error = await #expect(throws: TranscriptionError.self) {
      try await engine.prepare()
    }

    #expect(isModelUnavailable(error))
    // A reason with no content would make a first-run download failure
    // undiagnosable in the field, where there is no debugger attached.
    #expect(reason(of: error)?.isEmpty == false)
  }

  @Test("A loader that already speaks TranscriptionError is not re-wrapped")
  func typedLoadFailurePassesThrough() async {
    let failure = TranscriptionError.modelUnavailable(reason: "local mirror missing")
    let loader = FakeModelLoader(typedFailure: failure)
    let engine = ParakeetEngine(loader: loader)

    let error = await #expect(throws: TranscriptionError.self) {
      try await engine.prepare()
    }

    #expect(error == failure)
  }

  @Test("A failed load leaves prepare() retryable")
  func prepareIsRetryableAfterFailure() async throws {
    // The usual cause of a first-run failure is a dropped network, so a single
    // failure must not permanently poison the engine.
    let loader = FakeModelLoader(failuresBeforeSuccess: 1)
    let engine = ParakeetEngine(loader: loader)

    await #expect(throws: TranscriptionError.self) {
      try await engine.prepare()
    }
    try await engine.prepare()

    let loadCount = await loader.loadCount
    #expect(loadCount == 2)
  }

  @Test("Every concurrent caller of a failing load gets a typed error")
  func concurrentLoadFailuresAreAllTyped() async {
    // Exercises the second error path in `loadedManager()`: the callers that
    // joined the in-flight task get their error from the join, not from the
    // task's own catch block, so it needs its own mapping.
    let loader = FakeModelLoader(failuresBeforeSuccess: 4, holdsLoadUntilReleased: true)
    let engine = ParakeetEngine(loader: loader)

    let typedFailures = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<4 {
        group.addTask {
          do {
            try await engine.prepare()
            return false
          } catch let error as TranscriptionError {
            return isModelUnavailable(error)
          } catch {
            return false
          }
        }
      }
      await loader.waitUntilCalled()
      await loader.releaseLoad()
      var count = 0
      for await wasTyped in group where wasTyped { count += 1 }
      return count
    }

    #expect(typedFailures == 4)
  }

  // MARK: transcribe() preconditions

  @Test("An engine that never prepared refuses to transcribe")
  func transcribeBeforePrepareIsNotReady() async {
    let engine = ParakeetEngine(loader: FakeModelLoader())

    await #expect(throws: TranscriptionError.notReady) {
      _ = try await engine.transcribe(makeSilence(), biasTerms: [])
    }
  }

  @Test("Empty audio is rejected as invalid, prepared or not")
  func transcribeRejectsEmptyAudio() async throws {
    let engine = ParakeetEngine(loader: FakeModelLoader())
    try await engine.prepare()
    let empty = FalaKit.AudioBuffer(samples: [], sampleRate: 16_000)

    let error = await #expect(throws: TranscriptionError.self) {
      _ = try await engine.transcribe(empty, biasTerms: [])
    }

    #expect(reason(of: error) == "empty buffer")
  }

  @Test(
    "Audio at any rate other than 16 kHz is rejected before inference",
    arguments: [8_000.0, 22_050.0, 44_100.0, 48_000.0])
  func transcribeRejectsWrongSampleRate(sampleRate: Double) async throws {
    let engine = ParakeetEngine(loader: FakeModelLoader())
    try await engine.prepare()
    let audio = makeSilence(seconds: 0.5, sampleRate: sampleRate)

    let error = await #expect(throws: TranscriptionError.self) {
      _ = try await engine.transcribe(audio, biasTerms: [])
    }

    let text = reason(of: error)
    #expect(text?.contains("16000") == true)
    #expect(text?.contains(String(Int(sampleRate))) == true)
  }

  @Test("Validation runs before the readiness check")
  func validationPrecedesReadiness() async {
    // Order matters for the caller: bad audio is the caller's bug and is worth
    // reporting as such even on an engine that was never prepared. Pinning the
    // order here means a reshuffle of `transcribe` has to be deliberate.
    let engine = ParakeetEngine(loader: FakeModelLoader())
    let empty = FalaKit.AudioBuffer(samples: [], sampleRate: 16_000)

    let error = await #expect(throws: TranscriptionError.self) {
      _ = try await engine.transcribe(empty, biasTerms: [])
    }

    #expect(isInvalidAudio(error))
  }

  // MARK: biasTerms (FR-20 [AT RISK] — accepted, deliberately ignored)

  @Test("biasTerms are accepted and change nothing")
  func biasTermsAreAcceptedAndIgnored() async throws {
    // FluidAudio 0.15.5 has no biasing hook on the batch `AsrManager` path, so
    // the contract is "takes them, does nothing, does not fail". Proven by the
    // outcome being identical with and without terms — the only observable this
    // engine offers without loaded models.
    let engine = ParakeetEngine(loader: FakeModelLoader())
    try await engine.prepare()
    let audio = makeSilence()

    let withoutTerms = await #expect(throws: TranscriptionError.self) {
      _ = try await engine.transcribe(audio, biasTerms: [])
    }
    let withTerms = await #expect(throws: TranscriptionError.self) {
      _ = try await engine.transcribe(
        audio, biasTerms: ["Kubernetes", "endpoint", "pull request"])
    }

    #expect(withTerms == withoutTerms)
    // Not an argument-validation failure: the terms were swallowed, not judged.
    #expect(isInvalidAudio(withTerms) == false)
  }

  @Test("A manager with no models loaded reports notReady, not a raw ASRError")
  func unloadedManagerMapsToNotReady() async throws {
    // The fake loader hands back a genuine `AsrManager` that never loaded any
    // weights, so this goes all the way through `transcribe`: decoder-state
    // allocation (which must not `fatalError`), the real FluidAudio call, and
    // the `ASRError.notInitialized` → `.notReady` mapping.
    let engine = ParakeetEngine(loader: FakeModelLoader())
    try await engine.prepare()

    await #expect(throws: TranscriptionError.notReady) {
      _ = try await engine.transcribe(makeSilence(seconds: 1), biasTerms: [])
    }
  }

  // MARK: Error mapping (pure)

  @Test("Model-acquisition failures become .modelUnavailable with a reason")
  func modelFailureMapping() {
    let mapped = ParakeetEngine.mapModelFailure(StubError.plain)

    #expect(isModelUnavailable(mapped))
    #expect(reason(of: mapped)?.isEmpty == false)
  }

  @Test("Both mappers pass an existing TranscriptionError through untouched")
  func mappersDoNotDoubleWrap() {
    let original = TranscriptionError.transcriptionFailed(reason: "engine returned no text")

    #expect(ParakeetEngine.mapModelFailure(original) == original)
    #expect(ParakeetEngine.mapTranscriptionFailure(original) == original)
  }

  @Test("A cancelled load is reported as cancellation, not as a broken model")
  func cancellationIsDescribedAsSuch() {
    let mapped = ParakeetEngine.mapModelFailure(CancellationError())

    #expect(mapped == .modelUnavailable(reason: "cancelled"))
  }

  @Test("A LocalizedError's own description is what reaches the caller")
  func localizedDescriptionIsPreferred() {
    let mapped = ParakeetEngine.mapModelFailure(StubError.localized)

    #expect(mapped == .modelUnavailable(reason: StubError.localizedDescriptionText))
  }

  @Test("A non-localized error still yields a non-empty reason")
  func plainErrorsStillCarryAReason() {
    let mapped = ParakeetEngine.mapTranscriptionFailure(StubError.plain)

    // Falls back to `NSError.localizedDescription`, which is always populated.
    #expect(isTranscriptionFailed(mapped))
    #expect(reason(of: mapped)?.isEmpty == false)
  }

  @Test("ASRError.notInitialized is a readiness problem, not a model problem")
  func notInitializedMapsToNotReady() {
    #expect(ParakeetEngine.mapTranscriptionFailure(ASRError.notInitialized) == .notReady)
  }

  @Test("ASRError.invalidAudioData maps to .invalidAudio")
  func invalidAudioDataMapsToInvalidAudio() {
    let mapped = ParakeetEngine.mapTranscriptionFailure(ASRError.invalidAudioData)

    #expect(isInvalidAudio(mapped))
    #expect(reason(of: mapped)?.isEmpty == false)
  }

  @Test("Every model-side ASRError maps to .modelUnavailable")
  func modelSideAsrErrorsMapToModelUnavailable() {
    // These four say "the models are wrong/missing/unusable", which is a
    // different remedy (re-download, or refuse on Intel) from "this utterance
    // failed" — so they must not collapse into .transcriptionFailed.
    let cases: [ASRError] = [
      .modelLoadFailed,
      .modelCompilationFailed,
      .unsupportedPlatform("Apple Silicon required"),
      .encoderInstantiationFailed("ANE program"),
    ]

    for asrError in cases {
      let mapped = ParakeetEngine.mapTranscriptionFailure(asrError)
      #expect(isModelUnavailable(mapped), "\(asrError) should be .modelUnavailable")
      #expect(reason(of: mapped)?.isEmpty == false)
    }
  }

  @Test("Every run-side ASRError maps to .transcriptionFailed")
  func runSideAsrErrorsMapToTranscriptionFailed() {
    let fileURL = URL(fileURLWithPath: "/dev/null")
    let cases: [ASRError] = [
      .processingFailed("joint network"),
      .streamingConversionFailed(StubError.plain),
      .fileAccessFailed(fileURL, StubError.plain),
    ]

    for asrError in cases {
      let mapped = ParakeetEngine.mapTranscriptionFailure(asrError)
      #expect(isTranscriptionFailed(mapped), "\(asrError) should be .transcriptionFailed")
      #expect(reason(of: mapped)?.isEmpty == false)
    }
  }

  /// FR-8 is REJECTED and FR-20 is `_ = biasTerms`, so this single enum case is
  /// the ENTIRE implementation of FR-7's surviving mitigation (a): "apply the
  /// available script/language filter". Nothing pinned it, so a future "let's try
  /// English and see if the jargon losses improve" experiment could flip it with
  /// no test, gate, or review noticing.
  @Test("The language hint stays Portuguese (FR-7 mitigation (a))")
  func languageHintIsPortuguese() {
    #expect(ParakeetEngine.languageHint == .portuguese)
  }

}

// MARK: - Integration (real models, real ANE — skipped by default)

/// End-to-end check that `ParakeetEngine` actually transcribes PT-BR speech
/// (SPEC.md §6, Phase 1: "Parakeet returns non-empty text for a known PT-BR WAV
/// fixture"). This is the only test that downloads the ~1.1 GB Parakeet TDT v3
/// CoreML bundle, so it is OFF unless both env vars are set — CI and every
/// ordinary `./scripts/test.sh` run skip it.
///
/// ## Running it
/// ```bash
/// FALA_INTEGRATION=1 \
/// FALA_FIXTURE_WAV="$PWD/spike/audio/Audio_2.wav" \
///   ./scripts/test.sh --filter ParakeetEngineIntegrationTests
/// ```
/// The fixture is supplied by path on purpose: `spike/audio/` holds the user's
/// own voice, is git-ignored, and must never be committed (CLAUDE.md/LGPD). Any
/// mono or stereo WAV of PT-BR speech longer than 0.3 s works — `Resampler`
/// converts whatever rate it is at. With `FALA_INTEGRATION=1` but no readable
/// `FALA_FIXTURE_WAV`, the test skips rather than fails, so a fresh clone with
/// no recordings is not a red run.
@Suite("ParakeetEngine integration")
struct ParakeetEngineIntegrationTests {

  @Test(
    "Transcribes a PT-BR fixture to non-empty text, twice on one engine",
    .enabled(
      if: IntegrationFixture.isRunnable,
      "needs FALA_INTEGRATION=1 and FALA_FIXTURE_WAV=<path to a PT-BR .wav>"))
  func transcribesPortugueseFixture() async throws {
    let url = try #require(IntegrationFixture.url)
    let audio = try loadFixture(at: url)
    // FluidAudio rejects anything under 300 ms outright; fail with a readable
    // cause rather than an opaque .invalidAudio from deep inside the engine.
    try #require(
      audio.duration >= 0.3,
      "fixture is shorter than the 0.3 s FluidAudio requires")

    // The public initializer on purpose: this is the one test that exercises
    // `FluidAudioModelLoader`, i.e. the real `ASRConfig(melChunkContext: false)`.
    let engine = ParakeetEngine()
    try await engine.prepare()
    // Idempotency again, but against the real loader, where a second download
    // would be a 1.1 GB mistake rather than a counter increment.
    try await engine.prepare()

    let first = try await engine.transcribe(audio, biasTerms: [])
    // Never assert on, print, or interpolate the transcript itself (CLAUDE.md:
    // transcript text is never logged, and a failing #expect prints its
    // operands). Bind the derived value first so only that can be shown.
    let firstLength = first.text.count
    #expect(firstLength > 0)
    #expect(first.audioDuration > 0)
    #expect(first.processingTime > 0)
    // `calculateConfidence` clamps to [0.1, 1.0] in the pinned 0.15.5, so
    // anything outside that range means the result struct was not populated.
    #expect(first.confidence >= 0.1 && first.confidence <= 1)

    // Same engine, second utterance: proves the loaded models are reused and
    // that a fresh decoder state per call does not break the next dictation.
    // Bias terms are passed here to prove the real path tolerates them (FR-20).
    let second = try await engine.transcribe(
      audio, biasTerms: ["Kubernetes", "deploy", "endpoint"])
    let secondLength = second.text.count
    #expect(secondLength > 0)
    // Same weights, same input, fresh decoder state, and bias terms that are
    // documented as ignored — so the two runs must agree. If this ever fails,
    // one of those three claims is false and needs investigating; it is not a
    // flake to silence. Compared by length, never by content.
    #expect(secondLength == firstLength)
  }
}

// MARK: - Fakes

/// Stand-in for `FluidAudioModelLoader`, so `prepare()`'s idempotency, retry and
/// error mapping can be tested without the 1.1 GB download.
///
/// An `actor` because the concurrency tests call it from several tasks at once;
/// its counters would otherwise be the data race the tests are looking for.
private actor FakeModelLoader: ParakeetModelLoading {

  private let failuresBeforeSuccess: Int
  private let typedFailure: TranscriptionError?
  private let holdsLoadUntilReleased: Bool

  private var callCount = 0
  private var isReleased = false
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    failuresBeforeSuccess: Int = 0,
    typedFailure: TranscriptionError? = nil,
    holdsLoadUntilReleased: Bool = false
  ) {
    self.failuresBeforeSuccess = failuresBeforeSuccess
    self.typedFailure = typedFailure
    self.holdsLoadUntilReleased = holdsLoadUntilReleased
  }

  var loadCount: Int { callCount }

  func loadManager(
    onStage: @escaping @Sendable (ModelDownloadStage) -> Void
  ) async throws -> AsrManager {
    callCount += 1
    resumeArrivalWaiters()

    if holdsLoadUntilReleased, !isReleased {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    if let typedFailure {
      throw typedFailure
    }
    if callCount <= failuresBeforeSuccess {
      throw StubError.plain
    }
    // A real `AsrManager` with no models loaded: construction is cheap (no
    // CoreML, no disk), and any call into it throws `ASRError.notInitialized`,
    // which is exactly the FluidAudio error path worth exercising here.
    return AsrManager(config: ASRConfig(melChunkContext: false))
  }

  /// Suspends until `loadManager()` has been entered at least once, so a test
  /// can be sure the load is genuinely in flight before it releases the gate.
  func waitUntilCalled() async {
    while callCount == 0 {
      await withCheckedContinuation { arrivalWaiters.append($0) }
    }
  }

  func releaseLoad() {
    isReleased = true
    let waiters = releaseWaiters
    releaseWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  private func resumeArrivalWaiters() {
    let waiters = arrivalWaiters
    arrivalWaiters = []
    for waiter in waiters { waiter.resume() }
  }
}

/// Concrete, `Sendable` failures for the fakes. A stored `any Error` would not
/// be `Sendable`, and Swift 6 strict concurrency is not negotiable (CLAUDE.md).
private enum StubError: Error, Sendable {
  /// No `LocalizedError` conformance: forces the `NSError` fallback in `describe`.
  case plain
  /// Carries `errorDescription`, so it takes the `LocalizedError` branch.
  case localized

  static let localizedDescriptionText = "model bundle checksum mismatch"
}

extension StubError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .plain: return nil
    case .localized: return Self.localizedDescriptionText
    }
  }
}

// MARK: - Fixtures & helpers

/// A deterministic synthetic buffer. Content is irrelevant to every unit test
/// here — only length and sample rate are — and recorded speech is never
/// committed to the repo (see the `swift-testing` skill).
private func makeSilence(
  seconds: Double = 0.5,
  sampleRate: Double = 16_000
) -> FalaKit.AudioBuffer {
  FalaKit.AudioBuffer(
    samples: [Float](repeating: 0, count: Int(seconds * sampleRate)),
    sampleRate: sampleRate)
}

private func reason(of error: TranscriptionError?) -> String? {
  switch error {
  case .modelUnavailable(let reason), .invalidAudio(let reason),
    .transcriptionFailed(let reason):
    return reason
  case .notReady, nil:
    return nil
  }
}

private func isModelUnavailable(_ error: TranscriptionError?) -> Bool {
  if case .modelUnavailable = error { return true }
  return false
}

private func isInvalidAudio(_ error: TranscriptionError?) -> Bool {
  if case .invalidAudio = error { return true }
  return false
}

private func isTranscriptionFailed(_ error: TranscriptionError?) -> Bool {
  if case .transcriptionFailed = error { return true }
  return false
}

/// Env-var plumbing for the integration test, kept in one place so the skip
/// reason and the documentation above cannot drift apart.
private enum IntegrationFixture {
  static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["FALA_INTEGRATION"] == "1"
  }

  /// The fixture path, or nil when unset or not readable — an unreadable path
  /// skips instead of failing, because the recordings are personal and are not
  /// in the repo.
  static var url: URL? {
    guard let path = ProcessInfo.processInfo.environment["FALA_FIXTURE_WAV"],
      !path.isEmpty
    else { return nil }
    let expanded = (path as NSString).expandingTildeInPath
    guard FileManager.default.isReadableFile(atPath: expanded) else { return nil }
    return URL(fileURLWithPath: expanded)
  }

  static var isRunnable: Bool { isEnabled && url != nil }
}

private enum FixtureError: Error {
  case emptyFile
  case allocationFailed
}

/// Decodes a WAV at any rate into the 16 kHz mono Float32 the engine requires,
/// reusing the production `Resampler` rather than a second conversion path — so
/// the integration test also covers the real capture → engine handoff (FR-2).
private func loadFixture(at url: URL) throws -> FalaKit.AudioBuffer {
  let file = try AVAudioFile(forReading: url)
  guard file.length > 0 else { throw FixtureError.emptyFile }
  guard
    let buffer = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat,
      frameCapacity: AVAudioFrameCount(file.length))
  else { throw FixtureError.allocationFailed }

  try file.read(into: buffer)
  let resampler = try Resampler()
  return try resampler.finish(buffer)
}
