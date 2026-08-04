import AppKit
import FalaKit
import Foundation

/// The menu-bar application (SPEC.md FR-15, TASKS.md T2.2).
///
/// **What the CLI should call.** `main.swift` is deliberately untouched by this
/// task; add one case to its switch:
///
///     case "menubar":
///       FalaMenuBarApp.run()
///
/// and one line to the usage text ("menubar  app da barra de menus"). `run()`
/// never returns — `NSApplication.run()` owns the process from that point on, so
/// it must be the last thing the CLI does.
///
/// It must be launched from the signed bundle (`./scripts/run-app.sh menubar`).
/// From a terminal, macOS attributes Accessibility to the parent process and the
/// event tap silently never fires — the trap documented in CLAUDE.md.
@MainActor
enum FalaMenuBarApp {
  /// `NSApplication.delegate` is a weak reference, so the delegate has to be
  /// owned by something that outlives the call. Held here rather than in a local,
  /// where an optimised build is free to release it early.
  private static var delegate: MenuBarAppDelegate?

  static func run() -> Never {
    let app = NSApplication.shared
    // LSUIElement in Info.plist covers the bundle. This covers a direct run of
    // `.build/debug/Fala`, which has no Info.plist at all and would otherwise
    // put a Dock icon and a menu on screen for an app that has neither.
    app.setActivationPolicy(.accessory)
    let delegate = MenuBarAppDelegate()
    Self.delegate = delegate
    app.delegate = delegate
    app.run()
    // Only reached if the run loop stops without terminating the process.
    exit(EXIT_SUCCESS)
  }
}

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
  private var controller: MenuBarController?
  private var pipeline: DictationPipeline?
  private var settings: SettingsWindowBuilder?
  private var historyWindow: HistoryWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // NFR-4, FIRST: before the microphone prompt and before any model download.
    // A refused machine must be told why rather than led through a TCC dialog and
    // a 480 MB fetch that can never work.
    if let refusal = HostPlatform().refusal {
      // The app is .accessory/LSUIElement, so without activating first the modal
      // can open behind other windows and a user who just double-clicked sees
      // nothing happen at all.
      NSApp.activate(ignoringOtherApps: true)
      let alert = NSAlert()
      alert.messageText = refusal.title
      alert.informativeText = refusal.explanation
      alert.alertStyle = .critical
      alert.runModal()
      NSApp.terminate(nil)
      return
    }

    let dictation = DictationSwitch()
    // One store, shared: the pipeline writes to it and the popover reads from it.
    // Two instances would render an empty "Recentes" over a populated file.
    let history = DictationHistoryStore()
    // ONE instance, shared by the pipeline, the popover and the settings window.
    // Two would each hold their own engine and hotkey and silently disagree.
    let preferences = Preferences()
    // The SELECTED engine's readiness, not always Parakeet's. Reporting the
    // wrong engine's directory is the same class of lie as the "pronto · Zero
    // KB" that `ModelReadiness` was introduced to prevent.
    let presenter = MenuBarPresenter(
      dictation: dictation,
      modelStatus: { ModelStatus.current(preferences.engine.modelLayout) },
      // Read from the SAME preference as the status above. The name was a
      // constant, so with Cohere selected the popover reported "Modelo Parakeet
      // · pronto" over a directory it had measured in Cohere's folder.
      engineName: { preferences.engine.shortName },
      history: history)
    let pipeline = DictationPipeline(
      presenter: presenter, dictation: dictation, history: history,
      preferences: preferences)
    self.pipeline = pipeline

    // T2.11 / T2.12. Both windows are built lazily on first open: constructing
    // them here would do synchronous disk reads (model directory, dictionary
    // files, volume capacity) on the main actor at launch, for windows most
    // launches never open.
    let settings = SettingsWindowBuilder(pipeline: pipeline)
    let historyWindow = HistoryWindowController(model: HistoryWindowModel(history: history))
    self.settings = settings
    self.historyWindow = historyWindow

    var actions = MenuBarActions()
    actions.retryModelDownload = { [weak pipeline] in
      pipeline?.retryModelPreparation()
    }
    actions.openSettings = { settings.show() }
    actions.openHistory = { historyWindow.show() }
    self.controller = MenuBarController(presenter: presenter, actions: actions)

    Task { await presenter.refresh() }
    pipeline.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Releases the hotkey and uninstalls the event tap. Without it a crash-free
    // quit can still leave the tap registered for the lifetime of the session.
    pipeline?.stop()
  }
}

