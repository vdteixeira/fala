import Foundation
import Testing

@testable import FalaKit

// MARK: - Fakes

private actor FakeCapture: AudioCapturing {
  enum Event: Equatable { case start, stop, cancel }

  private(set) var events: [Event] = []
  private let audio: AudioBuffer
  private let startError: (any Error)?
  private let stopError: (any Error)?

  init(
    audio: AudioBuffer = AudioBuffer(samples: [0.1, 0.2, 0.3], sampleRate: 16_000),
    startError: (any Error)? = nil,
    stopError: (any Error)? = nil
  ) {
    self.audio = audio
    self.startError = startError
    self.stopError = stopError
  }

  func start() async throws {
    events.append(.start)
    if let startError { throw startError }
  }

  func stop() async throws -> AudioBuffer {
    events.append(.stop)
    if let stopError { throw stopError }
    return audio
  }

  func cancel() async { events.append(.cancel) }
}

private actor FakeInjector: TextInjector {
  private(set) var injected: [String] = []
  private let error: InjectionError?

  init(error: InjectionError? = nil) { self.error = error }

  func inject(_ text: String) async throws {
    injected.append(text)
    if let error { throw error }
  }
}

private func makeCoordinator(
  capture: FakeCapture = FakeCapture(),
  engine: MockTranscriptionEngine = MockTranscriptionEngine(),
  injector: FakeInjector = FakeInjector(),
  dictionary: JargonDictionary? = nil
) -> DictationCoordinator {
  DictationCoordinator(
    capture: capture, engine: engine, injector: injector, dictionary: dictionary)
}

// MARK: - Tests

@Suite("DictationCoordinator")
struct DictationCoordinatorTests {

  @Test("A full press/release cycle injects the transcript")
  func happyPath() async throws {
    let capture = FakeCapture()
    let engine = MockTranscriptionEngine(text: "fazer o deploy")
    let injector = FakeInjector()
    let coordinator = makeCoordinator(capture: capture, engine: engine, injector: injector)

    await coordinator.handle(.pressed)
    #expect(await coordinator.currentState == .recording)

    await coordinator.handle(.released)
    #expect(await coordinator.currentState == .success)
    #expect(await injector.injected == ["fazer o deploy"])
    #expect(await capture.events == [.start, .stop])
  }

  @Test("A release with no press does nothing")
  func releaseWithoutPressIsIgnored() async throws {
    let capture = FakeCapture()
    let coordinator = makeCoordinator(capture: capture)

    await coordinator.handle(.released)

    #expect(await coordinator.currentState == .idle)
    #expect(await capture.events.isEmpty)
  }

  /// The regression that protects the audio: a second press while the first
  /// utterance is still being transcribed must not start a second capture.
  @Test("A press during transcription does not start a second capture")
  func pressDuringTranscriptionIsDropped() async throws {
    let capture = FakeCapture()
    let coordinator = makeCoordinator(capture: capture)

    await coordinator.handle(.pressed)
    await coordinator.handle(.pressed)

    #expect(await capture.events == [.start])
  }

  @Test("The jargon dictionary is applied before injection")
  func dictionaryAppliedBeforeInjection() async throws {
    let dictionary = try JargonDictionary(entries: [
      JargonEntry(from: "brand", to: "branch", safety: .safe)
    ])
    let engine = MockTranscriptionEngine(text: "crie uma brand nova")
    let injector = FakeInjector()
    let coordinator = makeCoordinator(
      engine: engine, injector: injector, dictionary: dictionary)

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)

