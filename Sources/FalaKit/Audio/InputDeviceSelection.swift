// Choosing a microphone, remembering the choice, and telling the app when the
// route changes (SPEC.md FR-18, US-4; TASKS.md T2.6).
//
// The settings window that will drive this does not exist yet (DESIGN-HANDOFF.md
// "Ajustes › Áudio"). What is here is everything BELOW that window: the choice as
// a value, where it is stored, how it resolves against the devices actually
// attached, and the one seam `AudioCapture` uses to honour it.

import Foundation
import Observation

// MARK: - Choice

/// What the user picked in Ajustes › Áudio.
public enum InputDeviceChoice: Sendable, Equatable {
  /// Follow whatever macOS is using. The default, and the only sane one before
  /// the user has ever opened settings.
  case systemDefault
  /// A specific device, identified by its stable UID.
  ///
  /// `name` is carried alongside purely so the app can say WHICH microphone is
  /// missing when it is unplugged — by then the device is gone and there is
  /// nothing left to look the name up in.
  case device(uid: String, name: String?)

  public var uid: String? {
    guard case .device(let uid, _) = self else { return nil }
    return uid
  }

  public var name: String? {
    guard case .device(_, let name) = self else { return nil }
    return name
  }

  public init(_ device: InputDevice) {
    self = .device(uid: device.id, name: device.name)
  }
}

// MARK: - Resolution

/// A choice, resolved against the devices attached right now.
public enum InputDeviceResolution: Sendable, Equatable {
  /// Following the system default. The payload is `nil` when the Mac has no
  /// input device at all.
  case systemDefault(InputDevice?)
  /// The chosen device is attached and will be used.
  case selected(InputDevice)
  /// The chosen device is not attached. Dictation still works, on the system
  /// default — refusing to record because a microphone was unplugged would be a
  /// worse answer than recording from the one that IS there and saying so.
  case unavailable(choice: InputDeviceChoice, fallback: InputDevice?)

  public static func resolve(
    _ choice: InputDeviceChoice, in devices: [InputDevice]
  ) -> InputDeviceResolution {
    // Strictly the device the HAL flagged: if nothing is flagged there is no
    // default input, and guessing "the first one" would attribute a warning to a
    // microphone that is not being recorded from.
    let systemDefault = devices.first(where: \.isDefault)
    guard let uid = choice.uid else { return .systemDefault(systemDefault) }
    guard let match = devices.first(where: { $0.id == uid }) else {
      return .unavailable(choice: choice, fallback: systemDefault)
    }
    return .selected(match)
  }

  /// The device audio will actually come from.
  public var device: InputDevice? {
    switch self {
    case .systemDefault(let device): return device
    case .selected(let device): return device
    case .unavailable(_, let fallback): return fallback
    }
  }

  /// Whether `AudioCapture` has to bind to a specific device, or can let
  /// `AVAudioEngine` follow the system default as it always has.
  public var explicitDeviceID: UInt32? {
    guard case .selected(let device) = self else { return nil }
    return device.hardwareID
  }

  /// The route this resolution produces, warning included.
  public var route: InputRoute {
    switch self {
    case .systemDefault(let device):
      return InputRoute(device: device)
    case .selected(let device):
      return InputRoute(device: device)
    case .unavailable(let choice, let fallback):
      return InputRoute(
        device: fallback,
        substitutionNotice: InputDeviceStrings.selectionUnavailable(device: choice.name))
    }
  }
}

// MARK: - Persistence

/// Where the chosen microphone survives a relaunch.
///
/// Behind a protocol for the same reason `DictationEnabledStoring` is: a test
/// that wrote the shipping key would silently change which microphone the
/// developer's own app records from.
public protocol InputDeviceSelectionStoring: Sendable {
  func loadChoice() -> InputDeviceChoice
  func save(_ choice: InputDeviceChoice)
}

public struct UserDefaultsInputDeviceStore: InputDeviceSelectionStoring {
  private static let uidKey = "fala.inputDevice.uid"
  private static let nameKey = "fala.inputDevice.name"

  /// Stored as a name rather than as a `UserDefaults` instance so this type is
  /// genuinely `Sendable` — `AudioCapture` is an actor and reads the choice from
  /// its own isolation, so a main-actor store (the shape `DictationSwitch` uses)
  /// would not work here.
  private let suiteName: String?

  public init(suiteName: String? = nil) {
    self.suiteName = suiteName
  }

  private var defaults: UserDefaults {
    guard let suiteName, let suite = UserDefaults(suiteName: suiteName) else {
      return .standard
    }
    return suite
  }

  public func loadChoice() -> InputDeviceChoice {
    let defaults = defaults
    guard let uid = defaults.string(forKey: Self.uidKey), !uid.isEmpty else {
      return .systemDefault
    }
    let name = defaults.string(forKey: Self.nameKey)
    return .device(uid: uid, name: name?.isEmpty == true ? nil : name)
  }

  public func save(_ choice: InputDeviceChoice) {
    let defaults = defaults
    guard let uid = choice.uid else {
      defaults.removeObject(forKey: Self.uidKey)
      defaults.removeObject(forKey: Self.nameKey)
      return
    }
    defaults.set(uid, forKey: Self.uidKey)
    if let name = choice.name, !name.isEmpty {
      defaults.set(name, forKey: Self.nameKey)
    } else {
      defaults.removeObject(forKey: Self.nameKey)
    }
  }
}

