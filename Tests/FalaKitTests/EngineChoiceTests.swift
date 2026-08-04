import FluidAudio
import Foundation
import Testing
import os

@testable import FalaKit

// Choosing the transcription engine in Ajustes › Modelo.
//
// THE defect this file exists to prevent is the one Ajustes › Modelo already
// had once, generalised to two engines: a row that reports readiness it has not
// checked. With one engine that was "pronto · Zero KB" over an interrupted
// download; with two it would be a picker answering "pronto" for Cohere out of
// the Parakeet directory, which is the same lie with a longer reach — it would
// send the user into a dictation that cannot run.
//
// So every test below asks the same question in a different shape: does each
// engine's row describe THAT engine's own directory, and does it stay quiet
// about everything nobody has measured?

// MARK: - The choice itself

@Suite("TranscriptionEngineChoice")
struct TranscriptionEngineChoiceTests {

  /// SPEC.md §2 is [CONFIRMED] on one engine for v1. This picker is for
  /// comparison, not a silent switch: Parakeet is the default, it is listed
  /// first, and `Preferences` agrees.
  @Test("Parakeet is the default, and is offered first")
  func parakeetIsTheDefault() {
    #expect(TranscriptionEngineChoice.default == .parakeet)
    #expect(TranscriptionEngineChoice.allCases.first == .parakeet)
    #expect(TranscriptionEngineChoice.allCases.count == 2)
  }

  /// The names are what the user reads in the picker; the raw values are what
  /// lands in `defaults`. Renaming a raw value silently resets everyone's
  /// choice to the default on their next launch.
  @Test("Names are stable and distinct, in both alphabets")
  func namesAreStable() {
    #expect(TranscriptionEngineChoice.parakeet.rawValue == "parakeet")
    #expect(TranscriptionEngineChoice.cohere.rawValue == "cohere")
    #expect(TranscriptionEngineChoice.cohere.displayName == "Cohere Transcribe")
    // Shares the popover's product name, so the three surfaces cannot drift.
    #expect(TranscriptionEngineChoice.parakeet.displayName.hasPrefix(ModelBlock.modelName))
    #expect(
      TranscriptionEngineChoice.parakeet.displayName
        != TranscriptionEngineChoice.cohere.displayName)
  }

  /// The trade-off has to be stated, and each half of it is what makes the
  /// other engine worth choosing. If either sentence loses its half, the picker
  /// stops being a comparison and becomes a preference nobody can reason about.
  @Test("Each engine states the trade-off that makes the other one worth picking")
  func summariesStateTheTradeOff() {
    let parakeet = TranscriptionEngineChoice.parakeet.summary
    // Its win: measured speed. Its cost: it cannot pin Portuguese (FR-7).
    #expect(parakeet.contains("100 ms"))
    #expect(parakeet.contains("Não consegue fixar o português"))

    let cohere = TranscriptionEngineChoice.cohere.summary
    // Its win: a real language lock. Its costs, both measured: it is ~30×
    // slower and the download is nearly 5 GB.
    #expect(cohere.contains("Fixa o português"))
    #expect(cohere.contains("5 GB"))
    #expect(cohere.contains("lento"))
  }

  /// Cohere HAS been run here now (spike, 2026-08-03: 3,3–4,7 s per utterance
  /// after warm-up), so the picker states that number — and must never dress it
  /// up. It is roughly 30× slower than Parakeet, which is the single most
  /// important thing to know before switching, so the copy has to say slow.
  @Test("Cohere states its measured latency and does not claim to be fast")
  func cohereStatesItsMeasuredLatency() {
    let summary = TranscriptionEngineChoice.cohere.summary
    #expect(summary.contains("3,4 s"))
    #expect(summary.contains("lento"))
    // The recurring cost, not just the per-utterance one: 97 s of `prepare()`
    // at EVERY launch is the difference between "slower" and "slow to start".
    #expect(summary.contains("1,5 min"))
    for claim in ["mais rápid", "tão rápid", "rápido"] {
      #expect(!summary.contains(claim), "speed claim this engine cannot make: \(summary)")
    }
  }

  /// The 4,7 GB is `du` on the installed directory. FluidAudio ships the
  /// `.mlpackage` AND the pre-compiled `.mlmodelc` for three models while this
  /// app loads two `.mlmodelc`, so about half of it is never opened — but the
  /// user still pays for all of it, so that is the number they are shown.
  @Test("Cohere states the full download it will actually cost")
  func cohereStatesItsDownloadSize() {
    #expect(TranscriptionEngineChoice.cohere.summary.contains("5 GB"))

    // The precise figure belongs to the layout, so the sheet and the post-
    // download status line format the SAME number.
    let measured = try! #require(ModelLayout.cohere.expectedDownloadBytes)
    #expect(measured == 4_984_768_322)
    #expect(EnginePickerStrings.format(measured) == "4,98 GB")
  }

  /// A partial download must not pass as complete. The floor sits below the
  /// measured total so a slightly smaller future variant still passes, and far
  /// above anything a truncated transfer would leave behind.
  @Test("The Cohere size floor is below the real total and above a truncated one")
  func cohereFloorIsPlausible() throws {
    let floor = try #require(ModelLayout.cohere.minimumPlausibleBytes)
    let total = try #require(ModelLayout.cohere.expectedDownloadBytes)
    #expect(floor < total)
    #expect(floor > total / 2)
  }
}