/// Hotkey → coordinator, with the on/off switch in the middle.
///
/// This is what makes the popover's toggle real: every phase from
/// `HotkeyManager` passes through `CaptureGate` before it can reach
/// `DictationCoordinator`, so "desativado" means `AudioCapture.start()` is never
/// called — not that a control is greyed out.
@MainActor
final class DictationPipeline {
  private let presenter: MenuBarPresenter
  private let dictation: DictationSwitch
  private var gate = CaptureGate()
  private var hotkey: HotkeyManager?
  /// `any TranscriptionEngine`, not `ParakeetEngine`: the user can pick the
  /// engine in Ajustes › Modelo, and the whole point of the protocol is that
  /// nothing above it needs to know which one is loaded.
  private var engine: (any TranscriptionEngine)?
  /// Held for the process lifetime: the panel is the only surface that shows a
  /// failed or blocked dictation, and releasing it would take the window with it.
  private var overlay: PillOverlayController?
  /// FR-17 history, shared with the popover so both see the same entries.
  private let history: DictationHistoryStore
  /// FR-18 device tracking, held for the process lifetime.
  private var devices: InputDeviceCenter?
  /// Retained so the settings window's level meter can observe the SAME capture
  /// object the pipeline dictates with. Building a second `AudioCapture` for the
  /// meter would put two `AVAudioEngine`s on one microphone — the stacked-instance
  /// failure recorded in docs/architecture.md.
  private var capture: AudioCapture?
  /// Injected, not built here: the popover and the settings window read the
  /// same object, and two instances would silently disagree about the hotkey
  /// and the engine.
  let preferences: Preferences
  /// Retained so a hotkey change can re-point a fresh tap at the same flow.
  private var coordinator: DictationCoordinator?
  private var hotkeyTask: Task<Void, Never>?
  private var isHotkeySuppressed = false

  /// Exposed for the settings window (T2.11). Both are nil until Accessibility is
  /// granted and `bootstrap()` has run, which is exactly when the Áudio tab has
  /// nothing to show anyway.
  var deviceCenter: InputDeviceCenter? { devices }
  var levelMonitor: (any AudioLevelMonitoring)? { capture }
  private var tasks: [Task<Void, Never>] = []

  init(
    presenter: MenuBarPresenter,
    dictation: DictationSwitch,
    history: DictationHistoryStore,
    preferences: Preferences
  ) {
    self.presenter = presenter
    self.dictation = dictation
    self.history = history
    self.preferences = preferences
  }

  func start() {
    tasks.append(Task { @MainActor [weak self] in await self?.bootstrap() })
  }

  func stop() {
    for task in tasks { task.cancel() }
    tasks.removeAll()
    hotkey?.shutdown()
    hotkey = nil
    devices?.stop()
  }

