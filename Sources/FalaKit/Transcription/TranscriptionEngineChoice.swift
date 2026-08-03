import FluidAudio
import Foundation

/// Which ASR engine transcribes the next dictation.
///
/// ## This does not reopen SPEC.md §2
///
/// §2 is [CONFIRMED] on ONE engine for v1, and `parakeet` is the default here
/// and stays the default. What this type adds is a way to COMPARE the two on
/// the user's own voice, which is exactly what GATE S0 still needs: run 1
/// measured aggregate WER 11.4% but lost all seven English jargon terms it was
/// tested on, and the code-switching criterion failed. `CohereEngine` is the
/// first alternative that can actually pin Portuguese, so the comparison is now
/// worth offering — as a choice the user makes deliberately, never as a silent
/// switch.
///
/// ## What each case must be able to say for itself
///
/// A picker that describes an engine it cannot check is worse than no picker.
/// So every case carries three things: what it is called, what the trade-off
/// costs in plain pt-BR, and `modelLayout` — where ITS model lives and what
/// complete means for it. Nothing about one engine is ever answered from the
/// other's directory.
public enum TranscriptionEngineChoice: String, CaseIterable, Sendable, Identifiable {

  /// Parakeet TDT v3 through FluidAudio (SPEC.md FR-6). The default.
  case parakeet

  /// Cohere Transcribe through FluidAudio. Forces Portuguese in the decoder's
  /// prefill, which Parakeet's script filter cannot do (SPEC.md FR-7).
  case cohere

  public var id: String { rawValue }

  /// The engine the app ships with. Restated here so a reader of this type does
  /// not have to open `Preferences` to find out which one it is; the two are
  /// pinned to each other by `PreferencesDefaultsTests`.
  public static let `default` = TranscriptionEngineChoice.parakeet

  public var isDefault: Bool { self == Self.default }

  /// Product name, spelled as the popover and Ajustes › Modelo already spell it
  /// — `ModelBlock.modelName` is reused so the three surfaces cannot drift.
  public var displayName: String {
    switch self {
    case .parakeet: return "\(ModelBlock.modelName) v3"
    case .cohere: return "Cohere Transcribe"
    }
  }

  /// Short product name, for surfaces the mockup sizes tightly.
  ///
  /// The popover's block reads "Modelo <name> · pronto" and DESIGN.md makes the
  /// mockup the authority on visuals, where that string is "Modelo Parakeet ·
  /// pronto". `displayName` would stretch it to "Parakeet v3" / "Cohere
  /// Transcribe" and push the row into a second line.
  public var shortName: String {
    switch self {
    case .parakeet: return ModelBlock.modelName
    case .cohere: return "Cohere"
    }
  }

  /// The trade-off, in pt-BR, in the fewest honest words.
  ///
  /// Every number below is MEASURED and every gap is admitted:
  ///
  /// * Parakeet's ~100 ms is GATE S0 run 1 on this machine (94–149 ms per
  ///   utterance over 44.3 s of audio, 2026-08-02). Its 483 MB is the real
  ///   completed download, NOT the "1,1 GB" the mockup and FluidAudio's docs
  ///   quote — that is the upstream repository across every precision variant.
  /// * Parakeet's inability to pin Portuguese is not a hedge: FluidAudio's
  ///   `language` parameter filters Latin vs Cyrillic script and does not
  ///   condition the decoder, so it cannot separate pt from en (SPEC.md FR-7).
  /// * Cohere's ~3,4 s is the same run (3,3–4,7 s per utterance over the same
  ///   six fixtures, 2026-08-03), measured AFTER the warm-up `CohereEngine`
  ///   now performs during loading — the first inference in a process costs
  ///   ~92 s without it.
  /// * Cohere's 4,7 GB is `du` on the installed directory, not a spec sheet.
  ///   FluidAudio downloads the `.mlpackage` AND the pre-compiled `.mlmodelc`
  ///   for three models, of which this app loads two `.mlmodelc`; roughly half
  ///   those bytes are never opened. That is upstream's packaging, not
  ///   something this app can trim, so the user is told the number they will
  ///   actually pay.
  ///
  /// Accuracy is deliberately absent from BOTH strings. The spike measures
  /// Cohere well ahead on code-switching, but over 70 reference words with two
  /// self-graded fixtures — GATE S0 is open precisely because that is not
  /// enough to claim anything. Latency and disk are facts; accuracy is not yet.
  public var summary: String {
    switch self {
    case .parakeet:
      return "Padrão. Rápido: cerca de 100 ms por frase, medido neste Mac. "
        + "Não consegue fixar o português — o filtro de idioma dele só separa "
        + "alfabetos, então termos em inglês podem sair em inglês."
    case .cohere:
      return "Fixa o português no decodificador, coisa que o \(ModelBlock.modelName) "
        + "não consegue fazer. Em troca é bem mais lento: cerca de 3,4 s por "
        + "frase, medido neste Mac, e leva cerca de 1,5 min preparando toda vez "
        + "que o app abre. O download é grande, quase 5 GB."
    }
  }