// MARK: - Where each engine's model lives

@Suite("ModelLayout")
struct ModelLayoutTests {

  /// The two engines must never be asked about the same directory. This is the
  /// single assertion that keeps a Cohere row from being answered by a Parakeet
  /// download.
  @Test("The two engines look at different directories")
  func layoutsDoNotShareADirectory() {
    let parakeet = TranscriptionEngineChoice.parakeet.modelLayout
    let cohere = TranscriptionEngineChoice.cohere.modelLayout
    #expect(parakeet.location != cohere.location)
    #expect(!cohere.location.path.contains("parakeet"))
    #expect(!parakeet.location.path.contains("cohere"))
  }

  /// Parakeet keeps the nine exact paths a real download was enumerated for on
  /// 2026-08-02, and the floor derived from the same measurement.
  @Test("The Parakeet layout is unchanged by the generalisation")
  func parakeetLayoutIsUnchanged() {
    let layout = ModelLayout.parakeet
    #expect(layout.location == ModelStatus.defaultLocation)
    #expect(layout.requiredFiles == ModelStatus.requiredFiles)
    #expect(layout.requiredFiles.count == 9)
    #expect(layout.requiredBundles.isEmpty)
    #expect(layout.minimumPlausibleBytes == ModelStatus.minimumPlausibleBytes)
    #expect(layout.expectedDownloadBytes == ModelStatus.expectedDownloadBytes)
  }

  /// THE path bug this work found. `ModelHub.download` appends
  /// `Repo.folderName` to the directory it is given, and for this repo that is
  /// `cohere-transcribe/q8` — NOT the remote path
  /// `cohere-transcribe-03-2026-coreml/q8` that the engine's hand-written
  /// constant used to name. With the two out of step the model downloaded to
  /// one directory and was loaded from another, so `prepare()` failed on every
  /// first run and this picker would have reported "não baixado" forever.
  @Test("The Cohere directory is the one FluidAudio actually writes to")
  func cohereLocationMatchesFluidAudio() {
    let expected = CohereEngine.modelsRoot
      .appendingPathComponent(Repo.cohereTranscribeCoreml.folderName)
    #expect(ModelLayout.cohere.location == expected)
    #expect(CohereEngine.modelDirectory == expected)
    #expect(expected.path.hasSuffix("FluidAudio/Models/cohere-transcribe/q8"))
  }

  /// The bundle and vocabulary names come from FluidAudio's own required set,
  /// so a version bump that renames or adds one fails here rather than telling
  /// a user their complete download is broken.
  @Test("The Cohere required set matches FluidAudio's own")
  func cohereRequiredSetMatchesFluidAudio() {
    let layout = ModelLayout.cohere
    let named = Set(layout.requiredBundles + layout.requiredFiles)
    #expect(named == ModelNames.CohereTranscribe.requiredModels)
    // The v2 decoder is the ANE-friendly one `CohereEngine` loads; the legacy
    // FP16 decoder is a different file and is deliberately not required.
    #expect(layout.requiredBundles.contains("cohere_decoder_cache_external_v2.mlmodelc"))
    #expect(!layout.requiredBundles.contains("cohere_decoder_cache_external.mlmodelc"))
  }

  /// Both numbers now come from a real completed download (`find -exec stat`,
  /// 2026-08-03). Before that they were `nil`, and `nil` still has to mean "no
  /// floor" rather than "Parakeet's floor" for any engine added later — see
  /// `absentFloorIsNotInherited`.
  @Test("Cohere quotes only sizes that were measured on disk")
  func cohereLayoutQuotesMeasuredSizes() throws {
    let total = try #require(ModelLayout.cohere.expectedDownloadBytes)
    let floor = try #require(ModelLayout.cohere.minimumPlausibleBytes)
    #expect(total == 4_984_768_322)
    #expect(floor < total)
  }
}

