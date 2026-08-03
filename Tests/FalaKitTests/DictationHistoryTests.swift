import Foundation
import Testing
import os

@testable import FalaKit

// MARK: - Fixtures

/// A clock the test moves by hand, so ordering and ages are exact instead of
/// "whatever the machine did between two lines".
///
/// `OSAllocatedUnfairLock` rather than an actor: the store wants a synchronous
/// `@Sendable () -> Date`, and this is the one escape hatch CLAUDE.md allows.
private struct TestClock: Sendable {
  private let state = OSAllocatedUnfairLock(
    initialState: Date(timeIntervalSince1970: 1_770_000_000))

  var now: Date { state.withLock { $0 } }

  func advance(_ seconds: TimeInterval) {
    state.withLock { $0 = $0.addingTimeInterval(seconds) }
  }

  var reader: @Sendable () -> Date {
    { self.state.withLock { $0 } }
  }
}

private struct FixedFrontmostApp: FrontmostApplicationProviding {
  let app: DestinationApp?

  init(_ app: DestinationApp?) { self.app = app }

  func current() async -> DestinationApp? { app }
}

private let codeApp = DestinationApp(bundleIdentifier: "com.microsoft.VSCode", name: "VS Code")

private func makeScratchDirectory() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("fala-history-\(UUID().uuidString)", isDirectory: true)
}

private func removeScratchDirectory(_ url: URL) {
  try? FileManager.default.removeItem(at: url)
}

private func makeStore(
  in directory: URL,
  maxEntries: Int = DictationHistoryStore.defaultMaxEntries,
  frontmost: DestinationApp? = codeApp,
  clock: TestClock = TestClock()
) -> DictationHistoryStore {
  DictationHistoryStore(
    directory: directory,
    maxEntries: maxEntries,
    frontmost: FixedFrontmostApp(frontmost),
    clock: clock.reader)
}

// MARK: - Store

@Suite("DictationHistoryStore")
struct DictationHistoryStoreTests {

  @Test("A recorded dictation comes back as a RecentTranscription row")
  func recordsAndVends() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let clock = TestClock()
    let store = makeStore(in: directory, clock: clock)

    await store.record(text: "fazer o deploy no endpoint", duration: 2.5)

