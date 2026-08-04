import Foundation
import Observation

/// pt-BR copy for Ajustes › Modelo, in one place.
public enum ModelPaneStrings {
  /// Shown when switching engines could not prepare the new model.
  public static let preparationFailed =
    "Não consegui preparar esse motor. Verifique a conexão e tente de novo."

  /// Heading for the model row.
  ///
  /// Hardcoded to Parakeet ON PURPOSE, and derived from the choice rather than
  /// from a loose string: this row shows Parakeet's directory and its button
  /// runs `AsrModels.download(version: .v3)`, so it manages that engine and no
  /// other. Making it follow the selection would put Cohere's name over
  /// Parakeet's status and a button that re-downloads Parakeet.
  ///
  /// The popover's block is the opposite case and now behaves the opposite way:
  /// it reports the SELECTED engine, so its name is a parameter.
  public static var title: String { "\(TranscriptionEngineChoice.parakeet.displayName) · pt-BR" }
  public static let cancel = "Cancelar"
  public static let preparing = "Preparando o download…"
  /// Shown when the model is already on disk. Says LOADING, not downloading:
  /// picking an engine you already have used to read "Baixando modelo…" and sit
  /// there for 97 s, which is indistinguishable from re-downloading 4,98 GB.
  public static let loading = "Carregando o modelo…"
  public static let installing = "Instalando…"
  public static let cancelling = "Cancelando…"
  /// Said to VoiceOver on the disabled "Cancelar" during `installing`, which is
  /// otherwise an unexplained dead control.
  public static let cancelUnavailable =
    "A instalação não pode ser interrompida; ela termina em alguns segundos."
}

/// pt-BR copy for the engine picker that sits above the model block.
public enum EnginePickerStrings {
  public static let title = "Motor de transcrição"
  /// VoiceOver name and tooltip for the group as a whole.
  public static let help = "Escolher o motor usado nas próximas ditadas"

  /// Under the group when the app can adopt the change without a relaunch.
  public static let appliesNextDictation = "A troca vale a partir da próxima ditada."

  /// Under the group when it cannot. Not a nicer way of saying the same thing:
  /// the app builds its engine once at launch, so if nobody wired a handler,
  /// telling the user "próxima ditada" would be a straight lie.
  public static var appliesNextLaunch: String {
    "A troca vale quando você reabrir o \(MenuBarStrings.brandName)."
  }

  /// Title of the sheet that asks before a switch that costs a download. The
  /// cost itself is the message, so the title stays a question.
  public static let confirmTitle = "Trocar o motor de transcrição?"
  public static let confirmSwitch = "Trocar e baixar"

  /// Shown BEFORE the switch when the target engine's model is not on disk.
  ///
  /// The size is FORMATTED from `ModelLayout.expectedDownloadBytes`, never
  /// written into this string. A hardcoded "4,7 GB" here — a `du -h` reading, so
  /// GiB — sat next to a status line that formats the same directory in decimal
  /// GB and says "4,98 GB". One number, one source.
  ///
  /// When the layout has no measured size the sentence simply omits it, rather
  /// than guessing. That is the case for any engine added before someone
  /// completes a download of it.
  public static func downloadWarning(for name: String, downloadBytes: Int64?) -> String {
    let size = downloadBytes.map { " Ele ocupa cerca de \(Self.format($0))." } ?? ""
    return "O modelo do \(name) ainda não está no seu Mac. Ele é um download "
      + "separado, que só começa depois da troca e pode levar alguns minutos."
      + size
      + " Depois disso ele fica salvo aqui e o ditado volta a funcionar offline."
  }

  /// The same formatter `ModelStatus.formattedSize` uses, so a size quoted
  /// before the download and the size shown after it agree.
  static func format(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }

  /// The status line of one engine row — whether ITS OWN model is on disk.
  ///
  /// The size is whatever was MEASURED in that engine's directory, never a
  /// number from a doc and never the other engine's. When there is nothing to
  /// measure it says so instead of printing a size it does not have.
  public static func statusLine(for status: ModelStatus) -> String {
    switch status.readiness {
    case .ready:
      guard let size = status.formattedSize else { return "Modelo pronto" }
      return "Modelo pronto · \(size) em disco"
    case .incomplete:
      guard let size = status.formattedSize else { return "Download incompleto" }
      return "Download incompleto · \(size) em disco"
    case .notDownloaded:
      return "Modelo ainda não baixado"
    }
  }
}