// MARK: - Reading a Cohere directory

@Suite("ModelStatus for the Cohere layout")
struct CohereModelStatusTests {

  /// The first-run state, and the one the picker's warning is written for.
  @Test("An absent directory is not downloaded")
  func absentDirectoryIsNotDownloaded() {
    let status = ModelStatus.current(Self.layout(at: Self.temporaryDirectory()))
    #expect(status.readiness == .notDownloaded)
    #expect(!status.isPresent)
  }

  /// THE defect, in its second-engine form: an interrupted download leaves the
  /// bundle DIRECTORIES behind and nothing in them. FluidAudio's own
  /// existence check would pass this; ours must not.
  @Test("Bare bundle directories are not a model")
  func emptyBundleDirectoriesAreNotAModel() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    let fileManager = FileManager.default
    for bundle in ModelLayout.cohereBundles {
      try fileManager.createDirectory(
        at: root.appendingPathComponent(bundle), withIntermediateDirectories: true)
    }
    try Self.write(root.appendingPathComponent(ModelLayout.cohereVocabularyFile), bytes: 2_000_000)

    let status = ModelStatus.current(Self.layout(at: root))
    #expect(!status.isPresent)
    #expect(status.isIncomplete)
    #expect(status.missingComponents == ModelLayout.cohereBundles)
  }

  @Test("A complete download is ready, and reports what it weighs")
  func completeDownloadIsReady() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    try Self.makeCompleteDownload(at: root)

    let status = ModelStatus.current(Self.layout(at: root))
    #expect(status.readiness == .ready)
    #expect(status.isPresent)
    #expect(status.problemMessage == nil)
    #expect((status.sizeBytes ?? 0) > 0)
  }

  /// The shape a transfer that stopped between files takes: CoreML's descriptor
  /// landed, the payload never did. Parakeet catches this by naming
  /// `weights/weight.bin`; Cohere's bundles have never been enumerated here, so
  /// it is caught by weight instead — and it must still be caught.
  @Test("A bundle with a descriptor and no payload is incomplete")
  func descriptorWithoutPayloadIsIncomplete() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    try Self.makeCompleteDownload(at: root)
    Self.remove(
      root.appendingPathComponent(ModelLayout.cohereBundles[0]).appendingPathComponent("weights"))

    let status = ModelStatus.current(Self.layout(at: root))
    #expect(!status.isPresent)
    #expect(status.missingComponents == [ModelLayout.cohereBundles[0]])
  }

  /// The descriptor is what `MLModel(contentsOf:)` opens first. A bundle full
  /// of payload without one cannot load, so it is not ready either.
  @Test("A bundle with a payload and no descriptor is incomplete")
  func payloadWithoutDescriptorIsIncomplete() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    try Self.makeCompleteDownload(at: root)
    Self.remove(
      root.appendingPathComponent(ModelLayout.cohereBundles[1])
        .appendingPathComponent("coremldata.bin"))

    let status = ModelStatus.current(Self.layout(at: root))
    #expect(!status.isPresent)
    #expect(status.missingComponents == [ModelLayout.cohereBundles[1]])
  }

  @Test("A missing vocabulary is named, in pt-BR, with a path to delete")
  func missingVocabularyIsExplained() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    try Self.makeCompleteDownload(at: root, omittingVocabulary: true)

    let status = ModelStatus.current(Self.layout(at: root))
    #expect(status.missingComponents == [ModelLayout.cohereVocabularyFile])
    let message = try #require(status.problemMessage)
    #expect(message.contains("incompleto"))
    #expect(message.contains(ModelLayout.cohereVocabularyFile))
  }

  /// A layout with no measured floor applies NO floor — it must not silently
  /// inherit Parakeet's 300 MB, which would report every real download of a
  /// newly added engine as broken until someone noticed.
  @Test("No measured floor means no floor, not Parakeet's")
  func absentFloorIsNotInherited() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    try Self.makeCompleteDownload(at: root)

    let size = try #require(ModelStatus.current(Self.layout(at: root)).sizeBytes)
    #expect(size < ModelStatus.minimumPlausibleBytes)
    #expect(ModelStatus.current(Self.layout(at: root)).isPresent)
  }

  /// And where a floor DOES exist it has to bite. A directory with every file
  /// in the right place but a fraction of the bytes is exactly what a transfer
  /// killed near the end leaves behind, and it must not read as "pronto".
  @Test("A structurally complete but underweight directory is incomplete")
  func floorRejectsAnUnderweightDirectory() throws {
    let root = Self.temporaryDirectory()
    defer { Self.remove(root) }
    try Self.makeCompleteDownload(at: root)

    let floored = Self.layout(at: root, floor: ModelLayout.cohere.minimumPlausibleBytes)
    let status = ModelStatus.current(floored)
    #expect(!status.isPresent)
    #expect(status.isIncomplete)
  }

  // MARK: - Helpers

  /// The real layout's rules pointed at a fixture directory, with the byte floor
  /// under the caller's control.
  ///
  /// `relocated(to:)` deliberately KEEPS `minimumPlausibleBytes`, which is right
  /// in production and useless here: the real floor is 4 GB and these fixtures
  /// are 18 MB, so every structural check would fail on weight before it ever
  /// examined the shape. Structural tests pass `floor: nil` and test structure;
  /// the floor gets its own test.
  private static func layout(at root: URL, floor: Int64? = nil) -> ModelLayout {
    ModelLayout(
      location: root,
      requiredFiles: [ModelLayout.cohereVocabularyFile],
      requiredBundles: ModelLayout.cohereBundles,
      minimumPlausibleBytes: floor,
      expectedDownloadBytes: ModelLayout.cohere.expectedDownloadBytes)
  }

  /// A directory shaped like a finished download: each bundle gets CoreML's
  /// descriptor plus a payload over `minimumBundlePayloadBytes`, and the
  /// vocabulary sits beside them.
  private static func makeCompleteDownload(
    at root: URL,
    omittingVocabulary: Bool = false
  ) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for bundle in ModelLayout.cohereBundles {
      let directory = root.appendingPathComponent(bundle)
      try write(directory.appendingPathComponent("coremldata.bin"), bytes: 500)
      try write(directory.appendingPathComponent("weights/weight.bin"), bytes: 8_000_000)
    }
    guard !omittingVocabulary else { return }
    try write(root.appendingPathComponent(ModelLayout.cohereVocabularyFile), bytes: 2_000_000)
  }

  /// Sparse: `truncate` costs no disk and no time, and `.fileSizeKey` still
  /// reports the full length — which is the only thing under test.
  private static func write(_ url: URL, bytes: Int64) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fileManager.removeItem(at: url)
    guard fileManager.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    guard bytes > 0 else { return }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(bytes))
  }

  private static func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("fala-cohere-status-\(UUID().uuidString)", isDirectory: true)
  }

  private static func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}

