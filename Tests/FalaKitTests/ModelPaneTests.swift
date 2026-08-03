import Foundation
import Testing

@testable import FalaKit

/// Ajustes › Modelo (settings-window.dc.html, MODELO section).
///
/// The tab's whole job is to state measured reality, and the mockup's caption
/// states two things that are not: a size taken from the upstream repository and
/// a "verificado hoje" implying a stored date. Both corrections are pinned here.
@Suite("ModelPane")
struct ModelPaneTests {

  private static let location = URL(fileURLWithPath: "/tmp/fala-model-pane")

  private static func pane(
    readiness: ModelReadiness,
    sizeBytes: Int64?,
    capacity: VolumeCapacity? = VolumeCapacity(
      availableBytes: 182_000_000_000, volumeName: "Macintosh HD"),
    stage: ModelDownloadStage? = nil,
    isCancelling: Bool = false,
    outcome: ModelDownloadOutcome? = nil
  ) -> ModelPane {
    ModelPane(
      status: ModelStatus(readiness: readiness, sizeBytes: sizeBytes, location: location),
      capacity: capacity,
      stage: stage,
      isCancelling: isCancelling,
      outcome: outcome)
  }

  // MARK: - The heading

  @Test("The heading is the mockup's, and shares the popover's product name")
  func headingMatchesTheMockup() {
    #expect(Self.pane(readiness: .ready, sizeBytes: 483_256_769).title == "Parakeet v3 · pt-BR")
    #expect(ModelPaneStrings.title.hasPrefix(ModelBlock.modelName))
  }

  // MARK: - The caption that replaces "1,1 GB em disco · verificado hoje"

  /// THE correction. The mockup's "1,1 GB" is the upstream repository size across
  /// every precision variant; what lands on this disk is roughly 483 MB, and the
  /// tab reports what `ModelStatus` measured rather than what a doc quoted.
  @Test("The caption reports the size measured on disk, never the quoted 1,1 GB")
  func captionReportsTheMeasuredSize() {
    let pane = Self.pane(readiness: .ready, sizeBytes: 483_256_769)
    #expect(pane.subtitle.contains("483"))
    #expect(!pane.subtitle.contains("1,1 GB"))
    #expect(pane.subtitle.hasSuffix("em disco · pronto para usar"))
  }

  /// THE other correction. "verificado hoje" implies a stored last-verified date.
  /// None is stored, because `ModelStatus.current(at:)` re-runs the full
  /// integrity check on every read: a persisted stamp could only ever be older
  /// than the check that just ran, and it would go actively false the moment a
  /// file was deleted after it was written.
  @Test("Nothing in the caption claims a time")
  func captionMakesNoTimeClaim() {
    for pane in [
      Self.pane(readiness: .ready, sizeBytes: 483_256_769),
      Self.pane(readiness: .incomplete(missing: ["Encoder.mlmodelc"]), sizeBytes: 240_000_000),
      Self.pane(readiness: .notDownloaded, sizeBytes: nil),
    ] {
      for word in ["hoje", "ontem", "agora", "há ", "verificado em"] {
        #expect(!pane.subtitle.contains(word), "caption claims a time: \(pane.subtitle)")
      }
    }
  }

  @Test("A partial download says so, with the bytes it really has")
  func incompleteCaptionStatesWhatIsThere() {
    let pane = Self.pane(
      readiness: .incomplete(missing: ["Encoder.mlmodelc/weights/weight.bin"]),
      sizeBytes: 240_000_000)
    #expect(pane.subtitle == "240 MB em disco · download incompleto")
  }

  @Test("Nothing on disk says what a download will fetch")
  func notDownloadedCaptionStatesTheDownloadSize() {
    let pane = Self.pane(readiness: .notDownloaded, sizeBytes: nil)
    #expect(pane.subtitle.hasPrefix("Não baixado · "))
    #expect(pane.subtitle.contains(ModelStatus.formattedExpectedDownload))
  }

