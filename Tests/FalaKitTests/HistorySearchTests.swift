import Foundation
import Testing

@testable import FalaKit

// Search and day grouping for the history window (TASKS.md T2.12).
//
// Both are pure, so everything below is asserted against a stated rule rather
// than against a previous run: the folding claims are checked against
// Foundation's actual behaviour for Portuguese, and the day headings against a
// calendar pinned to a fixed time zone.

// MARK: - Fixtures

private let editor = DestinationApp(bundleIdentifier: "com.microsoft.VSCode", name: "VS Code")
private let mail = DestinationApp(bundleIdentifier: "com.apple.mail", name: "Mail")

/// São Paulo, so a test never depends on where the machine is.
private var saoPauloCalendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.locale = Locale(identifier: "pt_BR")
  calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo") ?? .gmt
  return calendar
}

private func date(_ text: String) -> Date {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(identifier: "America/Sao_Paulo")
  formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
  guard let date = formatter.date(from: text) else {
    Issue.record("bad fixture date: \(text)")
    return Date(timeIntervalSince1970: 0)
  }
  return date
}

private func entry(
  _ text: String,
  at when: String = "2026-08-03 14:32:00",
  app: DestinationApp? = editor,
  duration: TimeInterval = 3.4
) -> DictationHistoryEntry {
  DictationHistoryEntry(
    text: text, createdAt: date(when), duration: duration, destinationApp: app)
}

// MARK: - Folding

@Suite("History search folding")
struct HistoryTextFoldingTests {

  /// The requirement in the brief, stated as its own test: a Brazilian typing
  /// without accents must find what they dictated with them.
  @Test("codigo finds código, in both directions")
  func accentInsensitive() {
    #expect(HistoryTextFolding.fold("código") == "codigo")
    #expect(HistoryTextFolding.fold("CÓDIGO") == "codigo")
    #expect(HistoryTextFolding.fold("Codigo") == "codigo")
  }

  /// The cedilla is the one Portuguese users most often expect NOT to matter,
  /// and it is a diacritic to Foundation — so "acao" finds "ação".
  @Test("Portuguese diacritics all fold: ç, ã, õ, â, ê, à")
  func portugueseDiacritics() {
    #expect(HistoryTextFolding.fold("ação") == "acao")
    #expect(HistoryTextFolding.fold("Coração") == "coracao")
    #expect(HistoryTextFolding.fold("PÃO") == "pao")
    #expect(HistoryTextFolding.fold("opções") == "opcoes")
    #expect(HistoryTextFolding.fold("você") == "voce")
    #expect(HistoryTextFolding.fold("àquela") == "aquela")
  }

  /// macOS produces BOTH forms: a precomposed "ó" from most keyboards, and a
  /// decomposed o + combining acute from some input methods and from text
  /// pasted out of other systems.
  ///
  /// Note what this does NOT claim. Swift's `String ==` compares by CANONICAL
  /// EQUIVALENCE, so the two forms are already equal to each other — the scalar
  /// assertion below is what proves the fixture really is decomposed, and an
  /// earlier draft of this test failed precisely because it assumed otherwise.
  /// What is worth pinning is that folding preserves that property instead of
  /// destroying it: `.diacriticInsensitive` must strip a combining mark, not
  /// leave it stranded on a base letter that no longer matches.
  @Test("decomposed (NFD) accents fold to the same thing as precomposed")
  func normalizationForms() {
    let precomposed = "código"
    let decomposed = "co\u{0301}digo"
    #expect(
      Array(precomposed.unicodeScalars) != Array(decomposed.unicodeScalars),
      "fixture is not actually testing NFD")
    #expect(HistoryTextFolding.fold(decomposed) == HistoryTextFolding.fold(precomposed))
    #expect(HistoryTextFolding.fold(decomposed) == "codigo")
    // The folded haystack is what search actually matches against.
    #expect(HistoryQuery("codigo").matchesFolded(HistoryTextFolding.fold(decomposed)))
  }

  /// Why the locale is pinned. Case folding is locale-dependent: on a Mac set
  /// to Turkish, folding "I" with the CURRENT locale gives "ı" (dotless), and
  /// typing "item" would stop matching "Item". Measured here rather than
  /// assumed — if this ever stops differing, the pinning has become free and
  /// the comment above `HistoryTextFolding.locale` is wrong.
  @Test("the pt-BR locale is pinned, and it changes the answer")
  func localeIsPinned() {
    let turkish = "I".folding(
      options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
      locale: Locale(identifier: "tr_TR"))
    #expect(HistoryTextFolding.fold("I") == "i")
    #expect(turkish != "i", "Foundation no longer applies Turkish casing here")
  }
}