// MARK: - What the picker renders

@Suite("EnginePicker")
struct EnginePickerTests {

  private static func option(
    _ choice: TranscriptionEngineChoice,
    _ readiness: ModelReadiness,
    sizeBytes: Int64? = nil,
    isSelected: Bool = false
  ) -> EngineOption {
    EngineOption(
      choice: choice,
      status: ModelStatus(
        readiness: readiness, sizeBytes: sizeBytes, location: choice.modelLayout.location),
      isSelected: isSelected)
  }

  private static func picker(
    parakeet: ModelReadiness = .ready,
    parakeetBytes: Int64? = 483_256_769,
    cohere: ModelReadiness = .notDownloaded,
    cohereBytes: Int64? = nil,
    selected: TranscriptionEngineChoice = .parakeet,
    appliesImmediately: Bool = true
  ) -> EnginePicker {
    EnginePicker(
      options: [
        option(.parakeet, parakeet, sizeBytes: parakeetBytes, isSelected: selected == .parakeet),
        option(.cohere, cohere, sizeBytes: cohereBytes, isSelected: selected == .cohere),
      ],
      appliesImmediately: appliesImmediately)
  }

  // MARK: - Each row describes its own model

  /// The requirement, stated once: a row reports the readiness of ITS model.
  /// The interesting case is the asymmetric one — Parakeet downloaded, Cohere
  /// not — which is what every user will see the first time they open the tab.
  @Test("A downloaded engine and an undownloaded one read differently")
  func rowsReportTheirOwnModel() throws {
    let picker = Self.picker()
    let parakeet = try #require(picker.options.first { $0.choice == .parakeet })
    let cohere = try #require(picker.options.first { $0.choice == .cohere })

    #expect(parakeet.isModelReady)
    #expect(parakeet.statusLine == "Modelo pronto · 483,3 MB em disco")
    #expect(parakeet.stateKind == .success)
    #expect(parakeet.symbol == FalaSymbol.processor)

    #expect(!cohere.isModelReady)
    #expect(cohere.statusLine == "Modelo ainda não baixado")
    #expect(cohere.stateKind == .idle)
    #expect(cohere.symbol == FalaSymbol.download)
  }

