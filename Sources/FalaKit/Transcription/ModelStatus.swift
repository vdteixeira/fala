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

/// What a COMPLETE download looks like for ONE engine's model directory.
///
/// This type exists because there are now two engines and one disk check. The
/// check itself — "every required part exists, is non-empty, and the total is
/// plausible" — is the same for both; what differs is the directory, the file
/// names inside it, and how much of that is MEASURED rather than assumed.
///
/// ## Why the two engines are checked differently
///
/// `parakeet` names nine exact paths, because a real completed download was
/// enumerated on this machine on 2026-08-02 and every one of them was seen.
///
/// `cohere` names its two bundles and its vocabulary — those come from
/// FluidAudio's own `ModelNames.CohereTranscribe` — but it does NOT name the
/// files inside a bundle, because no Cohere download has ever been measured
/// here. Asserting `weights/weight.bin` on a bundle nobody has looked inside
/// would risk telling a user with a perfectly good model to delete it, and the
/// "delete and download again" advice would then loop forever. So a Cohere
/// bundle is checked by SHAPE instead (`requiredBundles`): CoreML's own
/// descriptor must be there, and the bundle must weigh more than a descriptor
/// possibly can. Both errors that matter are still caught — a bare directory
/// left by an interrupted download, and a bundle with no payload in it.
public struct ModelLayout: Sendable, Equatable {

  public let location: URL

  /// Exact relative paths that must exist and be non-empty. Use this only for
  /// files a real download was observed to contain.
  public let requiredFiles: [String]

  /// Compiled `.mlmodelc` bundles checked by shape rather than by name: each
  /// must hold a non-empty `coremldata.bin` and weigh at least
  /// `minimumBundlePayloadBytes`.
  public let requiredBundles: [String]

  /// Total-size floor for the whole directory, or `nil` when no complete
  /// download of this model has ever been measured — in which case NO floor is
  /// applied, rather than a guessed one.
  public let minimumPlausibleBytes: Int64?

  /// What a fresh download fetches, or `nil` when it has never been measured.
  /// `nil` means the UI must not print a size, not that the size is zero.
  public let expectedDownloadBytes: Int64?

  public init(
    location: URL,
    requiredFiles: [String],
    requiredBundles: [String] = [],
    minimumPlausibleBytes: Int64?,
    expectedDownloadBytes: Int64?
  ) {
    self.location = location
    self.requiredFiles = requiredFiles
    self.requiredBundles = requiredBundles
    self.minimumPlausibleBytes = minimumPlausibleBytes
    self.expectedDownloadBytes = expectedDownloadBytes
  }

  /// The same rules pointed at a different directory — how a test builds a
  /// fixture without writing to the user's real model cache.
  public func relocated(to location: URL) -> ModelLayout {
    ModelLayout(
      location: location,
      requiredFiles: requiredFiles,
      requiredBundles: requiredBundles,
      minimumPlausibleBytes: minimumPlausibleBytes,
      expectedDownloadBytes: expectedDownloadBytes)
  }

  /// Least a real compiled bundle can weigh.
  ///
  /// Not a measurement of any particular model: it is a floor chosen to sit far
  /// above every descriptor file a `.mlmodelc` contains (the four measured
  /// Parakeet descriptors are 485–554 bytes, `model.mil` a few hundred KB) and
  /// far below any ASR encoder or decoder payload. Its only job is to tell
  /// "the download wrote the descriptors and then died" apart from "the
  /// download finished".
  public static let minimumBundlePayloadBytes: Int64 = 1_000_000

  /// FluidAudio 0.15.5's `parakeet-tdt-0.6b-v3` int8 layout, verified against a
  /// real download on this machine on 2026-08-02.
  public static var parakeet: ModelLayout {
    ModelLayout(
      location: ModelStatus.defaultLocation,
      requiredFiles: ModelStatus.requiredFiles,
      minimumPlausibleBytes: ModelStatus.minimumPlausibleBytes,
      expectedDownloadBytes: ModelStatus.expectedDownloadBytes)
  }
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

  /// Reads the Parakeet model directory. Kept as the no-argument default so
  /// every existing caller (and `doctor`) means what it always meant.
  public static func current(at location: URL = ModelStatus.defaultLocation) -> ModelStatus {
    current(ModelLayout.parakeet.relocated(to: location))
  }

  /// Reads ONE engine's model directory, against that engine's own idea of
  /// complete. Nothing here is shared between engines except the algorithm —
  /// which is the point: a Cohere row must never be answered from Parakeet's
  /// directory.
  public static func current(_ layout: ModelLayout) -> ModelStatus {
    let location = layout.location
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: location.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return ModelStatus(readiness: .notDownloaded, sizeBytes: nil, location: location)
    }

    let size = directorySize(of: location, using: fileManager)
    var missing = layout.requiredFiles.filter {
      !isNonEmptyFile(at: location.appendingPathComponent($0), using: fileManager)
    }
    missing += layout.requiredBundles.filter {
      !isLoadableBundle(at: location.appendingPathComponent($0), using: fileManager)
    }
    // `?? 0` is not a fallback default: a layout with no measured floor applies
    // no floor at all, rather than a number nobody has verified.
    guard missing.isEmpty, size ?? 0 >= (layout.minimumPlausibleBytes ?? 0) else {
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

  /// A compiled bundle whose contents were never enumerated here, checked by
  /// the two properties that hold for every `.mlmodelc` CoreML can open:
  ///
  /// 1. `coremldata.bin` — the descriptor `MLModel(contentsOf:)` reads first. It
  ///    is a FILE, so requiring it rules out the bare directory an interrupted
  ///    download leaves behind (the defect `ModelReadiness` exists to catch);
  /// 2. a payload. FluidAudio writes each file to `<name>.partial` and renames
  ///    it only once the transfer completes, so a truncated file never appears
  ///    under its final name — which makes "the bundle weighs almost nothing"
  ///    the shape of a download that stopped between files.
  private static func isLoadableBundle(at url: URL, using fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      isNonEmptyFile(at: url.appendingPathComponent("coremldata.bin"), using: fileManager),
      let size = directorySize(of: url, using: fileManager)
    else { return false }
    return size >= ModelLayout.minimumBundlePayloadBytes
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
