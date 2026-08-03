import Foundation
import Testing
import os

@testable import FalaKit

// The cancellable model download (settings-window.dc.html, MODELO: a progress bar
// with "Cancelar" beside it).
//
// Nothing here touches the network. What CAN be proved without it is the part
// that was actually missing: that a cancel is observed, that a download which
// completes AFTER being cancelled is not reported as a success, that the
// progress arithmetic survives FluidAudio's four-sweep progress signal, and that
// the free-space check happens before anything destructive.
//
// What CANNOT be proved here is that FluidAudio's own transport honours
// cancellation. That was established by reading the pinned 0.15.5 source and is
// documented on `ModelDownloadController`; a unit test asserting it would have to
// download 483 MB to be honest about what it measured.

// MARK: - Progress translation

@Suite("ModelDownloadStageTracker")
struct ModelDownloadStageTrackerTests {

  private static let total = ModelStatus.expectedDownloadBytes

  private func tracker() -> ModelDownloadStageTracker {
    ModelDownloadStageTracker(expectedBytes: Self.total)
  }

  @Test("Listing is 'preparing', with no percentage to show")
  func listingIsPreparing() {
    #expect(tracker().stage(fraction: 0, phase: .listing) == .preparing)
  }

  /// THE rescale. `ProgressReporter` is built with `downloadPhaseWeight: 0.5` at
  /// every call site in the pinned FluidAudio, so a fraction reported during the
  /// download phase spans 0 → 0.5. Passed through unscaled the bar would stall
  /// at half and then jump.
  @Test("A download-phase fraction of 0.5 is a COMPLETE transfer, not half of one")
  func downloadPhaseIsRescaled() throws {
    let subject = tracker()
    _ = subject.stage(fraction: 0, phase: .listing)
    let stage = try #require(subject.stage(fraction: 0.5, phase: .downloading))
    guard case .transferring(let progress) = stage else {
      Issue.record("expected a transfer, got \(stage)")
      return
    }
    #expect(progress.percent == 100)
    #expect(progress.receivedBytes == Self.total)
  }

  @Test("A quarter of the download phase reads as half the transfer")
  func midDownloadFractionIsRescaled() throws {
    let subject = tracker()
    let stage = try #require(subject.stage(fraction: 0.25, phase: .downloading))
    #expect(stage.progress.percent == 50)
    #expect(stage.progress.totalBytes == Self.total)
  }

  /// `AsrModels.download` calls `ModelHub.loadModels` once per compiled bundle —
  /// four times for v3 — and each call builds its own `ProgressReporter` that
  /// sweeps 0 → 1. Applied naively the bar would run to 100% and restart three
  /// times.
  @Test("The second sweep cannot drag the bar backwards")
  func laterSweepsNeverRegress() {
    let subject = tracker()
    _ = subject.stage(fraction: 0.4, phase: .downloading)  // 80%
    // Sweep two starts over at zero.
    #expect(subject.stage(fraction: 0.0, phase: .downloading) == nil)
    #expect(subject.stage(fraction: 0.1, phase: .downloading) == nil)
  }

  /// Once a compile has been seen, the transfer is over. FluidAudio's later
  /// sweeps re-emit `.downloading` from their cached fast path, and without the
  /// latch the row would fall back from "Instalando…" to "Baixando…".
  @Test("Compiling latches: a later download report stays 'installing'")
  func compilingLatches() {
    let subject = tracker()
    _ = subject.stage(fraction: 0.4, phase: .downloading)
    #expect(subject.stage(fraction: 0.6, phase: .compiling) == .installing)
    #expect(subject.stage(fraction: 0.5, phase: .downloading) == nil)
    #expect(subject.stage(fraction: 0.0, phase: .listing) == nil)
  }

  /// The byte callback fires per received chunk — thousands of times across
  /// 483 MB, each one otherwise a hop to the main actor.
  @Test("Reports that do not move the percentage are dropped")
  func subPercentReportsAreThrottled() {
    let subject = tracker()
    _ = subject.stage(fraction: 0.25, phase: .downloading)
    #expect(subject.stage(fraction: 0.2501, phase: .downloading) == nil)
    #expect(subject.stage(fraction: 0.2502, phase: .downloading) == nil)
    #expect(subject.stage(fraction: 0.255, phase: .downloading) != nil)
  }