  /// The exact defect this file opens with: selecting an engine must not make
  /// its model appear. Readiness comes from the status and from nothing else.
  @Test("Selecting an engine does not make its model ready")
  func selectionDoesNotImplyReadiness() throws {
    let picker = Self.picker(selected: .cohere)
    let cohere = try #require(picker.options.first { $0.choice == .cohere })
    #expect(cohere.isSelected)
    #expect(!cohere.isModelReady)
    #expect(cohere.statusLine == "Modelo ainda não baixado")
    #expect(picker.downloadWarning(for: .cohere) != nil)
  }

  /// A half-finished download is not "pronto" and not "não baixado": it is the
  /// third state, and it says what is really there.
  @Test("A partial download says so, with the bytes it really has")
  func incompleteRowStatesWhatIsThere() throws {
    let picker = Self.picker(cohere: .incomplete(missing: ["x"]), cohereBytes: 240_000_000)
    let cohere = try #require(picker.options.first { $0.choice == .cohere })
    #expect(cohere.statusLine == "Download incompleto · 240 MB em disco")
    #expect(cohere.stateKind == .warning)
    #expect(!cohere.isModelReady)
  }

  /// `ModelLayout.cohere` carries no measured download size, so nothing in the
  /// picker may print one — not "1,1 GB", not Parakeet's 483 MB, not anything.
  @Test("No row invents a size for a model that is not there")
  func unmeasuredSizesAreNotPrinted() {
    let picker = Self.picker()
    let rows = picker.options.map { $0.statusLine + $0.summary }.joined()
    let text = rows + (picker.downloadWarning(for: .cohere) ?? "")
    #expect(!text.contains("1,1 GB"))
    // The only size in the whole picker is the one measured on this disk.
    #expect(text.components(separatedBy: "MB").count - 1 == 1)
  }

  // MARK: - The cost of switching

  /// Requirement: choosing an engine whose model is absent means a download,
  /// and the user is told BEFORE it starts.
  @Test("Switching to an engine with no model warns first")
  func absentModelWarnsBeforeSwitching() throws {
    let warning = try #require(Self.picker().downloadWarning(for: .cohere))
    #expect(warning.contains("Cohere Transcribe"))
    // Formatted from the measured byte count, not written into the string —
    // and it must agree with what the status line shows after the download.
    #expect(warning.contains("4,98 GB"))
    #expect(warning.contains("download separado"))
    #expect(warning.contains("ainda não está no seu Mac"))

    // The sheet asks a question and its buttons name the consequence, so the
    // download is never something the user only finds out about afterwards.
    let picker = Self.picker()
    #expect(picker.confirmationTitle == "Trocar o motor de transcrição?")
    #expect(picker.confirmTitle == "Trocar e baixar")
    #expect(picker.cancelTitle == SettingsStrings.cancel)
  }

  /// The warning is driven by the DISK, not by which engine it is: coming back
  /// to Parakeet on a machine whose Parakeet model was deleted costs exactly
  /// the same download, and saying nothing there would be the same omission.
  @Test("The warning follows the disk, not the engine's name")
  func warningFollowsTheDiskNotTheName() {
    let flipped = Self.picker(
      parakeet: .notDownloaded,
      parakeetBytes: nil,
      cohere: .ready,
      cohereBytes: 900_000_000,
      selected: .cohere)
    #expect(flipped.downloadWarning(for: .parakeet) != nil)
    #expect(flipped.downloadWarning(for: .cohere) == nil)
  }

  @Test("An engine already on disk switches without a dialog")
  func readyModelNeedsNoConfirmation() {
    #expect(Self.picker().downloadWarning(for: .parakeet) == nil)
  }

  // MARK: - When the change lands

  /// The caption may not promise an immediacy nothing delivers. With a handler
  /// wired the app can adopt the engine; without one the preference is all
  /// there is, and the next launch is when it matters.
  @Test("The caption tells the truth about when the switch takes effect")
  func captionMatchesWhatTheAppCanActuallyDo() {
    #expect(Self.picker(appliesImmediately: true).caption.contains("próxima ditada"))
    let deferred = Self.picker(appliesImmediately: false).caption
    #expect(deferred.contains("reabrir"))
    #expect(!deferred.contains("próxima ditada"))
  }

  @Test("The selected engine is reported once and only once")
  func exactlyOneRowIsSelected() {
    let picker = Self.picker(selected: .cohere)
    #expect(picker.selected == .cohere)
    #expect(picker.options.filter(\.isSelected).count == 1)
  }
}

// MARK: - The presenter

@MainActor
@Suite("ModelPanePresenter engine choice")
struct ModelPaneEngineTests {

