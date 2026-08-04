import Foundation
import Testing

@testable import FalaKit

/// "Apagar tudo", end to end against a REAL `DictationHistoryStore` on disk.
///
/// The rest of the history suite runs on `FakeHistory`, which is right for
/// testing the model's logic — but it cannot catch a file that survives, and the
/// reported defect ("não está apagando tudo do histórico") was a user watching
/// 45 real transcripts stay on disk after the alert closed.
@Suite("Apagar tudo (real store)")
@MainActor
struct HistoryEraseAllTests {

  private static func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("fala-erase-\(UUID().uuidString)")
  }

  private static func store(entries: Int, at directory: URL) async -> DictationHistoryStore {
    let store = DictationHistoryStore(directory: directory)
    for index in 0..<entries {
      await store.record(text: "ditada numero \(index)", duration: 1)
    }
    return store
  }

  // MARK: The store

  @Test("The store leaves nothing on disk and nothing in memory")
  func storeIsEmptyAfterErase() async throws {
    let directory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = await Self.store(entries: 5, at: directory)
    #expect(FileManager.default.fileExists(atPath: store.fileURL.path))

    try await store.eraseAll()

    #expect(await store.allEntries().isEmpty)
    #expect(await store.recent(limit: 100).isEmpty)
    let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    #expect(left.isEmpty, "files left behind: \(left)")
  }

  /// The next dictation must not write the old list back out.
  @Test("Recording after an erase does not resurrect the old entries")
  func recordAfterEraseDoesNotResurrect() async throws {
    let directory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = await Self.store(entries: 4, at: directory)

    try await store.eraseAll()
    await store.record(text: "nova", duration: 1)

    #expect(await store.allEntries().count == 1)
    // A separate reader sees the same thing — the file, not just the cache.
    let reopened = DictationHistoryStore(directory: directory)
    #expect(await reopened.allEntries().count == 1)
  }

  // MARK: The window, driven the way the alert drives it

  /// THE REPORTED DEFECT, against real files.
  ///
  /// SwiftUI clears an alert's `isPresented` as soon as any of its buttons is
  /// tapped, which runs the presentation binding's setter — `cancelEraseAll()`.
  /// This is that exact order: dismissal first, destructive action second.
  @Test("Tapping Apagar tudo really empties the file")
  func tappingEraseEmptiesTheFile() async throws {
    let directory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = await Self.store(entries: 6, at: directory)

    let model = HistoryWindowModel(history: store)
    model.beginSession()
    await model.load()
    #expect(model.totalCount == 6)

    model.requestEraseAll()
    let confirmation = try #require(model.eraseConfirmation)
    model.cancelEraseAll()  // ← what the dismissal does on tap
    await model.eraseAllConfirmed(confirmation).value

    #expect(model.totalCount == 0)
    #expect(model.days.isEmpty)
    #expect(await store.allEntries().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
  }

  /// A search narrows what is VISIBLE; it must never narrow what is destroyed.
  @Test("Erasing while a search is active still erases everything")
  func eraseWhileSearching() async throws {
    let directory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = await Self.store(entries: 6, at: directory)

    let model = HistoryWindowModel(history: store)
    model.beginSession()
    await model.load()
    model.setSearchText("numero 3")
    #expect(model.matchCount < model.totalCount)

    model.requestEraseAll()
    let confirmation = try #require(model.eraseConfirmation)
    await model.eraseAllConfirmed(confirmation).value

    #expect(await store.allEntries().isEmpty)
    #expect(model.totalCount == 0)
    #expect(model.days.isEmpty)
  }

  /// And reopening the window must not bring them back from any cache.
  @Test("Reopening the window after an erase shows nothing")
  func reopeningShowsNothing() async throws {
    let directory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = await Self.store(entries: 3, at: directory)

    let model = HistoryWindowModel(history: store)
    model.beginSession()
    await model.load()
    model.requestEraseAll()
    await model.eraseAllConfirmed(try #require(model.eraseConfirmation)).value
    model.forget()

    model.beginSession()
    await model.load()
    #expect(model.totalCount == 0)
    #expect(model.days.isEmpty)
  }
}
