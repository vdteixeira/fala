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
    let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "spike/audio"
    let dirURL = URL(fileURLWithPath: dir)

    let wavs = try fixtureWavs(in: dirURL)
    guard !wavs.isEmpty else {
      print("No .wav fixtures found in \(dir). See spike/README.md for recording instructions.")
      exit(1)
    }

    print("Loading Parakeet TDT v3 (downloads ~1.1 GB on first run)...")
    let models = try await AsrModels.downloadAndLoad(version: .v3)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)
    print("Model ready. Transcribing \(wavs.count) fixture(s)...\n")

    var totalEdits = 0
    var totalRefWords = 0
    var codeSwitchMisses: [String] = []

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
    }

    guard totalRefWords > 0 else {
      print("No scorable fixtures (all missing references).")
      exit(1)
    }

    let aggregate = Double(totalEdits) / Double(totalRefWords) * 100
    print(
      String(format: "\nAGGREGATE WER: %.1f%% over %d reference words", aggregate, totalRefWords))
    if !codeSwitchMisses.isEmpty {
      print(
        "Code-switching misses across fixtures: \(Set(codeSwitchMisses).sorted().joined(separator: ", "))"
      )
    }

    // Decision gate per SPEC.md NFR-2.
    switch aggregate {
    case ..<12.0:
      print(
        "VERDICT: <= 12% — Parakeet stays PRIMARY. Record the number in SPEC.md §6 and close GATE S0."
      )
    case ..<15.0:
      print(
        "VERDICT: 12–15% — borderline. Inspect code-switching quality; consider the WhisperKit evaluation."
      )
    default:
      print(
        "VERDICT: > 15% — trigger the WhisperKit large-v3-turbo evaluation as PRIMARY (SPEC.md NFR-2)."
      )
    }
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

  /// English IT-jargon terms present in the reference but absent from the hypothesis —
  /// the code-switching signal NFR-2 cares about, tracked separately from raw WER.
  static func missedJargon(reference: String, hypothesis: String) -> [String] {
    let jargon = [
      "deploy", "endpoint", "kubernetes", "commit", "pull request", "branch",
      "merge", "pipeline", "backend", "frontend", "cluster", "pod", "container",
      "rollback", "feature flag", "timeout", "cache", "token",
    ]
    let ref = reference.lowercased()
    let hyp = hypothesis.lowercased()
    return jargon.filter { ref.contains($0) && !hyp.contains($0) }
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
