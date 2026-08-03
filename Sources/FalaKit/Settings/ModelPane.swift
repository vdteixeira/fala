import Foundation
import Observation

/// pt-BR copy for Ajustes › Modelo, in one place.
public enum ModelPaneStrings {
  /// The mockup's heading for the model row. `ModelBlock.modelName` is reused so
  /// the popover and the settings tab cannot drift on the product name.
  public static var title: String { "\(ModelBlock.modelName) v3 · pt-BR" }
  public static let cancel = "Cancelar"
  public static let preparing = "Preparando o download…"
  public static let installing = "Instalando…"
  public static let cancelling = "Cancelando…"
  /// Said to VoiceOver on the disabled "Cancelar" during `installing`, which is
  /// otherwise an unexplained dead control.
  public static let cancelUnavailable =
    "A instalação não pode ser interrompida; ela termina em alguns segundos."
}

/// Everything Ajustes › Modelo renders, as one value.
///
/// Pure, like `MenuBarPresenter`'s blocks: the tab's SwiftUI view holds no
/// decisions, so every line of copy below is assertable without a window.
///
/// ## Why there is no "verificado hoje"
///
/// The mockup's caption reads "1,1 GB em disco · verificado hoje". Both halves
/// are replaced here, for different reasons.
///
/// **"1,1 GB" is wrong.** That is the upstream repository size across every
/// precision variant; a real int8 v3 download measures 483,256,769 bytes on this
/// machine. The tab reports `ModelStatus.formattedSize` — what is actually on
/// this disk — and `ModelStatus.expectedDownloadBytes` for what a download will
/// fetch.
///
/// **"verificado hoje" is a timestamp that would mean nothing.** It implies a
/// stored last-verified date, and storing one was considered and rejected:
/// `ModelStatus.current(at:)` re-runs the FULL integrity check on every read —
/// nine required files, each required to exist and be non-empty, plus a total-size
/// floor — and it is cheap enough to run every time the tab appears. A persisted
/// date could only ever be older than the check that just ran, and it would go
/// actively false the moment a file was deleted after the stamp was written:
/// "verificado hoje" printed over a model that broke an hour ago is the same
/// class of lie as the "pronto · Zero KB" that `ModelReadiness` exists to
/// prevent. So the caption states WHAT was verified rather than WHEN — the size
/// on disk and the readiness the check just established.
public struct ModelPane: Sendable, Equatable {

  public let status: ModelStatus

  /// `nil` when the volume could not be read; the free-space line is then hidden
  /// rather than guessed at.
  public let capacity: VolumeCapacity?

  /// `nil` when no download is running.
  public let stage: ModelDownloadStage?

  public let isCancelling: Bool

  /// How the last download ended, so a cancel or a failure has somewhere to
  /// surface after the progress row is gone.
  public let outcome: ModelDownloadOutcome?

  public init(
    status: ModelStatus,
    capacity: VolumeCapacity?,
    stage: ModelDownloadStage? = nil,
    isCancelling: Bool = false,
    outcome: ModelDownloadOutcome? = nil
  ) {
    self.status = status
    self.capacity = capacity
    self.stage = stage
    self.isCancelling = isCancelling
    self.outcome = outcome
  }

  // MARK: - The model row

  public var title: String { ModelPaneStrings.title }

  /// The caption that replaces "1,1 GB em disco · verificado hoje" — see the
  /// type comment for why both halves changed.
  public var subtitle: String {
    switch status.readiness {
    case .ready:
      let size = status.formattedSize ?? ModelStatus.formattedExpectedDownload
      return "\(size) em disco · pronto para usar"
    case .incomplete:
      guard let size = status.formattedSize else { return "Download incompleto" }
      return "\(size) em disco · download incompleto"
    case .notDownloaded:
      return "Não baixado · \(ModelStatus.formattedExpectedDownload) para baixar"
    }
  }

  /// The longer pt-BR explanation, shown only when it says something the caption
  /// does not.
  ///
  /// `ModelStatus.problemMessage` is reused rather than restated, but only for
  /// the incomplete case, where it names the missing files and the path to
  /// delete. For `.notDownloaded` it repeats what `subtitle` already says, and
  /// two lines saying "não baixado" is noise.
  public var problemDetail: String? {
    status.isIncomplete ? status.problemMessage : nil
  }

  public var symbol: String {
    switch status.readiness {
    case .ready: return FalaSymbol.processor
    case .incomplete: return FalaSymbol.warning
    case .notDownloaded: return FalaSymbol.download
    }
  }

  /// Which of the six states tints the row. The view resolves the color through
  /// `theme.style(for:)`; no color is named here.
  ///
  /// `incomplete` is `warning`, not `error`: the model is unusable but the fix is
  /// one button away, which is exactly the "degraded but recoverable" the shared
  /// vocabulary reserves amber for.
  public var stateKind: StateKind {
    switch status.readiness {
    case .ready: return .success
    case .incomplete: return .warning
    case .notDownloaded: return .idle
    }
  }

  // MARK: - The action button

  /// `.replace` only when there is a working model to replace. Anything else
  /// wants `.repair`, which resumes rather than deleting first.
  public var intent: ModelDownloadIntent {
    status.isPresent ? .replace : .repair
  }

  /// "Baixar novamente" / "Baixar modelo".
  public var actionTitle: String { intent.actionTitle }

  /// pt-BR confirmation to show before starting, `nil` when none is needed.
  /// Non-nil only for `.replace`, which deletes the working model first.
  public var confirmationMessage: String? { intent.confirmationMessage }

