import FluidAudio
import Foundation
import os

// The cancellable shape of the model download (settings-window.dc.html, MODELO:
// "Baixando novamente… {pct}%" with a "Cancelar" beside it).
//
// WHY THIS DOES NOT GO THROUGH `ParakeetEngine.prepare()`. `prepare()` funnels
// into `loadedManager()`, which wraps the loader in an UNSTRUCTURED
// `Task { try await loader.loadManager() }` and then awaits `task.value`.
// Cancelling the caller does nothing to that task, and `Task.value` does not
// throw when the AWAITING task is cancelled — measured on 2026-08-03: an outer
// task cancelled 100 ms in still waited the full 740 ms for the inner task,
// received its value, and the inner task reported `Task.isCancelled == false`
// throughout. A "Cancelar" wired to `prepare()` would therefore stop nothing and
// leave 483 MB still moving.
//
// Everything below instead awaits FluidAudio DIRECTLY inside one owned task, so
// cancellation propagates structurally into `FileDownloader.streamDownload`,
// which is where FluidAudio 0.15.5 actually cancels the `URLSessionDataTask`.

// MARK: - What the download is doing

/// The three things a model download can be doing, in the order they happen.
///
/// A single "baixando" state is not enough, because two of these look identical
/// on a progress bar and behave completely differently under "Cancelar": the
/// transfer stops on request, the CoreML open does not.
public enum ModelDownloadStage: Sendable, Equatable {

  /// Asking HuggingFace which files exist. No bytes yet, so no percentage.
  case preparing

  /// Bytes are moving. The only stage where "Cancelar" saves the user anything.
  case transferring(ModelDownloadProgress)

  /// Bytes are on disk and CoreML is opening the compiled bundles.
  ///
  /// NOT cancellable, and deliberately not dressed up as if it were: FluidAudio's
  /// compile loop (`ModelHub.loadModelsOnce`) contains no cancellation check and
  /// `MLModel(contentsOf:)` is a synchronous call that runs to completion.
  case installing

  /// The progress value the existing `ModelBlock.downloading` renders.
  ///
  /// `preparing` and `installing` map to `.unknown`, whose `isDeterminate` is
  /// false, so the popover draws an indeterminate bar instead of a frozen 0%.
  public var progress: ModelDownloadProgress {
    if case .transferring(let progress) = self { return progress }
    return .unknown
  }

  /// Whether "Cancelar" can still do anything. The view keeps the control
  /// visible-but-disabled rather than removing it, so it does not vanish under
  /// the pointer mid-download.
  public var isCancellable: Bool { self != .installing }

  /// Order of the stages. Reports arrive on an unspecified queue and are
  /// delivered to the main actor through independent tasks, so "later" has to be
  /// decided by content, not arrival.
  var rank: Int {
    switch self {
    case .preparing: return 0
    case .transferring: return 1
    case .installing: return 2
    }
  }

  /// Whether this report is worth applying over `other`.
  ///
  /// ONE rule doing two jobs, which is why it is a value and not a method on the
  /// controller:
  ///
  /// 1. **Monotonicity.** `AsrModels.download` calls `ModelHub.loadModels` once
  ///    per compiled bundle (four times for v3), and each call builds its own
  ///    `ProgressReporter` that sweeps 0 → 1. Applied naively the bar would run
  ///    to 100% and restart three times.
  /// 2. **Throttling.** The byte callback fires per received chunk — thousands of
  ///    times across 483 MB. Rejecting a report that does not move the integer
  ///    percentage keeps that from becoming thousands of main-actor hops.
  func supersedes(_ other: ModelDownloadStage?) -> Bool {
    guard let other else { return true }
    if rank != other.rank { return rank > other.rank }
    guard
      case .transferring(let new) = self,
      case .transferring(let old) = other
    else { return false }
    // Losing the total is a regression too: it would swap a determinate bar for
    // an indeterminate one mid-download.
    guard new.isDeterminate else { return false }
    return !old.isDeterminate || new.percent > old.percent
  }
}

// MARK: - How big the download is

extension ModelStatus {

  /// Bytes a complete `parakeet-tdt-0.6b-v3` int8 download occupies.
  ///
  /// This is the MEASURED total from a real completed download on this machine on
  /// 2026-08-02 — the same measurement `minimumPlausibleBytes` is derived from,
  /// named here so the two places that need the real number (the download's
  /// progress denominator and the free-space check) cannot drift apart.
  ///
  /// It is NOT the "~1,1 GB" the mockup and FluidAudio's own docs quote: that is
  /// the upstream repository size across every precision variant, and showing it
  /// would tell a user with 800 MB free that the model does not fit when it does.
  /// Re-measure when the pinned FluidAudio version changes.
  ///
  /// Deliberately an extension in this file rather than an edit to
  /// `ModelStatus.swift`: same namespace, no second definition, no edit to a file
  /// this work does not own.
  public static let expectedDownloadBytes: Int64 = 483_256_769