  /// Swaps the transcription engine (Ajustes › Modelo).
  ///
  /// Applies to the NEXT dictation: one already in flight keeps the engine it
  /// started with, so a mid-utterance switch cannot produce a transcript stitched
  /// from two models. Loading is deferred to `prepareModel`, which is also what
  /// puts the first-run download behind the popover's "baixando" state.
  func applyEngine(_ choice: TranscriptionEngineChoice) {
    guard let coordinator else { return }
    let engine = choice.makeEngine()
    self.engine = engine
    Task { await coordinator.setEngine(engine) }

    // Reported to BOTH surfaces. The popover has always had a model block; the
    // settings window is where the user actually clicked, and showing nothing
    // there is what made picking an engine look like a no-op while a
    // several-hundred-megabyte download was running.
    // Decided ONCE, before anything starts: is this a download or just a load?
    //
    // FluidAudio runs its listing/`downloading(21/21)` sequence either way — with
    // the files already there it is a existence check that completes instantly —
    // so its stages cannot answer this. Reporting them verbatim made selecting
    // an engine you already have look like it was re-fetching 4,98 GB, when the
    // time was really Cohere's 97 s ANE warm-up.
    let isInstalled = ModelStatus.current(choice.modelLayout).isPresent
    let epoch = beginModelActivity()
    if isInstalled {
      presenter.reportModelLoading()
    } else {
      presenter.reportModelProgress(.unknown)
    }
    // The progress handler is called off the main actor, so it hops back rather
    // than capturing `self` across isolation domains. Each hop is its own
    // unstructured Task, so "later" is undefined between them and the finish —
    // which is why every path below re-checks the epoch on the main actor.
    let report: @Sendable (ModelDownloadStage) -> Void = { [weak self] stage in
      Task { @MainActor in
        guard let self, self.activeModelEpoch == epoch else { return }
        guard !isInstalled else {
          // Nothing is being fetched; the stages below would only misdescribe it.
          self.presenter.updateModelLoading()
          self.onEnginePreparation?(.loading)
          return
        }
        // The popover's block only understands a byte-ish progress; the stage's
        // own `progress` is `.unknown` outside `.transferring`, which draws an
        // indeterminate bar instead of a frozen 0%.
        self.presenter.updateModelProgress(stage.progress)
        self.onEnginePreparation?(stage)
      }
    }

    tasks.append(
      Task { @MainActor [weak self] in
        do {
          try await engine.prepare(onStage: report)
          guard let self, self.endModelActivity(epoch) else { return }
          self.presenter.clearModelDownload()
          self.onEnginePreparationFinished?(nil)
        } catch {
          guard let self, self.endModelActivity(epoch) else { return }
          self.presenter.reportModelFailure()
          self.onEnginePreparationFinished?(ModelPaneStrings.preparationFailed)
        }
      })
  }

  /// Identity of the model activity currently allowed to touch the indicators.
  ///
  /// Bumped when a preparation starts, cleared when THAT preparation finishes.
  /// Two orderings need it: a report Task that lands after its own finish (the
  /// "Carregando o modelo… e não libera" report — the resurrected stage had no
  /// finish left to clear it), and a launch-time `prepareModel` completing after
  /// the user already switched engines, where the old finish would wipe the new
  /// preparation's bar mid-run.
  private var modelActivityEpoch = 0
  private var activeModelEpoch: Int?

  private func beginModelActivity() -> Int {
    modelActivityEpoch += 1
    activeModelEpoch = modelActivityEpoch
    return modelActivityEpoch
  }

  /// True while `epoch` is still the activity on screen; ends it when finishing.
  private func endModelActivity(_ epoch: Int) -> Bool {
    guard activeModelEpoch == epoch else { return false }
    activeModelEpoch = nil
    return true
  }

  /// Set by `SettingsWindowBuilder` so the Modelo tab can draw the same bar.
  var onEnginePreparation: (@MainActor (ModelDownloadStage) -> Void)?
  var onEnginePreparationFinished: (@MainActor (String?) -> Void)?

  /// Reinstalls the event tap on a new key (Ajustes › Geral).
  ///
  /// A live `CGEventTap` cannot be retargeted, so the manager is torn down and
  /// rebuilt. `shutdown()` publishes a release first, so a key held at the moment
  /// of the swap cannot leave the microphone recording.
  func applyHotkey(_ hotkey: Hotkey) {
    guard let coordinator else { return }
    hotkeyTask?.cancel()
    self.hotkeyTask = nil
    self.hotkey?.shutdown()
    self.hotkey = nil

    let manager = HotkeyManager(hotkey: hotkey)
    do {
      try manager.start()
    } catch {
      // Accessibility was revoked between launch and now; the popover's banner
      // is the surface for that.
      Task { @MainActor [weak self] in await self?.presenter.refresh() }
      return
    }
    self.hotkey = manager
    // The pill's keycap is the instruction for how to dictate; leaving it on the
    // old key tells the user to press something that no longer works.
    overlay?.setHotkey(hotkey)
    let task = forwardingTask(from: manager, to: coordinator)
    hotkeyTask = task
    tasks.append(task)
  }

