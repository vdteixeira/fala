import AVFoundation
import FluidAudio
import Foundation

/// Spike 0 — throwaway WER harness (TASKS.md, GATE S0). DELETE after the engine
/// decision. Validates FR-7/NFR-2: measured PT-BR WER with Parakeet TDT v3 via
/// FluidAudio, on the user's own fixture recordings.
///
/// Usage: swift run FalaSpike [fixtures-dir]   (default: spike/audio)
/// Expects pairs: <name>.wav + <name>.txt (reference transcription, one line).
///
/// PRIVACY NOTE: this harness intentionally prints hypothesis vs reference text.
/// That is acceptable ONLY because inputs are the user's own fixture recordings
/// made for this evaluation (see CLAUDE.md golden-rule exception). It must never
/// be pointed at live dictation audio.
@main
struct Spike {
  static func main() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    // --suggest: emit raw hypotheses as *.txt.suggested drafts for the user to
    // correct. NEVER writes .txt directly — a machine-written reference would
    // make the harness grade itself (WER ≈ 0) and the NFR-2 gate meaningless.
    let suggestMode = args.contains("--suggest")
    let dir = args.first { !$0.hasPrefix("--") } ?? "spike/audio"
    let dirURL = URL(fileURLWithPath: dir)

    let wavs = try fixtureWavs(in: dirURL)
    guard !wavs.isEmpty else {
      // Show the RESOLVED path: the default is relative to the current directory,
      // so running this from inside spike/audio looks for spike/audio/spike/audio
      // and reports "no fixtures" for a directory that is full of them.
      let resolved = dirURL.standardizedFileURL.path
      print("No .wav fixtures found in: \(resolved)")
      print("(current directory: \(FileManager.default.currentDirectoryPath))")
      print("Run this from the repository root, or pass an absolute path.")
      print("See spike/README.md for recording instructions.")
      exit(1)
    }

    print("Loading Parakeet TDT v3 (downloads ~480 MB on first run)...")
    let models = try await AsrModels.downloadAndLoad(version: .v3)
    // Must match ParakeetEngine's config or the measurement describes a different
    // system than the one that ships — see the comment there on melChunkContext.
    let manager = AsrManager(config: ASRConfig(melChunkContext: false))
    try await manager.loadModels(models)
    print("Model ready. Transcribing \(wavs.count) fixture(s)...\n")

    if suggestMode {
      try await writeSuggestions(for: wavs, using: manager)
      return
    }

    var totalEdits = 0
    var totalRefWords = 0
    // Tracked separately: fixtures containing English IT jargon are the product's
    // actual use case, so their WER is the number that matters. Jargon-free
    // fixtures dilute the aggregate and can float a failing engine over the gate.
    var jargonEdits = 0
    var jargonRefWords = 0
    var codeSwitchMisses: [String] = []
    var unverified: [String] = []

    for wav in wavs {
      let refURL = wav.deletingPathExtension().appendingPathExtension("txt")
      guard let reference = try? String(contentsOf: refURL, encoding: .utf8) else {
        print("SKIP \(wav.lastPathComponent): missing reference \(refURL.lastPathComponent)")
        continue
      }

      // Fresh decoder state per file: fixtures are independent utterances.
      var state = TdtDecoderState.make()
      let result = try await manager.transcribe(wav, decoderState: &state, language: .portuguese)

      let refWords = normalize(reference)
      let hypWords = normalize(result.text)
      let edits = levenshtein(refWords, hypWords)
      let wer = refWords.isEmpty ? 0 : Double(edits) / Double(refWords.count)
      totalEdits += edits
      totalRefWords += refWords.count

      let missed = missedJargon(reference: reference, hypothesis: result.text)
      codeSwitchMisses.append(contentsOf: missed)
      if containsJargon(reference) {
        jargonEdits += edits
        jargonRefWords += refWords.count
      }

      print(
        String(
          format: "%@  WER %5.1f%%  (%.0f ms proc, %.1f s audio)",
          wav.lastPathComponent, wer * 100,
          result.processingTime * 1000, result.duration))
      if wer > 0 {
        print("  ref: \(refWords.joined(separator: " "))")
        print("  hyp: \(hypWords.joined(separator: " "))")
      }
      if !missed.isEmpty {
        print("  jargon missed: \(missed.joined(separator: ", "))")
      }
      // Contamination signature: a reference that exactly matches the hypothesis
      // AND was never modified after creation is almost certainly a --suggest
      // draft renamed without review. It scores 0% by construction and inflates
      // the pass margin. Flag it rather than drop it — dropping data silently is
      // its own failure mode.
      if edits == 0 && wasNeverEdited(refURL) {
        unverified.append(wav.lastPathComponent)
        print("  ⚠︎ UNVERIFIED reference: identical to model output and never edited")
      }
    }