// MARK: - Query

@Suite("History query")
struct HistoryQueryTests {

  @Test("an empty or whitespace-only query matches everything")
  func inactiveQueries() {
    #expect(!HistoryQuery("").isActive)
    #expect(!HistoryQuery("   \n\t ").isActive)
    #expect(HistoryQuery("").matchesFolded("qualquer coisa"))
  }

  /// A term that folds away must not turn into `contains("")`, which is true
  /// for every string — an "active" filter that silently matches everything.
  @Test("a term that folds to nothing is dropped, not matched as empty")
  func emptyTermIsDropped() {
    let query = HistoryQuery("\u{200B}")
    #expect(query.terms.allSatisfy { !$0.isEmpty })
  }

  @Test("terms are ANDed, in any order")
  func termsAreAnded() {
    let haystack = HistoryTextFolding.fold("subir o deploy do código novo")
    #expect(HistoryQuery("deploy codigo").matchesFolded(haystack))
    #expect(HistoryQuery("codigo deploy").matchesFolded(haystack))
    #expect(!HistoryQuery("deploy kubernetes").matchesFolded(haystack))
  }
}

// MARK: - Index

@Suite("History search index")
struct HistorySearchIndexTests {

  @Test("codigo finds código through the index")
  func accentInsensitiveSearch() {
    let index = HistorySearchIndex([
      entry("Revisar o código do endpoint"),
      entry("Marcar a reunião de terça"),
    ])
    let hits = index.filter(HistoryQuery("codigo"))
    #expect(hits.count == 1)
    #expect(hits.first?.text == "Revisar o código do endpoint")
  }

  @Test("case is ignored in both directions")
  func caseInsensitiveSearch() {
    let index = HistorySearchIndex([entry("Fazer o DEPLOY agora")])
    #expect(index.filter(HistoryQuery("deploy")).count == 1)
    #expect(index.filter(HistoryQuery("DePlOy")).count == 1)
  }

  /// The destination app is part of the haystack, and the row displays it —
  /// so nothing invisible is being matched.
  @Test("the destination app name is searchable")
  func searchesDestinationApp() {
    let index = HistorySearchIndex([
      entry("primeiro", app: editor),
      entry("segundo", app: mail),
    ])
    let hits = index.filter(HistoryQuery("vs code"))
    #expect(hits.count == 1)
    #expect(hits.first?.text == "primeiro")
  }

  /// Terms are split on whitespace, so no single term can contain one — which
  /// is what stops a query from matching across the transcript/app boundary and
  /// producing a hit that neither field actually contains.
  @Test("a term cannot span the transcript-to-app join")
  func termCannotSpanJoin() {
    let index = HistorySearchIndex([entry("acabou em", app: editor)])
    #expect(index.filter(HistoryQuery("emvs")).isEmpty)
    #expect(index.filter(HistoryQuery("em vs")).count == 1)
  }

  @Test("an entry with no destination app is still indexed and findable")
  func entryWithoutApp() {
    let index = HistorySearchIndex([entry("sem app", app: nil)])
    #expect(index.filter(HistoryQuery("sem")).count == 1)
    #expect(index.filter(HistoryQuery("")).count == 1)
  }

  @Test("an inactive query returns everything, in store order")
  func inactiveQueryKeepsOrder() {
    let entries = [entry("um"), entry("dois"), entry("três")]
    let hits = HistorySearchIndex(entries).filter(HistoryQuery(" "))
    #expect(hits.map(\.text) == ["um", "dois", "três"])
  }

  @Test("filtering preserves the store's newest-first order")
  func filterPreservesOrder() {
    let entries = [
      entry("deploy A", at: "2026-08-03 10:00:00"),
      entry("outra coisa", at: "2026-08-02 10:00:00"),
      entry("deploy B", at: "2026-08-01 10:00:00"),
    ]
    let hits = HistorySearchIndex(entries).filter(HistoryQuery("deploy"))
    #expect(hits.map(\.text) == ["deploy A", "deploy B"])
  }
}

// MARK: - Day titles

@Suite("History day titles")
struct HistoryDayTitleTests {
  private let now = date("2026-08-03 14:32:00")