  @Test("An unreadable size does not render an empty caption")
  func incompleteWithoutASizeStillReads() {
    let pane = Self.pane(readiness: .incomplete(missing: []), sizeBytes: nil)
    #expect(pane.subtitle == "Download incompleto")
  }

  // MARK: - The detail line

  /// `ModelStatus.problemMessage` names the missing files and the path to delete
  /// — information the caption does not carry. For `.notDownloaded` it repeats
  /// the caption, and two lines saying "não baixado" is noise.
  @Test("The long explanation appears only where it adds something")
  func problemDetailOnlyForIncomplete() {
    let incomplete = Self.pane(
      readiness: .incomplete(missing: ["Decoder.mlmodelc/coremldata.bin"]),
      sizeBytes: 240_000_000)
    #expect(incomplete.problemDetail?.contains("Decoder.mlmodelc/coremldata.bin") == true)
    #expect(Self.pane(readiness: .ready, sizeBytes: 483_256_769).problemDetail == nil)
    #expect(Self.pane(readiness: .notDownloaded, sizeBytes: nil).problemDetail == nil)
  }

  // MARK: - Icon and tint

  @Test("Each readiness picks its own symbol and state")
  func symbolAndStateFollowReadiness() {
    let ready = Self.pane(readiness: .ready, sizeBytes: 483_256_769)
    #expect(ready.symbol == FalaSymbol.processor)
    #expect(ready.stateKind == .success)

    let partial = Self.pane(readiness: .incomplete(missing: ["x"]), sizeBytes: 1)
    #expect(partial.symbol == FalaSymbol.warning)
    // Amber, not red: unusable but one button from fixed.
    #expect(partial.stateKind == .warning)

    let absent = Self.pane(readiness: .notDownloaded, sizeBytes: nil)
    #expect(absent.symbol == FalaSymbol.download)
    #expect(absent.stateKind == .idle)
  }

  // MARK: - The action button

  /// `.replace` deletes the model before fetching, so it may only be offered when
  /// there is a working model to replace. Anything else resumes instead.
  @Test("Only a working model offers the destructive re-download")
  func intentDependsOnWhatIsOnDisk() {
    #expect(Self.pane(readiness: .ready, sizeBytes: 483_256_769).intent == .replace)
    #expect(Self.pane(readiness: .notDownloaded, sizeBytes: nil).intent == .repair)
    #expect(Self.pane(readiness: .incomplete(missing: ["x"]), sizeBytes: 1).intent == .repair)
  }

  @Test("The destructive re-download carries a confirmation; the repair does not")
  func confirmationFollowsTheIntent() {
    #expect(Self.pane(readiness: .ready, sizeBytes: 1).confirmationMessage != nil)
    #expect(Self.pane(readiness: .notDownloaded, sizeBytes: nil).confirmationMessage == nil)
  }

  @Test("The button reads as the mockup writes it")
  func buttonTitleMatchesTheMockup() {
    #expect(Self.pane(readiness: .ready, sizeBytes: 1).actionTitle == "Baixar novamente")
  }

