import Foundation

// MARK: - Values

/// The app a transcript was injected into, captured at injection time.
///
/// Both fields are optional because `NSWorkspace` can report a frontmost
/// application with no bundle identifier (a bare executable, a helper) and, more
/// rarely, no localized name. They are kept SEPARATE on purpose: the name is
/// what the user reads ("VS Code"), the bundle identifier is what undo compares
/// against, and a name alone is not safe to compare — two apps can share one.
public struct DestinationApp: Sendable, Equatable, Codable {
  public let bundleIdentifier: String?
  public let name: String?

  public init(bundleIdentifier: String?, name: String?) {
    self.bundleIdentifier = bundleIdentifier
    self.name = name
  }

  /// What a row shows. `nil` when nothing identified the app at all, which the
  /// popover renders as an age with no app suffix.
  public var displayName: String? {
    if let name, !name.isEmpty { return name }
    if let bundleIdentifier, !bundleIdentifier.isEmpty { return bundleIdentifier }
    return nil
  }

  /// Whether undo can verify this destination later. A destination without a
  /// bundle identifier is unverifiable, and undo refuses rather than guessing.
  public var isVerifiable: Bool {
    guard let bundleIdentifier else { return false }
    return !bundleIdentifier.isEmpty
  }
}

/// One persisted dictation (SPEC.md FR-17, DESIGN-HANDOFF.md §1 history-window).
///
/// PRIVACY — read `DictationHistoryStore`'s doc comment first. This is the ONE
/// type in the project that deliberately carries transcript text to disk, and it
/// is a product feature the user asked for, not logging: the file is local,
/// inspectable and erasable. Nothing here may reach `os_log`, stdout, or any
/// path other than the store's own file.
public struct DictationHistoryEntry: Sendable, Equatable, Identifiable, Codable {
  public let id: UUID
  /// The transcript exactly as it was injected — after the jargon dictionary,
  /// so the history matches what landed in the user's document.
  public let text: String
  public let createdAt: Date
  /// Length of the audio that produced it, in seconds.
  public let duration: TimeInterval
  public let destinationApp: DestinationApp?
  /// When undo was requested for this entry; `nil` while it is still undoable.
  /// Persisted so quitting the app cannot resurrect an undo that already fired.
  public var undoRequestedAt: Date?

  public init(
    id: UUID = UUID(),
    text: String,
    createdAt: Date,
    duration: TimeInterval = 0,
    destinationApp: DestinationApp? = nil,
    undoRequestedAt: Date? = nil
  ) {
    self.id = id
    self.text = text
    self.createdAt = createdAt
    self.duration = max(0, duration)
    self.destinationApp = destinationApp
    self.undoRequestedAt = undoRequestedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case text
    case createdAt
    case duration = "durationSeconds"
    case destinationApp
    case undoRequestedAt
  }

  /// The read-only shape the popover already renders (`RecentTranscription`).
  public var recentTranscription: RecentTranscription {
    RecentTranscription(
      id: id,
      text: text,
      createdAt: createdAt,
      destinationApp: destinationApp?.displayName)
  }

  /// "0,8 s" / "12 s", pt-BR decimal comma.
  ///
  /// Formatted by hand rather than with a `NumberFormatter` for the same reason
  /// `RelativeTimePtBR` is: a formatter reads the machine's locale, and this app
  /// is pt-BR by project rule on every Mac it runs on.
  /// Clamped here as well as in `init`: a hand-edited file goes through the
  /// synthesised `Codable` initialiser, which does not run the clamp.
  public var durationLabel: String {
    let seconds = max(0, duration)
    guard seconds >= 10 else {
      let text = String(format: "%.1f", seconds)
      return text.replacingOccurrences(of: ".", with: ",") + " s"
    }
    return "\(Int(seconds.rounded())) s"
  }
}

/// Everything the undo path is allowed to know about the last injection.
///
/// PRIVACY: deliberately carries NO transcript text. Undo synthesises a
/// keystroke into another application; it never needs the words, so this type
/// makes it structurally impossible for them to reach that code path.
public struct UndoableInjection: Sendable, Equatable {
  public let id: UUID
  public let destination: DestinationApp?
  public let injectedAt: Date
  /// Non-nil once undo has already been requested for this injection.
  public let undoRequestedAt: Date?

  public init(
    id: UUID,
    destination: DestinationApp?,
    injectedAt: Date,
    undoRequestedAt: Date? = nil
  ) {
    self.id = id
    self.destination = destination
    self.injectedAt = injectedAt
    self.undoRequestedAt = undoRequestedAt
  }
}

// MARK: - Problems