  @Test("A NaN fraction cannot drive the bar off its track")
  func nanFractionIsNeutralised() throws {
    let subject = tracker()
    let stage = try #require(subject.stage(fraction: .nan, phase: .downloading))
    #expect(stage.progress.percent == 0)
    #expect(stage.progress.fraction == 0)
  }

  @Test("A fraction past the download phase weight is clamped to 100%")
  func overshootIsClamped() throws {
    let subject = tracker()
    let stage = try #require(subject.stage(fraction: 0.9, phase: .downloading))
    #expect(stage.progress.percent == 100)
    #expect(stage.progress.fraction <= 1)
  }
}

// MARK: - Stage ordering

@Suite("ModelDownloadStage")
struct ModelDownloadStageTests {

  @Test("Every stage supersedes 'nothing published yet'")
  func firstReportAlwaysWins() {
    #expect(ModelDownloadStage.preparing.supersedes(nil))
    #expect(ModelDownloadStage.installing.supersedes(nil))
  }

  @Test("Stages advance and never go back")
  func stagesAdvanceOnly() {
    #expect(ModelDownloadStage.installing.supersedes(.preparing))
    #expect(!ModelDownloadStage.preparing.supersedes(.installing))
    #expect(!ModelDownloadStage.preparing.supersedes(.transferring(.unknown)))
  }

  @Test("A transfer report supersedes only a lower percentage")
  func transfersCompareOnPercent() {
    let low = ModelDownloadStage.transferring(
      ModelDownloadProgress(receivedBytes: 100, totalBytes: 1000))
    let high = ModelDownloadStage.transferring(
      ModelDownloadProgress(receivedBytes: 900, totalBytes: 1000))
    #expect(high.supersedes(low))
    #expect(!low.supersedes(high))
    #expect(!high.supersedes(high))
  }

  /// Reports cross to the main actor through independent tasks, so a determinate
  /// report can be overtaken by an indeterminate one. Accepting it would swap a
  /// real percentage for an indeterminate bar mid-download.
  @Test("Losing the total counts as a regression")
  func indeterminateNeverOverwritesDeterminate() {
    let known = ModelDownloadStage.transferring(
      ModelDownloadProgress(receivedBytes: 500, totalBytes: 1000))
    #expect(!ModelDownloadStage.transferring(.unknown).supersedes(known))
    #expect(known.supersedes(.transferring(.unknown)))
  }

  @Test("Only the transfer can be cancelled")
  func onlyTransferIsCancellable() {
    #expect(ModelDownloadStage.preparing.isCancellable)
    #expect(ModelDownloadStage.transferring(.unknown).isCancellable)
    // FluidAudio's compile loop has no cancellation check and
    // `MLModel(contentsOf:)` is synchronous.
    #expect(!ModelDownloadStage.installing.isCancellable)
  }

  @Test("Stages with no percentage draw an indeterminate bar")
  func nonTransferStagesAreIndeterminate() {
    #expect(!ModelDownloadStage.preparing.progress.isDeterminate)
    #expect(!ModelDownloadStage.installing.progress.isDeterminate)
  }
}

// MARK: - The measured size

@Suite("ModelDownloadSize")
struct ModelDownloadSizeTests {

  /// The mockup's "1,1 GB em disco" is the upstream repository size across every
  /// precision variant, not what lands here.
  @Test("The download size is the measured one, not the quoted 1,1 GB")
  func expectedSizeIsTheMeasuredOne() {
    #expect(ModelStatus.expectedDownloadBytes == 483_256_769)
    #expect(ModelStatus.expectedDownloadBytes < 1_100_000_000)
  }

  /// `minimumPlausibleBytes` is a floor derived from the same measurement; if the
  /// two ever cross, one of them was edited without re-measuring.
  @Test("The completeness floor sits below the measured download")
  func floorIsBelowTheRealSize() {
    #expect(ModelStatus.minimumPlausibleBytes < ModelStatus.expectedDownloadBytes)
  }

  @Test("The download size has a pt-BR rendering for the tab to show")
  func expectedSizeIsFormatted() {
    #expect(ModelStatus.formattedExpectedDownload.contains("483"))
    #expect(ModelStatus.formattedExpectedDownload.hasSuffix("MB"))
  }
}