    let rows = await store.recent(limit: 4)
    #expect(rows.count == 1)
    #expect(rows.first?.text == "fazer o deploy no endpoint")
    #expect(rows.first?.destinationApp == "VS Code")
    #expect(rows.first?.metaLine(relativeTo: clock.now) == "agora · VS Code")
  }

  @Test("Recents are newest first and never exceed the requested limit")
  func newestFirstWithinLimit() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let clock = TestClock()
    let store = makeStore(in: directory, clock: clock)

    for index in 1...5 {
      await store.record(text: "ditada \(index)", duration: 1)
      clock.advance(60)
    }

    let rows = await store.recent(limit: 3)
    #expect(rows.map(\.text) == ["ditada 5", "ditada 4", "ditada 3"])
  }

  @Test("A non-positive limit asks for nothing and gets nothing")
  func nonPositiveLimit() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let store = makeStore(in: directory)
    await store.record(text: "oi", duration: 1)

    #expect(await store.recent(limit: 0).isEmpty)
    #expect(await store.recent(limit: -3).isEmpty)
  }

  @Test("The hard cap drops the oldest entries instead of growing forever")
  func hardCapTrimsOldest() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let clock = TestClock()
    let store = makeStore(in: directory, maxEntries: 3, clock: clock)

    for index in 1...7 {
      await store.record(text: "ditada \(index)", duration: 1)
      clock.advance(10)
    }

    let entries = await store.allEntries()
    #expect(entries.map(\.text) == ["ditada 7", "ditada 6", "ditada 5"])
    // And the cap is enforced on DISK, not only in memory.
    let reopened = makeStore(in: directory, maxEntries: 3, clock: clock)
    #expect(await reopened.allEntries().count == 3)
  }

  @Test("The cap is clamped so a caller cannot ask for zero or unbounded history")
  func capIsClamped() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let store = makeStore(in: directory, maxEntries: 0)

    await store.record(text: "uma", duration: 1)
    #expect(await store.allEntries().count == 1)
    #expect(await store.status().maxEntries == 1)
  }

  @Test("Empty and whitespace-only text is never recorded")
  func emptyTextIsNotRecorded() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let store = makeStore(in: directory)

    await store.record(text: "", duration: 1)
    await store.record(text: "   \n\t ", duration: 1)

    #expect(await store.allEntries().isEmpty)
    // Nothing was written at all, so no file was created for an empty history.
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
  }

  @Test("Text is stored trimmed, so a row never renders leading blank space")
  func textIsTrimmed() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let store = makeStore(in: directory)

    await store.record(text: "  fazer o merge  \n", duration: 1)

    #expect(await store.allEntries().first?.text == "fazer o merge")
  }

  @Test("History survives the process: a second store reads what the first wrote")
  func survivesAcrossInstances() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let clock = TestClock()
    let writer = makeStore(in: directory, clock: clock)
    await writer.record(text: "subir o container", duration: 3.25)

    let reader = makeStore(in: directory, clock: clock)
    let entries = await reader.allEntries()
    #expect(entries.count == 1)
    #expect(entries.first?.text == "subir o container")
    #expect(entries.first?.duration == 3.25)
    #expect(entries.first?.destinationApp == codeApp)
    #expect(entries.first?.createdAt == clock.now)
  }

  @Test("Per-entry delete removes that row from disk (DESIGN-HANDOFF §1)")
  func deleteOneEntry() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let clock = TestClock()
    let store = makeStore(in: directory, clock: clock)
    await store.record(text: "primeira", duration: 1)
    clock.advance(30)
    await store.record(text: "segunda", duration: 1)

    let doomed = try #require(await store.allEntries().first { $0.text == "primeira" })
    try await store.delete(id: doomed.id)

    #expect(await store.allEntries().map(\.text) == ["segunda"])
    let reopened = makeStore(in: directory, clock: clock)
    #expect(await reopened.allEntries().map(\.text) == ["segunda"])
  }

  @Test("Deleting an id that is not there changes nothing")
  func deleteUnknownId() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let store = makeStore(in: directory)
    await store.record(text: "única", duration: 1)

    try await store.delete(id: UUID())

    #expect(await store.allEntries().count == 1)
  }

  @Test("'Apagar tudo' erases the file AND the quarantined copy")
  func eraseAllRemovesEveryTranscriptFile() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let store = makeStore(in: directory)
    await store.record(text: "algo particular", duration: 1)
    // Simulate a previously quarantined file: it holds transcripts too, so
    // "apagar tudo" that left it behind would be a lie.
    try Data("{ lixo }".utf8).write(to: store.quarantineURL)

    try await store.eraseAll()

    #expect(await store.allEntries().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: store.quarantineURL.path))
  }

  @Test("Erasing an empty history is a no-op, not an error")
  func eraseAllOnEmptyHistory() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let store = makeStore(in: directory)

    try await store.eraseAll()

    #expect(await store.lastProblem == nil)
  }

  @Test("The store writes exactly one file, in its own directory, and nothing else")
  func writesOnlyItsOwnFile() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let store = makeStore(in: directory)

    await store.record(text: "transcrição secreta", duration: 1)

    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(contents == ["history.json"])
  }

  @Test("The history file is not readable by other accounts on the Mac")
  func fileAndDirectoryArePrivate() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let store = makeStore(in: directory)
    await store.record(text: "conteúdo privado", duration: 1)
    // Twice, because the second write goes through the atomic REPLACE path,
    // which creates a new file: the mode has to be re-applied every time, not
    // only when the file is first created.
    await store.record(text: "mais conteúdo privado", duration: 1)

    let manager = FileManager.default
    let fileMode = try #require(
      manager.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)
    let directoryMode = try #require(
      manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
    #expect(fileMode.int16Value == 0o600)
    #expect(directoryMode.int16Value == 0o700)
  }

  @Test("The file is JSON a human can open and read")
  func fileIsInspectable() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let clock = TestClock()
    let store = makeStore(in: directory, clock: clock)
    await store.record(text: "rodar o pipeline", duration: 1)

    let text = try String(contentsOf: store.fileURL, encoding: .utf8)
    #expect(text.contains("rodar o pipeline"))
    #expect(text.contains("\"version\""))
    #expect(text.contains("\"createdAt\""))
    #expect(text.contains("\"durationSeconds\""))
    // Pretty-printed, so it is diffable and editable rather than one long line.
    #expect(text.contains("\n"))
    // ISO-8601, not a raw epoch number nobody can read.
    let timestamp = HistoryDateFormat.string(from: clock.now)
    #expect(text.contains(timestamp))
  }

  @Test("A hand-written minimal file loads, including a date without milliseconds")
  func handWrittenFileLoads() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = makeStore(in: directory)
    let json = """
      {
        "version" : 1,
        "entries" : [
          {
            "id" : "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
            "text" : "antiga",
            "createdAt" : "2026-08-01T10:00:00Z",
            "durationSeconds" : 1
          },
          {
            "id" : "3F2504E0-4F89-41D3-9A0C-0305E82C3302",
            "text" : "recente",
            "createdAt" : "2026-08-02T10:00:00.500Z",
            "durationSeconds" : 2
          }
        ]
      }
      """
    try Data(json.utf8).write(to: store.fileURL)

    let entries = await store.allEntries()
    // Sorted newest-first even though the file listed them the other way round.
    #expect(entries.map(\.text) == ["recente", "antiga"])
    // A missing `destinationApp` is legal and renders as an age with no app.
    #expect(entries.last?.destinationApp == nil)
    #expect(await store.lastProblem == nil)
  }

  @Test("An unreadable file is moved aside, never silently overwritten")
  func corruptFileIsQuarantined() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = makeStore(in: directory)
    let original = Data("{ isto não é json válido".utf8)
    try original.write(to: store.fileURL)

    #expect(await store.allEntries().isEmpty)
    #expect(await store.lastProblem == .unreadableFileMovedAside(file: "history-anterior.json"))
    // The user's bytes still exist, byte for byte, under the quarantine name.
    #expect(try Data(contentsOf: store.quarantineURL) == original)

    // And the store keeps working from there.
    await store.record(text: "depois do estrago", duration: 1)
    #expect(await store.allEntries().map(\.text) == ["depois do estrago"])
  }

  @Test("A file from a future format version is quarantined, not misread")
  func unknownVersionIsQuarantined() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = makeStore(in: directory)
    try Data("{ \"version\" : 99, \"entries\" : [] }".utf8).write(to: store.fileURL)

    #expect(await store.allEntries().isEmpty)
    #expect(await store.lastProblem == .unreadableFileMovedAside(file: "history-anterior.json"))
  }

  @Test("Every problem message is pt-BR and names a file, never a path or a transcript")
  func problemMessagesAreSafePortuguese() {
    let problems: [DictationHistoryProblem] = [
      .unreadableFileMovedAside(file: "history-anterior.json"),
      .unreadableFile(file: "history.json"),
      .cannotWrite(file: "history.json"),
      .cannotErase(file: "history.json"),
    ]
    for problem in problems {
      #expect(!problem.message.isEmpty)
      #expect(!problem.message.contains("/"))
      #expect(!problem.message.contains("Users"))
    }
    #expect(DictationHistoryProblem.cannotWrite(file: "history.json").message.contains("gravar"))
  }

  @Test("status() summarises the store in one pt-BR line with an abbreviated path")
  func statusSummary() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let store = makeStore(in: directory, maxEntries: 10)

    let empty = await store.status()
    #expect(empty.entryCount == 0)
    #expect(!empty.fileExists)
    #expect(empty.isHealthy)
    #expect(empty.summary.hasPrefix(DictationHistoryStrings.empty))

    await store.record(text: "uma ditada", duration: 1)
    let filled = await store.status()
    #expect(filled.entryCount == 1)
    #expect(filled.fileExists)
    #expect(filled.summary.contains("1 ditada guardada"))
    #expect(filled.summary.contains("máx. 10"))

    let home = FileManager.default.homeDirectoryForCurrentUser
    let inHome = DictationHistoryStatus(
      entryCount: 2,
      maxEntries: 500,
      fileURL: home.appendingPathComponent("Library/Application Support/Fala/history.json"),
      fileExists: true,
      problem: nil)
    #expect(inHome.displayPath == "~/Library/Application Support/Fala/history.json")
    #expect(inHome.summary.contains("2 ditadas guardadas"))
  }
}