  @Test("The button is dead while a download runs and while the disk is too full")
  func actionIsGatedOnStateAndSpace() {
    #expect(Self.pane(readiness: .ready, sizeBytes: 1).isActionEnabled)
    #expect(!Self.pane(readiness: .ready, sizeBytes: 1, stage: .preparing).isActionEnabled)
    #expect(
      !Self.pane(
        readiness: .notDownloaded, sizeBytes: nil,
        capacity: VolumeCapacity(availableBytes: 1_000, volumeName: "Macintosh HD")
      ).isActionEnabled)
  }

  // MARK: - The in-progress row

  @Test("The progress line reads as the mockup writes it")
  func progressLineMatchesTheMockup() {
    let pane = Self.pane(
      readiness: .ready, sizeBytes: 483_256_769,
      stage: .transferring(ModelDownloadProgress(receivedBytes: 41, totalBytes: 100)))
    #expect(pane.downloadTitle == "Baixando novamente… 41%")
    #expect(pane.progressFraction == 0.41)
    #expect(pane.isDownloading)
  }

  @Test("A first download says 'Baixando modelo', not 'novamente'")
  func firstDownloadUsesItsOwnVerb() {
    let pane = Self.pane(
      readiness: .notDownloaded, sizeBytes: nil,
      stage: .transferring(ModelDownloadProgress(receivedBytes: 10, totalBytes: 100)))
    #expect(pane.downloadTitle == "Baixando modelo… 10%")
  }

  /// The two stages the mockup does not draw, and that a real download spends
  /// real time in: listing the repository before any byte moves, and opening the
  /// compiled bundles after the last one.
  @Test("Preparing and installing are named rather than faked as 0%")
  func undrawnStagesAreNamed() {
    let preparing = Self.pane(readiness: .notDownloaded, sizeBytes: nil, stage: .preparing)
    #expect(preparing.downloadTitle == "Preparando o download…")
    #expect(preparing.progressFraction == nil)

    let installing = Self.pane(readiness: .notDownloaded, sizeBytes: nil, stage: .installing)
    #expect(installing.downloadTitle == "Instalando…")
    #expect(installing.progressFraction == nil)
  }

  @Test("Nothing running means no progress row at all")
  func idlePaneHasNoProgressRow() {
    let pane = Self.pane(readiness: .ready, sizeBytes: 483_256_769)
    #expect(!pane.isDownloading)
    #expect(pane.downloadTitle == nil)
    #expect(pane.progressFraction == nil)
    #expect(pane.downloadDetail.isEmpty)
  }

  /// The bytes are an estimate — FluidAudio's progress handler reports a
  /// fraction and no byte counts — but the denominator is the measured download,
  /// never the quoted 1,1 GB.
  @Test("The MB detail counts against the measured download size")
  func detailUsesTheMeasuredDenominator() {
    let stage = ModelDownloadStageTracker(expectedBytes: ModelStatus.expectedDownloadBytes)
      .stage(fraction: 0.25, phase: .downloading)
    let pane = Self.pane(readiness: .notDownloaded, sizeBytes: nil, stage: stage)
    #expect(pane.downloadDetail.contains(" de "))
    #expect(pane.downloadDetail.contains("483"))
  }

  // MARK: - Cancelling

  @Test("Cancelar is live during a transfer")
  func cancelIsLiveWhileTransferring() {
    let pane = Self.pane(
      readiness: .ready, sizeBytes: 1,
      stage: .transferring(ModelDownloadProgress(receivedBytes: 1, totalBytes: 100)))
    #expect(pane.cancelTitle == "Cancelar")
    #expect(pane.isCancelEnabled)
    #expect(pane.cancelUnavailableHint == nil)
  }

  /// FluidAudio's compile loop has no cancellation check and
  /// `MLModel(contentsOf:)` is synchronous, so the control is disabled rather
  /// than allowed to look ignored — and VoiceOver is told why, since the dimming
  /// alone is invisible to it.
  @Test("Cancelar goes dead during install, and says why")
  func cancelIsDisabledWhileInstalling() {
    let pane = Self.pane(readiness: .ready, sizeBytes: 1, stage: .installing)
    #expect(!pane.isCancelEnabled)
    #expect(pane.cancelUnavailableHint == ModelPaneStrings.cancelUnavailable)
  }

  @Test("A cancel already in flight reports itself instead of offering again")
  func cancellingStateIsVisible() {
    let pane = Self.pane(
      readiness: .ready, sizeBytes: 1,
      stage: .transferring(.unknown), isCancelling: true)
    #expect(pane.downloadTitle == "Cancelando…")
    #expect(!pane.isCancelEnabled)
    #expect(pane.cancelUnavailableHint == nil)
  }

  @Test("Nothing running means nothing to cancel")
  func idlePaneCannotCancel() {
    #expect(!Self.pane(readiness: .ready, sizeBytes: 1).isCancelEnabled)
  }

  // MARK: - Outcome

  @Test("A finished cancel is reported as a cancel, not as an error")
  func cancelledOutcomeSurfaces() {
    let pane = Self.pane(readiness: .ready, sizeBytes: 1, outcome: .cancelled)
    #expect(pane.outcomeMessage == "Download cancelado.")
  }

  @Test("A successful download leaves no message behind")
  func completedOutcomeIsSilent() {
    #expect(Self.pane(readiness: .ready, sizeBytes: 1, outcome: .completed).outcomeMessage == nil)
  }

  @Test("A new download hides the previous outcome")
  func outcomeIsHiddenWhileRunning() {
    let pane = Self.pane(
      readiness: .ready, sizeBytes: 1, stage: .preparing, outcome: .cancelled)
    #expect(pane.outcomeMessage == nil)
  }

  // MARK: - The free-space line

  @Test("The free-space line reads as the mockup writes it")
  func diskLineMatchesTheMockup() {
    let pane = Self.pane(readiness: .ready, sizeBytes: 483_256_769)
    #expect(pane.diskLine == "182 GB livres em Macintosh HD")
    #expect(pane.diskSymbol == FalaSymbol.disk)
    #expect(pane.insufficientSpaceWarning == nil)
  }

  @Test("A volume that cannot be read hides the line rather than guessing")
  func unreadableVolumeHidesTheLine() {
    let pane = Self.pane(readiness: .ready, sizeBytes: 1, capacity: nil)
    #expect(pane.diskLine == nil)
    #expect(pane.insufficientSpaceWarning == nil)
    // A volume nobody could measure must not block the button either.
    #expect(pane.isActionEnabled)
  }

  @Test("A volume too small to hold the model warns before the button is pressed")
  func fullVolumeWarns() throws {
    let pane = Self.pane(
      readiness: .notDownloaded, sizeBytes: nil,
      capacity: VolumeCapacity(availableBytes: 120_000_000, volumeName: "Macintosh HD"))
    let warning = try #require(pane.insufficientSpaceWarning)
    #expect(warning.contains("120 MB"))
    #expect(pane.hasInsufficientSpace)
  }

  /// The size the mockup quotes would fail this check on a volume where the real
  /// download fits comfortably.
  @Test("600 MB free is enough for the real model and not for the quoted one")
  func theQuotedSizeWouldRefuseAValidDownload() {
    let pane = Self.pane(
      readiness: .notDownloaded, sizeBytes: nil,
      capacity: VolumeCapacity(availableBytes: 600_000_000, volumeName: "Macintosh HD"))
    #expect(!pane.hasInsufficientSpace)
    #expect(pane.isActionEnabled)
  }
}

