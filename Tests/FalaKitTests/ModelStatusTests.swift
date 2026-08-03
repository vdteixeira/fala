import Foundation
import Testing

@testable import FalaKit

/// Readiness of the on-disk ASR model, checked against a REAL directory.
///
/// The previous test for this passed a hand-built `ModelStatus` value into the
/// menu-bar blocks, so it could only ever prove that a `true` renders as "pronto".
/// It could not see the defect, which lived entirely in `current(at:)`: any
/// existing directory was "present", contents irrelevant, so an interrupted
/// first download rendered "Modelo Parakeet · pronto · Zero KB" while nothing
/// worked. Every test here therefore builds a directory on disk and asks
/// `current(at:)` about it.
@Suite struct ModelStatusTests {

  // MARK: - The three states

  @Test("Nothing on disk is 'not downloaded', with no size to report")
  func absentDirectoryIsNotDownloaded() {
    let root = Self.temporaryDirectory()
    let status = ModelStatus.current(at: root)
    #expect(status.readiness == .notDownloaded)
    #expect(!status.isPresent)
    #expect(!status.isIncomplete)
    #expect(status.sizeBytes == nil)
    #expect(status.formattedSize == nil)
  }

  /// THE defect. An interrupted first download leaves the directory behind and
  /// nothing else; this used to answer `isPresent == true`.
  @Test("An empty model directory is NOT ready — it is an interrupted download")
  func emptyDirectoryIsNotReady() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let status = ModelStatus.current(at: root)
    #expect(!status.isPresent)
    #expect(status.isIncomplete)
    #expect(status.sizeBytes == 0)
    // Every required part is named, not just the first one.
    #expect(status.missingComponents.count == ModelStatus.requiredFiles.count)
  }

  @Test("A complete download is ready, and reports what it weighs")
  func completeDownloadIsReady() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    try Self.makeCompleteDownload(at: root)

    let status = ModelStatus.current(at: root)
    #expect(status.readiness == .ready)
    #expect(status.isPresent)
    #expect(status.missingComponents.isEmpty)
    #expect(status.problemMessage == nil)
    // ~483 MB, the size a real v3/int8 download measured on 2026-08-02.
    #expect((status.sizeBytes ?? 0) > 400_000_000)
  }

  // MARK: - The shapes a broken download actually takes

  /// The likeliest interruption point: the small bundles landed, the 445 MB
  /// encoder payload did not.
  @Test("A download missing the encoder weights is incomplete, and says which file")
  func missingEncoderWeightsIsIncomplete() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    try Self.makeCompleteDownload(at: root, omitting: ["Encoder.mlmodelc/weights/weight.bin"])

    let status = ModelStatus.current(at: root)
    #expect(!status.isPresent)
    #expect(status.missingComponents == ["Encoder.mlmodelc/weights/weight.bin"])
  }

  /// FluidAudio's own `AsrModels.modelsExist(at:)` asks only whether the four
  /// `.mlmodelc` paths exist — and they are DIRECTORIES, so this layout passes
  /// its check while failing to load. Ours has to look inside.
  @Test("Bare .mlmodelc directories with nothing in them are not a model")
  func emptyBundleDirectoriesAreNotAModel() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    let fileManager = FileManager.default
    for name in ModelStatus.compiledModelNames {
      try fileManager.createDirectory(
        at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try Self.write(root.appendingPathComponent(ModelStatus.vocabularyFileName), bytes: 151_122)

    let status = ModelStatus.current(at: root)
    #expect(!status.isPresent)
    #expect(status.missingComponents.contains("Encoder.mlmodelc/coremldata.bin"))
    #expect(status.missingComponents.contains("Decoder.mlmodelc/weights/weight.bin"))
  }

  @Test("A required part that exists but is empty does not count as present")
  func zeroByteFilesDoNotCount() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    try Self.makeCompleteDownload(at: root)
    // Truncate one payload to nothing, as a killed writer would leave it.
    try Self.write(
      root.appendingPathComponent("Decoder.mlmodelc/weights/weight.bin"), bytes: 0)

    let status = ModelStatus.current(at: root)
    #expect(!status.isPresent)
    #expect(status.missingComponents == ["Decoder.mlmodelc/weights/weight.bin"])
  }

  /// The backstop: every path exists and every file has bytes, but the whole
  /// tree weighs a few kilobytes. That is a transfer cut off mid-file, and the
  /// per-file existence check alone cannot see it.
  @Test("Every file present but implausibly small is still not ready")
  func truncatedDownloadIsRejected() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    try Self.makeCompleteDownload(at: root, scale: 1.0 / 100_000)

    let status = ModelStatus.current(at: root)
    #expect(!status.isPresent)
    #expect(status.isIncomplete)
    // Nothing is missing — the size floor is what rejected it.
    #expect(status.missingComponents.isEmpty)
    #expect((status.sizeBytes ?? 0) > 0)
  }

  // MARK: - What the user is told

  @Test("An incomplete download explains itself in pt-BR, naming a file to delete")
  func incompleteDownloadExplainsItselfInPortuguese() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    try Self.makeCompleteDownload(at: root, omitting: ["parakeet_vocab.json"])

    let message = try #require(ModelStatus.current(at: root).problemMessage)
    #expect(message.contains("incompleto"))
    #expect(message.contains("parakeet_vocab.json"))
    #expect(message.contains("Apague"))
  }

  @Test("Nothing downloaded explains itself in pt-BR, without alarming the user")
  func absentModelExplainsItselfInPortuguese() {
    let message = ModelStatus.current(at: Self.temporaryDirectory()).problemMessage
    #expect(message?.contains("Não baixado") == true)
  }

  /// A directory that lost everything must not print nine file names.
  @Test("The list of missing parts is clipped in the message but complete in the value")
  func missingListIsClippedInProse() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let status = ModelStatus.current(at: root)
    let message = try #require(status.problemMessage)
    #expect(message.contains("e mais \(status.missingComponents.count - 3)"))
    #expect(status.missingComponents.count == 9)
  }

  @Test("The reported path abbreviates the home directory")
  func displayPathAbbreviatesHome() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let status = ModelStatus(
      readiness: .notDownloaded,
      sizeBytes: nil,
      location: home.appendingPathComponent("Library/Application Support/FluidAudio/Models"))
    #expect(status.displayPath == "~/Library/Application Support/FluidAudio/Models")
  }

  // MARK: - The layout this is all checked against

  /// Guards the contract with FluidAudio 0.15.5: `Preprocessor`, `Encoder`
  /// (int8, the pinned default), `Decoder` and the v3-only `JointDecisionv3`,
  /// plus the shared vocabulary. If a version bump renames any of these, this
  /// fails before a user is told a working model is missing.
  @Test("The required set matches the four v3 bundles plus the vocabulary")
  func requiredSetMatchesFluidAudioV3() {
    #expect(
      ModelStatus.compiledModelNames == [
        "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc",
      ])
    #expect(ModelStatus.vocabularyFileName == "parakeet_vocab.json")
    #expect(ModelStatus.requiredFiles.count == 9)
  }

  @Test("The default location is FluidAudio's cache for the pinned model")
  func defaultLocationIsFluidAudioCache() {
    let path = ModelStatus.defaultLocation.path
    #expect(path.hasSuffix("Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"))
  }

  // MARK: - Helpers

  /// Byte counts of a REAL completed download, measured at
  /// `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`
  /// on 2026-08-02 (483,256,769 bytes in total).
  private static let realSizes: [(path: String, bytes: Int64)] = [
    ("Preprocessor.mlmodelc/coremldata.bin", 486),
    ("Preprocessor.mlmodelc/weights/weight.bin", 491_072),
    ("Encoder.mlmodelc/coremldata.bin", 485),
    ("Encoder.mlmodelc/weights/weight.bin", 445_187_200),
    ("Decoder.mlmodelc/coremldata.bin", 554),
    ("Decoder.mlmodelc/weights/weight.bin", 23_604_992),
    ("JointDecisionv3.mlmodelc/coremldata.bin", 521),
    ("JointDecisionv3.mlmodelc/weights/weight.bin", 12_642_764),
    ("parakeet_vocab.json", 151_122),
  ]

  /// Reproduces that layout in a temp directory.
  ///
  /// - Parameters:
  ///   - omitting: relative paths to leave out, i.e. the shape of a download
  ///     that died part-way.
  ///   - scale: multiplies every size, so a truncated transfer can be built
  ///     without changing the shape.
  private static func makeCompleteDownload(
    at root: URL,
    omitting: [String] = [],
    scale: Double = 1
  ) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for entry in realSizes where !omitting.contains(entry.path) {
      let bytes = max(1, Int64(Double(entry.bytes) * scale))
      try write(root.appendingPathComponent(entry.path), bytes: bytes)
    }
  }

  /// Writes a SPARSE file of the given logical size: `truncate` costs no disk
  /// and no time on APFS, but `.fileSizeKey` still reports the full length —
  /// which is the only thing under test. Without this a "complete download"
  /// fixture would mean writing 460 MB per test.
  private static func write(_ url: URL, bytes: Int64) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fileManager.removeItem(at: url)
    guard fileManager.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    guard bytes > 0 else { return }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(bytes))
  }

  private static func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("fala-model-status-\(UUID().uuidString)", isDirectory: true)
  }

  private static func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}