// MARK: - Intent

@Suite("ModelDownloadIntent")
struct ModelDownloadIntentTests {

  /// `AsrModels.download(force: true)` calls `removeItem(at: targetDir)` BEFORE
  /// requesting a byte, so "Baixar novamente" can leave a user who cancels with
  /// no model at all. The button is not allowed to look harmless.
  @Test("Replacing warns that it deletes first; repairing does not")
  func replaceCarriesAConfirmation() throws {
    let message = try #require(ModelDownloadIntent.replace.confirmationMessage)
    #expect(message.contains("apaga o modelo atual"))
    #expect(message.contains("483"))
    #expect(ModelDownloadIntent.repair.confirmationMessage == nil)
  }

  @Test("Each intent names its own button")
  func intentsNameTheirButtons() {
    #expect(ModelDownloadIntent.replace.actionTitle == "Baixar novamente")
    #expect(ModelDownloadIntent.repair.actionTitle == "Baixar modelo")
  }
}

// MARK: - The controller

@MainActor
@Suite("ModelDownloadController")
struct ModelDownloadControllerTests {

  @Test("A finished download reports success and clears the row")
  func successfulDownloadCompletes() async {
    let downloader = FakeModelDownloader { _, report in
      report(.transferring(ModelDownloadProgress(receivedBytes: 50, totalBytes: 100)))
      report(.installing)
    }
    let controller = ModelDownloadController(downloader: downloader)

    let outcome = await controller.run(.repair)
    #expect(outcome == .completed)
    #expect(controller.stage == nil)
    #expect(!controller.isRunning)
    #expect(controller.lastOutcome == .completed)
    #expect(controller.lastOutcome?.message == nil)
  }

  @Test("Progress reaches the published stage while the download runs")
  func progressIsPublished() async {
    let downloader = FakeModelDownloader { _, report in
      report(.transferring(ModelDownloadProgress(receivedBytes: 40, totalBytes: 100)))
      try await Task.sleep(for: .seconds(30))
    }
    let controller = ModelDownloadController(downloader: downloader)
    controller.start(.repair)

    // The report crosses to the main actor through its own task, so the value is
    // polled rather than read once.
    var seen: ModelDownloadStage?
    for _ in 0..<10_000 where seen == nil {
      if let stage = controller.stage, stage != .preparing { seen = stage }
      await Task.yield()
    }
    #expect(seen?.progress.percent == 40)

    controller.cancel()
    await controller.waitUntilIdle()
  }

  /// The user pressed a button; that is not a failure and must never be painted
  /// like one.
  @Test("Cancelling a transfer ends as cancelled, not as a failure")
  func cancelIsNotAFailure() async {
    let downloader = FakeModelDownloader { _, report in
      report(.transferring(ModelDownloadProgress(receivedBytes: 10, totalBytes: 100)))
      try await Task.sleep(for: .seconds(30))
    }
    let controller = ModelDownloadController(downloader: downloader)
    controller.start(.replace)
    await downloader.waitUntilCalled()

    controller.cancel()
    #expect(controller.isCancelling)

    await controller.waitUntilIdle()
    #expect(controller.lastOutcome == .cancelled)
    #expect(controller.lastOutcome?.message == "Download cancelado.")
    #expect(!controller.isCancelling)
  }

  /// THE case that makes the `Task.isCancelled` re-check necessary. FluidAudio's
  /// compile loop contains no cancellation check and `MLModel(contentsOf:)` is
  /// synchronous, so a download cancelled during `installing` returns
  /// SUCCESSFULLY. Reporting that as `.completed` would tell the user their
  /// cancel was ignored AND that everything worked.
  @Test("A download that completes after being cancelled is still 'cancelled'")
  func completionAfterCancelIsStillCancelled() async {
    let downloader = FakeModelDownloader { _, report in
      report(.installing)
      // Swallows cancellation exactly the way the CoreML open does.
      while !Task.isCancelled { await Task.yield() }
    }
    let controller = ModelDownloadController(downloader: downloader)
    controller.start(.repair)
    await downloader.waitUntilCalled()

    controller.cancel()
    await controller.waitUntilIdle()
    #expect(controller.lastOutcome == .cancelled)
  }

