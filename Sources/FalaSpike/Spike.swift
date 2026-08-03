import FalaKit
import FluidAudio
import Foundation

/// Spike 0 — throwaway WER harness (TASKS.md, GATE S0). DELETE after the engine
/// decision. Validates FR-7/NFR-2: measured PT-BR WER on the user's own fixture
/// recordings — now for BOTH candidate engines, on the same audio, side by side.
///
/// Usage: swift run FalaSpike [fixtures-dir] [--engines parakeet,cohere] [--suggest]
/// Defaults: fixtures-dir = spike/audio, engines = both.
/// Expects pairs: <name>.wav + <name>.txt (reference transcription, one line).
///
/// PRIVACY NOTE: this harness intentionally prints hypothesis vs reference text.
/// That is acceptable ONLY because inputs are the user's own fixture recordings
/// made for this evaluation (see CLAUDE.md golden-rule exception). It must never
/// be pointed at live dictation audio.
@main
struct Spike {

  /// SPEC.md NFR-2's WER arm. Scored on the jargon-bearing subset, not the
  /// aggregate — see the comment on `Totals.jargonWer`.
  static let werThreshold = 12.0

  /// Below this many reference words the measurement cannot separate 11% from 15%.
  static let minimumReferenceWords = 300

  static let usage = """
    Usage: swift run FalaSpike [fixtures-dir] [--engines <list>] [--suggest]

      fixtures-dir   directory of <name>.wav + <name>.txt pairs (default: spike/audio)
      --engines      comma-separated subset of: parakeet, cohere (default: both)
      --suggest      write <name>.txt.suggested drafts instead of scoring
      --help         show this text

    Examples:
      swift run FalaSpike spike/audio
      swift run FalaSpike spike/audio --engines parakeet
      swift run FalaSpike spike/audio --engines parakeet,cohere
      swift run FalaSpike spike/audio --engines parakeet --suggest
    """

  static func main() async throws {
    let options: Options
    do {
      options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    } catch let error as OptionError {
      print(error.message)
      print("")
      print(usage)
      exit(1)
    }

    if options.showHelp {
      print(usage)
      return
    }

    let dirURL = URL(fileURLWithPath: options.directory)
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

    if options.suggest {
      try await runSuggestMode(wavs: wavs, engines: options.engines)
      return
    }

    try await runScoringMode(wavs: wavs, engines: options.engines)
  }

  // MARK: - Modes

  /// Draft mode. Only ONE engine writes drafts (the first selected): drafts are
  /// raw model output that the user then corrects by hand, and two engines'
  /// disagreeing guesses would just be two things to throw away.
  static func runSuggestMode(wavs: [URL], engines: [EngineID]) async throws {
    guard let id = engines.first else { return }
    print("Loading \(id.displayName) — \(id.downloadNote)...")
    let engine = makeEngine(id)
    do {
      try await engine.prepare()
    } catch {
      print("Could not load \(id.displayName): \(error.localizedDescription)")
      print(id.acquisitionHint)
      exit(1)
    }
    try await writeSuggestions(for: wavs, using: engine, id: id)
  }

  static func runScoringMode(wavs: [URL], engines: [EngineID]) async throws {
    // Decoded ONCE and shared by every engine: a difference in the numbers below
    // must be a difference between engines, not between two audio-loading paths.
    let fixtures = loadFixtures(wavs)
    let referenceWords = fixtures.reduce(0) { $0 + normalize($1.reference).count }
    guard !fixtures.isEmpty, referenceWords > 0 else {
      print("No scorable fixtures (all missing or empty references).")
      exit(1)
    }

    let names = engines.map(\.rawValue).joined(separator: ", ")
    print("\nFixtures: \(fixtures.count). Engines: \(names)")

    var reports: [EngineReport] = []
    for id in engines {
      print("\nLoading \(id.displayName) — \(id.downloadNote)...")
      let engine = makeEngine(id)
      do {
        try await engine.prepare()
      } catch {
        // Requirement of a two-engine harness: a model the user has not
        // downloaded yet must cost them the OTHER engine's numbers, not the run.
        print("SKIPPING \(id.displayName): could not load (\(error.localizedDescription))")
        print(id.acquisitionHint)
        continue
      }
      reports.append(await score(engine, id: id, over: fixtures))
    }

    guard !reports.isEmpty else {
      print("\nNo engine could be loaded — nothing was measured.")
      exit(1)
    }

    printGate(reports)
    printComparison(reports)
    printWarnings(reports, referenceWords: referenceWords)
    printVerdict(reports)
  }

