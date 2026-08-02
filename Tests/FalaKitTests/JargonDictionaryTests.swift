import Foundation
import Testing

@testable import FalaKit

/// Tests for SPEC.md FR-9 / US-2.
///
/// The suite is deliberately weighted toward NEGATIVE cases. Leaving jargon
/// misspelled costs the user one manual fix; silently rewriting correct
/// Portuguese costs them trust in the whole app, and they may not even notice.
/// Every "does not fire" test below corresponds to a real Portuguese word that a
/// naive find-and-replace built from the Spike 0 measurements would have eaten.
@Suite struct JargonDictionaryTests {

  // MARK: - Negative tests: correct Portuguese must survive

  @Test("A legitimate 'depois' is never rewritten by the default dictionary")
  func legitimateDepoisSurvives() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let text = "Volto depois do almoço e depois eu te aviso."
    #expect(dictionary.apply(to: text) == text)
  }

  @Test("A legitimate clitic 'me' is never rewritten by the default dictionary")
  func legitimateMeSurvives() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let text = "Ele me disse que me avisa quando terminar."
    #expect(dictionary.apply(to: text) == text)
  }

  /// Spike 0 RUN 1, Audio_1. The reference is
  /// "Fazer deploy do endpoint do Kubernetes depois do merge." — the decoder
  /// turned `deploy` into `depois` while the sentence ALSO contains a correct
  /// `depois`. Any unconditional rule fixes one and destroys the other, so the
  /// dictionary must decline to guess and leave the sentence exactly as it is.
  @Test("The Audio_1 hypothesis is left untouched rather than half-fixed")
  func audioOneHypothesisIsNotGuessed() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let hypothesis = "Fazer depois do endpoint do Kubernetes depois do me."
    #expect(dictionary.apply(to: hypothesis) == hypothesis)
  }

  @Test("A jargon-free Portuguese sentence passes through byte-for-byte")
  func plainPortugueseIsUntouched() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let text = "Abre um e-mail e escreva sobre o projeto que estamos construindo."
    #expect(dictionary.apply(to: text) == text)
  }

  @Test("Multi-word entries do not match across punctuation")
  func multiWordDoesNotMatchAcrossPunctuation() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let text = "Trabalho no back, end do mês que vem."
    #expect(dictionary.apply(to: text) == text)
  }

  // MARK: - Risky entries are opt-in, and the opt-in is a documented hazard

  @Test("Risky entries are excluded unless the caller opts in")
  func riskyEntriesAreExcludedByDefault() throws {
    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.entries.contains { $0.safety == .risky })
    #expect(dictionary.activeEntryCount < dictionary.entries.count)
  }

  /// This test exists to PROVE the hazard, not to endorse it: with `includeRisky`
  /// the same sentence gets one word fixed and one word destroyed. It is the
  /// evidence for shipping those two entries disabled.
  @Test("Opting into risky entries corrupts the correct 'depois' in the same sentence")
  func riskyOptInCorruptsCorrectPortuguese() throws {
    let dictionary = try JargonDictionary.loadDefault(includeRisky: true)
    let hypothesis = "Fazer depois do endpoint do Kubernetes depois do me."
    let expected = "Fazer deploy do endpoint do Kubernetes deploy do merge."
    #expect(dictionary.apply(to: hypothesis) == expected)
    #expect(dictionary.apply(to: "Volto depois do almoço.") == "Volto deploy do almoço.")
  }

  // MARK: - Word-boundary anchoring

  @Test("An entry never matches inside a longer word")
  func entriesDoNotMatchInsideWords() throws {
    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.apply(to: "Tomou um brandy no bar.") == "Tomou um brandy no bar.")
    #expect(dictionary.apply(to: "Vou postergar a reunião.") == "Vou postergar a reunião.")
  }

  /// Even the most dangerous entry, once enabled, only touches whole tokens.
  @Test("Boundary anchoring holds for the risky 'me' entry when it is enabled")
  func boundaryAnchoringHoldsForRiskyEntry() throws {
    let dictionary = try JargonDictionary.loadDefault(includeRisky: true)
    let input = "Mesmo assim o comentário me ajudou bastante."
    let expected = "Mesmo assim o comentário merge ajudou bastante."
    #expect(dictionary.apply(to: input) == expected)
  }

  @Test("Hyphens end a token, so 'com pose' cannot match 'com-pose'")
  func hyphenEndsAToken() throws {
    let entry = JargonEntry(from: "com pose", to: "Compose")
    let dictionary = try JargonDictionary(entries: [entry])
    #expect(dictionary.apply(to: "roda o com-pose") == "roda o com-pose")
    #expect(dictionary.apply(to: "roda o com pose") == "roda o Compose")
  }

  // MARK: - Exact matching and casing

  @Test("A single-word misrendering is replaced exactly")
  func exactSingleWordSubstitution() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let input = "Sobe o container no posterg."
    #expect(dictionary.apply(to: input) == "Sobe o container no Postgres.")
  }

  @Test("The canonical casing in the JSON wins over the casing in the transcript")
  func canonicalCasingWins() throws {
    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.apply(to: "roda no cubernetes") == "roda no Kubernetes")
    #expect(dictionary.apply(to: "roda no kubernetes") == "roda no Kubernetes")
    #expect(dictionary.apply(to: "roda no Kubernetes") == "roda no Kubernetes")
  }

  @Test("An all-lowercase replacement inherits a leading capital from the source")
  func lowercaseReplacementInheritsLeadingCapital() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let input = "Brand nova a partir da main."
    #expect(dictionary.apply(to: input) == "Branch nova a partir da main.")
    #expect(dictionary.apply(to: "cria uma brand nova") == "cria uma branch nova")
  }

  @Test("Matching ignores diacritics, so one entry covers accented renderings")
  func matchingIgnoresDiacritics() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let input = "Faz um rollback no último comitê."
    #expect(dictionary.apply(to: input) == "Faz um rollback no último commit.")
  }

  // MARK: - Multi-word phrases and longest-match

  /// Spike 0 RUN 1, Audio_4: three separate failures in one sentence.
  @Test("The Audio_4 hypothesis is fully repaired, including the split 'com pose'")
  func audioFourHypothesisIsRepaired() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let hypothesis = "Sobe o container no posterg com o docker com pose no cluster de station."
    let expected = "Sobe o container no Postgres com o Docker Compose no cluster de staging."
    #expect(dictionary.apply(to: hypothesis) == expected)
  }

  @Test("Where two entries match at the same token, the longer one wins")
  func longestMatchWins() throws {
    let dictionary = try JargonDictionary(entries: [
      JargonEntry(from: "a", to: "SHORT"),
      JargonEntry(from: "a b", to: "LONG"),
    ])
    #expect(dictionary.apply(to: "a b") == "LONG")
    #expect(dictionary.apply(to: "a c") == "SHORT c")
  }

  @Test("Replacements are not rescanned, so entries cannot cascade")
  func replacementsAreNotRescanned() throws {
    let dictionary = try JargonDictionary(entries: [
      JargonEntry(from: "um", to: "dois"),
      JargonEntry(from: "dois", to: "tres"),
    ])
    #expect(dictionary.apply(to: "um dois") == "dois tres")
  }

  // MARK: - Contextual entries

  @Test("A contextual entry does not fire without its context word")
  func contextualEntryDoesNotFireWithoutContext() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let text = "Ele veio com pose de chefe."
    #expect(dictionary.apply(to: text) == text)
  }

  @Test("A contextual entry fires when its context word is nearby")
  func contextualEntryFiresWithContext() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let input = "Sobe o docker, com pose no cluster."
    #expect(dictionary.apply(to: input) == "Sobe o Docker, Compose no cluster.")
  }

  @Test("'comitê' without a git-flavoured neighbour stays Portuguese")
  func committeeStaysPortugueseWithoutGitContext() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let text = "O comitê aprovou o projeto na reunião de ontem."
    #expect(dictionary.apply(to: text) == text)
  }

  @Test("Context is only honoured within the declared window of word tokens")
  func contextWindowIsBounded() throws {
    let entry = JargonEntry(
      from: "pose",
      to: "Compose",
      safety: .contextual,
      contextBefore: ["docker"]
    )
    let dictionary = try JargonDictionary(entries: [entry])
    #expect(JargonDictionary.contextWindow == 3)
    #expect(dictionary.apply(to: "docker um dois pose") == "docker um dois Compose")
    #expect(dictionary.apply(to: "docker um dois tres pose") == "docker um dois tres pose")
  }

  @Test("A context word after the match satisfies contextAfter")
  func contextAfterIsHonoured() throws {
    let entry = JargonEntry(
      from: "comite",
      to: "commit",
      safety: .contextual,
      contextAfter: ["anterior"]
    )
    let dictionary = try JargonDictionary(entries: [entry])
    #expect(dictionary.apply(to: "o comite anterior") == "o commit anterior")
    #expect(dictionary.apply(to: "o comite da empresa") == "o comite da empresa")
  }

  // MARK: - Whitespace and punctuation fidelity

  @Test("Unmatched characters, spacing and punctuation are preserved exactly")
  func spacingAndPunctuationArePreserved() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let input = "  Sobe o posterg,  depois roda o becape!\n"
    let expected = "  Sobe o Postgres,  depois roda o backup!\n"
    #expect(dictionary.apply(to: input) == expected)
  }

  @Test("Empty and word-free input round-trip unchanged")
  func emptyInputRoundTrips() throws {
    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.apply(to: "") == "")
    #expect(dictionary.apply(to: "... !!! ") == "... !!! ")
  }

  @Test("Applying the dictionary twice changes nothing the second time")
  func applyIsIdempotent() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let hypothesis = "Sobe o container no posterg com o docker com pose no cluster de station."
    let once = dictionary.apply(to: hypothesis)
    #expect(dictionary.apply(to: once) == once)
  }

  // MARK: - Loading

  @Test("The bundled default dictionary loads from Bundle.module")
  func defaultDictionaryLoads() throws {
    let url = try JargonDictionary.defaultResourceURL()
    #expect(FileManager.default.fileExists(atPath: url.path))
    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.entries.count > 20)
    #expect(dictionary.activeEntryCount > 0)
  }

  /// Bias terms feed `TranscriptionEngine.transcribe(_:biasTerms:)`. They must
  /// include the targets of the disabled risky entries — nudging the decoder
  /// toward "deploy" is safe, which is exactly why it is the mitigation this
  /// layer cannot provide by substitution.
  @Test("Bias terms cover every canonical spelling, including disabled entries")
  func biasTermsIncludeDisabledTargets() throws {
    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.biasTerms.contains("Kubernetes"))
    #expect(dictionary.biasTerms.contains("Postgres"))
    #expect(dictionary.biasTerms.contains("deploy"))
    #expect(dictionary.biasTerms.contains("merge"))
    #expect(Set(dictionary.biasTerms).count == dictionary.biasTerms.count)
  }

  @Test("A user override loads from an arbitrary URL")
  func userOverrideLoadsFromURL() throws {
    let json = """
      {
        "$comment": "user override",
        "entries": [
          { "from": "esse queuel", "to": "SQL", "safety": "safe" }
        ]
      }
      """
    let url = try Self.writeTemporaryFile(json)
    defer { try? FileManager.default.removeItem(at: url) }
    let dictionary = try JargonDictionary.load(contentsOf: url)
    #expect(dictionary.apply(to: "roda um esse queuel") == "roda um SQL")
  }

  @Test("The legacy flat 'substitutions' map still loads, as safe entries")
  func legacyFlatMapLoads() throws {
    let json = """
      { "$comment": "legacy", "substitutions": { "becape": "backup" } }
      """
    let url = try Self.writeTemporaryFile(json)
    defer { try? FileManager.default.removeItem(at: url) }
    let dictionary = try JargonDictionary.load(contentsOf: url)
    #expect(dictionary.entries.first?.safety == .safe)
    #expect(dictionary.apply(to: "faz o becape") == "faz o backup")
  }

  // MARK: - Configuration errors fail loudly

  @Test("A missing file reports .unreadable rather than falling back silently")
  func missingFileThrows() {
    let url = URL(fileURLWithPath: "/nonexistent/fala-jargon-\(UUID().uuidString).json")
    do {
      _ = try JargonDictionary.load(contentsOf: url)
      Issue.record("expected JargonDictionaryError.unreadable")
    } catch let error as JargonDictionaryError {
      guard case .unreadable = error else {
        Issue.record("expected .unreadable, got \(error)")
        return
      }
    } catch {
      Issue.record("expected JargonDictionaryError, got \(error)")
    }
  }

  @Test("JSON with neither 'entries' nor 'substitutions' is rejected")
  func malformedDocumentThrows() {
    let data = Data(#"{ "$comment": "nothing useful here" }"#.utf8)
    do {
      _ = try JargonDictionary(json: data)
      Issue.record("expected JargonDictionaryError.malformedJSON")
    } catch let error as JargonDictionaryError {
      guard case .malformedJSON = error else {
        Issue.record("expected .malformedJSON, got \(error)")
        return
      }
    } catch {
      Issue.record("expected JargonDictionaryError, got \(error)")
    }
  }

  @Test("A 'contextual' entry with no context words is a configuration error")
  func contextualEntryWithoutContextIsRejected() {
    expectInvalidEntry {
      try JargonDictionary(entries: [
        JargonEntry(from: "com pose", to: "Compose", safety: .contextual)
      ])
    }
  }

  @Test("A multi-word context term is a configuration error, not a dead entry")
  func multiWordContextTermIsRejected() {
    expectInvalidEntry {
      try JargonDictionary(entries: [
        JargonEntry(
          from: "comite",
          to: "commit",
          safety: .contextual,
          contextBefore: ["pull request"]
        )
      ])
    }
  }

  @Test("Entries with an empty 'from' or 'to' are rejected")
  func emptyEntrySidesAreRejected() {
    expectInvalidEntry { try JargonDictionary(entries: [JargonEntry(from: "  ", to: "branch")]) }
    expectInvalidEntry { try JargonDictionary(entries: [JargonEntry(from: "brand", to: "")]) }
  }

  // MARK: - Helpers

  private func expectInvalidEntry(
    _ build: () throws -> JargonDictionary,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    do {
      _ = try build()
      Issue.record("expected JargonDictionaryError.invalidEntry", sourceLocation: sourceLocation)
    } catch let error as JargonDictionaryError {
      guard case .invalidEntry = error else {
        Issue.record("expected .invalidEntry, got \(error)", sourceLocation: sourceLocation)
        return
      }
    } catch {
      Issue.record("expected JargonDictionaryError, got \(error)", sourceLocation: sourceLocation)
    }
  }

  private static func writeTemporaryFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("fala-jargon-\(UUID().uuidString).json")
    try Data(contents.utf8).write(to: url)
    return url
  }
}
