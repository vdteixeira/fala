import Foundation
import Testing

@testable import FalaKit

/// The manglings of "Postgres", "staging" and "Docker Compose" observed in LIVE
/// dictation on 2026-08-02 — not in the scored Spike 0 fixture set.
///
/// Eleven forms were reported. Eight are now fixed; three are recorded as
/// `risky` and deliberately do NOT fire, because `from` is a word the user might
/// genuinely have said. Every refusal below has a test proving the correct text
/// survives, and a companion test proving the entry is still on record — the
/// point is that they were measured and declined, not overlooked.
///
/// The observation recorded only the mangled TOKEN, never the sentence around
/// it. That is why no entry in this batch claims context evidence it does not
/// have: `composa`/`compost` are gated on `docker`/`doque` by analogy with the
/// existing `com pose` rule, and `steak` is gated on nothing because nothing was
/// measured.
@Suite struct JargonLiveManglingTests {

  // MARK: - Postgres

  @Test("The three non-word Postgres manglings are fixed")
  func postgresManglingsAreFixed() throws {
    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.apply(to: "Sobe o banco no postergis.") == "Sobe o banco no Postgres.")
    #expect(dictionary.apply(to: "roda no postergress hoje") == "roda no Postgres hoje")
    #expect(dictionary.apply(to: "Conecta no Posthuglis.") == "Conecta no Postgres.")
  }

  /// The reason `postergress` needed its own entry: matching is whole-word, so
  /// the pre-existing `posterg` fragment does not cover it. This test fails the
  /// day someone "simplifies" the two entries into one.
  @Test("'postergress' is not covered by the 'posterg' entry — hence its own rule")
  func postergressIsNotCoveredByTheFragmentEntry() throws {
    let fragmentOnly = try JargonDictionary(entries: [
      JargonEntry(from: "posterg", to: "Postgres", safety: .safe)
    ])
    #expect(fragmentOnly.apply(to: "no postergress") == "no postergress")

    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.apply(to: "no postergress") == "no Postgres")
  }

  @Test("'postergar' still survives now that three 'posterg…' rules exist")
  func postergarStillSurvives() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let text = "Vou postergar a reunião e postergo a decisão."
    #expect(dictionary.apply(to: text) == text)
  }

  // MARK: - staging

  /// "staging" is all-lowercase, so it inherits the capital of the token it
  /// replaces — the observed "Steiging" becomes "Staging", not "staging".
  @Test("Both non-word staging manglings are fixed")
  func stagingManglingsAreFixed() throws {
    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.apply(to: "Sobe no Steiging primeiro.") == "Sobe no Staging primeiro.")
    #expect(dictionary.apply(to: "o cluster de steving") == "o cluster de staging")
  }

  // MARK: - Docker Compose

  @Test("'doque compos' is fixed as a two-word sequence")
  func doqueComposIsFixed() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let input = "Roda o doque compos no servidor."
    #expect(dictionary.apply(to: input) == "Roda o Docker Compose no servidor.")
  }

  @Test("'composa' and 'compost' are fixed when Docker is nearby")
  func composeManglingsFireWithDockerContext() throws {
    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.apply(to: "Sobe com o docker composa.") == "Sobe com o Docker Compose.")
    #expect(dictionary.apply(to: "roda o docker compost agora") == "roda o Docker Compose agora")
    #expect(dictionary.apply(to: "no doque composa") == "no doque Compose")
  }

  /// Contextual, not safe: both forms are one deleted letter away from a word
  /// that is common in exactly this register.
  @Test("'composa' and 'compost' do not fire without Docker nearby")
  func composeManglingsNeedContext() throws {
    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.apply(to: "roda o composa") == "roda o composa")
    #expect(dictionary.apply(to: "o compost do jardim") == "o compost do jardim")
  }

  @Test("'composto' survives even with Docker in the same sentence")
  func compostoSurvivesNextToDocker() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let input = "O docker compose é composto por três serviços."
    #expect(dictionary.apply(to: input) == "O Docker Compose é composto por três serviços.")
  }

  /// `compos` folds onto `compôs`, so no standalone entry for it was added —
  /// only the two-word `doque compos`.
  @Test("'compôs' survives even with Docker in the same sentence")
  func composFormOfComporSurvives() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let input = "No docker, ele compôs a trilha."
    #expect(dictionary.apply(to: input) == "No Docker, ele compôs a trilha.")
  }

  @Test("'doque' alone is left alone — it is a Portuguese noun")
  func doqueAloneSurvives() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let text = "O navio atracou no doque e ficou lá."
    #expect(dictionary.apply(to: text) == text)
  }

  // MARK: - Refused: correct text must survive

  @Test("'post' is never rewritten — it is everyday Portuguese")
  func postIsNeverRewritten() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let text = "Publiquei um post no blog e o post do cliente ainda não saiu."
    #expect(dictionary.apply(to: text) == text)
  }

  @Test("'steak' is never rewritten — it is an ordinary loanword")
  func steakIsNeverRewritten() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let text = "Pedi um steak no almoço."
    #expect(dictionary.apply(to: text) == text)
  }

  @Test("'proced' is never rewritten — too far from Postgres to attribute")
  func procedIsNeverRewritten() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let text = "O fluxo proced daqui pra frente."
    #expect(dictionary.apply(to: text) == text)
  }

  @Test("A sentence carrying every refused form is untouched")
  func sentenceWithEveryRefusedFormIsUntouched() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let text =
      "O comitê pediu para postergar o post do blog; comi um steak, "
      + "o navio atracou no doque e o relatório é composto por três partes."
    #expect(dictionary.apply(to: text) == text)
  }

  // MARK: - Refused, but on record

  @Test("The three refused manglings are declared as risky, not dropped")
  func refusedManglingsAreRecordedAsRisky() throws {
    let dictionary = try JargonDictionary.loadDefault()
    let risky = Set(dictionary.entries.filter { $0.safety == .risky }.map(\.from))
    #expect(risky.isSuperset(of: ["post", "steak", "proced"]))
    for entry in dictionary.entries where risky.contains(entry.from) {
      #expect(entry.note?.isEmpty == false, "a risky entry must say why it is off")
    }
  }

  /// The evidence for refusing them. `includeRisky` is the caller saying "I
  /// accept this"; the damage it does here is why the default says no.
  @Test("Opting into risky entries turns correct Portuguese into jargon")
  func riskyOptInCorruptsTheRefusedForms() throws {
    let dictionary = try JargonDictionary.loadDefault(includeRisky: true)
    #expect(dictionary.apply(to: "Publiquei um post no blog.") == "Publiquei um Postgres no blog.")
    #expect(dictionary.apply(to: "Pedi um steak no almoço.") == "Pedi um staging no almoço.")
  }

  // MARK: - Bias terms

  /// Substitution refused ≠ mitigation refused: biasing the decoder toward the
  /// canonical spelling cannot corrupt anything, so the refused entries still
  /// pull their weight through `biasTerms`.
  @Test("The refused entries still contribute their canonical spellings to biasTerms")
  func refusedEntriesStillFeedBiasTerms() throws {
    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.biasTerms.contains("Postgres"))
    #expect(dictionary.biasTerms.contains("staging"))
    #expect(dictionary.biasTerms.contains("Compose"))
  }

  // MARK: - Correct Portuguese must survive (measured regressions)

  /// Both of these were MEASURED corrupting correct text while the entries were
  /// marked `safe`. "brand" is everyday Brazilian business vocabulary and
  /// "station" appears in PlayStation/workstation; a bare substitution rewrote
  /// both. They are `contextual` now, so these sentences must come back untouched.
  @Test(
    "Correct Portuguese survives the brand/station entries",
    arguments: [
      "A brand da empresa mudou.",
      "Trabalhamos a brand no ano passado.",
      "A station de trabalho travou.",
      "Comprei um Play Station novo.",
    ])
  func correctPortugueseIsNotCorrupted(sentence: String) throws {
    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.apply(to: sentence) == sentence)
  }

  /// The other half of the same gate: with git- or deploy-shaped neighbours the
  /// entries must still fire, or downgrading them would have silently dropped
  /// two of the Spike 0 fixes.
  @Test("The jargon reading still fires in context")
  func jargonReadingStillFires() throws {
    let dictionary = try JargonDictionary.loadDefault()
    #expect(dictionary.apply(to: "crie uma brand nova").contains("branch"))
    #expect(dictionary.apply(to: "no cluster de station").contains("staging"))
  }
}