/// One row of the engine picker.
///
/// `status` is read from `choice.modelLayout` and from nowhere else. That is the
/// whole defence against the defect this tab already had once, in reverse: a row
/// that reported "pronto" from the Parakeet directory while the engine it named
/// had never been downloaded.
public struct EngineOption: Sendable, Equatable, Identifiable {

  public let choice: TranscriptionEngineChoice

  /// Readiness of THIS engine's model directory.
  public let status: ModelStatus

  public let isSelected: Bool

  public init(choice: TranscriptionEngineChoice, status: ModelStatus, isSelected: Bool) {
    self.choice = choice
    self.status = status
    self.isSelected = isSelected
  }

  public var id: TranscriptionEngineChoice { choice }
  public var title: String { choice.displayName }
  public var summary: String { choice.summary }
  public var statusLine: String { EnginePickerStrings.statusLine(for: status) }

  /// True only when this engine could transcribe right now. Everything that
  /// warns about a download reads this, never `choice`.
  public var isModelReady: Bool { status.isPresent }

  public var symbol: String {
    switch status.readiness {
    case .ready: return FalaSymbol.processor
    case .incomplete: return FalaSymbol.warning
    case .notDownloaded: return FalaSymbol.download
    }
  }

  /// Which of the six states tints the status line. Same mapping as the model
  /// block's: amber for "unusable but recoverable", neutral for "not here yet".
  public var stateKind: StateKind {
    switch status.readiness {
    case .ready: return .success
    case .incomplete: return .warning
    case .notDownloaded: return .idle
    }
  }
}

/// The engine picker, as one value (SPEC.md FR-5's seam, made visible).
public struct EnginePicker: Sendable, Equatable {

  /// Always every case of `TranscriptionEngineChoice`, in declaration order —
  /// the default first.
  public let options: [EngineOption]

  /// Whether a change reaches the RUNNING app, or only the next launch.
  ///
  /// Not cosmetic and not a guess: the presenter sets it from whether anyone
  /// wired `onEngineChanged`, so the caption cannot claim an immediacy that
  /// nothing in the app delivers.
  public let appliesImmediately: Bool

  public init(options: [EngineOption], appliesImmediately: Bool) {
    self.options = options
    self.appliesImmediately = appliesImmediately
  }

  public var title: String { EnginePickerStrings.title }
  public var help: String { EnginePickerStrings.help }

  public var selected: TranscriptionEngineChoice? {
    options.first(where: \.isSelected)?.choice
  }

  public var caption: String {
    appliesImmediately
      ? EnginePickerStrings.appliesNextDictation
      : EnginePickerStrings.appliesNextLaunch
  }

  /// The pt-BR sentence to show BEFORE switching, or `nil` when the switch costs
  /// nothing.
  ///
  /// Driven by what is on disk, not by which engine it is: switching back to
  /// Parakeet on a machine whose Parakeet model was deleted also downloads, and
  /// saying nothing there would be the same omission.
  public func downloadWarning(for choice: TranscriptionEngineChoice) -> String? {
    guard let option = options.first(where: { $0.choice == choice }) else { return nil }
    guard !option.isModelReady else { return nil }
    return EnginePickerStrings.downloadWarning(
      for: option.title, downloadBytes: choice.modelLayout.expectedDownloadBytes)
  }

  /// Sheet title, then the button that goes through with it.
  public var confirmationTitle: String { EnginePickerStrings.confirmTitle }
  public var confirmTitle: String { EnginePickerStrings.confirmSwitch }
  public var cancelTitle: String { SettingsStrings.cancel }
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

  public var isActionEnabled: Bool { !isBusy && !hasInsufficientSpace }

  // MARK: - The in-progress row

  /// Any stage is running — a transfer OR a load. Drives whether the in-progress
  /// row is on screen at all.
  public var isBusy: Bool { stage != nil }

  /// Bytes are actually moving. NARROWER than `isBusy` on purpose: `.loading` is
  /// a CoreML open plus, for Cohere, a 97 s ANE warm-up, with nothing being
  /// fetched. Anything that says "download" to the user must ask this one.
  public var isDownloading: Bool {
    guard let stage else { return false }
    return stage != .loading
  }