// MARK: - Values

@Suite("DictationHistoryEntry")
struct DictationHistoryEntryTests {

  @Test("An entry with no identified destination renders as an age alone")
  func metaLineWithoutDestination() {
    let now = Date(timeIntervalSince1970: 1_770_000_000)
    let entry = DictationHistoryEntry(
      text: "sem destino", createdAt: now.addingTimeInterval(-120), duration: 1)

    #expect(entry.recentTranscription.destinationApp == nil)
    #expect(entry.recentTranscription.metaLine(relativeTo: now) == "há 2 min")
  }

  @Test("A destination with only a bundle identifier still labels the row")
  func displayNameFallsBackToBundleIdentifier() {
    let noName = DestinationApp(bundleIdentifier: "com.apple.dt.Xcode", name: nil)
    #expect(noName.displayName == "com.apple.dt.Xcode")
    #expect(noName.isVerifiable)

    let empty = DestinationApp(bundleIdentifier: "", name: "")
    #expect(empty.displayName == nil)
    #expect(!empty.isVerifiable)

    let nameOnly = DestinationApp(bundleIdentifier: nil, name: "Terminal")
    #expect(nameOnly.displayName == "Terminal")
    // Undo refuses this one: a name cannot identify an app safely.
    #expect(!nameOnly.isVerifiable)
  }

