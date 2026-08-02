import Foundation

/// Whether the ASR model is actually on disk, so `doctor` can report readiness it
/// has checked rather than readiness it assumes.
///
/// Without this, a user with no model downloaded is told "tudo pronto para ditar"
/// and then meets a multi-minute silent download on their first hotkey press —
/// the exact first-run failure the diagnostic exists to prevent.
public struct ModelStatus: Sendable, Equatable {
  public let isPresent: Bool
  /// Bytes on disk, when present. Reported rather than asserted: the commonly
  /// quoted "~1.1 GB" is the upstream repository size, not what lands here.
  public let sizeBytes: Int64?
  public let location: URL

  /// FluidAudio 0.15.5's cache location. Verified against a real download on this
  /// machine; re-check it when the pinned version changes (see the
  /// `fluidaudio-asr` skill's version-bump checklist).
  public static var defaultLocation: URL {
    FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/FluidAudio/Models")
      .appendingPathComponent("parakeet-tdt-0.6b-v3")
  }

  public static func current(at location: URL = ModelStatus.defaultLocation) -> ModelStatus {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: location.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return ModelStatus(isPresent: false, sizeBytes: nil, location: location)
    }
    return ModelStatus(
      isPresent: true, sizeBytes: directorySize(of: location, using: fileManager),
      location: location)
  }

  /// Human-readable size, or nil when the model is absent.
  public var formattedSize: String? {
    guard let sizeBytes else { return nil }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: sizeBytes)
  }

  private static func directorySize(of url: URL, using fileManager: FileManager) -> Int64? {
    guard
      let enumerator = fileManager.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
    else { return nil }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
      total += Int64(size ?? 0)
    }
    return total
  }
}
