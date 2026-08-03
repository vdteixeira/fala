import Foundation
import Testing

@testable import FalaKit

/// Free disk space for Ajustes › Modelo (settings-window.dc.html: "182 GB livres
/// em Macintosh HD").
///
/// LOCALE NOTE: `ByteCountFormatter` has no locale property — it follows the
/// system one — so every assertion below either uses a byte count that formats
/// identically everywhere (a whole number of GB has no decimal separator) or
/// checks structure rather than the number.
@Suite("VolumeCapacity")
struct VolumeCapacityTests {

  // MARK: - The line the mockup draws

  @Test("The free-space line reads as the mockup writes it")
  func freeLineMatchesTheMockup() {
    let capacity = VolumeCapacity(availableBytes: 182_000_000_000, volumeName: "Macintosh HD")
    #expect(capacity.freeLine == "182 GB livres em Macintosh HD")
  }

  /// The reason `isAdaptive` is turned off. Left at its default, this exact byte
  /// count — what this machine really reported on 2026-08-03 — renders as
  /// "299,45 GB", two decimals of precision nobody asked for in a caption whose
  /// job is a rough yes/no.
  @Test("Free space is stated in whole units, not to two decimals")
  func freeSpaceIsRoundedToWholeUnits() {
    let capacity = VolumeCapacity(availableBytes: 299_449_212_356, volumeName: "Macintosh HD")
    #expect(capacity.formattedAvailable == "299 GB")
  }

  /// `ByteCountFormatter`'s default renders zero as "Zero KB", which reads as a
  /// formatting bug in the one case where the number matters most.
  @Test("A full volume says 0, not 'Zero KB'")
  func fullVolumeFormatsNumerically() {
    let capacity = VolumeCapacity(availableBytes: 0, volumeName: "Disco")
    #expect(capacity.formattedAvailable == "0 MB")
    #expect(capacity.freeLine == "0 MB livres em Disco")
  }

  @Test("A negative reading is clamped rather than printed as '-0,000005 MB'")
  func negativeCapacityIsClamped() {
    let capacity = VolumeCapacity(availableBytes: -5, volumeName: "Disco")
    #expect(capacity.formattedAvailable == "0 MB")
  }

  // MARK: - Does the model fit?

  @Test("Exactly enough room is enough — no invented safety margin")
  func exactFitCounts() {
    let capacity = VolumeCapacity(
      availableBytes: ModelStatus.expectedDownloadBytes, volumeName: "Macintosh HD")
    #expect(capacity.hasRoom(for: ModelStatus.expectedDownloadBytes))
    #expect(capacity.insufficientSpaceWarning(for: ModelStatus.expectedDownloadBytes) == nil)
  }

  @Test("One byte short is not enough")
  func oneByteShortFails() {
    let capacity = VolumeCapacity(
      availableBytes: ModelStatus.expectedDownloadBytes - 1, volumeName: "Macintosh HD")
    #expect(!capacity.hasRoom(for: ModelStatus.expectedDownloadBytes))
  }