  @Test("Cancelling when nothing is running does nothing at all")
  func cancelWithoutADownloadIsInert() {
    let controller = ModelDownloadController(downloader: FakeModelDownloader { _, _ in })
    controller.cancel()
    #expect(!controller.isCancelling)
    #expect(controller.lastOutcome == nil)
  }

  /// Two concurrent `AsrModels.download` calls would write the same `.partial`
  /// files from two sockets, and a `.replace` would delete the directory the
  /// other one is filling.
  @Test("A second press while a download runs is ignored, not queued")
  func doubleStartIsIgnored() async {
    let downloader = FakeModelDownloader { _, _ in
      try await Task.sleep(for: .seconds(30))
    }
    let controller = ModelDownloadController(downloader: downloader)
    controller.start(.repair)
    await downloader.waitUntilCalled()

    controller.start(.replace)
    controller.start(.repair)
    #expect(downloader.callCount == 1)

    controller.cancel()
    await controller.waitUntilIdle()
    #expect(downloader.callCount == 1)
  }

  @Test("A failed download reports a pt-BR message")
  func failureIsTypedAndTranslated() async {
    let downloader = FakeModelDownloader { _, _ in
      throw ModelDownloadError.failed(reason: "HTTP 503")
    }
    let controller = ModelDownloadController(downloader: downloader)

    let outcome = await controller.run(.repair)
    #expect(outcome == .failed(.failed(reason: "HTTP 503")))
    #expect(outcome.message == "Não foi possível baixar o modelo: HTTP 503")
  }

  /// FluidAudio surfaces a cancelled transfer as `URLError.cancelled`, not as
  /// `CancellationError` — `RetryPolicy.isCancellation` in the pinned source
  /// exists for exactly that reason. Left unmapped, pressing "Cancelar" would
  /// paint a red failure.
  @Test("URLError.cancelled is a cancel, not a download failure")
  func urlCancellationIsReadAsACancel() async {
    let downloader = FakeModelDownloader { _, _ in
      throw URLError(.cancelled)
    }
    let controller = ModelDownloadController(downloader: downloader)
    #expect(await controller.run(.repair) == .cancelled)
  }

  @Test("An untyped error still becomes a pt-BR message rather than raw text")
  func untypedErrorIsWrapped() async {
    let downloader = FakeModelDownloader { _, _ in throw URLError(.timedOut) }
    let controller = ModelDownloadController(downloader: downloader)

    let outcome = await controller.run(.repair)
    guard case .failed(.failed(let reason)) = outcome else {
      Issue.record("expected a typed failure, got \(outcome)")
      return
    }
    #expect(!reason.isEmpty)
    #expect(outcome.message?.hasPrefix("Não foi possível baixar o modelo") == true)
  }

  /// Reports arrive on an unspecified queue and cross to the main actor through
  /// independent tasks, so "later" cannot mean "arrived later".
  @Test("An out-of-order report cannot drag the bar backwards")
  func outOfOrderReportsAreDropped() async {
    let downloader = FakeModelDownloader { _, _ in
      try await Task.sleep(for: .seconds(30))
    }
    let controller = ModelDownloadController(downloader: downloader)
    controller.start(.repair)
    await downloader.waitUntilCalled()

    controller.apply(.transferring(ModelDownloadProgress(receivedBytes: 80, totalBytes: 100)))
    controller.apply(.transferring(ModelDownloadProgress(receivedBytes: 20, totalBytes: 100)))
    #expect(controller.stage?.progress.percent == 80)

    controller.cancel()
    await controller.waitUntilIdle()
  }

  @Test("A report arriving after the download ended is ignored")
  func lateReportsAfterCompletionAreIgnored() async {
    let downloader = FakeModelDownloader { _, _ in }
    let controller = ModelDownloadController(downloader: downloader)
    _ = await controller.run(.repair)

    controller.apply(.transferring(ModelDownloadProgress(receivedBytes: 50, totalBytes: 100)))
    #expect(controller.stage == nil)
  }
}

// MARK: - The production downloader's pre-flight

@Suite("FluidAudioModelDownloader")
struct FluidAudioModelDownloaderTests {

