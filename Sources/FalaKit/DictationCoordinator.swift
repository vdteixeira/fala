import Foundation

/// What the app is doing right now. Drives the pill overlay in Phase 2, and the
/// six-state vocabulary in design/DESIGN-HANDOFF.md maps onto it directly.
public enum DictationState: Sendable, Equatable {
  case idle
  case recording
  /// Carries how much audio was actually captured. Surfaced because a truncated
  /// recording is otherwise indistinguishable from a bad transcription: both look
  /// like "the model got it wrong", and the fixes are completely different.
  case transcribing(capturedSeconds: TimeInterval)
  case success
  /// Something failed. The message is pt-BR and safe to show: it never contains
  /// transcript text.
  case failure(message: String)
}

/// The one place the whole dictation flow is wired together (SPEC.md US-1).
///
/// hotkey down → capture → hotkey up → transcribe → jargon dictionary → inject.
///
/// Every collaborator is a protocol, so this is fully testable without a
/// microphone, a model download, or Accessibility. It owns no UI and no event
/// tap: `HotkeyManager` feeds it phases, and it publishes states back.
public actor DictationCoordinator {
  private let capture: any AudioCapturing
  private let engine: any TranscriptionEngine
  private let injector: any TextInjector
  private let dictionary: JargonDictionary?

  private var state: DictationState = .idle
  private var continuations: [UUID: AsyncStream<DictationState>.Continuation] = [:]

  /// Terms the engine should favour. Empty unless a dictionary is loaded; passed
  /// through the protocol's opaque `biasTerms`, so no engine's vocabulary API
  /// leaks in here.
  private let biasTerms: [String]

  public init(
    capture: any AudioCapturing,
    engine: any TranscriptionEngine,
    injector: any TextInjector,
    dictionary: JargonDictionary? = nil
  ) {
    self.capture = capture
    self.engine = engine
    self.injector = injector
    self.dictionary = dictionary
    self.biasTerms = dictionary?.biasTerms ?? []
  }

  public var currentState: DictationState { state }

  /// States, for the overlay. Each subscriber gets the current state immediately
  /// so a late subscriber is never out of sync.
  public func states() -> AsyncStream<DictationState> {
    AsyncStream { continuation in
      let id = UUID()
      continuations[id] = continuation
      continuation.yield(state)
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeContinuation(id) }
      }
    }
  }

  /// Feeds one hotkey transition. Never throws: a dictation failing must not take
  /// down whatever is driving the event tap.
  public func handle(_ phase: HotkeyPhase) async {
    switch phase {
    case .pressed:
      await beginRecording()
    case .released:
      await finishRecording()
    }
  }

  private func beginRecording() async {
    // A press arriving mid-transcription is dropped rather than queued: starting a
    // second capture would interleave with the first utterance's audio. Dropping
    // costs the user one repeat; interleaving corrupts both.
    guard state == .idle || isTerminal(state) else { return }

    do {
      try await capture.start()
      transition(to: .recording)
    } catch {
      transition(to: .failure(message: "Não consegui acessar o microfone."))
    }
  }

  private func finishRecording() async {
    guard state == .recording else { return }

    // Stop BEFORE announcing `.transcribing`, so the announcement can carry how
    // much audio there actually is. `stop()` is a drain and a flush, not a wait.
    let audio: AudioBuffer
    do {
      audio = try await capture.stop()
    } catch {
      transition(to: .failure(message: "A gravação falhou."))
      return
    }

    guard !audio.isEmpty else {
      transition(to: .failure(message: "Nada foi capturado."))
      return
    }
    transition(to: .transcribing(capturedSeconds: audio.duration))

    do {
      let transcript = try await engine.transcribe(audio, biasTerms: biasTerms)
      let text = finalText(from: transcript)
      guard !text.isEmpty else {
        transition(to: .failure(message: "Não entendi o que foi dito."))
        return
      }
      try await injector.inject(text)
      transition(to: .success)
    } catch let error as InjectionError {
      transition(to: .failure(message: Self.message(for: error)))
    } catch {
      transition(to: .failure(message: "A transcrição falhou."))
    }
  }

  /// Applies the jargon dictionary. Kept separate so the ordering — ASR output
  /// first, substitutions second — is visible and testable.
  private func finalText(from transcript: Transcript) -> String {
    let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let dictionary, !raw.isEmpty else { return raw }
    return dictionary.apply(to: raw)
  }

  /// pt-BR messages for the cases the user can act on (SPEC.md FR-13, US-3).
  /// None of these embeds transcript text.
  static func message(for error: InjectionError) -> String {
    switch error {
    case .secureInputActive:
      return "Campo protegido — injeção bloqueada."
    case .accessibilityDenied:
      return "Permissão de Acessibilidade necessária."
    case .emptyText:
      return "Nada para inserir."
    case .pasteboardFailure:
      return "Não consegui inserir o texto."
    }
  }

  private func isTerminal(_ state: DictationState) -> Bool {
    if case .failure = state { return true }
    return state == .success
  }

  private func transition(to newState: DictationState) {
    state = newState
    for continuation in continuations.values {
      continuation.yield(newState)
    }
  }

  private func removeContinuation(_ id: UUID) {
    continuations[id] = nil
  }
}
