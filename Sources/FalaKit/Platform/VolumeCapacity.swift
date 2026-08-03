import Foundation

/// How much room the volume holding a given path has, and what that volume is
/// called — the two facts behind the Modelo tab's "182 GB livres em Macintosh HD"
/// (settings-window.dc.html, MODELO section).
///
/// The line is not decoration. It sits directly under the download controls
/// because the question it answers is "does the ~483 MB model fit?", which is the
/// one thing a user cannot find out from anywhere else in the app before starting
/// a multi-minute transfer.
public struct VolumeCapacity: Sendable, Equatable {

  /// Space available to this app for a download it wants to keep.
  ///
  /// Read from `volumeAvailableCapacityForImportantUsage`, which is what Apple
  /// documents for exactly this decision: it counts purgeable space (caches,
  /// local Time Machine snapshots) that the system will reclaim under pressure.
  /// `volumeAvailableCapacity` does not, and it under-reports badly — measured on
  /// this machine on 2026-08-03: 282,391,396,352 bytes plain vs
  /// 299,449,212,356 for important usage, a 17 GB difference that would make the
  /// app refuse a download that fits.
  public let availableBytes: Int64

  /// The user-visible volume name ("Macintosh HD"), from
  /// `volumeLocalizedNameKey`. Never empty — a reader that cannot name the
  /// volume must return `nil` rather than an unnamed capacity, so the line is
  /// hidden instead of rendered as "182 GB livres em ".
  public let volumeName: String

  public init(availableBytes: Int64, volumeName: String) {
    self.availableBytes = availableBytes
    self.volumeName = volumeName
  }

  // MARK: - pt-BR

  /// "182 GB livres em Macintosh HD".
  public var freeLine: String {
    "\(formattedAvailable) livres em \(volumeName)"
  }

  /// "182 GB". Whole units on purpose: `ByteCountFormatter`'s adaptive mode
  /// prints two decimals at GB scale ("299,45 GB" here), which is noise in a
  /// caption whose job is a rough yes/no. The decimal separator still follows the
  /// user's locale, so a pt-BR Mac reads "1,5 GB".
  public var formattedAvailable: String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    formatter.isAdaptive = false
    // Default `true` renders zero as "Zero KB", which reads as a formatting bug
    // in the one situation where the number matters most.
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: max(0, availableBytes))
  }

  /// Whether a download of `bytes` fits.
  ///
  /// No safety margin is added. A margin would be a number nobody measured, and
  /// the peak cost of the transfer really is one copy: FluidAudio streams into
  /// `<file>.partial` beside the destination and then `moveItem`s it, which is a
  /// rename within the same volume, not a second copy.
  public func hasRoom(for bytes: Int64) -> Bool {
    availableBytes >= bytes
  }

  /// pt-BR warning when the model does not fit, `nil` when it does.
  ///
  /// States both numbers because "espaço insuficiente" alone leaves the user with
  /// no idea how much they need to free up.
  public func insufficientSpaceWarning(for bytes: Int64) -> String? {
    guard !hasRoom(for: bytes) else { return nil }
    let needed = VolumeCapacity(availableBytes: bytes, volumeName: volumeName)
      .formattedAvailable
    return "Espaço insuficiente: o download precisa de \(needed) e há "
      + "\(formattedAvailable) livres em \(volumeName)."
  }
}

/// The seam.
///
/// Behind a protocol because the interesting answers are the ones this machine
/// cannot be made to produce on demand: a full disk, an unnamed volume, a read
/// that fails. Every one of those changes what the Modelo tab renders, and none
/// of them is reachable in a test without substituting the reader.
public protocol VolumeCapacityReading: Sendable {

  /// Capacity of the volume holding `url`, or `nil` when it cannot be
  /// determined.
  ///
  /// `nil` is a real answer, not an error: the tab hides the free-space line
  /// rather than printing a guess. `url` need not exist — see
  /// `FileSystemVolumeCapacityReader`.
  func capacity(at url: URL) -> VolumeCapacity?
}

/// Production reader, backed by `URLResourceValues`.
public struct FileSystemVolumeCapacityReader: VolumeCapacityReading {

  public init() {}

  public func capacity(at url: URL) -> VolumeCapacity? {
    // `FileManager` is not `Sendable`, so it is created where it is used rather
    // than stored — the same shape `ModelStatus.current(at:)` uses. There is no
    // test seam here on purpose: the seam is `VolumeCapacityReading` itself.
    guard let existing = Self.nearestExistingAncestor(of: url, using: .default) else {
      return nil
    }
    guard
      let values = try? existing.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeLocalizedNameKey,
      ]),
      let available = values.volumeAvailableCapacityForImportantUsage,
      let name = values.volumeLocalizedName,
      !name.isEmpty
    else { return nil }
    return VolumeCapacity(availableBytes: available, volumeName: name)
  }

  /// Walks up until it finds a directory that exists.
  ///
  /// REQUIRED, not defensive. The path this is asked about is
  /// `ModelStatus.defaultLocation`, and on the run that matters most — the one
  /// before the first download — that directory does not exist yet. Measured on
  /// 2026-08-03: `resourceValues(forKeys:)` on an absent path throws
  /// `NSCocoaErrorDomain` 260 rather than answering about the volume, so asking
  /// directly returns `nil` on exactly the first run where the user most needs to
  /// know whether the model fits.
  ///
  /// Terminates at the filesystem root: `deletingLastPathComponent()` on "/"
  /// returns "/", which is caught by comparing paths rather than by a depth cap.
  static func nearestExistingAncestor(of url: URL, using fileManager: FileManager) -> URL? {
    var candidate = url.standardizedFileURL
    while true {
      if fileManager.fileExists(atPath: candidate.path) { return candidate }
      let parent = candidate.deletingLastPathComponent().standardizedFileURL
      if parent.path == candidate.path { return nil }
      candidate = parent
    }
  }
}