    guard totalRefWords > 0 else {
      print("No scorable fixtures (all missing references).")
      exit(1)
    }

    let aggregate = Double(totalEdits) / Double(totalRefWords) * 100
    let jargonWer =
      jargonRefWords > 0 ? Double(jargonEdits) / Double(jargonRefWords) * 100 : aggregate

    print(
      String(format: "\nAGGREGATE WER: %.1f%% over %d reference words", aggregate, totalRefWords))
    if jargonRefWords > 0 && jargonRefWords < totalRefWords {
      print(
        String(
          format: "CODE-SWITCHING WER: %.1f%% over %d words (jargon-bearing fixtures only)",
          jargonWer, jargonRefWords))
    }

    let missedTerms = Set(codeSwitchMisses).sorted()
    if missedTerms.isEmpty {
      print("Code-switching: all jargon terms preserved.")
    } else {
      print("Code-switching MISSES: \(missedTerms.joined(separator: ", "))")
    }

    // SPEC.md NFR-2 joins TWO criteria with OR: the WER threshold and
    // code-switching integrity. The WER arm is scored on the jargon-bearing subset,
    // because jargon-free fixtures dilute the aggregate and can float a failing
    // engine over the line — this product exists to dictate code-switched speech.
    let werPasses = jargonWer <= 12.0
    let codeSwitchingPasses = missedTerms.isEmpty

    print("\n--- GATE S0 (SPEC.md NFR-2) ---")
    print(
      String(
        format: "  WER criterion (<= 12%% on code-switching speech):  %@",
        werPasses ? "PASS" : "FAIL"))
    print(
      "  Code-switching criterion (no terms lost):         "
        + (codeSwitchingPasses ? "PASS" : "FAIL"))

    if !unverified.isEmpty {
      print(
        """

        ⚠︎ MEASUREMENT INTEGRITY: \(unverified.count) reference(s) scored 0% while being
          byte-identical to the model's own output and never edited after creation:
          \(unverified.joined(separator: ", "))
          These are self-graded and inflate the pass margin. Rewrite them by hand
          before trusting any verdict below.
        """)
    }

    if totalRefWords < 300 {
      print(
        """

        ⚠︎ SAMPLE SIZE: \(totalRefWords) reference words. A single utterance moves the
          aggregate by several points, and this cannot distinguish 11% from 15%.
          Aim for ~300 reference words before treating a verdict as decisive.
        """)
    }