@MainActor
@Suite("ModelPanePresenter")
struct ModelPanePresenterTests {

  private static let location = URL(fileURLWithPath: "/tmp/fala-model-pane")
  private static let full = VolumeCapacity(
    availableBytes: 182_000_000_000, volumeName: "Macintosh HD")

  private static func presenter(
    _ status: ModelStatus,
    capacity: VolumeCapacity? = full,
    downloads: ModelDownloadController = ModelDownloadController(
      downloader: FakeModelDownloader { _, _ in })
  ) -> ModelPanePresenter {
    ModelPanePresenter(
      downloads: downloads,
      modelStatus: { status },
      capacityReader: StubVolumeCapacityReader(result: capacity))
  }

  private static func ready() -> ModelStatus {
    ModelStatus(readiness: .ready, sizeBytes: 483_256_769, location: location)
  }

  @Test("The presenter assembles the pane from the disk and the volume")
  func paneIsAssembledFromLiveSources() {
    let pane = Self.presenter(Self.ready()).pane
    #expect(pane.subtitle.hasSuffix("em disco · pronto para usar"))
    #expect(pane.diskLine == "182 GB livres em Macintosh HD")
    #expect(!pane.isDownloading)
  }

  /// The disk is read in `refresh()` and nowhere else, so a progress tick
  /// re-renders the row without enumerating the model directory again.
  @Test("Reading the pane never touches the disk")
  func paneAccessDoesNotReadTheDisk() {
    let reads = Counter()
    let presenter = ModelPanePresenter(
      downloads: ModelDownloadController(downloader: FakeModelDownloader { _, _ in }),
      modelStatus: { reads.increment() },
      capacityReader: StubVolumeCapacityReader(result: Self.full))
    #expect(reads.value == 1)

    for _ in 0..<20 { _ = presenter.pane }
    #expect(reads.value == 1)

    presenter.refresh()
    #expect(reads.value == 2)
  }

