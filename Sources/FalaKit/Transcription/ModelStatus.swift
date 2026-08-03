import Foundation

/// How usable the on-disk ASR model actually is.
///
/// The middle case is the whole point. `parakeet-tdt-0.6b-v3` is a ~483 MB
/// download made of four compiled CoreML bundles; interrupt it (sleep, network
/// drop, quit) and what is left behind is a DIRECTORY that exists and is
/// useless. Answering "is that directory there?" reported "Modelo Parakeet ·
/// pronto · Zero KB" while nothing worked, which is worse than reporting
/// nothing: the user is told the one thing that is broken is fine.
public enum ModelReadiness: Sendable, Equatable {

  /// Every required file is on disk, non-empty, and the total is plausible.
  case ready

  /// Nothing at the location at all — the normal first-run state, and the one
  /// the first hotkey press resolves by downloading.
  case notDownloaded

  /// The directory is there but the model cannot load: an interrupted download,
  /// or files deleted by hand. `missing` names the required parts that are
  /// absent or empty, relative to the model directory; it is EMPTY when every
  /// part is present but the total weighs far less than a complete download,
  /// which is what a transfer truncated mid-file looks like.
  case incomplete(missing: [String])
}

/// Whether the ASR model is actually on disk AND complete, so `doctor` and the
/// menu bar can report readiness they have checked rather than readiness they
/// assume.
///
/// Without this, a user with no model downloaded is told "tudo pronto para
/// ditar" and then meets a multi-minute silent download on their first hotkey
/// press — the exact first-run failure the diagnostic exists to prevent.
public struct ModelStatus: Sendable, Equatable {

  public let readiness: ModelReadiness

  /// Bytes on disk, when anything is there. Reported rather than asserted: the
  /// commonly quoted "~1.1 GB" is the upstream repository size, not what lands
  /// here. Non-nil for an incomplete download too — "parcial, 40 MB" is the
  /// evidence that tells the user their download died half-way.
  public let sizeBytes: Int64?

  public let location: URL

  /// True only when the model can actually be loaded. Callers that gate a
  /// download or an "everything is fine" line want exactly this.
  public var isPresent: Bool { readiness == .ready }

  /// True when something is on disk but unusable — the state that used to be
  /// indistinguishable from `ready`.
  public var isIncomplete: Bool {
    if case .incomplete = readiness { return true }
    return false
  }

  /// Required parts that are missing or empty, relative to `location`. Empty
  /// unless the download is incomplete in that specific way.
  public var missingComponents: [String] {
    if case .incomplete(let missing) = readiness { return missing }
    return []
  }

  public init(readiness: ModelReadiness, sizeBytes: Int64?, location: URL) {
    self.readiness = readiness
    self.sizeBytes = sizeBytes
    self.location = location
  }

  /// Convenience for callers (and tests) that only care about the binary
  /// question. `false` means "not downloaded"; a partial download can only be
  /// produced by `current(at:)`, which is the only thing that can detect one.
  public init(isPresent: Bool, sizeBytes: Int64?, location: URL) {
    self.init(
      readiness: isPresent ? .ready : .notDownloaded, sizeBytes: sizeBytes, location: location)
  }

  /// FluidAudio 0.15.5's cache location. Verified against a real download on this
  /// machine; re-check it when the pinned version changes (see the
  /// `fluidaudio-asr` skill's version-bump checklist).
  public static var defaultLocation: URL {
    FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/FluidAudio/Models")
      .appendingPathComponent("parakeet-tdt-0.6b-v3")
  }

  // MARK: - What "complete" means

  /// The four compiled CoreML bundles a Parakeet TDT v3 load opens.
  ///
  /// Taken from FluidAudio 0.15.5's own `ModelNames.ASR.requiredModelsV3(
  /// precision: .int8)` — `Preprocessor`, `Encoder` (int8 is the pinned default
  /// of `AsrModels.downloadAndLoad(version:)`), `Decoder` and the v3-specific
  /// `JointDecisionv3` — and re-verified against a real completed download on
  /// this machine on 2026-08-02.
  static let compiledModelNames = [
    "Preprocessor.mlmodelc",
    "Encoder.mlmodelc",
    "Decoder.mlmodelc",
    "JointDecisionv3.mlmodelc",
  ]