  public var isActionEnabled: Bool { !isDownloading && !hasInsufficientSpace }

  // MARK: - The in-progress row

  public var isDownloading: Bool { stage != nil }

  /// "Baixando novamente… 41%" — the mockup's line, with the verb matching the
  /// button that started it, plus the two stages the mockup does not draw and
  /// that a real download spends real time in.
  public var downloadTitle: String? {
    guard let stage else { return nil }
    if isCancelling { return ModelPaneStrings.cancelling }
    switch stage {
    case .preparing:
      return ModelPaneStrings.preparing
    case .transferring(let progress):
      let verb = intent == .replace ? "Baixando novamente" : "Baixando modelo"
      return progress.isDeterminate ? "\(verb)… \(progress.percent)%" : "\(verb)…"
    case .installing:
      return ModelPaneStrings.installing
    }
  }

  /// 0...1, or `nil` when the bar must be indeterminate (preparing, installing,
  /// or a transfer whose size is not known yet).
  public var progressFraction: Double? {
    guard case .transferring(let progress) = stage, progress.isDeterminate else { return nil }
    return progress.fraction
  }

  /// "241 MB de 483 MB", empty when there is nothing honest to put there.
  ///
  /// An ESTIMATE: FluidAudio's progress handler reports a fraction and no byte
  /// counts, so this is that fraction applied to the measured download size. See
  /// `ModelDownloadStageTracker`.
  public var downloadDetail: String {
    stage?.progress.detail ?? ""
  }

  public var cancelTitle: String { ModelPaneStrings.cancel }

  /// False during `installing`, which cannot be interrupted. The control stays
  /// visible and disabled rather than disappearing under the pointer.
  public var isCancelEnabled: Bool {
    guard let stage, !isCancelling else { return false }
    return stage.isCancellable
  }

  /// What VoiceOver is told when "Cancelar" is disabled mid-run — the dimming
  /// alone is invisible to it.
  public var cancelUnavailableHint: String? {
    guard isDownloading, !isCancelEnabled, !isCancelling else { return nil }
    return ModelPaneStrings.cancelUnavailable
  }

  /// "Download cancelado." or a failure message, once the row is gone.
  public var outcomeMessage: String? {
    isDownloading ? nil : outcome?.message
  }

  // MARK: - The free-space line

  /// "182 GB livres em Macintosh HD", or `nil` when the volume could not be read.
  public var diskLine: String? { capacity?.freeLine }

  public var diskSymbol: String { FalaSymbol.disk }

  /// pt-BR warning when the model does not fit on the volume it would land on.
  public var insufficientSpaceWarning: String? {
    capacity?.insufficientSpaceWarning(for: ModelStatus.expectedDownloadBytes)
  }

  public var hasInsufficientSpace: Bool { insufficientSpaceWarning != nil }
}

/// Assembles `ModelPane` from the live sources, so the tab's view holds nothing.
///
/// The disk is read in `refresh()` and NOWHERE ELSE. `pane` is computed from
/// cached values plus the download controller's observable state, so a progress
/// tick re-renders the row without walking the model directory again — which it
/// would do sixty times a second if `ModelStatus.current()` sat in the view body.
@MainActor
@Observable
public final class ModelPanePresenter {

  /// Everything Ajustes › Modelo renders. Recomputed on access; reading
  /// `downloads`' observable state here is what makes the progress bar move.
  public var pane: ModelPane {
    ModelPane(
      status: status,
      capacity: capacity,
      stage: downloads.stage,
      isCancelling: downloads.isCancelling,
      outcome: downloads.lastOutcome)
  }

  public let downloads: ModelDownloadController

  private var status: ModelStatus
  private var capacity: VolumeCapacity?

  @ObservationIgnored private let modelStatus: @Sendable () -> ModelStatus
  @ObservationIgnored private let capacityReader: any VolumeCapacityReading

  public init(
    downloads: ModelDownloadController = ModelDownloadController(),
    modelStatus: @escaping @Sendable () -> ModelStatus = { ModelStatus.current() },
    capacityReader: any VolumeCapacityReading = FileSystemVolumeCapacityReader()
  ) {
    self.downloads = downloads
    self.modelStatus = modelStatus
    self.capacityReader = capacityReader
    self.status = modelStatus()
    self.capacity = capacityReader.capacity(at: ModelStatus.defaultLocation)

    // A finished download changes both readings — a `.replace` that failed
    // half-way is the case that matters, since the tab would otherwise keep
    // showing the size of a model that no longer exists.
    //
    // CHAINED, not assigned: the same controller is expected to be shared with
    // the menu bar, whose presenter also needs to know a download ended
    // (`MenuBarPresenter.clearModelDownload()`). Overwriting the handler here
    // would silently leave the popover showing a download that finished minutes
    // ago, and nothing would fail to compile.
    let existing = downloads.onFinish
    downloads.onFinish = { [weak self] outcome in
      existing?(outcome)
      self?.refresh()
    }
  }

  /// Re-reads the model directory and the volume. Call it when the tab appears,
  /// not from a view body: `ModelStatus.current()` enumerates the whole model
  /// directory.
  public func refresh() {
    status = modelStatus()
    capacity = capacityReader.capacity(at: ModelStatus.defaultLocation)
  }

  /// Starts whichever download the current state calls for. Ignored when the
  /// button is not offered — the guard lives here so the view cannot start a
  /// `.replace` on a volume that has no room for it.
  public func startDownload() {
    let pane = pane
    guard pane.isActionEnabled else { return }
    downloads.start(pane.intent)
  }

  public func cancelDownload() {
    downloads.cancel()
  }
}