  @Test("Duration reads in pt-BR, with a decimal comma, on any machine's locale")
  func durationLabelIsPortuguese() {
    #expect(DictationHistoryEntry(text: "a", createdAt: .now, duration: 0).durationLabel == "0,0 s")
    #expect(
      DictationHistoryEntry(text: "a", createdAt: .now, duration: 0.75).durationLabel == "0,8 s")
    #expect(
      DictationHistoryEntry(text: "a", createdAt: .now, duration: 9.94).durationLabel == "9,9 s")
    #expect(
      DictationHistoryEntry(text: "a", createdAt: .now, duration: 12.4).durationLabel == "12 s")
    // Negative durations cannot be constructed, and a hand-edited one is clamped.
    #expect(DictationHistoryEntry(text: "a", createdAt: .now, duration: -5).duration == 0)
  }

  @Test("The undo record carries no transcript text at all")
  func undoRecordIsTextFree() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let clock = TestClock()
    let store = makeStore(in: directory, clock: clock)
    await store.record(text: "isto nunca deve chegar ao undo", duration: 1)

    let injection = try #require(await store.lastInjection())
    // Structural, not stylistic: `UndoableInjection` has no text member, so the
    // only way this can regress is by someone adding one.
    #expect(injection.destination == codeApp)
    #expect(injection.injectedAt == clock.now)
    #expect(injection.undoRequestedAt == nil)
    let mirrored = Mirror(reflecting: injection).children.compactMap(\.label)
    #expect(mirrored == ["id", "destination", "injectedAt", "undoRequestedAt"])
  }

  @Test("markUndoRequested persists and the first mark wins")
  func markUndoRequestedIsIdempotent() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let clock = TestClock()
    let store = makeStore(in: directory, clock: clock)
    await store.record(text: "desfazível", duration: 1)
    let injection = try #require(await store.lastInjection())
    let firstMark = clock.now.addingTimeInterval(5)

    await store.markUndoRequested(id: injection.id, at: firstMark)
    await store.markUndoRequested(id: injection.id, at: firstMark.addingTimeInterval(600))

    #expect(await store.lastInjection()?.undoRequestedAt == firstMark)
    let reopened = makeStore(in: directory, clock: clock)
    #expect(await reopened.lastInjection()?.undoRequestedAt == firstMark)
  }

  @Test("An empty history has no last injection")
  func noLastInjection() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    #expect(await makeStore(in: directory).lastInjection() == nil)
  }
}

// MARK: - Coordinator hook

private actor RecordingSpy: DictationHistoryRecording {
  struct Call: Sendable, Equatable {
    let text: String
    let duration: TimeInterval
  }

  private(set) var calls: [Call] = []

  func record(text: String, duration: TimeInterval) async {
    calls.append(Call(text: text, duration: duration))
  }
}

private actor SpyCapture: AudioCapturing {
  private let audio: AudioBuffer

  init(audio: AudioBuffer) { self.audio = audio }

  func start() async throws {}
  func stop() async throws -> AudioBuffer { audio }
  func cancel() async {}
}

