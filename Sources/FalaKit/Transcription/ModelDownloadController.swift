import Foundation
import Observation

/// How a download ended.
public enum ModelDownloadOutcome: Sendable, Equatable {

  /// Every required file is on disk and CoreML opened it.
  case completed

  /// The user pressed "Cancelar" — NOT a failure, and never rendered as one.
  case cancelled

  case failed(ModelDownloadError)

  /// pt-BR, or `nil` for the outcomes with nothing to say.
  public var message: String? {
    switch self {
    case .completed: return nil
    case .cancelled: return "Download cancelado."
    case .failed(let error): return error.message
    }
  }
}

/// Owns the one in-flight model download and the only handle that can stop it
/// (settings-window.dc.html, MODELO: the "Cancelar" beside the progress bar).
///
/// WHAT CANCELLATION ACTUALLY GUARANTEES — all three verified against the pinned
/// FluidAudio 0.15.5 source on 2026-08-03, because "we cancelled the Task" and
/// "the network stopped" are not the same claim:
///
/// * **The transfer really stops.** `FileDownloader.streamDownload` wraps its
///   continuation in `withTaskCancellationHandler { … } onCancel: { delegate
///   .cancel() }`, and that handler calls `cancel()` on the live
///   `URLSessionDataTask`. Cancelling this controller's task therefore closes the
///   socket rather than merely abandoning the await.
/// * **Nothing restarts it.** `RetryPolicy.isRetryable` classifies
///   `URLError.cancelled` as permanent, so the bounded-retry loop rethrows
///   instead of re-dialling.
/// * **The cache survives.** `ModelHub.loadModels` normally deletes the model
///   directory and re-downloads when a load fails; it checks
///   `RetryPolicy.isCancellation` FIRST and preserves the cache, so cancelling a
///   `.repair` cannot destroy an otherwise fine download.
///
/// WHAT IT DOES NOT GUARANTEE:
///
/// * **Nothing is reclaimed.** Received bytes stay in `<file>.partial` beside the
///   destination, together with an `.etag` sidecar, precisely so a later attempt
///   resumes instead of restarting. Cancelling frees no disk space; it stops the
///   download from taking more.
/// * **`installing` is not interruptible.** FluidAudio's compile loop has no
///   cancellation check and `MLModel(contentsOf:)` is synchronous, so a cancel
///   issued there is only observed after the current bundle finishes opening.
///   That is why the task's completion is re-checked against `Task.isCancelled`
///   below: the call can return SUCCESSFULLY after being cancelled, and reporting
///   that as `.completed` would be a lie.
/// * **One file may still arrive.** `withTaskCancellationHandler` runs its
///   handler BEFORE the operation body when the task is already cancelled
///   (measured on 2026-08-03: the handler ran first, then the body). If a cancel
///   lands in the window between two files, `delegate.cancel()` finds no attached
///   task and the next `URLSessionDataTask` is created and resumed uncancelled —
///   so up to one more file can transfer in full. This is a FluidAudio-side race
///   that nothing in this package can close; see the report accompanying this
///   work.
@MainActor
@Observable
public final class ModelDownloadController {

  /// What the download is doing, or `nil` when nothing is running.
  public private(set) var stage: ModelDownloadStage?

  /// How the last download ended. Survives past the run so the tab can show
  /// "Download cancelado." or a failure after the progress row disappears.
  public private(set) var lastOutcome: ModelDownloadOutcome?

  /// True between pressing "Cancelar" and the task actually unwinding.
  ///
  /// Not cosmetic: a cancel that lands during `installing` is not observed until
  /// the current CoreML bundle finishes opening, which is seconds of a control
  /// that would otherwise look ignored.
  public private(set) var isCancelling = false

  public var isRunning: Bool { task != nil }

  /// Fires on the main actor when a download ends, whatever the outcome. The
  /// caller re-reads `ModelStatus` from here — this type deliberately does not
  /// touch the disk itself.
  @ObservationIgnored public var onFinish: (@MainActor (ModelDownloadOutcome) -> Void)?

  @ObservationIgnored private let downloader: any ModelDownloading
  @ObservationIgnored private var task: Task<Void, Never>?

  public init(downloader: any ModelDownloading = FluidAudioModelDownloader()) {
    self.downloader = downloader
  }

  // MARK: - Running

  /// Starts a download, unless one is already running.
  ///
  /// A second press is IGNORED rather than queued or restarted: two concurrent
  /// `AsrModels.download` calls would write the same `.partial` files from two
  /// sockets, and a `.replace` would delete the directory the other one is
  /// filling.
  public func start(_ intent: ModelDownloadIntent) {
    guard task == nil else { return }

    isCancelling = false
    lastOutcome = nil
    stage = .preparing

    let started = Task { [downloader] in
      let report: @Sendable (ModelDownloadStage) -> Void = { [weak self] stage in
        // The handler is called on an unspecified queue (FluidAudio documents
        // exactly that), so every report crosses to the main actor. The tracker
        // has already thinned thousands of byte callbacks down to one per
        // percentage point, and `apply` drops anything that arrives out of order.
        Task { @MainActor [weak self] in self?.apply(stage) }
      }
      do {
        // Awaited DIRECTLY — no intermediate unstructured Task. That is the whole
        // reason cancellation reaches FluidAudio's URLSession task at all.
        try await downloader.download(intent, reportingTo: report)
      } catch {
        await MainActor.run { [weak self] in self?.finish(Self.outcome(for: error)) }
        return
      }
      // Success is only success if nobody asked to stop: the install phase can
      // run to completion after a cancel (see the type comment).
      let outcome: ModelDownloadOutcome = Task.isCancelled ? .cancelled : .completed
      await MainActor.run { [weak self] in self?.finish(outcome) }
    }
    task = started
  }

  /// Requests cancellation. Idempotent, and a no-op when nothing is running.
  public func cancel() {
    guard let task else { return }
    isCancelling = true
    task.cancel()
  }

  // MARK: - Inputs

  /// Applies a progress report, dropping any that does not move the row forward.
  func apply(_ stage: ModelDownloadStage) {
    guard task != nil, stage.supersedes(self.stage) else { return }
    self.stage = stage
  }

  private func finish(_ outcome: ModelDownloadOutcome) {
    task = nil
    stage = nil
    isCancelling = false
    lastOutcome = outcome
    onFinish?(outcome)
  }

  /// Cancellation arrives in three shapes across the FluidAudio call stack;
  /// none of them is a download failure.
  private static func outcome(for error: any Error) -> ModelDownloadOutcome {
    if error is CancellationError { return .cancelled }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
      return .cancelled
    }
    if let error = error as? ModelDownloadError { return .failed(error) }
    return .failed(.failed(reason: nsError.localizedDescription))
  }
}