  // MARK: - Scoring

  static func score(
    _ engine: any SpikeEngine, id: EngineID, over fixtures: [Fixture]
  ) async -> EngineReport {
    print("\n=== ENGINE: \(id.displayName) ===")
    var scores: [FixtureScore] = []
    var failures: [String] = []

    for fixture in fixtures {
      let result: SpikeResult
      do {
        result = try await engine.transcribe(fixture.samples)
      } catch {
        failures.append(fixture.name)
        print("FAIL \(fixture.name): \(error.localizedDescription)")
        continue
      }

      let refWords = normalize(fixture.reference)
      let hypWords = normalize(result.text)
      let edits = levenshtein(refWords, hypWords)
      let wer = refWords.isEmpty ? 0 : Double(edits) / Double(refWords.count)
      let missed = missedJargon(reference: fixture.reference, hypothesis: result.text)
      // Contamination signature: a reference that exactly matches the hypothesis
      // AND was never modified after creation is almost certainly a --suggest
      // draft renamed without review. It scores 0% by construction and inflates
      // the pass margin. Flag it rather than drop it — dropping data silently is
      // its own failure mode.
      let unverified = edits == 0 && wasNeverEdited(fixture.referenceURL)

      scores.append(
        FixtureScore(
          name: fixture.name,
          refWords: refWords.count,
          edits: edits,
          hasJargon: containsJargon(fixture.reference),
          missed: missed,
          processingTime: result.processingTime,
          audioDuration: fixture.duration,
          unverified: unverified))

      print(
        String(
          format: "%@  WER %5.1f%%  (%.0f ms proc, %.1f s audio)",
          fixture.name, wer * 100,
          result.processingTime * 1000, fixture.duration))
      if wer > 0 {
        print("  ref: \(refWords.joined(separator: " "))")
        print("  hyp: \(hypWords.joined(separator: " "))")
      }
      if !missed.isEmpty {
        print("  jargon missed: \(missed.joined(separator: ", "))")
      }
      if unverified {
        print("  ⚠︎ UNVERIFIED reference: identical to model output and never edited")
      }
    }

    let report = EngineReport(id: id, scores: scores, failures: failures)
    printSummary(report)
    return report
  }

  static func totals(of scores: [FixtureScore]) -> Totals {
    var totals = Totals()
    var missed: Set<String> = []
    for score in scores {
      totals.edits += score.edits
      totals.refWords += score.refWords
      // Tracked separately: fixtures containing English IT jargon are the
      // product's actual use case, so their WER is the number that matters.
      // Jargon-free fixtures dilute the aggregate and can float a failing
      // engine over the gate.
      if score.hasJargon {
        totals.jargonEdits += score.edits
        totals.jargonRefWords += score.refWords
      }
      missed.formUnion(score.missed)
      totals.processingTime += score.processingTime
      totals.audioDuration += score.audioDuration
    }
    totals.missedTerms = missed.sorted()
    return totals
  }

  // MARK: - Reporting

