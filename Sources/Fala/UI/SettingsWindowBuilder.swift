import AppKit
import FalaKit

/// Builds the settings window the first time it is asked for, and reuses it after.
///
/// Lazy on purpose. Every settings presenter does synchronous disk work in its
/// initialiser — `ModelStatus.current()` enumerates the model directory,
/// `VolumeCapacity` stats the volume, `DictionaryPanePresenter.reload()` reads the
/// bundled JSON and the user's override, `LaunchAtLoginModel` asks
/// `SMAppService` — and the whole SwiftUI graph gets built with them. Doing that
/// in `applicationDidFinishLaunching` is main-thread latency at every launch for a
/// window most launches never open (NFR-3: never block the main thread).
@MainActor
final class SettingsWindowBuilder {
  private weak var pipeline: DictationPipeline?
  private var controller: SettingsWindowController?

  init(pipeline: DictationPipeline) {
    self.pipeline = pipeline
  }

  func show() {
    if let controller {
      controller.show()
      return
    }
    let built = make()
    controller = built
    built.show()
  }

  private func make() -> SettingsWindowController {
    // The pipeline's instance, not a fresh one: two `Preferences` objects would
    // each hold their own hotkey and silently disagree about which is current.
    let preferences = pipeline?.preferences ?? Preferences()

    var actions = SettingsActions()
    // Without this the recorder wrote the preference and nothing acted on it —
    // changing the hotkey in Ajustes appeared to work and did nothing.
    actions.hotkeyChanged = { [weak pipeline] hotkey in
      pipeline?.applyHotkey(hotkey)
    }
    // The currently-assigned hotkey is still live while the recorder listens, so
    // without this, pressing keys at the recorder starts a real dictation.
    actions.hotkeyRecordingChanged = { [weak pipeline] isRecording in
      pipeline?.setHotkeySuppressed(isRecording)
    }
    actions.showOverlayChanged = { [weak pipeline] isOn in
      pipeline?.setOverlayEnabled(isOn)
    }
    actions.dictionaryChanged = { [weak pipeline] dictionary in
      pipeline?.applyDictionary(dictionary)
    }
    // Without this the picker persists the choice and nothing acts on it until
    // the next launch — and the pane's caption honestly says so when it is nil.
    actions.engineChanged = { [weak pipeline] choice in
      pipeline?.applyEngine(choice)
    }
    actions.openURL = { NSWorkspace.shared.open($0) }

    // Same bar, drawn where the user clicked. Without these two the Modelo tab
    // showed nothing while the engine's model downloaded, so picking Cohere
    // looked like a no-op.
    let modelPresenter = ModelPanePresenter(preferences: preferences)
    pipeline?.onEnginePreparation = { [weak modelPresenter] stage in
      modelPresenter?.reportEnginePreparation(stage)
    }
    pipeline?.onEnginePreparationFinished = { [weak modelPresenter] failure in
      modelPresenter?.finishEnginePreparation(error: failure)
    }

    let controller = SettingsWindowController(
      general: GeneralPanePresenter(
        preferences: preferences, launch: LaunchAtLoginModel()),
      // The SAME AudioCapture the pipeline dictates with. A second one would put
      // two AVAudioEngines on one device — the stacked-instance failure recorded
      // in docs/architecture.md, which cost an evening of debugging.
      audio: AudioPanePresenter(
        devices: pipeline?.deviceCenter ?? InputDeviceCenter(),
        monitor: pipeline?.levelMonitor),
      dictionary: DictionaryPanePresenter(),
      model: modelPresenter,
      actions: actions)
    return controller
  }
}