  /// Checked BEFORE `.replace` deletes anything. Without it, a user with 120 MB
  /// free who presses "Baixar novamente" loses their working model and then
  /// meets a write failure minutes into the transfer.
  ///
  /// Safe to run: the space check throws before any network call is made.
  @Test("A volume too small to hold the model refuses before deleting anything")
  func insufficientSpaceRefusesUpFront() async {
    let downloader = FluidAudioModelDownloader(
      capacity: StubVolumeCapacityReader(
        result: VolumeCapacity(availableBytes: 120_000_000, volumeName: "Macintosh HD")))

    await #expect(throws: ModelDownloadError.self) {
      try await downloader.download(.replace) { _ in }
    }
  }

  @Test("The refusal is the pt-BR warning, not a generic failure")
  func refusalCarriesTheWarning() async {
    let capacity = VolumeCapacity(availableBytes: 1_000, volumeName: "Macintosh HD")
    let downloader = FluidAudioModelDownloader(
      capacity: StubVolumeCapacityReader(result: capacity))
    let warning = capacity.insufficientSpaceWarning(for: ModelStatus.expectedDownloadBytes)
    do {
      try await downloader.download(.repair) { _ in }
      Issue.record("expected the download to refuse")
    } catch let error as ModelDownloadError {
      #expect(error == .insufficientSpace(message: warning ?? ""))
      #expect(error.message.contains("Macintosh HD"))
    } catch {
      Issue.record("expected ModelDownloadError, got \(error)")
    }
  }
}

// MARK: - Fixtures

/// A `ModelDownloading` whose whole body is supplied by the test.
///
/// It awaits the closure DIRECTLY, so cancelling the controller's task reaches it
/// the same way it reaches FluidAudio — a fake that wrapped the work in its own
/// unstructured `Task` would sever cancellation and make every cancel test pass
/// for the wrong reason.
/// `CheckedContinuation` is not `Sendable`, so the shared state lives inside an
/// `OSAllocatedUnfairLock` — the one escape hatch this project allows (CLAUDE.md
/// bans `@unchecked Sendable`).
final class FakeModelDownloader: ModelDownloading, Sendable {

  typealias Report = @Sendable (ModelDownloadStage) -> Void
  typealias Body = @Sendable (ModelDownloadIntent, @escaping Report) async throws -> Void

  private struct State {
    var callCount = 0
    var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
  }

  private let body: Body
  private let state = OSAllocatedUnfairLock(uncheckedState: State())

  init(_ body: @escaping Body) {
    self.body = body
  }

  var callCount: Int { state.withLockUnchecked { $0.callCount } }

  func download(
    _ intent: ModelDownloadIntent,
    reportingTo report: @escaping Report
  ) async throws {
    let arrivals = state.withLockUnchecked { state -> [CheckedContinuation<Void, Never>] in
      state.callCount += 1
      defer { state.arrivalWaiters = [] }
      return state.arrivalWaiters
    }
    for waiter in arrivals { waiter.resume() }
    try await body(intent, report)
  }

  /// Suspends until `download` has been entered, so a test can be sure the work
  /// is genuinely in flight before it cancels.
  ///
  /// The check and the park happen under ONE lock acquisition: split in two, an
  /// arrival landing between them would leave the waiter parked forever and hang
  /// the suite instead of failing it.
  func waitUntilCalled() async {
    await withCheckedContinuation { continuation in
      let alreadyCalled = state.withLockUnchecked { state -> Bool in
        if state.callCount > 0 { return true }
        state.arrivalWaiters.append(continuation)
        return false
      }
      if alreadyCalled { continuation.resume() }
    }
  }
}

extension ModelDownloadController {

  /// Starts a download and suspends until it ends, returning how it ended.
  @MainActor
  func run(_ intent: ModelDownloadIntent) async -> ModelDownloadOutcome {
    await withCheckedContinuation { continuation in
      onFinish = { continuation.resume(returning: $0) }
      start(intent)
    }
  }

  /// Suspends until no download is running. Bounded so a broken controller fails
  /// the test instead of hanging the suite.
  @MainActor
  func waitUntilIdle() async {
    for _ in 0..<10_000 where isRunning {
      await Task.yield()
    }
    #expect(!isRunning)
  }
}