    #expect(await injector.injected == ["crie uma branch nova"])
  }

  @Test("The dictionary's bias terms reach the engine")
  func biasTermsForwarded() async throws {
    let dictionary = try JargonDictionary(entries: [
      JargonEntry(from: "posterg", to: "Postgres", safety: .safe)
    ])
    let engine = MockTranscriptionEngine()
    let coordinator = makeCoordinator(engine: engine, dictionary: dictionary)

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)

    #expect(await engine.receivedBiasTerms.last?.contains("Postgres") == true)
  }

  @Test("A secure field surfaces the pt-BR block message and injects nothing")
  func secureInputSurfacesPortugueseMessage() async throws {
    let injector = FakeInjector(error: .secureInputActive)
    let coordinator = makeCoordinator(injector: injector)

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)

    #expect(
      await coordinator.currentState
        == .failure(message: "Campo protegido — injeção bloqueada."))
  }

  @Test("Empty audio fails without calling the engine")
  func emptyAudioShortCircuits() async throws {
    let capture = FakeCapture(audio: AudioBuffer(samples: [], sampleRate: 16_000))
    let engine = MockTranscriptionEngine()
    let coordinator = makeCoordinator(capture: capture, engine: engine)

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)

    #expect(await engine.transcribeCallCount == 0)
    #expect(await coordinator.currentState == .failure(message: "Nada foi capturado."))
  }

  @Test("A blank transcript is not injected")
  func blankTranscriptIsNotInjected() async throws {
    let engine = MockTranscriptionEngine(text: "   ")
    let injector = FakeInjector()
    let coordinator = makeCoordinator(engine: engine, injector: injector)

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)

    #expect(await injector.injected.isEmpty)
    #expect(await coordinator.currentState == .failure(message: "Não entendi o que foi dito."))
  }

  @Test("A microphone failure is reported and leaves the coordinator recoverable")
  func microphoneFailureIsRecoverable() async throws {
    let capture = FakeCapture(startError: AudioCaptureError.noInputDevice)
    let coordinator = makeCoordinator(capture: capture)

    await coordinator.handle(.pressed)
    let expected = DictationState.failure(message: "Não consegui acessar o microfone.")
    #expect(await coordinator.currentState == expected)

    // A failed attempt must not wedge the app: the next press starts cleanly.
    let recovered = makeCoordinator()
    await recovered.handle(.pressed)
    #expect(await recovered.currentState == .recording)
  }

  @Test("After a failure, a new press starts a new recording")
  func failureStateDoesNotBlockNextDictation() async throws {
    let engine = MockTranscriptionEngine(text: "   ")
    let coordinator = makeCoordinator(engine: engine)

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)
    #expect(await coordinator.currentState == .failure(message: "Não entendi o que foi dito."))

    await coordinator.handle(.pressed)
    #expect(await coordinator.currentState == .recording)
  }

  @Test("Subscribers observe the state sequence, starting from the current one")
  func statesArePublished() async throws {
    let coordinator = makeCoordinator()
    var seen: [DictationState] = []

    let stream = await coordinator.states()
    let collector = Task {
      for await state in stream {
        seen.append(state)
        if state == .success { break }
      }
      return seen
    }

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)

    let observed = await collector.value
    #expect(observed.first == .idle)
    #expect(observed.contains(.recording))
    #expect(
      observed.contains {
        if case .transcribing = $0 { return true }
        return false
      })
    #expect(observed.last == .success)
  }

  @Test("No failure message can contain transcript text")
  func failureMessagesCarryNoTranscript() {
    let messages = [
      DictationCoordinator.message(for: .secureInputActive),
      DictationCoordinator.message(for: .accessibilityDenied),
      DictationCoordinator.message(for: .emptyText),
      DictationCoordinator.message(for: .pasteboardFailure(reason: "segredo do usuário")),
    ]
    #expect(messages.allSatisfy { !$0.contains("segredo") })
    #expect(messages.allSatisfy { !$0.isEmpty })
  }

  /// A truncated recording and a bad transcription look identical to the user, so
  /// the captured duration has to reach the UI. Without it, "Sobin." from a five
  /// second sentence reads as a model failure when it is really lost audio.
  @Test("The transcribing state carries how much audio was captured")
  func transcribingCarriesCapturedDuration() async throws {
    // 1.5 s at 16 kHz.
    let samples = [Float](repeating: 0.1, count: 24_000)
    let capture = FakeCapture(audio: AudioBuffer(samples: samples, sampleRate: 16_000))
    let coordinator = makeCoordinator(capture: capture)

    var seen: [DictationState] = []
    let stream = await coordinator.states()
    let collector = Task {
      for await state in stream {
        seen.append(state)
        if state == .success { break }
      }
      return seen
    }

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)

    let observed = await collector.value
    let captured = observed.compactMap { state -> TimeInterval? in
      if case .transcribing(let seconds) = state { return seconds }
      return nil
    }
    #expect(captured.count == 1)
    #expect((captured.first ?? 0) == 1.5)
  }

  /// Editing the dictionary in Ajustes must reach the NEXT dictation. It used to
  /// be a `let` fixed at construction, so a term added in the settings window did
  /// nothing until the app was relaunched.
  @Test("A dictionary swap applies to the next dictation")
  func dictionarySwapAppliesToNextDictation() async throws {
    let engine = MockTranscriptionEngine(text: "crie uma brand nova")
    let injector = FakeInjector()
    let coordinator = makeCoordinator(engine: engine, injector: injector)

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)
    #expect(await injector.injected == ["crie uma brand nova"])

    let dictionary = try JargonDictionary(entries: [
      JargonEntry(from: "brand", to: "branch", safety: .safe)
    ])
    await coordinator.setDictionary(dictionary)

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)
    #expect(await injector.injected.last == "crie uma branch nova")

    // The bias terms must follow the swap too, or the engine keeps being told
    // about the old vocabulary.
    #expect(await engine.receivedBiasTerms.last?.contains("branch") == true)
  }

  // MARK: - Why the dictation failed

  /// Every `TranscriptionError` case used to arrive as the single string "A
  /// transcrição falhou.". A model that was never downloaded and an utterance
  /// too short to decode need OPPOSITE actions from the user, and nothing about
  /// a dictation may be logged — so if the pill does not distinguish them,
  /// nothing does.
  @Test("Each transcription failure says something different and actionable")
  func transcriptionFailuresAreDistinguished() async throws {
    let cases: [TranscriptionError] = [
      .notReady,
      .modelUnavailable(reason: "download failed"),
      .invalidAudio(reason: "too short"),
      .transcriptionFailed(reason: "no text"),
    ]

    var seen: Set<String> = []
    for error in cases {
      let coordinator = makeCoordinator(engine: MockTranscriptionEngine.failing(error))
      await coordinator.handle(.pressed)
      await coordinator.handle(.released)

      guard case .failure(let message) = await coordinator.currentState else {
        Issue.record("expected a failure for \(error)")
        continue
      }
      #expect(!message.isEmpty)
      #expect(message != "A transcrição falhou.", "still the catch-all: \(error)")
      seen.insert(message)
    }
    #expect(seen.count == cases.count, "two failures share a message: \(seen)")
  }

  /// The reason a third-party string must never reach the pill: FluidAudio's
  /// errors are English, and the `reason` payloads exist for developers.
  @Test("A failure message never leaks the error's internal reason")
  func failureMessagesDoNotLeakInternalReasons() async {
    let coordinator = makeCoordinator(
      engine: MockTranscriptionEngine.failing(
        .transcriptionFailed(reason: "cohere pipeline failed")))
    await coordinator.handle(.pressed)
    await coordinator.handle(.released)

    guard case .failure(let message) = await coordinator.currentState else {
      Issue.record("expected a failure")
      return
    }
    #expect(!message.contains("cohere"))
    #expect(!message.contains("pipeline"))
  }
}