    print("")
    switch (werPasses, codeSwitchingPasses) {
    case (true, true):
      print("VERDICT: both criteria pass — Parakeet stays PRIMARY. Record in SPEC.md §6.")
    case (true, false):
      print(
        """
        VERDICT: WER passes but CODE-SWITCHING FAILS. The jargon terms above were lost —
        that is this product's core use case (SPEC.md US-2), so the gate does NOT close on
        the WER number alone. Decide explicitly whether the FR-9 dictionary can recover
        these terms, or whether WhisperKit is evaluated as PRIMARY.
        """)
    default:
      print(
        "VERDICT: gate FAILS — evaluate WhisperKit large-v3-turbo as PRIMARY (SPEC.md NFR-2).")
    }
  }

  /// Writes raw hypotheses as `<name>.txt.suggested` drafts. The user corrects
  /// each against what they actually said and renames it to `<name>.txt`.
  /// The rename is deliberate and manual on purpose: an uncorrected machine
  /// transcript used as its own reference scores ~0% WER and would silently
  /// invalidate the NFR-2 engine gate.
  static func writeSuggestions(for wavs: [URL], using manager: AsrManager) async throws {
    var written = 0
    for wav in wavs {
      let refURL = wav.deletingPathExtension().appendingPathExtension("txt")
      if FileManager.default.fileExists(atPath: refURL.path) {
        print("SKIP \(wav.lastPathComponent): reference already exists")
        continue
      }

      var state = TdtDecoderState.make()
      let result = try await manager.transcribe(wav, decoderState: &state, language: .portuguese)
      let draftURL = refURL.appendingPathExtension("suggested")
      try (result.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        .write(to: draftURL, atomically: true, encoding: .utf8)

      print("\(wav.lastPathComponent) -> \(draftURL.lastPathComponent)")
      print("  \(result.text)")
      written += 1
    }

    guard written > 0 else {
      print("\nNothing to suggest.")
      return
    }
    print(
      """

      Wrote \(written) draft(s). NEXT: open each .txt.suggested, fix it against what
      you ACTUALLY said (jargon spelled correctly: deploy, Kubernetes, pull request),
      then rename it to .txt:

        cd spike/audio && for f in *.txt.suggested; do mv "$f" "${f%.suggested}"; done

      Do not rename without reading — an uncorrected draft scores 0% WER and makes
      the engine gate meaningless.
      """
    )
  }

  static func fixtureWavs(in dir: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
    return try FileManager.default
      .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension.lowercased() == "wav" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// Lowercase, strip punctuation (keeping letters/digits incl. accents), split on whitespace.
  static func normalize(_ text: String) -> [String] {
    text.lowercased()
      .map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " }
      .reduce(into: "") { $0.append($1) }
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
  }

  /// English IT terms this product must get right (SPEC.md US-2). Extend as the
  /// fixture set grows.
  static let jargonTerms = [
    "deploy", "endpoint", "kubernetes", "commit", "pull request", "branch",
    "merge", "pipeline", "backend", "frontend", "cluster", "pod", "container",
    "rollback", "feature flag", "timeout", "cache", "token", "postgres",
    "docker", "compose", "staging", "build", "redis", "runtime",
  ]

  /// English IT-jargon terms present in the reference but absent from the hypothesis —
  /// the code-switching signal NFR-2 cares about, tracked separately from raw WER.
  static func missedJargon(reference: String, hypothesis: String) -> [String] {
    let ref = reference.lowercased()
    let hyp = hypothesis.lowercased()
    return jargonTerms.filter { ref.contains($0) && !hyp.contains($0) }
  }

  /// True when the file has not been modified since it was created — i.e. it was
  /// written once and never opened for editing. Combined with a 0-error score this
  /// is the signature of a `--suggest` draft renamed without review.
  static func wasNeverEdited(_ url: URL) -> Bool {
    guard
      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      let created = attrs[.creationDate] as? Date,
      let modified = attrs[.modificationDate] as? Date
    else { return false }
    return abs(modified.timeIntervalSince(created)) < 1
  }

  /// True when a reference exercises code-switching at all.
  static func containsJargon(_ reference: String) -> Bool {
    let ref = reference.lowercased()
    return jargonTerms.contains { ref.contains($0) }
  }

  /// Word-level Levenshtein distance (substitution/insertion/deletion, unit cost).
  static func levenshtein(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      }
      swap(&previous, &current)
    }
    return previous[b.count]
  }
}
