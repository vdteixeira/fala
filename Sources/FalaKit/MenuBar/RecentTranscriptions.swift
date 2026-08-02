import Foundation

/// One row of the popover's "Recentes" list (DESIGN-HANDOFF.md §1).
///
/// PRIVACY (CLAUDE.md, NFR-1). `text` is transcript content, so this type is
/// deliberately a read-only in-memory value: nothing in this file, and nothing in
/// the menu bar that renders it, writes it to disk, to a log, or anywhere else.
/// It lives exactly as long as the provider keeps vending it.
///
/// The store that produces these is TASKS.md **T2.5 and is not implemented here**.
/// This is the shape T2.5 has to fill; `NoRecentTranscriptions` is what the
/// popover renders until it does.
public struct RecentTranscription: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let text: String
  public let createdAt: Date
  /// Localized name of the app the text was injected into ("VS Code"). `nil` when
  /// the frontmost app could not be identified — the row then shows only the age.
  public let destinationApp: String?

  public init(
    id: UUID = UUID(),
    text: String,
    createdAt: Date,
    destinationApp: String? = nil
  ) {
    self.id = id
    self.text = text
    self.createdAt = createdAt
    self.destinationApp = destinationApp
  }

  /// The single line the row shows.
  ///
  /// The row also truncates visually (`.lineLimit(1)`), which is what puts the
  /// ellipsis at the real pixel width. This collapses WHITESPACE first, because a
  /// dictation containing a line break otherwise renders as its first line alone
  /// with no ellipsis at all — the rest of the sentence disappears silently
  /// instead of visibly.
  public func previewText(maxCharacters: Int = 120) -> String {
    guard maxCharacters > 0 else { return "" }
    let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard collapsed.count > maxCharacters else { return collapsed }
    return collapsed.prefix(maxCharacters).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// The secondary line: "há 2 min · VS Code" (mockup `r.meta`).
  public func metaLine(relativeTo now: Date) -> String {
    let age = RelativeTimePtBR.describe(now.timeIntervalSince(createdAt))
    guard let app = destinationApp, !app.isEmpty else { return age }
    return "\(age) · \(app)"
  }
}

/// pt-BR ages, formatted the way the mockup writes them ("há 2 min", "há 1 h").
///
/// Hand-rolled rather than `RelativeDateTimeFormatter` on purpose: the popover
/// needs the mockup's exact abbreviations, and a formatter would make the string
/// depend on the machine's locale — an app whose UI is pt-BR by project rule
/// would then render "2 min ago" on an en-US Mac. Calendar dates are the History
/// window's job (Surface 4); here everything collapses to days.
public enum RelativeTimePtBR {
  public static func describe(_ secondsAgo: TimeInterval) -> String {
    // A negative age means the clock moved (skew, DST, a manual change), not that
    // the dictation is in the future. Reading it as "agora" is the honest answer.
    let seconds = max(0, secondsAgo)
    if seconds < 60 { return "agora" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "há \(minutes) min" }
    let hours = minutes / 60
    if hours < 24 { return "há \(hours) h" }
    return "há \(hours / 24) d"
  }
}

/// The read-only seam the menu bar needs from history (TASKS.md T2.5).
///
/// Intentionally minimal: vending is all the popover does. No insert, no delete,
/// no undo — those belong to T2.5's own API, and keeping them out of this
/// protocol is what stops the menu bar from growing a second, competing history.
public protocol RecentTranscriptionsProviding: Sendable {
  /// Most recent first, at most `limit` entries.
  func recent(limit: Int) async -> [RecentTranscription]
}

/// The stub the popover ships with until T2.5 exists. Renders the empty state.
public struct NoRecentTranscriptions: RecentTranscriptionsProviding {
  public init() {}

  public func recent(limit: Int) async -> [RecentTranscription] { [] }
}