  static func printSummary(_ report: EngineReport) {
    let totals = report.totals
    guard totals.refWords > 0 else {
      print("\nNo scorable fixtures for \(report.id.displayName).")
      return
    }

    print(
      String(
        format: "\nAGGREGATE WER: %.1f%% over %d reference words",
        totals.aggregateWer, totals.refWords))
    if totals.jargonRefWords > 0 && totals.jargonRefWords < totals.refWords {
      print(
        String(
          format: "CODE-SWITCHING WER: %.1f%% over %d words (jargon-bearing fixtures only)",
          totals.jargonWer, totals.jargonRefWords))
    }

    if totals.missedTerms.isEmpty {
      print("Code-switching: all jargon terms preserved.")
    } else {
      print("Code-switching MISSES: \(totals.missedTerms.joined(separator: ", "))")
    }

    print(
      String(
        format: "Processing: %.2f s total over %.1f s of audio",
        totals.processingTime, totals.audioDuration))
    if !report.failures.isEmpty {
      print("Not transcribed by this engine: \(report.failures.joined(separator: ", "))")
    }
  }

  /// SPEC.md NFR-2 joins TWO criteria: the WER threshold and code-switching
  /// integrity. The WER arm is scored on the jargon-bearing subset, because
  /// jargon-free fixtures dilute the aggregate and can float a failing engine
  /// over the line — this product exists to dictate code-switched speech.
  static func printGate(_ reports: [EngineReport]) {
    print("\n--- GATE S0 (SPEC.md NFR-2) ---")
    for report in reports {
      let totals = report.totals
      print("  \(report.id.displayName)")
      print(
        String(
          format: "    WER criterion (<= %.0f%% on code-switching speech):  %@  (%.1f%%)",
          werThreshold, totals.werPasses ? "PASS" : "FAIL", totals.jargonWer))
      print(
        "    Code-switching criterion (no terms lost):         "
          + (totals.codeSwitchingPasses ? "PASS" : "FAIL")
          + "  (\(totals.missedTerms.count) lost)")
    }
  }

  /// The side-by-side that the engine decision is actually made on.
  static func printComparison(_ reports: [EngineReport]) {
    guard let first = reports.first, reports.count > 1 else {
      print("\n(Only one engine measured — run with --engines parakeet,cohere to compare.)")
      return
    }

    // Compare on the fixtures EVERY engine scored: a file one engine failed on
    // would otherwise show up as a WER difference between engines.
    let common = reports.dropFirst().reduce(first.scoredNames) {
      $0.intersection($1.scoredNames)
    }
    guard !common.isEmpty else {
      print("\nNo fixture was scored by every engine — nothing comparable.")
      return
    }
    let entries: [(id: EngineID, totals: Totals)] = reports.map { report in
      (report.id, totals(of: report.scores.filter { common.contains($0.name) }))
    }

    print("\n--- COMPARISON (jargon-bearing subset = the decision surface, SPEC.md §6) ---")
    if common.count < first.scores.count || reports.contains(where: { !$0.failures.isEmpty }) {
      print("  (restricted to the \(common.count) fixture(s) every engine transcribed)")
    }

    var grid: [[String]] = [["metric"] + entries.map(\.id.displayName)]
    grid.append(
      ["CODE-SWITCHING WER  <-- decides"] + entries.map(\.totals.jargonWerLabel))
    grid.append(["aggregate WER  (diluted)"] + entries.map(\.totals.aggregateWerLabel))
    grid.append(
      ["jargon terms lost"] + entries.map { "\($0.totals.missedTerms.count)" })
    grid.append(
      ["processing time"]
        + entries.map { String(format: "%.2f s", $0.totals.processingTime) })
    print(render(grid))

    for entry in entries where !entry.totals.missedTerms.isEmpty {
      print("  \(entry.id.displayName) lost: \(entry.totals.missedTerms.joined(separator: ", "))")
    }

    printWinner(entries)
  }