  /// The glyph beside the in-progress row.
  ///
  /// A pulsing download arrow was drawn for EVERY stage, so switching to a model
  /// already on disk showed "Carregando o modelo…" next to a downloading icon —
  /// and the icon won. Reported twice as "fica marcando baixando".
  public var progressSymbol: String {
    isDownloading ? FalaSymbol.download : FalaSymbol.processor
  }

  /// Whether "Cancelar" is offered at all.
  ///
  /// A load has nothing to cancel, and a permanently disabled "Cancelar" beside
  /// a moving progress bar reads as a transfer the user is not allowed to stop.
  public var isCancelOffered: Bool { isDownloading }

  /// "Baixando novamente… 41%" — the mockup's line, with the verb matching the
  /// button that started it, plus the two stages the mockup does not draw and
  /// that a real download spends real time in.
  public var downloadTitle: String? {
    guard let stage else { return nil }
    if isCancelling { return ModelPaneStrings.cancelling }
    switch stage {
    case .loading:
      return ModelPaneStrings.loading
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
    // Only for a real transfer; a load never offers the control at all.
    return ModelPaneStrings.cancelUnavailable
  }

  /// "Download cancelado." or a failure message, once the row is gone.
  public var outcomeMessage: String? {
    isBusy ? nil : outcome?.message
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
      // The engine switch wins: it is the download the user just triggered.
      stage: enginePreparation ?? downloads.stage,
      isCancelling: enginePreparation == nil && downloads.isCancelling,
      outcome: enginePreparationFailure.map { .failed(.failed(reason: $0)) }
        ?? downloads.lastOutcome)
  }

  /// The engine picker. Reads `preferences.engine` (observable) and the cached
  /// per-engine statuses, so selecting a row re-renders both rows.
  public var engines: EnginePicker {
    EnginePicker(
      options: TranscriptionEngineChoice.allCases.map { choice in
        EngineOption(
          choice: choice,
          status: engineStatus[choice] ?? Self.absent(choice),
          isSelected: choice == preferences.engine)
      },
      appliesImmediately: onEngineChanged != nil)
  }

  /// The engine-switch download, kept apart from `downloads` (which drives the
  /// Parakeet-only "Baixar novamente" button). Same bar, different trigger: this
  /// one starts because the user picked an engine, not because they pressed a
  /// button.
  /// OBSERVED, deliberately. Marking these `@ObservationIgnored` — as the rest of
  /// this type's injected collaborators are — froze the tab on the first state it
  /// rendered: the user saw "preparando" forever while the download ran fine
  /// underneath, because SwiftUI was never told anything had changed.
  public private(set) var enginePreparation: ModelDownloadStage?
  public private(set) var enginePreparationFailure: String?

  public let downloads: ModelDownloadController

  /// Where the engine choice survives a relaunch. MUST be the app's shared
  /// instance — see the initialiser.
  public let preferences: Preferences

  /// Called when the user picks a different engine, so a running app can rebuild
  /// its pipeline around it.
  ///
  /// Wiring it is what makes `EnginePicker.caption` say "a partir da próxima
  /// ditada"; leaving it nil makes the same caption say "quando você reabrir",
  /// which is the truth in an app that only reads the preference at launch.
  /// Either is honest — silently claiming the first while doing the second is
  /// not, which is why this is a callback and not a Bool.
  @ObservationIgnored public var onEngineChanged: ((TranscriptionEngineChoice) -> Void)?

  private var status: ModelStatus
  private var capacity: VolumeCapacity?
  private var engineStatus: [TranscriptionEngineChoice: ModelStatus] = [:]

  @ObservationIgnored private let modelStatus: @Sendable () -> ModelStatus
  @ObservationIgnored private let engineStatusReader:
    @Sendable (TranscriptionEngineChoice) -> ModelStatus
  @ObservationIgnored private let capacityReader: any VolumeCapacityReading