  /// Shared across Parakeet versions (`ModelNames.ASR.vocabularyFile`). Without
  /// it FluidAudio re-fetches, so its absence is a real "not ready".
  static let vocabularyFileName = "parakeet_vocab.json"

  /// Files that must exist and be non-empty, relative to the model directory.
  ///
  /// FluidAudio's own `AsrModels.modelsExist(at:)` asks only whether the four
  /// `.mlmodelc` PATHS exist — and a `.mlmodelc` is a directory, so a download
  /// killed after `createDirectory` satisfies it. We look one level in, at the
  /// two files a bundle cannot have unless it was really written: the
  /// `coremldata.bin` descriptor CoreML opens first, and the `weights/weight.bin`
  /// payload that is almost all of the download.
  static var requiredFiles: [String] {
    compiledModelNames.flatMap {
      ["\($0)/coremldata.bin", "\($0)/weights/weight.bin"]
    } + [vocabularyFileName]
  }

  /// Backstop against a transfer truncated mid-file, where every required path
  /// exists and is non-empty but holds a fraction of its bytes.
  ///
  /// A complete v3/int8 download measured 483,256,769 bytes on 2026-08-02 (the
  /// encoder weights alone are 445 MB). The floor sits well under that so a
  /// packaging change in a patch release cannot make a working model report as
  /// broken, and well over any partial state. Re-measure it when the pinned
  /// FluidAudio version changes.
  static let minimumPlausibleBytes: Int64 = 300_000_000

  // MARK: - Reading the disk

  public static func current(at location: URL = ModelStatus.defaultLocation) -> ModelStatus {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: location.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return ModelStatus(readiness: .notDownloaded, sizeBytes: nil, location: location)
    }

    let size = directorySize(of: location, using: fileManager)
    let missing = requiredFiles.filter {
      !isNonEmptyFile(at: location.appendingPathComponent($0), using: fileManager)
    }
    guard missing.isEmpty, size ?? 0 >= minimumPlausibleBytes else {
      return ModelStatus(
        readiness: .incomplete(missing: missing), sizeBytes: size, location: location)
    }
    return ModelStatus(readiness: .ready, sizeBytes: size, location: location)
  }

  /// Human-readable size, or nil when nothing is on disk.
  public var formattedSize: String? {
    guard let sizeBytes else { return nil }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: sizeBytes)
  }

  /// Path with `$HOME` abbreviated to `~`, so a diagnostic can be pasted into a
  /// bug report without carrying the user's account name.
  public var displayPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = location.path
    guard path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }

  /// pt-BR explanation of why the model is not usable, or `nil` when it is.
  ///
  /// Names file names and an abbreviated path only — never audio, never a
  /// transcript.
  public var problemMessage: String? {
    switch readiness {
    case .ready:
      return nil
    case .notDownloaded:
      return "Não baixado — a primeira ditada vai baixá-lo (alguns minutos)."
    case .incomplete(let missing):
      let size = formattedSize.map { " (\($0) em disco)" } ?? ""
      let detail =
        missing.isEmpty
        ? "os arquivos estão menores do que deveriam"
        : "falta \(Self.list(missing))"
      return "Download incompleto\(size): \(detail). Apague \(displayPath) e "
        + "deixe baixar de novo."
    }
  }

  // MARK: - Helpers

  /// At most three names, so a directory that lost everything does not print
  /// nine lines of noise.
  private static func list(_ names: [String]) -> String {
    let shown = names.prefix(3).joined(separator: ", ")
    return names.count > 3 ? shown + " e mais \(names.count - 3)" : shown
  }

  /// A required part counts only as a real file with bytes in it: an empty
  /// placeholder and a directory of the same name are both failures.
  private static func isNonEmptyFile(at url: URL, using fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue,
      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    else { return false }
    return size > 0
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