  static func printWinner(_ entries: [(id: EngineID, totals: Totals)]) {
    let ranked = entries.sorted { lhs, rhs in
      if lhs.totals.jargonWer != rhs.totals.jargonWer {
        return lhs.totals.jargonWer < rhs.totals.jargonWer
      }
      return lhs.totals.missedTerms.count < rhs.totals.missedTerms.count
    }
    guard let best = ranked.first, let runnerUp = ranked.dropFirst().first else { return }

    let delta = runnerUp.totals.jargonWer - best.totals.jargonWer
    // Below a tenth of a point the two engines are indistinguishable at any
    // sample size this harness will realistically see; do not dress that up
    // as a winner.
    guard delta >= 0.1 else {
      print(
        String(
          format: "\nTIE on code-switching WER (%.1f%% vs %.1f%%). Decide on jargon losses:",
          best.totals.jargonWer, runnerUp.totals.jargonWer))
      print(
        "  \(best.id.displayName): \(best.totals.missedTerms.count) lost"
          + "   \(runnerUp.id.displayName): \(runnerUp.totals.missedTerms.count) lost")
      printExclusiveLosses(entries)
      return
    }

    let relative = runnerUp.totals.jargonWer > 0 ? delta / runnerUp.totals.jargonWer * 100 : 0
    print(
      String(
        format: "\nWINNER on code-switching WER: %@", best.id.displayName))
    print(
      String(
        format: "  %.1f%% vs %.1f%% (%@) = %.1f points better, %.0f%% relative reduction.",
        best.totals.jargonWer, runnerUp.totals.jargonWer, runnerUp.id.displayName,
        delta, relative))
    printExclusiveLosses(entries)
  }

  /// With exactly two engines, the terms only ONE of them loses are the concrete
  /// evidence for or against switching — more useful than either raw set.
  static func printExclusiveLosses(_ entries: [(id: EngineID, totals: Totals)]) {
    guard entries.count == 2, let a = entries.first, let b = entries.dropFirst().first else {
      return
    }
    let onlyA = Set(a.totals.missedTerms).subtracting(b.totals.missedTerms).sorted()
    let onlyB = Set(b.totals.missedTerms).subtracting(a.totals.missedTerms).sorted()
    print("  lost only by \(a.id.displayName): \(list(onlyA))")
    print("  lost only by \(b.id.displayName): \(list(onlyB))")
  }

  static func list(_ terms: [String]) -> String {
    terms.isEmpty ? "(none)" : terms.joined(separator: ", ")
  }

  static func printWarnings(_ reports: [EngineReport], referenceWords: Int) {
    var flagged: [String: [String]] = [:]
    for report in reports {
      for score in report.scores where score.unverified {
        flagged[score.name, default: []].append(report.id.displayName)
      }
    }

    if !flagged.isEmpty {
      let lines = flagged.sorted { $0.key < $1.key }.map {
        "\($0.key) — matched by \($0.value.joined(separator: ", "))"
      }
      print(
        """

        ⚠︎ MEASUREMENT INTEGRITY: \(flagged.count) reference(s) scored 0% while being
          byte-identical to an engine's own output and never edited after creation:
          \(lines.joined(separator: "\n  "))
          These are self-graded and inflate the pass margin. Rewrite them by hand
          before trusting any verdict below.
        """)
    }

    if referenceWords < minimumReferenceWords {
      print(
        """

        ⚠︎ SAMPLE SIZE: \(referenceWords) reference words. A single utterance moves the
          aggregate by several points, and this cannot distinguish 11% from 15%.
          Aim for ~\(minimumReferenceWords) reference words before treating a verdict as decisive.
        """)
    }
  }