  /// Where THIS engine's model lives and what a complete download of it looks
  /// like. The whole reason `ModelLayout` exists.
  /// Builds the engine this choice names.
  ///
  /// Lives here rather than in the UI layer so the CLI paths (`listen`, `run`)
  /// and the menu-bar pipeline cannot drift into disagreeing about what
  /// "cohere" means — they all hardcoded `ParakeetEngine()` before this existed
  /// and silently ignored the setting.
  public func makeEngine() -> any TranscriptionEngine {
    switch self {
    case .parakeet: return ParakeetEngine()
    case .cohere: return CohereEngine()
    }
  }

  public var modelLayout: ModelLayout {
    switch self {
    case .parakeet: return .parakeet
    case .cohere: return .cohere
    }
  }
}

// MARK: - The Cohere layout

extension ModelLayout {

  /// FluidAudio 0.15.5's `cohere-transcribe/q8` cache.
  ///
  /// The names come from `ModelNames.CohereTranscribe`, so a version bump that
  /// renames a bundle changes this with it instead of leaving a settings row
  /// quietly reporting a directory that no longer exists.
  ///
  /// Both size fields were `nil` until a complete download existed to measure.
  /// It does now: 4.984.768.322 bytes over 21 files, `find -exec stat` on the
  /// finished directory (2026-08-03), which the app's own formatter renders as
  /// "4,98 GB". Roughly half of that is never opened — FluidAudio ships the
  /// `.mlpackage` AND the pre-compiled `.mlmodelc` for three models while this
  /// app loads two `.mlmodelc` — but the user pays for all of it, so all of it
  /// is what gets quoted.
  ///
  /// Do not replace either number with one read off a model card. "pronto ·
  /// 1,1 GB" over a directory nobody had measured is how this row stopped
  /// meaning anything the first time.
  public static var cohere: ModelLayout {
    ModelLayout(
      location: CohereEngine.modelDirectory,
      requiredFiles: [cohereVocabularyFile],
      requiredBundles: cohereBundles,
      // A floor, not the total: a partial download must fail the check, and a
      // future variant that legitimately shrinks a little must not.
      minimumPlausibleBytes: 4_000_000_000,
      expectedDownloadBytes: 4_984_768_322)
  }

  /// The ANE-friendly v2 decoder set — the one `CohereEngine` loads
  /// (`decoderVariant: .v2`). The legacy FP16 decoder is a different file and
  /// would report as missing, which is correct: we do not load it.
  static var cohereBundles: [String] {
    [
      ModelNames.CohereTranscribe.encoderCompiledFile,
      ModelNames.CohereTranscribe.decoderCacheExternalV2CompiledFile,
    ]
  }

  static var cohereVocabularyFile: String { ModelNames.CohereTranscribe.vocab }
}