  private static func presenter(
    engine: TranscriptionEngineChoice = .parakeet,
    cohere: ModelReadiness = .notDownloaded
  ) -> (ModelPanePresenter, InMemoryPreferencesStore) {
    let store = InMemoryPreferencesStore(engine: engine)
    let presenter = ModelPanePresenter(
      downloads: ModelDownloadController(downloader: FakeModelDownloader { _, _ in }),
      preferences: Preferences(store: store),
      modelStatus: { Self.parakeetStatus },
      engineStatus: { choice in
        switch choice {
        case .parakeet: return Self.parakeetStatus
        case .cohere:
          return ModelStatus(
            readiness: cohere, sizeBytes: nil, location: ModelLayout.cohere.location)
        }
      },
      capacityReader: StubVolumeCapacityReader(
        result: VolumeCapacity(availableBytes: 182_000_000_000, volumeName: "Macintosh HD")))
    return (presenter, store)
  }

  /// `nonisolated` so the `@Sendable` status closures can read it: the readers
  /// are deliberately off the main actor, because the real ones walk the disk.
  nonisolated static let parakeetStatus = ModelStatus(
    readiness: .ready, sizeBytes: 483_256_769, location: ModelStatus.defaultLocation)

  @Test("A fresh presenter shows the confirmed default selected")
  func defaultSelectionIsParakeet() {
    let (presenter, _) = Self.presenter()
    #expect(presenter.engines.selected == .parakeet)
    #expect(presenter.engines.options.count == 2)
  }

  @Test("Choosing an engine persists it and tells the app")
  func selectingPersistsAndNotifies() {
    let (presenter, store) = Self.presenter()
    let observed = Box<TranscriptionEngineChoice?>(nil)
    presenter.onEngineChanged = { observed.value = $0 }

    presenter.selectEngine(.cohere)

    #expect(presenter.engines.selected == .cohere)
    #expect(store.loadEngine() == .cohere)
    #expect(observed.value == .cohere)
  }

  /// A row re-applies its binding on every render; writing and re-notifying the
  /// app each time would rebuild the pipeline for nothing.
  @Test("Re-choosing the current engine writes nothing and notifies nobody")
  func reselectingIsANoOp() {
    let (presenter, store) = Self.presenter()
    let observed = Box<TranscriptionEngineChoice?>(nil)
    presenter.onEngineChanged = { observed.value = $0 }

    presenter.selectEngine(.parakeet)

    #expect(store.engineWrites == 0)
    #expect(observed.value == nil)
  }

  /// The caption is derived from whether anyone is listening, so an app that
  /// forgot to wire the handler tells the user the truth instead of a promise.
  @Test("An unwired app says the change lands on the next launch")
  func unwiredPresenterDefersTheClaim() {
    let (presenter, _) = Self.presenter()
    #expect(!presenter.engines.appliesImmediately)
    #expect(presenter.engines.caption.contains("reabrir"))

    presenter.onEngineChanged = { _ in }
    #expect(presenter.engines.appliesImmediately)
    #expect(presenter.engines.caption.contains("próxima ditada"))
  }

  /// The presenter must not answer a Cohere row out of the Parakeet directory.
  /// Here Parakeet is ready and Cohere is not, and the two rows must disagree.
  @Test("Each row is answered from its own engine's status reader")
  func rowsComeFromSeparateReads() throws {
    let (presenter, _) = Self.presenter()
    let picker = presenter.engines
    let parakeet = try #require(picker.options.first { $0.choice == .parakeet })
    let cohere = try #require(picker.options.first { $0.choice == .cohere })

    #expect(parakeet.isModelReady)
    #expect(!cohere.isModelReady)
    #expect(parakeet.status.location != cohere.status.location)
  }

  /// Switching engines must not disturb the Parakeet STATUS that shares the tab
  /// — the "Baixar novamente" button still manages Parakeet and only Parakeet.
  @Test("Choosing Cohere leaves the Parakeet status alone")
  func modelStatusIsUnaffectedByTheChoice() {
    let (presenter, _) = Self.presenter()
    let before = presenter.pane
    presenter.selectEngine(.cohere)
    #expect(presenter.pane.status == before.status)
    #expect(presenter.pane.capacity == before.capacity)
    #expect(presenter.pane.title == ModelPaneStrings.title)
  }