  /// Suppresses the live hotkey while the recorder in Ajustes is listening.
  ///
  /// Without this the currently-assigned key is still armed, so pressing it at
  /// the recorder starts a real dictation behind the settings window.
  func setHotkeySuppressed(_ suppressed: Bool) {
    isHotkeySuppressed = suppressed
  }

  /// FR-21's "Mostrar overlay durante o ditado".
  func setOverlayEnabled(_ enabled: Bool) {
    overlay?.setSuppressed(!enabled)
  }

  /// Rebuilds the coordinator's dictionary after an edit in Ajustes › Dicionário,
  /// so a term added there takes effect on the NEXT dictation rather than after a
  /// relaunch.
  func applyDictionary(_ dictionary: JargonDictionary) {
    guard let coordinator else { return }
    Task { await coordinator.setDictionary(dictionary) }
  }

  /// "Tentar novamente" on the model block.
  func retryModelPreparation() {
    guard let engine else { return }
    prepareModel(engine, allowDownload: true)
  }

  private func bootstrap() async {
    let permissions = SystemPermissionChecker()
    if !permissions.isGranted(.microphone) {
      _ = await permissions.requestMicrophoneAccess()
    }
    await presenter.refresh()

    // Without Accessibility there is no event tap, so there is nothing to start.
    // The popover's banner is already telling the user exactly that, and
    // `showPopover` refreshes it, so granting the permission and reopening the
    // popover is the recovery path.
    guard permissions.isGranted(.accessibility) else { return }

    do {
      // FR-18: bind the chosen microphone and follow route changes, so an HFP
      // headset raises the pill's warning instead of silently degrading the audio.
      let devices = InputDeviceCenter()
      devices.start()
      self.devices = devices

      let capture = try AudioCapture(inputDevice: devices.captureSelection)
      self.capture = capture
      let engine = preferences.engine.makeEngine()
      self.engine = engine
      // FR-9: the user's override file wins over the bundled default. Falls back
      // to the bundled dictionary when the user's file is unusable, so a typo in
      // it degrades dictation quality instead of breaking dictation.
      let dictionary =
        (try? JargonDictionaryStore().load())?.dictionary
        ?? (try? JargonDictionary.loadDefault())

      let coordinator = DictationCoordinator(
        capture: capture,
        engine: engine,
        // FR-12/FR-14: picks clipboard or typing per app, and falls back to
        // typing when the clipboard holds content it cannot restore — without
        // this, a copied spreadsheet range blocks every dictation.
        injector: AdaptiveTextInjector(),
        dictionary: dictionary,
        history: history)

      // FR-16: without this the six states have no visible surface at all — a
      // blocked injection (US-3) would fail silently, since the status icon
      // deliberately collapses success/failure to idle.
      let overlay = PillOverlayController(hotkey: preferences.hotkey)
      overlay.attach(to: coordinator)
      self.overlay = overlay

      presenter.observe(await coordinator.states())

      // The same status lines `Fala run` writes, from the mode people actually
      // use. Without this a failed dictation in the menu-bar app left NO record
      // anywhere: the pill shows the message for a few seconds and then it is
      // gone, and nothing about a dictation may be logged in `FalaKit`. So the
      // one report we could get was "an error appeared", with no way to tell
      // which of six messages it was.
      //
      // States and messages only — never the transcript, never audio
      // (CLAUDE.md). `DictationState` carries neither.
      tasks.append(
        Task { [states = await coordinator.states()] in
          for await state in states {
            switch state {
            case .recording: say("● gravando…")
            case .transcribing(let seconds):
              say(String(format: "… transcrevendo (%.1fs capturados)", seconds))
            case .success: say("✓ inserido")
            case .failure(let message): say("✗ \(message)")
            case .idle: break
            }
          }
        })

      prepareModel(engine, allowDownload: false)

      // FR-1: honour the user's choice. This read used to be missing entirely,
      // so `HotkeyManager()` always installed the DEFAULT key and changing the
      // hotkey in Ajustes had no effect — not on the running app, and not even
      // after a relaunch.
      let manager = HotkeyManager(hotkey: preferences.hotkey)
      try manager.start()
      hotkey = manager
      self.coordinator = coordinator
      let forwarding = forwardingTask(from: manager, to: coordinator)
      hotkeyTask = forwarding
      tasks.append(forwarding)
    } catch {
      // The two constructors that can fail here — the audio engine and the event
      // tap — both fail for permission-shaped reasons, and a refresh is what
      // brings the banner back. KNOWN GAP: a failure with any other cause has no
      // surface in this popover yet (there is no error slot in the mockup).
      await presenter.refresh()
    }
  }