  static func printVerdict(_ reports: [EngineReport]) {
    let ranked = reports.sorted { $0.totals.jargonWer < $1.totals.jargonWer }
    let passing = ranked.filter { $0.totals.werPasses && $0.totals.codeSwitchingPasses }

    print("")
    if let winner = passing.first {
      if winner.id == .parakeet {
        print("VERDICT: both criteria pass — Parakeet stays PRIMARY. Record in SPEC.md §6.")
      } else {
        print(
          """
          VERDICT: both criteria pass for \(winner.id.displayName) — promote it to PRIMARY
          (SPEC.md §2 is [CONFIRMED] on one engine for v1, so this is an explicit swap, not
          an addition). Record in SPEC.md §6.
          """)
      }
      return
    }

    if let closest = ranked.first, closest.totals.werPasses {
      print(
        """
        VERDICT: WER passes but CODE-SWITCHING FAILS for every engine measured. The jargon
        terms above were lost — that is this product's core use case (SPEC.md US-2), so the
        gate does NOT close on the WER number alone. Decide explicitly whether the FR-9
        dictionary can recover these terms, or whether WhisperKit is evaluated as PRIMARY.
        """)
      return
    }

    print("VERDICT: gate FAILS — evaluate WhisperKit large-v3-turbo as PRIMARY (SPEC.md NFR-2).")
  }

  /// Left-aligns a grid into columns. Last column is not padded, so nothing
  /// trails whitespace.
  static func render(_ grid: [[String]]) -> String {
    let columns = grid.map(\.count).max() ?? 0
    guard columns > 0 else { return "" }
    var widths = [Int](repeating: 0, count: columns)
    for row in grid {
      for (index, cell) in row.enumerated() {
        widths[index] = max(widths[index], cell.count)
      }
    }
    return
      grid
      .map { row in
        "  "
          + row.enumerated()
          .map { index, cell in
            index == row.count - 1
              ? cell
              : cell.padding(toLength: widths[index] + 2, withPad: " ", startingAt: 0)
          }
          .joined()
      }
      .joined(separator: "\n")
  }

  // MARK: - Suggest mode

