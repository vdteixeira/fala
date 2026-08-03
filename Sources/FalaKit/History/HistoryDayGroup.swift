import Foundation

// Day grouping and row copy for the history window (TASKS.md T2.12,
// DESIGN-HANDOFF.md §1: "search field, day grouping, per-row: text, timestamp,
// destination app, duration").
//
// PRIVACY (CLAUDE.md, NFR-1): every value below is in-memory only. `HistoryRow`
// carries transcript text because the window's whole purpose is to show it;
// nothing here writes it anywhere, and `metaLine` / `countLabel` /
// `accessibilityLabel` are built from timestamps and app names only.

/// pt-BR month and weekday names, written out.
///
/// Hand-rolled for the same reason `RelativeTimePtBR` is: a `DateFormatter`
/// reads the machine's locale, and an app whose UI is pt-BR by project rule
/// would render "Friday, August 1" on an en-US Mac. Writing them out also makes
/// the section headings assertable to the character instead of "whatever ICU
/// produced on this OS build".
public enum PtBRCalendarNames {
  /// Indexed by `Calendar`'s 1-based month component.
  public static let months = [
    "janeiro", "fevereiro", "março", "abril", "maio", "junho",
    "julho", "agosto", "setembro", "outubro", "novembro", "dezembro",
  ]

  /// Indexed by `Calendar`'s 1-based weekday component (1 = domingo).
  public static let weekdays = [
    "domingo", "segunda-feira", "terça-feira", "quarta-feira",
    "quinta-feira", "sexta-feira", "sábado",
  ]

  /// Empty for an out-of-range index, so a corrupt date degrades the heading
  /// instead of trapping.
  public static func month(_ index: Int) -> String {
    guard months.indices.contains(index - 1) else { return "" }
    return months[index - 1]
  }

  public static func weekday(_ index: Int) -> String {
    guard weekdays.indices.contains(index - 1) else { return "" }
    return weekdays[index - 1]
  }
}

/// The calendar every history surface uses.
///
/// Gregorian and pt-BR explicitly; the time zone is the machine's, because a
/// dictation belongs to the day the user was living, not to UTC. Tests inject a
/// calendar with a fixed zone so "Hoje" does not depend on where the machine is.
public enum HistoryCalendar {
  public static var ptBR: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = HistoryTextFolding.locale
    return calendar
  }
}

/// The pt-BR heading for one day's section.
public enum HistoryDayTitle {
  /// "Hoje" · "Ontem" · "Sexta-feira, 1 de agosto" · "1 de agosto de 2025".
  ///
  /// "Amanhã" is reachable and therefore handled: the history file is a plain
  /// JSON the user is invited to inspect, and a clock that moved backwards (DST,
  /// skew, a manual change) makes an entry recorded minutes ago sit in the
  /// future. Falling through to a date heading there would print tomorrow's
  /// date under today's dictation.
  public static func title(for day: Date, now: Date, calendar: Calendar) -> String {
    let today = calendar.startOfDay(for: now)
    let target = calendar.startOfDay(for: day)
    switch calendar.dateComponents([.day], from: today, to: target).day {
    case 0: return "Hoje"
    case -1: return "Ontem"
    case 1: return "Amanhã"
    default: break
    }
    let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: target)
    guard let year = parts.year, let month = parts.month, let dayNumber = parts.day else {
      return ""
    }
    let monthName = PtBRCalendarNames.month(month)
    guard year == calendar.component(.year, from: today) else {
      // A different year drops the weekday: by then the year is the fact that
      // orients the reader, and the weekday is noise.
      return "\(dayNumber) de \(monthName) de \(year)"
    }
    let weekday = PtBRCalendarNames.weekday(parts.weekday ?? 0)
    guard !weekday.isEmpty else { return "\(dayNumber) de \(monthName)" }
    return "\(weekday.prefix(1).uppercased())\(weekday.dropFirst()), \(dayNumber) de \(monthName)"
  }

  /// "14:32", 24-hour.
  ///
  /// Formatted by hand rather than with a `DateFormatter`, so the machine's
  /// 12/24-hour setting cannot turn a pt-BR surface into "2:32 PM". Same
  /// reasoning as `DictationHistoryEntry.durationLabel`.
  public static func time(for date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
  }
}

/// One row of the history list.
///
/// The popover's `RecentTranscription` is deliberately NOT reused: that type is
/// a one-line preview with no duration, no id-bearing entry to delete, and no
/// destination bundle identifier — and this surface needs all three. It carries
/// the whole `DictationHistoryEntry` so copy, re-inject and delete act on the
/// real record rather than on a reconstruction of it.
public struct HistoryRow: Sendable, Equatable, Identifiable {
  public let entry: DictationHistoryEntry
  /// "14:32".
  public let timeLabel: String