  @Test("today and yesterday are named, not dated")
  func relativeDays() {
    let calendar = saoPauloCalendar
    #expect(
      HistoryDayTitle.title(for: date("2026-08-03 00:01:00"), now: now, calendar: calendar)
        == "Hoje")
    #expect(
      HistoryDayTitle.title(for: date("2026-08-02 23:59:00"), now: now, calendar: calendar)
        == "Ontem")
  }

  /// Reachable without anyone doing anything wrong: DST, clock skew or a manual
  /// change puts a just-recorded dictation in the future. A date heading there
  /// would print tomorrow over today's work.
  @Test("a future entry reads Amanhã instead of a date")
  func futureDay() {
    #expect(
      HistoryDayTitle.title(for: date("2026-08-04 09:00:00"), now: now, calendar: saoPauloCalendar)
        == "Amanhã")
  }

  @Test("an older day this year carries the weekday, capitalized")
  func sameYear() {
    // 2026-06-12 is a Friday.
    #expect(
      HistoryDayTitle.title(for: date("2026-06-12 09:00:00"), now: now, calendar: saoPauloCalendar)
        == "Sexta-feira, 12 de junho")
  }

  @Test("a different year drops the weekday and states the year")
  func differentYear() {
    #expect(
      HistoryDayTitle.title(for: date("2025-12-31 09:00:00"), now: now, calendar: saoPauloCalendar)
        == "31 de dezembro de 2025")
  }

  /// A `DateFormatter` here would print "August" on an en-US Mac and "2:32 PM"
  /// wherever the user prefers 12-hour time. The whole point of hand-rolling
  /// both is that the pt-BR surface stays pt-BR everywhere.
  @Test("month names are pt-BR regardless of the machine's locale")
  func monthNamesArePortuguese() {
    #expect(PtBRCalendarNames.month(3) == "março")
    #expect(PtBRCalendarNames.month(8) == "agosto")
    #expect(PtBRCalendarNames.weekday(1) == "domingo")
    #expect(PtBRCalendarNames.weekday(7) == "sábado")
  }

  @Test("an out-of-range component degrades to an empty name, it does not trap")
  func outOfRangeNames() {
    #expect(PtBRCalendarNames.month(0).isEmpty)
    #expect(PtBRCalendarNames.month(13).isEmpty)
    #expect(PtBRCalendarNames.weekday(0).isEmpty)
    #expect(PtBRCalendarNames.weekday(8).isEmpty)
  }

  @Test("the time is 24-hour and zero-padded")
  func timeLabel() {
    let calendar = saoPauloCalendar
    #expect(HistoryDayTitle.time(for: date("2026-08-03 14:32:00"), calendar: calendar) == "14:32")
    #expect(HistoryDayTitle.time(for: date("2026-08-03 09:05:00"), calendar: calendar) == "09:05")
    #expect(HistoryDayTitle.time(for: date("2026-08-03 00:00:00"), calendar: calendar) == "00:00")
  }
}

// MARK: - Grouping

@Suite("History day grouping")
struct HistoryDayGroupingTests {
  private let now = date("2026-08-03 18:00:00")

  @Test("entries land in one section per day, days newest first")
  func groupsByDay() {
    let entries = [
      entry("hoje tarde", at: "2026-08-03 14:00:00"),
      entry("hoje cedo", at: "2026-08-03 09:00:00"),
      entry("ontem", at: "2026-08-02 20:00:00"),
      entry("semana passada", at: "2026-07-28 11:00:00"),
    ]
    let days = HistoryDayGrouping.groups(for: entries, now: now, calendar: saoPauloCalendar)
    #expect(days.map(\.title) == ["Hoje", "Ontem", "Terça-feira, 28 de julho"])
    #expect(days[0].rows.map(\.fullText) == ["hoje tarde", "hoje cedo"])
    #expect(days[1].rows.count == 1)
  }

  /// The store hands entries over newest-first and sorts them stably. Sorting
  /// again here could only agree with that or silently disagree with it.
  @Test("row order inside a day is the order the store gave, not a re-sort")
  func preservesStoreOrder() {
    let entries = [
      entry("segundo na lista", at: "2026-08-03 09:00:00"),
      entry("primeiro na lista", at: "2026-08-03 14:00:00"),
    ]
    let days = HistoryDayGrouping.groups(for: entries, now: now, calendar: saoPauloCalendar)
    #expect(days.count == 1)
    #expect(days[0].rows.map(\.fullText) == ["segundo na lista", "primeiro na lista"])
  }