  /// "Espaço insuficiente" on its own leaves the user with no idea how much to
  /// free up, so both numbers and the volume name have to be in the sentence.
  @Test("The warning names how much is needed, how much is free, and where")
  func warningCarriesBothNumbers() throws {
    let capacity = VolumeCapacity(availableBytes: 120_000_000, volumeName: "Macintosh HD")
    let warning = try #require(
      capacity.insufficientSpaceWarning(for: ModelStatus.expectedDownloadBytes))
    #expect(warning.contains("120 MB"))
    // "483" rather than the formatted string: the caller's number goes through
    // the same whole-unit formatter, so it reads "483 MB" while
    // `formattedExpectedDownload` (adaptive) reads "483,3 MB".
    #expect(warning.contains("483"))
    #expect(warning.contains("Macintosh HD"))
    #expect(warning.hasPrefix("Espaço insuficiente"))
  }

  @Test("A download of 1,1 GB would not fit where 483 MB does — the numbers matter")
  func theQuotedSizeAndTheRealSizeDisagree() {
    let capacity = VolumeCapacity(availableBytes: 600_000_000, volumeName: "Macintosh HD")
    #expect(capacity.hasRoom(for: ModelStatus.expectedDownloadBytes))
    // The "~1,1 GB" the mockup and FluidAudio's docs quote is the upstream repo
    // size. Believing it would refuse a download that fits.
    #expect(!capacity.hasRoom(for: 1_100_000_000))
  }

  // MARK: - Reading a real volume

  /// The whole reason `nearestExistingAncestor` exists. Measured on 2026-08-03:
  /// `resourceValues(forKeys:)` on an absent path throws `NSCocoaErrorDomain`
  /// 260 instead of answering about the volume — and the path this is asked
  /// about, `ModelStatus.defaultLocation`, does NOT exist before the first
  /// download, which is precisely the run where the user needs to know whether
  /// the model fits.
  @Test("A path that does not exist yet still reports its volume")
  func absentPathStillResolvesAVolume() throws {
    let reader = FileSystemVolumeCapacityReader()
    let absent = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/FluidAudio/Models")
      .appendingPathComponent("no-such-model-\(UUID().uuidString)")
    #expect(!FileManager.default.fileExists(atPath: absent.path))

    let capacity = try #require(reader.capacity(at: absent))
    #expect(capacity.availableBytes > 0)
    #expect(!capacity.volumeName.isEmpty)
  }

  @Test("An existing path and its absent descendant report the same volume")
  func ancestorAndDescendantAgree() throws {
    let reader = FileSystemVolumeCapacityReader()
    let home = FileManager.default.homeDirectoryForCurrentUser
    let deep = home.appendingPathComponent("a/b/c/\(UUID().uuidString)")

    let fromHome = try #require(reader.capacity(at: home))
    let fromDeep = try #require(reader.capacity(at: deep))
    #expect(fromHome.volumeName == fromDeep.volumeName)
  }

  @Test("The walk stops at the root instead of looping on '/'")
  func walkTerminatesAtRoot() throws {
    let found = try #require(
      FileSystemVolumeCapacityReader.nearestExistingAncestor(
        of: URL(fileURLWithPath: "/definitely-not-here-\(UUID().uuidString)/x/y"),
        using: .default))
    #expect(found.path == "/")
  }

  @Test("An existing directory is returned as-is")
  func existingPathIsItsOwnAncestor() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fala-volume-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let found = try #require(
      FileSystemVolumeCapacityReader.nearestExistingAncestor(of: directory, using: .default))
    #expect(found.standardizedFileURL.path == directory.standardizedFileURL.path)
  }

  /// `volumeAvailableCapacityForImportantUsage` counts purgeable space (caches,
  /// local snapshots) and `volumeAvailableCapacity` does not. Measured here on
  /// 2026-08-03 the gap was 17 GB, which is the difference between refusing a
  /// download and allowing it — so this pins that the reader uses the one Apple
  /// documents for "can I download this".
  @Test("The reader uses the important-usage capacity, not the plain one")
  func readerUsesImportantUsageCapacity() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let values = try home.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ])
    let important = try #require(values.volumeAvailableCapacityForImportantUsage)
    let capacity = try #require(FileSystemVolumeCapacityReader().capacity(at: home))
    // Free space moves between the two reads, so this compares against the
    // important-usage figure with slack rather than for equality.
    let drift = abs(capacity.availableBytes - important)
    #expect(drift < 5_000_000_000)
  }

  // MARK: - The seam

  @Test("A reader that cannot answer hides the line instead of guessing")
  func unreadableVolumeYieldsNil() {
    let reader = StubVolumeCapacityReader(result: nil)
    #expect(reader.capacity(at: ModelStatus.defaultLocation) == nil)
  }
}

/// Fixed answer, so the states this machine cannot be made to produce — a full
/// disk, an unnamed volume, a failed read — are all reachable in a test.
struct StubVolumeCapacityReader: VolumeCapacityReading {
  let result: VolumeCapacity?

  func capacity(at url: URL) -> VolumeCapacity? { result }
}