  /// "483,3 MB" — what the tab tells the user they are about to fetch.
  public static var formattedExpectedDownload: String {
    ModelDownloadProgress.format(expectedDownloadBytes)
  }
}

// MARK: - Why a download is running

/// The two reasons the app downloads the model, which differ in one dangerous
/// way.
public enum ModelDownloadIntent: Sendable, Equatable {

  /// Fetch whatever is missing. A complete model on disk is left alone; a partial
  /// one resumes from its `.partial` bytes. This is the safe intent and the one
  /// the first run and the "Tentar novamente" button want.
  case repair

  /// "Baixar novamente" — throw away what is there and fetch it again.
  ///
  /// DESTRUCTIVE FIRST. `AsrModels.download(force: true)` calls
  /// `removeItem(at: targetDir)` BEFORE any byte is requested, so a user who
  /// starts this with a working model and then cancels — or loses their
  /// connection — is left with no model at all. That is the behaviour of the
  /// pinned dependency, not a choice made here, which is why this case carries
  /// its own confirmation copy instead of pretending the button is harmless.
  case replace

  /// pt-BR confirmation to show BEFORE starting, or `nil` when none is needed.
  public var confirmationMessage: String? {
    switch self {
    case .repair:
      return nil
    case .replace:
      return "Baixar novamente apaga o modelo atual antes de começar. Se o "
        + "download for interrompido, o ditado fica indisponível até você baixar "
        + "de novo (\(ModelStatus.formattedExpectedDownload))."
    }
  }

  /// pt-BR label for the button that starts it.
  public var actionTitle: String {
    switch self {
    case .repair: return "Baixar modelo"
    case .replace: return "Baixar novamente"
    }
  }
}

// MARK: - The seam

/// Whatever actually moves the ~483 MB.
///
/// Behind a protocol for the usual reason (no test may hit the network) and one
/// unusual one: the property that matters most here is that the implementation
/// *respects cancellation*, and a fake is the only way to assert that the
/// controller cancels at all without downloading half a gigabyte to find out.
///
/// IMPLEMENTORS MUST await their work structurally. Wrapping it in an
/// unstructured `Task` severs cancellation silently — that is exactly the defect
/// that keeps this off `ParakeetEngine.prepare()`.
public protocol ModelDownloading: Sendable {

  /// - Parameter report: Called on an unspecified queue, possibly very often.
  ///   Callers must not assume ordering; `ModelDownloadStage.supersedes` exists
  ///   for that.
  func download(
    _ intent: ModelDownloadIntent,
    reportingTo report: @escaping @Sendable (ModelDownloadStage) -> Void
  ) async throws
}

/// Typed failures, so nothing FluidAudio throws reaches the UI raw.
public enum ModelDownloadError: Error, Equatable, Sendable {

  /// The transfer failed. `reason` is third-party text: file names, paths, HTTP
  /// codes. PRIVACY — the download path never sees audio or a transcript, so
  /// nothing here can carry one.
  case failed(reason: String)

  /// The volume holding the model cannot fit it.
  case insufficientSpace(message: String)

  /// pt-BR, ready to render.
  public var message: String {
    switch self {
    case .failed(let reason):
      let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
      return detail.isEmpty
        ? "Não foi possível baixar o modelo."
        : "Não foi possível baixar o modelo: \(detail)"
    case .insufficientSpace(let message):
      return message
    }
  }
}

// MARK: - Production downloader

/// FluidAudio 0.15.5's model acquisition, mapped into `ModelDownloadStage`.
public struct FluidAudioModelDownloader: ModelDownloading {

  private let capacity: any VolumeCapacityReading

  public init(capacity: any VolumeCapacityReading = FileSystemVolumeCapacityReader()) {
    self.capacity = capacity
  }