  private func forwardingTask(
    from manager: HotkeyManager,
    to coordinator: DictationCoordinator
  ) -> Task<Void, Never> {
    Task { @MainActor [weak self] in
      for await phase in manager.phases {
        guard let self else { return }
        // Suppressed while the hotkey recorder is listening.
        guard !self.isHotkeySuppressed else { continue }
        guard
          let admitted = self.gate.admit(phase, dictationEnabled: self.dictation.isEnabled)
        else { continue }
        await coordinator.handle(admitted)
      }
    }
  }

  /// Loads the model into the ANE.
  ///
  /// `allowDownload` is false at launch on purpose: the model is ~1.1 GB, and
  /// FluidAudio exposes no download progress, so fetching it unasked would be a
  /// silent multi-minute stall behind a popover that says nothing. Absent, the
  /// block reads "baixa no primeiro uso" and the first dictation pays the cost —
  /// the same contract `Fala doctor` already states.
  private func prepareModel(_ engine: any TranscriptionEngine, allowDownload: Bool) {
    // The SELECTED engine's directory. Reading Parakeet's while Cohere is chosen
    // would gate a download on the wrong model — and report "pronto" for one the
    // user never fetched.
    let status = ModelStatus.current(preferences.engine.modelLayout)
    // On a machine that has never run Fala the model is absent, and returning
    // here left the app in a state where EVERY dictation failed with "A
    // transcrição falhou." and the popover offered no way out — fatal for anyone
    // who received this as a .dmg. Fetch it, and show it being fetched: the
    // popover has a "baixando" variant precisely for this.
    let mustFetch = !status.isPresent
    guard allowDownload || mustFetch || status.isPresent else { return }
    // Reported even when nothing is downloaded. LOADING is the slow part now:
    // Cohere's `prepare()` measures 97 s on a machine that already holds the
    // model, because of the ANE warm-up, and it is paid at every launch. The
    // condition here used to be `allowDownload || mustFetch`, so that whole
    // minute and a half passed behind a popover saying nothing at all.
    // Same distinction as `applyEngine`: at launch the model is usually already
    // there, and the wait is the load, not a transfer.
    let epoch = beginModelActivity()
    if mustFetch {
      presenter.reportModelProgress(.unknown)
    } else {
      presenter.reportModelLoading()
    }
    tasks.append(
      Task { @MainActor [weak self] in
        do {
          try await engine.prepare()
          // The user may have switched engines while this launch-time load ran;
          // clearing then would wipe the NEW preparation's bar mid-run.
          guard let self, self.endModelActivity(epoch) else { return }
          self.presenter.clearModelDownload()
        } catch {
          guard let self, self.endModelActivity(epoch) else { return }
          self.presenter.reportModelFailure()
        }
      })
  }
}