  @Test("A download in flight shows up in the pane")
  func downloadStateReachesThePane() async {
    let downloader = FakeModelDownloader { _, _ in
      try await Task.sleep(for: .seconds(30))
    }
    let presenter = Self.presenter(
      Self.ready(), downloads: ModelDownloadController(downloader: downloader))

    presenter.startDownload()
    #expect(presenter.pane.isDownloading)
    #expect(presenter.pane.downloadTitle == "Preparando o download…")

    presenter.cancelDownload()
    #expect(presenter.pane.downloadTitle == "Cancelando…")
    await presenter.downloads.waitUntilIdle()
    #expect(presenter.pane.outcomeMessage == "Download cancelado.")
  }

  /// The guard lives in the presenter so a view cannot start a `.replace` — which
  /// deletes the working model first — on a volume with no room for the refetch.
  @Test("A volume with no room refuses to start the download at all")
  func fullVolumeBlocksTheDownload() {
    let downloader = FakeModelDownloader { _, _ in }
    let presenter = Self.presenter(
      Self.ready(),
      capacity: VolumeCapacity(availableBytes: 1_000, volumeName: "Macintosh HD"),
      downloads: ModelDownloadController(downloader: downloader))

    presenter.startDownload()
    #expect(downloader.callCount == 0)
    #expect(!presenter.pane.isDownloading)
  }

  /// A `.replace` that fails half-way leaves a directory that no longer holds a
  /// working model; without the re-read the tab would keep showing its old size.
  @Test("A finished download re-reads the disk")
  func finishingADownloadRefreshes() async {
    let reads = Counter()
    let presenter = ModelPanePresenter(
      downloads: ModelDownloadController(downloader: FakeModelDownloader { _, _ in }),
      modelStatus: { reads.increment() },
      capacityReader: StubVolumeCapacityReader(result: Self.full))
    #expect(reads.value == 1)

    presenter.startDownload()
    await presenter.downloads.waitUntilIdle()
    #expect(reads.value == 2)
  }

  /// The same controller is shared with the menu bar, which also needs to know a
  /// download ended. Assigning `onFinish` instead of chaining it would leave the
  /// popover showing a finished download forever, and nothing would fail to
  /// compile.
  @Test("Wiring the presenter does not silently eat an existing onFinish")
  func onFinishIsChainedNotReplaced() async {
    let controller = ModelDownloadController(downloader: FakeModelDownloader { _, _ in })
    let observed = Box<ModelDownloadOutcome?>(nil)
    controller.onFinish = { observed.value = $0 }

    let presenter = Self.presenter(Self.ready(), downloads: controller)
    presenter.startDownload()
    await controller.waitUntilIdle()

    #expect(observed.value == .completed)
  }
}

/// One mutable value a `@MainActor` test can write from a callback.
@MainActor
final class Box<Value> {
  var value: Value

  init(_ value: Value) {
    self.value = value
  }
}

/// Counts how often the status closure is called, and hands back a fixed status.
@MainActor
final class Counter {
  private(set) var value = 0

  @discardableResult
  nonisolated func increment() -> ModelStatus {
    MainActor.assumeIsolated { value += 1 }
    return ModelStatus(
      readiness: .ready, sizeBytes: 483_256_769,
      location: URL(fileURLWithPath: "/tmp/fala-model-pane"))
  }
}
