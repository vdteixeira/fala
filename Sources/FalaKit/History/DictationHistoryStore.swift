import Foundation

/// The dictation history (SPEC.md FR-17, US-5; TASKS.md T2.5).
///
/// PRIVACY — the exception, stated once, in the one place that takes it.
/// CLAUDE.md's golden rule is that transcripts are NEVER logged: not to stdout,
/// not to `os_log`, not to files. This store is the single deliberate exception,
/// and it is a product feature the user asked for rather than logging. What
/// makes it defensible, and what any change here must preserve:
///
/// 1. **One file, one place.** `~/Library/Application Support/Fala/history.json`
///    and nothing else. No temporary copies outside that directory, no second
///    sink, no network — this type performs no I/O other than on `fileURL` and
///    `quarantineURL`.
/// 2. **Inspectable.** Pretty-printed JSON with ISO-8601 timestamps, so the user
///    can open it in any editor and read exactly what is kept about them.
/// 3. **Erasable.** `eraseAll()` deletes the file *and* any quarantined copy, so
///    "apagar tudo" is literally true. `delete(id:)` removes one entry.
/// 4. **Bounded.** A hard cap on entries; the oldest fall off. The file cannot
///    grow without limit behind the user's back.
/// 5. **Not readable by other accounts.** Directory `0700`, file `0600`.
/// 6. **Never in a message.** `DictationHistoryProblem` carries file names only.
///
/// An `actor` because the file is shared mutable state written from the
/// dictation flow and read from the menu bar at the same time.
public actor DictationHistoryStore:
  RecentTranscriptionsProviding, DictationHistoryRecording, DictationHistoryManaging,
  LastInjectionProviding
{
  public static let fileName = "history.json"
  /// Where an unparseable file is moved so a fresh start never destroys data.
  public static let quarantineFileName = "history-anterior.json"

  /// Hard cap (requirement of T2.5: the file must not grow without bound).
  ///
  /// 500 dictations at a generous 300 characters each is roughly 200 KB — small
  /// enough to read and to erase, large enough that the history window has
  /// something to group by day. It is a COUNT rather than a byte budget because
  /// truncating a transcript would break both row actions the mockup specifies
  /// (copy and re-inject) and would silently hand the user a lie.
  public static let defaultMaxEntries = 500

  /// `~/Library/Application Support/Fala`, resolved the same way
  /// `JargonDictionaryStore` resolves it (same directory, different file).
  public static var defaultDirectory: URL {
    let fallback = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fallback
    return base.appendingPathComponent("Fala", isDirectory: true)
  }

  public let directory: URL
  private let maxEntries: Int
  private let frontmost: any FrontmostApplicationProviding
  private let clock: @Sendable () -> Date

  /// `nil` until the first read touches the disk. Loading lazily keeps the
  /// constructor free of I/O, so building the object in a test or a preview
  /// never creates a file.
  private var entries: [DictationHistoryEntry]?
  private var problem: DictationHistoryProblem?

  /// - Parameters:
  ///   - directory: overridable so tests never touch the real Application
  ///     Support directory.
  ///   - maxEntries: clamped to 1...10_000.
  ///   - frontmost: the destination-app seam. Injected so tests need no real
  ///     frontmost application.
  public init(
    directory: URL = DictationHistoryStore.defaultDirectory,
    maxEntries: Int = DictationHistoryStore.defaultMaxEntries,
    frontmost: any FrontmostApplicationProviding = SystemFrontmostApplication(),
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.directory = directory
    self.maxEntries = min(max(maxEntries, 1), 10_000)
    self.frontmost = frontmost
    self.clock = clock
  }

  public nonisolated var fileURL: URL {
    directory.appendingPathComponent(Self.fileName, isDirectory: false)
  }

  public nonisolated var quarantineURL: URL {
    directory.appendingPathComponent(Self.quarantineFileName, isDirectory: false)
  }

  /// `FileManager` is not `Sendable`, so it is fetched per call rather than
  /// stored — the same pattern `JargonDictionaryStore` uses.
  private nonisolated var fileManager: FileManager { .default }

  // MARK: - Recording

  public func record(text: String, duration: TimeInterval) async {
    let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // An empty dictation is not history. The coordinator already refuses to
    // inject one, so reaching here would mean recording something the user never
    // saw.
    guard !transcript.isEmpty else { return }

    // Read the destination BEFORE touching `entries`: this is the only `await`
    // in the method, and actors are reentrant across it. Everything after this
    // line runs without suspension, so two overlapping dictations cannot
    // interleave their insert-trim-write.
    let destination = await frontmost.current()

    var list = loadIfNeeded()
    list.insert(
      DictationHistoryEntry(
        text: transcript,
        createdAt: clock(),
        duration: duration,
        destinationApp: destination),
      at: 0)
    entries = trimmed(list)
    persist()
  }

  // MARK: - Reading

  public func recent(limit: Int) async -> [RecentTranscription] {
    guard limit > 0 else { return [] }
    return loadIfNeeded().prefix(limit).map(\.recentTranscription)
  }

  public func allEntries() async -> [DictationHistoryEntry] {
    loadIfNeeded()
  }

  public func status() async -> DictationHistoryStatus {
    let count = loadIfNeeded().count
    return DictationHistoryStatus(
      entryCount: count,
      maxEntries: maxEntries,
      fileURL: fileURL,
      fileExists: fileManager.fileExists(atPath: fileURL.path),
      problem: problem)
  }

  /// The last problem the store hit, or `nil`. Cleared by the next successful
  /// write, so a transient failure does not stick to the UI forever.
  public var lastProblem: DictationHistoryProblem? { problem }

  // MARK: - Deleting

  public func delete(id: UUID) async throws {
    let list = loadIfNeeded()
    let remaining = list.filter { $0.id != id }
    // Nothing to do — and, more to the point, nothing to REWRITE. Persisting an
    // unchanged list would churn the file for a row that was already gone.
    guard remaining.count != list.count else { return }
    entries = remaining
    try persistThrowing()
  }

  /// "Apagar tudo" (DESIGN-HANDOFF.md §1).
  ///
  /// Deletes the quarantined copy too. A version that removed only
  /// `history.json` would leave every transcript from before a parse failure
  /// sitting on disk after the user was told everything was erased.
  public func eraseAll() async throws {
    entries = []
    problem = nil
    var failure: DictationHistoryProblem?
    for url in [fileURL, quarantineURL] where fileManager.fileExists(atPath: url.path) {
      do {
        try fileManager.removeItem(at: url)
      } catch {
        failure = failure ?? .cannotErase(file: url.lastPathComponent)
      }
    }
    if let failure {
      problem = failure
      throw failure
    }
  }

  // MARK: - Undo support

  public func lastInjection() async -> UndoableInjection? {
    guard let entry = loadIfNeeded().first else { return nil }
    return UndoableInjection(
      id: entry.id,
      destination: entry.destinationApp,
      injectedAt: entry.createdAt,
      undoRequestedAt: entry.undoRequestedAt)
  }

  public func markUndoRequested(id: UUID, at date: Date) async {
    var list = loadIfNeeded()
    guard let index = list.firstIndex(where: { $0.id == id }) else { return }
    // First mark wins: re-marking would move the timestamp forward and could
    // reopen an undo window that already closed.
    guard list[index].undoRequestedAt == nil else { return }
    list[index].undoRequestedAt = date
    entries = list
    persist()
  }

  // MARK: - Disk

  private func trimmed(_ list: [DictationHistoryEntry]) -> [DictationHistoryEntry] {
    guard list.count > maxEntries else { return list }
    return Array(list.prefix(maxEntries))
  }

  private func loadIfNeeded() -> [DictationHistoryEntry] {
    if let entries { return entries }
    guard fileManager.fileExists(atPath: fileURL.path) else {
      entries = []
      return []
    }
    do {
      let data = try Data(contentsOf: fileURL)
      let document = try Self.decoder().decode(HistoryDocument.self, from: data)
      guard document.version == HistoryDocument.currentVersion else {
        throw DictationHistoryProblem.unreadableFile(file: Self.fileName)
      }
      let ordered = trimmed(Self.newestFirst(document.entries))
      entries = ordered
      return ordered
    } catch {
      // The file is the user's own dictations. Losing them to a parse error —
      // ours or a hand edit — is not acceptable, so it is renamed rather than
      // overwritten, and the rename is reported.
      quarantineUnreadableFile()
      entries = []
      return []
    }
  }

  /// Descending by date, STABLY: entries recorded within the same encoded
  /// instant keep their file order, which is already newest-first. Only a
  /// hand-edited file can produce that tie, but a shuffled history is exactly
  /// the kind of thing a user would blame on the app.
  private static func newestFirst(_ list: [DictationHistoryEntry]) -> [DictationHistoryEntry] {
    list.enumerated()
      .sorted { lhs, rhs in
        if lhs.element.createdAt != rhs.element.createdAt {
          return lhs.element.createdAt > rhs.element.createdAt
        }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  private func quarantineUnreadableFile() {
    try? fileManager.removeItem(at: quarantineURL)
    do {
      try fileManager.moveItem(at: fileURL, to: quarantineURL)
      problem = .unreadableFileMovedAside(file: Self.quarantineFileName)
    } catch {
      problem = .unreadableFile(file: Self.fileName)
    }
  }

  /// Writes without throwing — the recording path must never fail a dictation.
  private func persist() {
    do {
      try persistThrowing()
    } catch let failure as DictationHistoryProblem {
      problem = failure
    } catch {
      problem = .cannotWrite(file: Self.fileName)
    }
  }

  private func persistThrowing() throws {
    let document = HistoryDocument(entries: entries ?? [])
    do {
      try createDirectoryIfNeeded()
      let data = try Self.encoder().encode(document)
      try data.write(to: fileURL, options: .atomic)
      // Best effort: on the atomic path the replacement file inherits the
      // previous file's mode, so this matters most on the very first write. The
      // 0700 directory above is the protection that does not depend on it.
      try? fileManager.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      problem = nil
    } catch {
      throw DictationHistoryProblem.cannotWrite(file: Self.fileName)
    }
  }

  private func createDirectoryIfNeeded() throws {
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    // `createDirectory` applies attributes only to directories it creates, and
    // this one may already exist (the jargon store creates it too). Tightening
    // it is best effort: failing here must not stop a dictation being recorded.
    try? fileManager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    // The file is documentation of what we keep about the user, so it is
    // formatted to be read, not to be small.
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(HistoryDateFormat.string(from: date))
    }
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard let date = HistoryDateFormat.date(from: text) else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "not an ISO-8601 timestamp")
      }
      return date
    }
    return decoder
  }
}

// MARK: - File format

/// The on-disk shape. Versioned so a future format change can refuse to
/// misread an old file instead of silently dropping fields.
private struct HistoryDocument: Codable {
  static let currentVersion = 1

  let version: Int
  let entries: [DictationHistoryEntry]

  init(version: Int = HistoryDocument.currentVersion, entries: [DictationHistoryEntry]) {
    self.version = version
    self.entries = entries
  }
}

/// ISO-8601 with fractional seconds.
///
/// Fractional seconds are not decoration: `.iso8601`'s whole-second form makes
/// two dictations recorded in the same second indistinguishable, and history is
/// ordered by exactly that value. Reading a hand-edited file without them still
/// works.
enum HistoryDateFormat {
  static func string(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  static func date(from text: String) -> Date? {
    let precise = ISO8601DateFormatter()
    precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = precise.date(from: text) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: text)
  }
}
