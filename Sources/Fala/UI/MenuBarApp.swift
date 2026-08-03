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

  func applicationDidFinishLaunching(_ notification: Notification) {
    let dictation = DictationSwitch()
    // One store, shared: the pipeline writes to it and the popover reads from it.
    // Two instances would render an empty "Recentes" over a populated file.
    let history = DictationHistoryStore()
    let presenter = MenuBarPresenter(dictation: dictation, history: history)
    let pipeline = DictationPipeline(
      presenter: presenter, dictation: dictation, history: history)
    self.pipeline = pipeline

    var actions = MenuBarActions()
    actions.retryModelDownload = { [weak pipeline] in
      pipeline?.retryModelPreparation()
    }
    // openSettings (T2.6+) and openHistory (T2.5) have no surface yet, so their
    // rows stay visibly disabled instead of silently doing nothing.
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
      let overlay = PillOverlayController()
      overlay.attach(to: coordinator)
      self.overlay = overlay

      presenter.observe(await coordinator.states())
      prepareModel(engine, allowDownload: false)

      let manager = HotkeyManager()
      try manager.start()
      hotkey = manager
      tasks.append(forwardingTask(from: manager, to: coordinator))
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
    guard allowDownload || ModelStatus.current().isPresent else { return }
    if allowDownload {
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