  /// - Parameter preferences: the app's SHARED instance. The default builds a
  ///   fresh one so this type stays constructible on its own (and testable), but
  ///   two `Preferences` objects each hold their own copy of every value and
  ///   only agree by accident — the same trap `SettingsWindowBuilder` already
  ///   documents for the hotkey.
  public init(
    downloads: ModelDownloadController = ModelDownloadController(),
    preferences: Preferences = Preferences(),
    modelStatus: @escaping @Sendable () -> ModelStatus = { ModelStatus.current() },
    engineStatus: @escaping @Sendable (TranscriptionEngineChoice) -> ModelStatus = {
      ModelStatus.current($0.modelLayout)
    },
    capacityReader: any VolumeCapacityReading = FileSystemVolumeCapacityReader()
  ) {
    self.downloads = downloads
    self.preferences = preferences
    self.modelStatus = modelStatus
    self.engineStatusReader = engineStatus
    self.capacityReader = capacityReader
    self.status = modelStatus()
    self.capacity = capacityReader.capacity(at: ModelStatus.defaultLocation)
    self.engineStatus = Self.readEngineStatus(using: engineStatus)

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
    engineStatus = Self.readEngineStatus(using: engineStatusReader)
  }

  /// Walks every engine's own directory, once, off the view body — each call is
  /// a full integrity check of a model directory.
  private static func readEngineStatus(
    using read: @Sendable (TranscriptionEngineChoice) -> ModelStatus
  ) -> [TranscriptionEngineChoice: ModelStatus] {
    Dictionary(uniqueKeysWithValues: TranscriptionEngineChoice.allCases.map { ($0, read($0)) })
  }

  /// Stand-in for a status that was never read. It reports NOT DOWNLOADED at the
  /// engine's real location rather than `.ready`: an engine nobody has checked
  /// must never render as usable.
  private static func absent(_ choice: TranscriptionEngineChoice) -> ModelStatus {
    ModelStatus(
      readiness: .notDownloaded, sizeBytes: nil, location: choice.modelLayout.location)
  }

  /// Persists the user's engine choice and tells the app about it.
  ///
  /// The view is expected to have shown `EnginePicker.downloadWarning(for:)`
  /// first when it is non-nil; this does not enforce that, because a caller that
  /// legitimately knows better (a CLI flag, a test) should not have to fake a
  /// dialog. What it does enforce is that re-selecting the current engine writes
  /// nothing and notifies nobody.
  public func selectEngine(_ choice: TranscriptionEngineChoice) {
    guard choice != preferences.engine else { return }
    preferences.setEngine(choice)
    // Show the bar IMMEDIATELY when the chosen model is not on disk. The first
    // real progress report only arrives after HuggingFace answers, which is
    // seconds — and the user had just clicked and seen nothing happen at all.
    //
    // Read through `engineStatus`, the same map the rows render from, NOT
    // `ModelStatus.current(...)`. Going straight to the filesystem here made the
    // decision disagree with what the tab was displaying, and made the test for
    // this line pass or fail according to whether the developer's own
    // `~/Library/Application Support` happened to hold a 4,7 GB Cohere cache.
    // `.preparing` when there are bytes to fetch, `.loading` when there are not.
    // Both need SOME immediate feedback — the click has to do something visible —
    // but showing a download for a model that is already on disk is what made
    // switching to an installed engine look like a second 4,98 GB transfer.
    // Read FRESH through the same reader the rows are built from, not from the
    // cached map. The cache is refreshed when the window opens, but a model
    // downloaded since then would leave it saying "not there" — and the popover
    // decides this from a fresh disk read, so the two surfaces would disagree
    // about whether the very same click is a download.
    enginePreparation = engineStatusReader(choice).isPresent ? .loading : .preparing
    enginePreparationFailure = nil
    onEngineChanged?(choice)
  }

  /// Progress of the SELECTED engine's preparation, pushed by the pipeline.
  ///
  /// Separate from `downloads`, which drives the Parakeet-only "Baixar
  /// novamente" button: this is the download that starts because the user
  /// switched engines, and it has no button of its own to hang off.
  public func reportEnginePreparation(_ stage: ModelDownloadStage) {
    // Dropped unless a preparation is actually on screen. Every report crosses
    // to the main actor in its own unstructured Task, so one spawned just
    // before `prepare()` returned can land AFTER `finishEnginePreparation` —
    // and re-showing the stage then leaves "Carregando o modelo…" on screen
    // forever, because the finish that would clear it has already run.
    // `ModelDownloadController.apply` has guarded against exactly this
    // (`task != nil`) since it was written; this path lacked it.
    guard enginePreparation != nil else { return }
    enginePreparation = stage
  }

  /// Preparation ended. `error` nil means it worked.
  public func finishEnginePreparation(error: String?) {
    enginePreparation = nil
    enginePreparationFailure = error
    refresh()
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