// MARK: - The capture seam

/// What `AudioCapture` asks, immediately before it starts an engine.
///
/// Deliberately synchronous, `Sendable` and free of any state of its own: it is
/// called from inside the capture actor, once per utterance, and answering it
/// must not require hopping to another isolation domain in the middle of a
/// push-to-talk gesture.
public protocol InputDeviceSelecting: Sendable {
  /// The CoreAudio `AudioDeviceID` to bind to, or `nil` to leave `AVAudioEngine`
  /// on the system default.
  ///
  /// Returns `nil` when the chosen device is not attached: falling back to the
  /// system default is what every other macOS app does, and the missing device
  /// is already reported through `InputRoute.substitutionNotice`.
  func currentInputDeviceID() -> UInt32?
}

/// The shipping `InputDeviceSelecting`: read the saved choice, resolve it against
/// the HAL, hand back an ID.
///
/// No cached state, so it cannot go stale: a device unplugged between two
/// dictations is noticed on the next one.
public struct StoredInputDeviceSelection: InputDeviceSelecting {
  private let store: any InputDeviceSelectionStoring
  private let catalog: any InputDeviceCataloging

  public init(
    store: any InputDeviceSelectionStoring = UserDefaultsInputDeviceStore(),
    catalog: any InputDeviceCataloging = CoreAudioInputDeviceCatalog()
  ) {
    self.store = store
    self.catalog = catalog
  }

  public func currentInputDeviceID() -> UInt32? {
    let choice = store.loadChoice()
    guard choice.uid != nil else { return nil }
    let devices = (try? catalog.inputDevices()) ?? []
    return InputDeviceResolution.resolve(choice, in: devices).explicitDeviceID
  }
}

// MARK: - Center

/// The one object the app holds: which microphones exist, which one is chosen,
/// what the current route is, and a stream that fires when any of that changes.
///
/// Main-actor because everything that consumes it is — the pill overlay
/// controller and, later, Ajustes › Áudio. The capture side does NOT go through
/// here: it uses `captureSelection`, which is `Sendable` and reads the same
/// store, so `AudioCapture` never has to await the main actor mid-gesture.
@MainActor
@Observable
public final class InputDeviceCenter {
  public private(set) var devices: [InputDevice] = []
  public private(set) var route: InputRoute = .none
  public private(set) var choice: InputDeviceChoice

  /// The amber row / warning pill, or `nil` when the route is fine.
  public var warning: AudioRouteWarning? { route.warning }

  /// What `AudioCapture(inputDevice:)` takes. `nonisolated` so it can be handed
  /// to the capture actor without crossing back to the main actor.
  public nonisolated let captureSelection: StoredInputDeviceSelection

  @ObservationIgnored private let catalog: any InputDeviceCataloging
  @ObservationIgnored private let watcher: any InputDeviceChangeWatching
  @ObservationIgnored private let store: any InputDeviceSelectionStoring
  @ObservationIgnored private var watchTask: Task<Void, Never>?
  @ObservationIgnored
  private var continuations: [UUID: AsyncStream<InputRoute>.Continuation] = [:]

  public init(
    catalog: any InputDeviceCataloging = CoreAudioInputDeviceCatalog(),
    watcher: any InputDeviceChangeWatching = CoreAudioInputDeviceWatcher(),
    store: any InputDeviceSelectionStoring = UserDefaultsInputDeviceStore()
  ) {
    self.catalog = catalog
    self.watcher = watcher
    self.store = store
    self.choice = store.loadChoice()
    self.captureSelection = StoredInputDeviceSelection(store: store, catalog: catalog)
  }

  /// Reads the hardware once and then follows it. Idempotent.
  public func start() {
    refresh()
    guard watchTask == nil else { return }
    watchTask = Task { [weak self] in
      guard let changes = self?.watcher.changes() else { return }
      for await _ in changes {
        guard let self else { return }
        self.refresh()
      }
    }
  }

  /// Stops following the hardware and closes every route stream.
  public func stop() {
    watchTask?.cancel()
    watchTask = nil
    for continuation in continuations.values { continuation.finish() }
    continuations.removeAll()
  }

  /// Re-reads the device list and republishes the route if it changed.
  public func refresh() {
    devices = (try? catalog.inputDevices()) ?? []
    publish(InputDeviceResolution.resolve(choice, in: devices).route)
  }

  /// Picks a microphone and remembers it. Takes effect on the next dictation —
  /// `AudioCapture` binds the device when it starts an engine, and changing it
  /// mid-utterance would truncate the recording in progress.
  public func select(_ choice: InputDeviceChoice) {
    guard choice != self.choice else { return }
    self.choice = choice
    store.save(choice)
    refresh()
  }

  public func select(_ device: InputDevice) {
    select(InputDeviceChoice(device))
  }

  /// The current route, then one value per change — the same contract
  /// `DictationCoordinator.states()` has, so the overlay wiring reads the same.
  ///
  /// Deduplicated: the HAL happily fires several notifications for one physical
  /// event, and a pill that rebuilt itself on each of them would flicker.
  public func routes() -> AsyncStream<InputRoute> {
    AsyncStream { continuation in
      let id = UUID()
      continuations[id] = continuation
      continuation.yield(route)
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in self?.continuations[id] = nil }
      }
    }
  }

  private func publish(_ next: InputRoute) {
    guard next != route else { return }
    route = next
    for continuation in continuations.values { continuation.yield(next) }
  }
}