  /// Reported as "quando seleciono um modelo que já foi baixado ele fica
  /// processando como se tivesse baixando novamente". Selecting an engine whose
  /// model is already on disk must say LOADING, never downloading — for Cohere
  /// that wait is 97 s of ANE warm-up with no bytes moving at all.
  @Test("Choosing an engine already on disk loads, it does not download")
  func choosingAnInstalledEngineDoesNotSayDownloading() {
    let (presenter, _) = Self.presenter(cohere: .ready)

    presenter.selectEngine(.cohere)

    #expect(presenter.pane.stage == .loading)
    #expect(presenter.pane.downloadTitle == ModelPaneStrings.loading)
    let title = try! #require(presenter.pane.downloadTitle)
    #expect(!title.lowercased().contains("baix"), "still says downloading: \(title)")
    // Nothing is being fetched, so there is no fraction and no byte detail to
    // show — an indeterminate bar is the honest shape.
    #expect(presenter.pane.progressFraction == nil)
    #expect(presenter.pane.downloadDetail.isEmpty)
  }

  /// THE REGRESSION behind "somente fica Carregando o modelo… e não libera".
  ///
  /// Every stage report crosses to the main actor in its own unstructured Task,
  /// so one spawned just before `prepare()` returned can land AFTER the finish.
  /// Applying it re-showed the stage — and nothing was left to clear it, so the
  /// row stayed on "Carregando o modelo…" forever. A report with no active
  /// preparation must be dropped.
  @Test("A report landing after the finish does not resurrect the bar")
  func lateReportDoesNotResurrectTheBar() {
    let (presenter, _) = Self.presenter(cohere: .ready)
    presenter.selectEngine(.cohere)
    #expect(presenter.pane.stage == .loading)

    presenter.finishEnginePreparation(error: nil)
    #expect(presenter.pane.stage == nil)

    // The straggler — the exact report the race delivers late.
    presenter.reportEnginePreparation(.loading)

    #expect(presenter.pane.stage == nil, "resurrected: the bar will never clear")
    #expect(!presenter.pane.isBusy)
  }

  /// And with nothing selected at all, a stray report shows nothing either.
  @Test("A report with no preparation in progress is ignored")
  func strayReportIsIgnored() {
    let (presenter, _) = Self.presenter()
    presenter.reportEnginePreparation(
      .transferring(ModelDownloadProgress(receivedBytes: 3, totalBytes: 21, unit: .files)))
    #expect(presenter.pane.stage == nil)
  }

  /// The word was fixed once and the SYMBOL still said the opposite: the tab drew
  /// a pulsing download arrow for every stage, plus a "Cancelar" button, so
  /// "Carregando o modelo…" still read as a download. Reported twice.
  @Test("Nothing in the loading row claims a transfer")
  func loadingRowClaimsNoTransfer() {
    let (presenter, _) = Self.presenter(cohere: .ready)
    presenter.selectEngine(.cohere)
    let pane = presenter.pane

    #expect(pane.stage == .loading)
    #expect(pane.isBusy, "the row must still be on screen")
    #expect(!pane.isDownloading, "a load is not a download")
    #expect(pane.progressSymbol == FalaSymbol.processor)
    #expect(pane.progressSymbol != FalaSymbol.download)
    // Nothing to stop, so nothing is offered — a dead "Cancelar" beside a moving
    // bar reads as a transfer the user may not cancel.
    #expect(!pane.isCancelOffered)
    #expect(!pane.isCancelEnabled)
  }

  /// A real transfer keeps every one of those affordances.
  @Test("A real transfer still shows the download arrow and Cancelar")
  func realTransferKeepsItsAffordances() {
    let (presenter, _) = Self.presenter(cohere: .notDownloaded)
    presenter.selectEngine(.cohere)
    presenter.reportEnginePreparation(
      .transferring(ModelDownloadProgress(receivedBytes: 3, totalBytes: 21, unit: .files)))
    let pane = presenter.pane

    #expect(pane.isBusy)
    #expect(pane.isDownloading)
    #expect(pane.progressSymbol == FalaSymbol.download)
    #expect(pane.isCancelOffered)
  }

  /// And the popover's block must agree: it is the surface that said "Baixando
  /// modelo…" for the whole 97 s.
  @Test("The popover block distinguishes loading from downloading")
  func popoverBlockDistinguishesLoading() {
    #expect(!ModelBlock.loading.isDownloading)
    #expect(ModelBlock.loading.isBusy)
    #expect(ModelBlock.loading.symbol == FalaSymbol.processor)
    #expect(ModelBlock.loading.progressFraction == nil)

    let title = ModelBlock.loading.title(engine: "Cohere")
    #expect(title.contains("Cohere"))
    #expect(!title.lowercased().contains("baix"), "still says downloading: \(title)")

    // A real transfer still says so.
    let real = ModelBlock.downloading(ModelDownloadProgress(receivedBytes: 1, totalBytes: 21, unit: .files))
    #expect(real.isDownloading)
    #expect(real.title(engine: "Cohere").lowercased().contains("baix"))
  }

