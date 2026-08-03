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
    let presenter = MenuBarPresenter(dictation: dictation, history: history)
    let pipeline = DictationPipeline(
      presenter: presenter, dictation: dictation, history: history)
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
  private var engine: ParakeetEngine?
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
  /// One instance, shared with the settings window: two `Preferences` objects
  /// would each hold their own copy of the hotkey and silently disagree.
  let preferences = Preferences()
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
    history: DictationHistoryStore
  ) {
    self.presenter = presenter
    self.dictation = dictation
    self.history = history
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
      let engine = ParakeetEngine()
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
  private func prepareModel(_ engine: ParakeetEngine, allowDownload: Bool) {
    let status = ModelStatus.current()
    // On a machine that has never run Fala the model is absent, and returning
    // here left the app in a state where EVERY dictation failed with "A
    // transcrição falhou." and the popover offered no way out — fatal for anyone
    // who received this as a .dmg. Fetch it, and show it being fetched: the
    // popover has a "baixando" variant precisely for this.
    let mustFetch = !status.isPresent
    guard allowDownload || mustFetch || status.isPresent else { return }
    if allowDownload || mustFetch {
      presenter.reportModelProgress(.unknown)
    }
    tasks.append(
      Task { @MainActor [weak self] in
        do {
          try await engine.prepare()
          self?.presenter.clearModelDownload()
        } catch {
          self?.presenter.reportModelFailure()
        }
      })
  }
}