  /// 23:30 in São Paulo is 02:30 UTC the NEXT day. Grouping in the wrong zone
  /// files a late-night dictation under tomorrow — and labels it "Amanhã".
  @Test("days are cut in the user's time zone, not UTC")
  func groupsInLocalTimeZone() {
    let lateNight = entry("dictado tarde da noite", at: "2026-08-03 23:30:00")
    let days = HistoryDayGrouping.groups(
      for: [lateNight], now: now, calendar: saoPauloCalendar)
    #expect(days.map(\.title) == ["Hoje"])

    var utc = saoPauloCalendar
    utc.timeZone = .gmt
    let utcDays = HistoryDayGrouping.groups(for: [lateNight], now: now, calendar: utc)
    #expect(utcDays.map(\.title) != ["Hoje"], "fixture no longer straddles midnight")
  }

  @Test("no entries means no sections")
  func empty() {
    #expect(HistoryDayGrouping.groups(for: [], now: now, calendar: saoPauloCalendar).isEmpty)
  }

  @Test("each section counts its own rows in pt-BR")
  func countLabels() {
    let entries = [
      entry("a", at: "2026-08-03 14:00:00"),
      entry("b", at: "2026-08-03 09:00:00"),
      entry("c", at: "2026-08-02 09:00:00"),
    ]
    let days = HistoryDayGrouping.groups(for: entries, now: now, calendar: saoPauloCalendar)
    #expect(days[0].countLabel == "2 ditadas")
    #expect(days[1].countLabel == "1 ditada")
  }
}

// MARK: - Rows

@Suite("History row")
struct HistoryRowTests {

  private func row(_ entry: DictationHistoryEntry) -> HistoryRow {
    HistoryRow(
      entry: entry,
      timeLabel: HistoryDayTitle.time(for: entry.createdAt, calendar: saoPauloCalendar))
  }

  @Test("the meta line carries time, app and duration — and no transcript")
  func metaLine() {
    let line = row(entry("texto secreto", duration: 3.4)).metaLine
    #expect(line == "14:32 · VS Code · 3,4 s")
    #expect(!line.contains("secreto"))
  }

  @Test("an unidentified app collapses the meta line instead of showing a gap")
  func metaLineWithoutApp() {
    #expect(row(entry("oi", app: nil, duration: 12)).metaLine == "14:32 · 12 s")
  }

  /// A dictation with a line break otherwise renders its first line and hides
  /// the rest behind the line limit with no ellipsis — the sentence disappears
  /// silently rather than visibly.
  @Test("the collapsed text flattens line breaks")
  func collapsedText() {
    let value = row(entry("primeira linha\nsegunda linha\n\nterceira")).collapsedText
    #expect(value == "primeira linha segunda linha terceira")
  }

  @Test("full text is preserved verbatim for copy and re-inject")
  func fullTextIsVerbatim() {
    let text = "linha um\nlinha dois"
    #expect(row(entry(text)).fullText == text)
  }

  @Test("only a long transcript offers Mostrar tudo")
  func needsExpansion() {
    #expect(!row(entry("curto")).needsExpansion)
    let long = String(repeating: "a", count: HistoryWindowLayout.collapsedCharacterBudget + 1)
    #expect(row(entry(long)).needsExpansion)
  }

  /// Re-injection has to bring a specific app forward first, so an entry whose
  /// destination cannot be verified must not offer the action at all — at that
  /// moment the frontmost app is Fala's own window.
  @Test("re-inject is offered only for a verifiable destination")
  func canReinject() {
    #expect(row(entry("com app", app: editor)).canReinject)
    #expect(!row(entry("sem app", app: nil)).canReinject)
    let nameOnly = DestinationApp(bundleIdentifier: nil, name: "Algum App")
    #expect(!row(entry("só nome", app: nameOnly)).canReinject)
  }

  @Test("the button names its destination, and explains itself when disabled")
  func reinjectTitle() {
    #expect(row(entry("x", app: editor)).reinjectTitle == "Inserir de novo em “VS Code”")
    #expect(row(entry("x", app: editor)).reinjectUnavailableHint == nil)
    let orphan = row(entry("x", app: nil))
    #expect(orphan.reinjectTitle == HistoryWindowStrings.reinject)
    #expect(orphan.reinjectUnavailableHint != nil)
  }

  @Test("a row is identified by its entry, so deleting one cannot shift another")
  func identity() {
    let value = entry("x")
    #expect(row(value).id == value.id)
  }
}