  public func download(
    _ intent: ModelDownloadIntent,
    reportingTo report: @escaping @Sendable (ModelDownloadStage) -> Void
  ) async throws {
    // Checked BEFORE `.replace` deletes anything: filling the volume mid-transfer
    // would leave the user with neither the old model nor the new one, and the
    // failure would surface as an opaque write error minutes in.
    if let room = capacity.capacity(at: ModelStatus.defaultLocation),
      let warning = room.insufficientSpaceWarning(for: ModelStatus.expectedDownloadBytes)
    {
      throw ModelDownloadError.insufficientSpace(message: warning)
    }

    let tracker = ModelDownloadStageTracker(expectedBytes: ModelStatus.expectedDownloadBytes)
    // FluidAudio lists the repository tree before it emits anything, which takes
    // a visible moment on a cold connection. Without this the row would render
    // empty until the first byte lands.
    report(.preparing)

    let handler: ProgressHandler = { progress in
      guard
        let stage = tracker.stage(
          fraction: progress.fractionCompleted,
          phase: RawModelDownloadPhase(progress.phase))
      else { return }
      report(stage)
    }

    do {
      // `encoderPrecision` is left at FluidAudio's `.int8` default on purpose:
      // that is the variant `ModelStatus.compiledModelNames` was verified
      // against, and the two must agree or a complete download reads as broken.
      _ = try await AsrModels.download(
        force: intent == .replace, version: .v3, progressHandler: handler)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if (error as NSError).domain == NSURLErrorDomain,
        (error as NSError).code == NSURLErrorCancelled
      {
        // FluidAudio surfaces a cancelled transfer as URLError.cancelled, not as
        // CancellationError. Translating it here keeps "the user pressed
        // Cancelar" from being reported as a download failure.
        throw CancellationError()
      }
      throw ModelDownloadError.failed(reason: Self.describe(error))
    }
  }

  private static func describe(_ error: any Error) -> String {
    if let error = error as? any LocalizedError, let description = error.errorDescription {
      return description
    }
    return (error as NSError).localizedDescription
  }
}

// MARK: - Progress translation

/// FluidAudio's `DownloadPhase`, restated as a FalaKit value.
///
/// Exists so `ModelDownloadStageTracker` — which holds all the arithmetic worth
/// testing — can be driven from a test without constructing FluidAudio types.
enum RawModelDownloadPhase: Sendable, Equatable {
  case listing
  case downloading
  case compiling

  init(_ phase: DownloadPhase) {
    switch phase {
    case .listing: self = .listing
    case .downloading: self = .downloading
    case .compiling: self = .compiling
    }
  }
}

/// Turns FluidAudio's fraction-and-phase into a stage the UI can trust.
///
/// Three things have to happen here, and none of them is guesswork — each is read
/// off the pinned `ProgressReporter`:
///
/// 1. **Rescale.** `ProgressReporter` is built with `downloadPhaseWeight: 0.5`, so
///    a fraction reported during `.downloading` spans 0 → 0.5, never 0 → 1.
///    Passing it through unscaled would stall the bar at half.
/// 2. **Latch.** `AsrModels.download` runs the whole listing/download/compile
///    sweep once per compiled bundle. Only the FIRST sweep transfers anything —
///    the rest find the cache populated and emit `cachedModelsAvailable()`
///    followed by compiles. Once a compile has been seen, every later report is
///    treated as `installing`, so the row cannot fall back to "baixando".
/// 3. **Estimate the bytes.** FluidAudio's public progress carries a fraction and
///    nothing else — no byte counts reach `ProgressHandler`. The "241 MB de
///    483 MB" line is therefore the normalized fraction applied to the MEASURED
///    download size, and it is an estimate. It is still worth showing: the
///    denominator is real and the ratio is byte-weighted upstream
///    (`ProgressReporter.downloadFraction` divides completed by total bytes).
///
/// `Sendable` via a lock, not `@unchecked`: the handler is called on an
/// unspecified queue and FluidAudio makes no promise about which.
final class ModelDownloadStageTracker: Sendable {

  /// `ProgressReporter(handler:downloadPhaseWeight:)` is constructed with 0.5
  /// at every call site in the pinned 0.15.5. Re-verify on a version bump; if it
  /// changes, the bar reaches 100% early or stops half-way.
  static let downloadPhaseWeight = 0.5

  private struct State {
    var installed = false
    var highestFraction = 0.0
    var lastEmitted: ModelDownloadStage?
  }

  private let expectedBytes: Int64
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(expectedBytes: Int64) {
    self.expectedBytes = expectedBytes
  }

  /// The stage to publish, or `nil` when this report adds nothing.
  func stage(fraction: Double, phase: RawModelDownloadPhase) -> ModelDownloadStage? {
    state.withLock { state in
      if phase == .compiling { state.installed = true }

      let candidate: ModelDownloadStage
      if state.installed {
        candidate = .installing
      } else {
        switch phase {
        case .listing:
          candidate = .preparing
        case .downloading:
          // `.isNaN` guards a handler that hands over a NaN fraction; `max(0)`
          // and the clamp keep a bad value from driving the bar off its track.
          let raw = fraction.isNaN ? 0 : fraction
          let normalized = min(max(raw / Self.downloadPhaseWeight, 0), 1)
          state.highestFraction = max(state.highestFraction, normalized)
          candidate = .transferring(
            ModelDownloadProgress(
              receivedBytes: Int64((state.highestFraction * Double(expectedBytes)).rounded()),
              totalBytes: expectedBytes))
        case .compiling:
          candidate = .installing
        }
      }

      guard candidate.supersedes(state.lastEmitted) else { return nil }
      state.lastEmitted = candidate
      return candidate
    }
  }
}