  /// A load cannot be cancelled — there is no transfer to stop, and the CoreML
  /// open plus warm-up have no cancellation check to reach.
  @Test("Loading is not offered as cancellable")
  func loadingIsNotCancellable() {
    #expect(!ModelDownloadStage.loading.isCancellable)
    #expect(ModelDownloadStage.preparing.isCancellable)
  }

  /// If an on-disk copy turns out to be incomplete and real bytes start moving,
  /// the download stages must still take over from `loading`.
  @Test("A real transfer supersedes a loading report")
  func transferSupersedesLoading() {
    #expect(ModelDownloadStage.preparing.supersedes(.loading))
    #expect(ModelDownloadStage.transferring(.unknown).supersedes(.loading))
    #expect(!ModelDownloadStage.loading.supersedes(.preparing))
  }

  /// The bar has to appear on the CLICK, not on the first progress report:
  /// HuggingFace takes seconds to answer, and the user had just picked an engine
  /// and seen nothing happen at all — which is what they reported as "nada
  /// acontece".
  @Test("Choosing an engine whose model is absent shows progress immediately")
  func choosingAnAbsentEngineShowsProgressAtOnce() {
    let (presenter, _) = Self.presenter()
    #expect(presenter.pane.stage == nil)

    presenter.selectEngine(.cohere)

    #expect(presenter.pane.isDownloading)
    #expect(presenter.pane.stage == .preparing)
  }

  /// The regression behind "está preparando um tempo grande e não inicia": the
  /// download WAS running (measured: listing 5 s, then 21 files), but the two
  /// progress properties were `@ObservationIgnored`, so SwiftUI was never told
  /// and the tab stayed frozen on the first state it drew.
  @Test("Progress reports actually change what the pane renders")
  func progressReportsReachThePane() {
    let (presenter, _) = Self.presenter()
    presenter.selectEngine(.cohere)
    #expect(presenter.pane.stage == .preparing)

    presenter.reportEnginePreparation(
      .transferring(ModelDownloadProgress(receivedBytes: 3, totalBytes: 21, unit: .files)))
    #expect(presenter.pane.stage != .preparing)
    #expect(presenter.pane.isDownloading)

    presenter.reportEnginePreparation(.installing)
    #expect(presenter.pane.stage == .installing)
  }

  /// File counts must not be rendered as bytes — that produced "1 byte de 21
  /// bytes" — nor as a percentage, which sits at 5% for as long as the biggest
  /// file takes and reads as a hang.
  @Test("File-count progress renders as files, not bytes or a percentage")
  func fileCountProgressRendersHonestly() {
    let progress = ModelDownloadProgress(receivedBytes: 1, totalBytes: 21, unit: .files)
    #expect(progress.detail == "arquivo 1 de 21")
    #expect(!progress.detail.contains("byte"))

    let bytes = ModelDownloadProgress(receivedBytes: 700_000_000, totalBytes: 1_100_000_000)
    #expect(bytes.detail.contains("de"))
    #expect(!bytes.detail.contains("arquivo"))
  }

  /// And it must go away again, so a finished download does not leave a bar
  /// spinning forever.
  @Test("Finishing preparation clears the bar")
  func finishingPreparationClearsTheBar() {
    let (presenter, _) = Self.presenter()
    presenter.selectEngine(.cohere)
    #expect(presenter.pane.isDownloading)

    presenter.finishEnginePreparation(error: nil)
    #expect(!presenter.pane.isDownloading)
    #expect(presenter.pane.stage == nil)
  }
}

/// A `PreferencesStoring` that keeps values in memory, so a test never writes
/// the shipping keys and changes the developer's own settings.
final class InMemoryPreferencesStore: PreferencesStoring {
  private struct State {
    var engine: TranscriptionEngineChoice
    var engineWrites = 0
  }

  private let state: OSAllocatedUnfairLock<State>

  init(engine: TranscriptionEngineChoice = Preferences.defaultEngine) {
    self.state = OSAllocatedUnfairLock(initialState: State(engine: engine))
  }

  var engineWrites: Int { state.withLock { $0.engineWrites } }

  func loadShowOverlay() -> Bool { Preferences.defaultShowOverlay }
  func saveShowOverlay(_ showOverlay: Bool) {}
  func loadHotkey() -> Hotkey { Preferences.defaultHotkey }
  func saveHotkey(_ hotkey: Hotkey) {}

  func loadEngine() -> TranscriptionEngineChoice { state.withLock { $0.engine } }

  func saveEngine(_ engine: TranscriptionEngineChoice) {
    state.withLock {
      $0.engine = engine
      $0.engineWrites += 1
    }
  }
}