  public init(entry: DictationHistoryEntry, timeLabel: String) {
    self.entry = entry
    self.timeLabel = timeLabel
  }

  public var id: UUID { entry.id }

  /// The transcript exactly as it was injected. What copy and re-inject use.
  public var fullText: String { entry.text }

  /// Whitespace collapsed to single spaces, for the collapsed row.
  ///
  /// Without this a dictation containing a line break renders its first line and
  /// hides the rest behind a line limit with no ellipsis — the same defect
  /// `RecentTranscription.previewText` collapses whitespace to avoid.
  public var collapsedText: String {
    fullText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// Whether the row offers "Mostrar tudo".
  ///
  /// An APPROXIMATION, and knowingly so: real truncation depends on the window
  /// width and the font, which no pure value can know. The budget is
  /// `collapsedLineLimit` lines at roughly the characters that fit on one line
  /// of the default window, so the toggle appears slightly early on a widened
  /// window rather than never appearing on a narrow one.
  public var needsExpansion: Bool {
    collapsedText.count > HistoryWindowLayout.collapsedCharacterBudget
  }

  /// "VS Code", or `nil` when nothing identified the app.
  public var appLabel: String? { entry.destinationApp?.displayName }

  /// "0,8 s" / "12 s".
  public var durationLabel: String { entry.durationLabel }

  /// "14:32 · VS Code · 3,4 s", collapsing to "14:32 · 3,4 s" when the app is
  /// unknown. Contains no transcript text.
  public var metaLine: String {
    var parts = [timeLabel]
    if let appLabel, !appLabel.isEmpty { parts.append(appLabel) }
    parts.append(durationLabel)
    return parts.joined(separator: " · ")
  }

  /// Whether "Inserir de novo" can run at all.
  ///
  /// False when the destination cannot be verified, because re-injection has to
  /// bring a specific app forward first — see `TranscriptReinjector`. The button
  /// is then visibly disabled rather than pasting the transcript into whatever
  /// happens to be in front, which at that moment is Fala's own window.
  public var canReinject: Bool { entry.destinationApp?.isVerifiable ?? false }

  /// "Inserir de novo em “VS Code”" — the destination is named ON the control,
  /// so the user knows where the text lands before pressing it.
  public var reinjectTitle: String {
    guard canReinject, let appLabel, !appLabel.isEmpty else {
      return HistoryWindowStrings.reinject
    }
    return "\(HistoryWindowStrings.reinject) em “\(appLabel)”"
  }

  /// What VoiceOver is told when the button is disabled; the dimming alone is
  /// invisible to it.
  public var reinjectUnavailableHint: String? {
    canReinject ? nil : HistoryWindowStrings.reinjectUnavailable
  }
}

/// One day's section: heading plus its rows, newest first.
public struct HistoryDay: Sendable, Equatable, Identifiable {
  /// Midnight of the day, in the grouping calendar's time zone.
  public let startOfDay: Date
  /// "Hoje" · "Ontem" · "Sexta-feira, 1 de agosto".
  public let title: String
  public let rows: [HistoryRow]

  public init(startOfDay: Date, title: String, rows: [HistoryRow]) {
    self.startOfDay = startOfDay
    self.title = title
    self.rows = rows
  }

  public var id: Date { startOfDay }

  /// "1 ditada" / "3 ditadas".
  public var countLabel: String {
    rows.count == 1 ? "1 ditada" : "\(rows.count) ditadas"
  }
}

/// Groups entries into day sections (DESIGN-HANDOFF.md §1: "day grouping").
public enum HistoryDayGrouping {
  /// Days newest first, rows within a day in the order they arrived — which the
  /// store already guarantees is newest first.
  ///
  /// Deliberately order-preserving rather than re-sorting: `DictationHistoryStore`
  /// sorts stably by timestamp on load and a second sort here could only either
  /// agree with it or silently disagree with it.
  public static func groups(
    for entries: [DictationHistoryEntry],
    now: Date,
    calendar: Calendar = HistoryCalendar.ptBR
  ) -> [HistoryDay] {
    var order: [Date] = []
    var buckets: [Date: [HistoryRow]] = [:]
    for entry in entries {
      let day = calendar.startOfDay(for: entry.createdAt)
      let row = HistoryRow(
        entry: entry,
        timeLabel: HistoryDayTitle.time(for: entry.createdAt, calendar: calendar))
      if buckets[day] == nil {
        buckets[day] = []
        order.append(day)
      }
      buckets[day]?.append(row)
    }
    return order.map { day in
      HistoryDay(
        startOfDay: day,
        title: HistoryDayTitle.title(for: day, now: now, calendar: calendar),
        rows: buckets[day] ?? [])
    }
  }
}