  /// Writes raw hypotheses as `<name>.txt.suggested` drafts. The user corrects
  /// each against what they actually said and renames it to `<name>.txt`.
  /// The rename is deliberate and manual on purpose: an uncorrected machine
  /// transcript used as its own reference scores ~0% WER and would silently
  /// invalidate the NFR-2 engine gate.
  static func writeSuggestions(
    for wavs: [URL], using engine: any SpikeEngine, id: EngineID
  ) async throws {
    let converter = AudioConverter()
    var written = 0
    for wav in wavs {
      let refURL = wav.deletingPathExtension().appendingPathExtension("txt")
      if FileManager.default.fileExists(atPath: refURL.path) {
        print("SKIP \(wav.lastPathComponent): reference already exists")
        continue
      }
      guard let samples = try? converter.resampleAudioFile(wav), !samples.isEmpty else {
        print("SKIP \(wav.lastPathComponent): could not decode audio")
        continue
      }

      let result = try await engine.transcribe(samples)
      // NEVER `.txt`: a machine-written reference makes the harness grade itself
      // (WER ≈ 0) and the NFR-2 gate meaningless.
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

      Wrote \(written) draft(s) with \(id.displayName). NEXT: open each .txt.suggested, fix
      it against what you ACTUALLY said (jargon spelled correctly: deploy, Kubernetes, pull
      request), then rename it to .txt:

        cd spike/audio && for f in *.txt.suggested; do mv "$f" "${f%.suggested}"; done

      Do not rename without reading — an uncorrected draft scores 0% WER and makes
      the engine gate meaningless.
      """
    )
  }

  // MARK: - Fixtures

  static func fixtureWavs(in dir: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
    return try FileManager.default
      .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension.lowercased() == "wav" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  static func loadFixtures(_ wavs: [URL]) -> [Fixture] {
    // Both engines want 16 kHz mono Float32, which is this converter's default
    // target — the same format FR-2 resamples the microphone to.
    let converter = AudioConverter()
    let sampleRate = Double(CohereAsrConfig.sampleRate)
    var fixtures: [Fixture] = []

    for wav in wavs {
      let refURL = wav.deletingPathExtension().appendingPathExtension("txt")
      guard let reference = try? String(contentsOf: refURL, encoding: .utf8) else {
        print("SKIP \(wav.lastPathComponent): missing reference \(refURL.lastPathComponent)")
        continue
      }
      guard let samples = try? converter.resampleAudioFile(wav), !samples.isEmpty else {
        print("SKIP \(wav.lastPathComponent): could not decode audio")
        continue
      }
      fixtures.append(
        Fixture(
          name: wav.lastPathComponent,
          referenceURL: refURL,
          reference: reference,
          samples: samples,
          duration: Double(samples.count) / sampleRate))
    }
    return fixtures
  }

  // MARK: - Options

  static func parseOptions(_ args: [String]) throws -> Options {
    var options = Options()
    var sawDirectory = false
    var index = 0

    while index < args.count {
      let arg = args[index]
      switch arg {
      case "--help", "-h":
        options.showHelp = true
      case "--suggest":
        options.suggest = true
      case "--engines":
        index += 1
        guard index < args.count else {
          throw OptionError(message: "--engines needs a value, e.g. --engines parakeet,cohere")
        }
        options.engines = try parseEngines(args[index])
      default:
        if let value = flagValue("--engines=", in: arg) {
          options.engines = try parseEngines(value)
        } else if arg.hasPrefix("-") {
          throw OptionError(message: "Unknown option: \(arg)")
        } else if sawDirectory {
          throw OptionError(message: "Unexpected extra argument: \(arg)")
        } else {
          options.directory = arg
          sawDirectory = true
        }
      }
      index += 1
    }
    return options
  }

  static func parseEngines(_ raw: String) throws -> [EngineID] {
    var selected: [EngineID] = []
    for piece in raw.split(separator: ",") {
      let name = piece.trimmingCharacters(in: .whitespaces).lowercased()
      guard let id = EngineID(rawValue: name) else {
        let valid = EngineID.allCases.map(\.rawValue).joined(separator: ", ")
        throw OptionError(message: "Unknown engine '\(name)'. Valid engines: \(valid)")
      }
      if !selected.contains(id) {
        selected.append(id)
      }
    }
    guard !selected.isEmpty else {
      throw OptionError(message: "--engines needs at least one engine name")
    }
    return selected
  }

  static func flagValue(_ prefix: String, in arg: String) -> String? {
    arg.hasPrefix(prefix) ? String(arg.dropFirst(prefix.count)) : nil
  }

  static func makeEngine(_ id: EngineID) -> any SpikeEngine {
    switch id {
    case .parakeet: return ShippingSpikeEngine(TranscriptionEngineChoice.parakeet.makeEngine())
    case .cohere: return ShippingSpikeEngine(TranscriptionEngineChoice.cohere.makeEngine())
    }
  }

  // MARK: - WER math (verified in Run 1 — do not rewrite)

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

// MARK: - Options model

struct Options {
  var directory = "spike/audio"
  var suggest = false
  var engines = EngineID.allCases
  var showHelp = false
}

struct OptionError: Error {
  let message: String
}

// MARK: - Engines

/// The candidate engines GATE S0 has to choose between.
enum EngineID: String, CaseIterable, Sendable {
  /// The incumbent. Cannot force Portuguese: FluidAudio's `language` on this
  /// path is a Latin-vs-Cyrillic SCRIPT filter (SPEC.md FR-7).
  case parakeet
  /// The candidate. Forces `<|pt|>` twice in the decoder prefill, which is a
  /// real language lock and the whole reason it is being measured.
  case cohere

  var displayName: String {
    switch self {
    case .parakeet: return "Parakeet TDT v3"
    case .cohere: return "Cohere Transcribe (pt forced)"
    }
  }

  /// Printed before loading so a first run is not a silent multi-minute stall.
  var downloadNote: String {
    switch self {
    case .parakeet:
      return "downloads ~480 MB on first run"
    case .cohere:
      return
        "SEPARATE first-run download (~1 GB); Ctrl-C and pass --engines parakeet to skip it"
    }
  }

  var acquisitionHint: String {
    switch self {
    case .parakeet:
      return "  Parakeet is the default engine; check the network and retry."
    case .cohere:
      return "  Cohere's CoreML bundle is a separate download. Re-run when you want to fetch it."
    }
  }
}

/// One decoded fixture. Audio is decoded once and handed to every engine.
struct Fixture {
  let name: String
  let referenceURL: URL
  let reference: String
  let samples: [Float]
  let duration: TimeInterval
}

struct SpikeResult: Sendable {
  let text: String
  let processingTime: TimeInterval
}

struct FixtureScore {
  let name: String
  let refWords: Int
  let edits: Int
  let hasJargon: Bool
  let missed: [String]
  let processingTime: TimeInterval
  let audioDuration: TimeInterval
  let unverified: Bool
}

struct Totals {
  var edits = 0
  var refWords = 0
  var jargonEdits = 0
  var jargonRefWords = 0
  var missedTerms: [String] = []
  var processingTime: TimeInterval = 0
  var audioDuration: TimeInterval = 0

  var aggregateWer: Double {
    refWords > 0 ? Double(edits) / Double(refWords) * 100 : 0
  }

  /// The WER the gate is scored on: SPEC.md §6 records that the aggregate is
  /// diluted by jargon-free fixtures (11.4% vs 13.8% in Run 1 — opposite sides
  /// of the line), and this product exists for code-switched speech. Falls back
  /// to the aggregate only when no fixture carries jargon at all.
  var jargonWer: Double {
    jargonRefWords > 0 ? Double(jargonEdits) / Double(jargonRefWords) * 100 : aggregateWer
  }

  var werPasses: Bool { jargonWer <= Spike.werThreshold }
  var codeSwitchingPasses: Bool { missedTerms.isEmpty }

  var aggregateWerLabel: String {
    String(format: "%.1f%% (%d/%d)", aggregateWer, edits, refWords)
  }

  var jargonWerLabel: String {
    jargonRefWords > 0
      ? String(format: "%.1f%% (%d/%d)", jargonWer, jargonEdits, jargonRefWords)
      : "n/a (no jargon fixtures)"
  }
}

struct EngineReport {
  let id: EngineID
  let scores: [FixtureScore]
  let failures: [String]

  var totals: Totals { Spike.totals(of: scores) }
  var scoredNames: Set<String> { Set(scores.map(\.name)) }
}

/// What the harness needs from an engine.
///
/// Deliberately NOT FalaKit's `TranscriptionEngine`: the `FalaSpike` target
/// links FluidAudio only (Package.swift), so each engine's exact production
/// call is reproduced below. Keep both in sync with
/// `Sources/FalaKit/Transcription/{ParakeetEngine,CohereEngine}.swift` — a
/// measurement of a different configuration describes a different system than
/// the one that ships.
protocol SpikeEngine: Sendable {
  func prepare() async throws
  func transcribe(_ samples: [Float]) async throws -> SpikeResult
}

enum SpikeEngineError: Error, LocalizedError {
  case notPrepared

  var errorDescription: String? {
    switch self {
    case .notPrepared: return "engine was not prepared"
    }
  }
}

/// Adapts a SHIPPING `TranscriptionEngine` to the harness.
///
/// Delegating rather than reimplementing is the whole point: the gate decides
/// which engine ships, so measuring a hand-copied lookalike would let the two
/// drift on exactly the settings that matter — `melChunkContext`, the forced
/// language, the decoder variant. Whatever the app does, the harness measures.
actor ShippingSpikeEngine: SpikeEngine {
  private let engine: any TranscriptionEngine
  private let sampleRate: Double

  init(_ engine: any TranscriptionEngine, sampleRate: Double = 16_000) {
    self.engine = engine
    self.sampleRate = sampleRate
  }

  func prepare() async throws {
    try await engine.prepare()
  }

  func transcribe(_ samples: [Float]) async throws -> SpikeResult {
    let audio = AudioBuffer(samples: samples, sampleRate: sampleRate)
    let transcript = try await engine.transcribe(audio)
    return SpikeResult(text: transcript.text, processingTime: transcript.processingTime)
  }
}