private actor SpyInjector: TextInjector {
  private let error: InjectionError?

  init(error: InjectionError? = nil) { self.error = error }

  func inject(_ text: String) async throws {
    if let error { throw error }
  }
}

@Suite("DictationCoordinator + history")
struct DictationCoordinatorHistoryTests {
  private static let audio = AudioBuffer(
    samples: Array(repeating: Float(0.1), count: 32_000), sampleRate: 16_000)

  @Test("A successful dictation is recorded with the injected text and the audio length")
  func recordsOnSuccess() async throws {
    let spy = RecordingSpy()
    let coordinator = DictationCoordinator(
      capture: SpyCapture(audio: Self.audio),
      engine: MockTranscriptionEngine(text: "fazer o deploy"),
      injector: SpyInjector(),
      history: spy)

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)

    #expect(await coordinator.currentState == .success)
    #expect(await spy.calls == [.init(text: "fazer o deploy", duration: 2.0)])
  }

  @Test("A blocked injection records nothing — history is what actually landed")
  func recordsNothingWhenInjectionFails() async throws {
    let spy = RecordingSpy()
    let coordinator = DictationCoordinator(
      capture: SpyCapture(audio: Self.audio),
      engine: MockTranscriptionEngine(text: "senha secreta"),
      injector: SpyInjector(error: .secureInputActive),
      history: spy)

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)

    let blocked = DictationCoordinator.message(for: .secureInputActive)
    #expect(await coordinator.currentState == .failure(message: blocked))
    #expect(await spy.calls.isEmpty)
  }

  @Test("The history is optional: existing call sites keep working without one")
  func historyIsOptional() async throws {
    let coordinator = DictationCoordinator(
      capture: SpyCapture(audio: Self.audio),
      engine: MockTranscriptionEngine(text: "sem histórico"),
      injector: SpyInjector())

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)

    #expect(await coordinator.currentState == .success)
  }

  @Test("The real store, driven by the coordinator, ends up on disk")
  func endToEndThroughTheRealStore() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let store = makeStore(in: directory)
    let coordinator = DictationCoordinator(
      capture: SpyCapture(audio: Self.audio),
      engine: MockTranscriptionEngine(text: "subir para staging"),
      injector: SpyInjector(),
      history: store)

    await coordinator.handle(.pressed)
    await coordinator.handle(.released)

    let reopened = makeStore(in: directory)
    let entries = await reopened.allEntries()
    #expect(entries.map(\.text) == ["subir para staging"])
    #expect(entries.first?.duration == 2.0)
    #expect(entries.first?.destinationApp?.name == "VS Code")
  }
}

// MARK: - Popover

private struct StubPermissions: PermissionChecking {
  func isGranted(_ permission: Permission) -> Bool { true }
}

@MainActor
private final class StubDictationStore: DictationEnabledStoring {
  func loadDictationEnabled() -> Bool { true }
  func saveDictationEnabled(_ enabled: Bool) {}
}

@Suite("History feeds the popover")
struct HistoryPopoverTests {

  @Test("The store satisfies the popover's existing seam, so 'Recentes' fills in")
  @MainActor
  func presenterRendersStoredDictations() async throws {
    let directory = makeScratchDirectory()
    defer { removeScratchDirectory(directory) }
    let clock = TestClock()
    let store = makeStore(in: directory, clock: clock)
    await store.record(text: "primeira ditada", duration: 1)
    clock.advance(120)
    await store.record(text: "segunda ditada", duration: 1)

    let presenter = MenuBarPresenter(
      dictation: DictationSwitch(store: StubDictationStore()),
      permissions: StubPermissions(),
      modelStatus: {
        ModelStatus(isPresent: true, sizeBytes: 1, location: ModelStatus.defaultLocation)
      },
      engineName: { TranscriptionEngineChoice.parakeet.shortName },
      history: store,
      clock: clock.reader,
      recentsLimit: 4)

    await presenter.refresh()

    let texts = presenter.recents.map { (row: RecentTranscription) in row.text }
    #expect(texts == ["segunda ditada", "primeira ditada"])
    #expect(presenter.recents.first?.metaLine(relativeTo: presenter.now) == "agora · VS Code")
    #expect(presenter.recents.last?.metaLine(relativeTo: presenter.now) == "há 2 min · VS Code")
  }
}