/// Something went wrong with the history FILE rather than with a dictation.
///
/// None of these can stop the user dictating: history is a record, not a step in
/// the flow. They exist so the failure is reportable instead of silent.
/// Carries file NAMES only — never a full path (which embeds the user's account
/// name) and never transcript text.
public enum DictationHistoryProblem: Error, Equatable, Sendable {
  /// The file could not be parsed, so it was renamed out of the way and a fresh
  /// one started. The user's old entries still exist under `file`.
  case unreadableFileMovedAside(file: String)
  /// The file could not be parsed AND could not be renamed. The next write will
  /// overwrite it.
  case unreadableFile(file: String)
  case cannotWrite(file: String)
  case cannotErase(file: String)

  /// pt-BR, safe to show: file names only.
  public var message: String {
    switch self {
    case .unreadableFileMovedAside(let file):
      return "O histórico estava ilegível. Guardei o arquivo antigo como '\(file)' "
        + "e comecei um novo."
    case .unreadableFile(let file):
      return "Não consegui ler '\(file)'. O histórico recomeça vazio."
    case .cannotWrite(let file):
      return "Não consegui gravar '\(file)'. Esta ditada não entrou no histórico."
    case .cannotErase(let file):
      return "Não consegui apagar '\(file)'."
    }
  }
}

/// What `doctor` and the history window need to describe the store in one line.
public struct DictationHistoryStatus: Sendable, Equatable {
  public let entryCount: Int
  public let maxEntries: Int
  public let fileURL: URL
  public let fileExists: Bool
  public let problem: DictationHistoryProblem?

  public init(
    entryCount: Int,
    maxEntries: Int,
    fileURL: URL,
    fileExists: Bool,
    problem: DictationHistoryProblem?
  ) {
    self.entryCount = entryCount
    self.maxEntries = maxEntries
    self.fileURL = fileURL
    self.fileExists = fileExists
    self.problem = problem
  }

  /// Path with `$HOME` abbreviated to `~`, so a diagnostic can be pasted into a
  /// bug report without carrying the user's account name.
  public var displayPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = fileURL.path
    guard path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }

  /// One pt-BR line: how much is stored and where.
  public var summary: String {
    guard entryCount > 0 else {
      return "\(DictationHistoryStrings.empty) \(displayPath)"
    }
    let noun = entryCount == 1 ? "ditada guardada" : "ditadas guardadas"
    return "\(entryCount) \(noun) (máx. \(maxEntries)) · \(displayPath)"
  }

  public var isHealthy: Bool { problem == nil }
}

// MARK: - Seams

/// The write side of history, and the ONLY thing `DictationCoordinator` sees.
///
/// Deliberately one method with no return value: recording must never be able to
/// fail a dictation, and the coordinator must not grow a second responsibility.
public protocol DictationHistoryRecording: Sendable {
  /// Records one dictation that was successfully injected.
  ///
  /// The destination app is NOT a parameter: the implementation captures it
  /// itself, at the moment of the call, from its own frontmost-app seam.
  func record(text: String, duration: TimeInterval) async
}

/// The read/edit side, for the history window (DESIGN-HANDOFF.md §1). Extends
/// the popover's existing read-only seam rather than competing with it.
public protocol DictationHistoryManaging: RecentTranscriptionsProviding {
  /// Every stored entry, newest first.
  func allEntries() async -> [DictationHistoryEntry]
  /// Per-row `trash` action.
  func delete(id: UUID) async throws
  /// "Apagar tudo" — removes every stored transcript, including any quarantined
  /// copy, so the promise is literally true.
  func eraseAll() async throws
  func status() async -> DictationHistoryStatus
}

/// What the undo service is allowed to ask history for.
///
/// Separate from `DictationHistoryManaging` so the undo path depends on the
/// smallest possible surface — and, in particular, on a type that carries no
/// transcript text.
public protocol LastInjectionProviding: Sendable {
  /// The most recent injection, or `nil` if there is none.
  func lastInjection() async -> UndoableInjection?
  /// Marks an injection as "undo was requested", so a second attempt cannot
  /// send a second Cmd+Z into work the user did afterwards.
  func markUndoRequested(id: UUID, at date: Date) async
}

// MARK: - Strings

/// pt-BR strings for the history surfaces (project rule: user-facing text is
/// Brazilian Portuguese; identifiers stay English).
public enum DictationHistoryStrings {
  public static let windowTitle = "Histórico — Fala"
  public static let empty = "Nenhuma ditada guardada ainda."
  public static let eraseAll = "Apagar tudo"
  public static let eraseAllConfirm = "Apagar todo o histórico? Isso não pode ser desfeito."
  public static let delete = "Apagar"
  public static let undo = "Desfazer"
  public static let copy = "Copiar"
  /// The history window's own privacy line (DESIGN-HANDOFF.md §1).
  public static let privacyNote = "O histórico fica só neste Mac. Apague quando quiser."
}
