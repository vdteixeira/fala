// The CoreAudio HAL layer for input-device selection (SPEC.md FR-18, T2.6).
//
// Everything here talks to hardware, so everything here is behind a protocol and
// none of it is unit-testable on a machine without the device in question. The
// DECISIONS — what counts as a hands-free route, which device a saved choice
// resolves to, what the user is told — live in `InputDevice.swift` and
// `InputDeviceSelection.swift`, which have no CoreAudio in them at all.
//
// Nothing in this file logs. Device names and UIDs are read to be rendered.

import CoreAudio
import Foundation
import os

// MARK: - Errors

public enum InputDeviceError: Error, Equatable, Sendable {
  /// A HAL property could not be read. Carries the CoreAudio status so a report
  /// can be diagnosed; carries no device name, because a failure to enumerate is
  /// not tied to one device.
  case propertyUnavailable(property: String, status: Int32)
}

// MARK: - Seams

/// Enumerates the microphones the user could dictate through.
///
/// Behind a protocol so tests drive a fixed device list — including devices this
/// machine has never had attached, which is the only way the HFP rule can be
/// tested at all.
public protocol InputDeviceCataloging: Sendable {
  /// Every device with at least one input channel, in the HAL's own order.
  /// Exactly one has `isDefault == true`, unless the Mac has no input at all.
  func inputDevices() throws -> [InputDevice]
}

/// Tells its consumer that something about the audio hardware changed — a device
/// arrived or left, the default input moved, or a device's sample rate changed
/// underneath us (which is what a Bluetooth link switching into the hands-free
/// profile looks like from here).
///
/// `Void` on purpose: the watcher's job is to say "look again", not to decide
/// what changed. Re-reading the catalog is cheap, and it keeps the CoreAudio
/// layer free of any policy.
public protocol InputDeviceChangeWatching: Sendable {
  /// Emits once per change. Never finishes on its own; stops watching when the
  /// stream's iteration ends.
  func changes() -> AsyncStream<Void>
}

// MARK: - HAL helpers

/// Thin, typed reads of `AudioObjectGetPropertyData`. Free of policy.
enum CoreAudioHAL {
  static let systemObject = AudioObjectID(kAudioObjectSystemObject)

  static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  static func string(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> String? {
    var address = address(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString?
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    return value as String
  }

  static func uint32(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> UInt32? {
    var address = address(selector)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var value: UInt32 = 0
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    else { return nil }
    return value
  }

  static func double(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> Double? {
    var address = address(selector)
    var size = UInt32(MemoryLayout<Float64>.size)
    var value: Float64 = 0
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    else { return nil }
    return Double(value)
  }

  /// The top of `kAudioDevicePropertyAvailableNominalSampleRates`.
  static func highestSampleRate(_ object: AudioObjectID) -> Double {
    var address = address(kAudioDevicePropertyAvailableNominalSampleRates)
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
      size >= UInt32(MemoryLayout<AudioValueRange>.size)
    else { return 0 }
    var ranges = [AudioValueRange](
      repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
      count: Int(size) / MemoryLayout<AudioValueRange>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ranges) == noErr
    else { return 0 }
    return ranges.map(\.mMaximum).max() ?? 0
  }

  /// Total input channels. Zero means "this is an output-only device", which is
  /// how a device that cannot be a microphone is filtered out — reading the name
  /// and guessing would be the alternative.
  static func inputChannelCount(_ object: AudioObjectID) -> Int {
    var address = address(
      kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0
    else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw) == noErr
    else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(
      raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  static func deviceIDs() throws -> [AudioObjectID] {
    var address = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
    guard status == noErr else {
      throw InputDeviceError.propertyUnavailable(property: "devices", status: status)
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: count)
    status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids)
    guard status == noErr else {
      throw InputDeviceError.propertyUnavailable(property: "devices", status: status)
    }
    return ids
  }

  static func defaultInputDeviceID() -> AudioObjectID? {
    guard let id = uint32(systemObject, kAudioHardwarePropertyDefaultInputDevice),
      id != AudioObjectID(kAudioObjectUnknown)
    else { return nil }
    return id
  }
}

// MARK: - Catalog

/// The real catalog, reading the CoreAudio HAL.
public struct CoreAudioInputDeviceCatalog: InputDeviceCataloging {
  public init() {}

  public func inputDevices() throws -> [InputDevice] {
    let defaultID = CoreAudioHAL.defaultInputDeviceID()
    return try CoreAudioHAL.deviceIDs().compactMap { id in
      let channels = CoreAudioHAL.inputChannelCount(id)
      guard channels > 0 else { return nil }
      // A device with no UID cannot be persisted or resolved later, so it is not
      // offerable as a choice. In practice every real device has one.
      guard let uid = CoreAudioHAL.string(id, kAudioDevicePropertyDeviceUID),
        !uid.isEmpty
      else { return nil }
      let name =
        CoreAudioHAL.string(id, kAudioObjectPropertyName)
        ?? InputDeviceStrings.followSystemDefault
      let transport = CoreAudioHAL.uint32(id, kAudioDevicePropertyTransportType) ?? 0
      return InputDevice(
        id: uid,
        name: name,
        isDefault: id == defaultID,
        transport: AudioTransport(rawValue: transport),
        nominalSampleRate: CoreAudioHAL.double(id, kAudioDevicePropertyNominalSampleRate)
          ?? 0,
        highestSupportedSampleRate: CoreAudioHAL.highestSampleRate(id),
        inputChannelCount: channels,
        hardwareID: id)
    }
  }
}

// MARK: - Watcher

/// Watches the HAL for route changes, so the HFP warning can appear while the app
/// is idle rather than only being noticed on the next dictation.
///
/// Listener-driven, never polled: NFR-7 asks for 0% CPU when idle, and a timer
/// re-reading the device list every second would spend it for nothing.
public struct CoreAudioInputDeviceWatcher: InputDeviceChangeWatching {
  public init() {}

  public func changes() -> AsyncStream<Void> {
    AsyncStream { continuation in
      let registry = HALListenerRegistry(continuation: continuation)
      registry.start()
      continuation.onTermination = { _ in registry.stop() }
    }
  }
}

/// Owns the registered HAL listeners for one `changes()` stream.
///
/// Two rules shape this class, and both are about not hanging:
///
/// 1. **Every add and every remove happens on `controlQueue`, never on
///    `eventQueue`.** `AudioObjectRemovePropertyListenerBlock` is documented to
///    stop delivery, and the HAL is entitled to wait for an in-flight callback
///    before returning. Removing a listener from inside a callback on the SAME
///    serial queue would then be a self-deadlock — and this class does exactly
///    that shape of thing: a device-list notification re-points the per-device
///    listeners. Two queues make it impossible by construction.
/// 2. **The lock is never held across a HAL call.** Registrations are swapped out
///    under the lock and the HAL is called afterwards.
///
/// `AudioObjectPropertyListenerBlock` is an imported Objective-C block and is
/// therefore not `Sendable`, which is why the registrations live inside an
/// `OSAllocatedUnfairLock` — the one escape hatch this project allows (CLAUDE.md
/// bans `@unchecked Sendable`).
private final class HALListenerRegistry: Sendable {
  private struct Registration {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
  }

  private struct State {
    var system: [Registration] = []
    var devices: [Registration] = []
    var isStopped = false
  }

  private let state = OSAllocatedUnfairLock(uncheckedState: State())
  /// Where the HAL delivers notifications.
  private let eventQueue = DispatchQueue(label: "com.fala.input-device-watcher.events")
  /// Where listeners are added and removed. Serial, so start / refresh / stop
  /// cannot interleave.
  private let controlQueue = DispatchQueue(
    label: "com.fala.input-device-watcher.control")
  private let continuation: AsyncStream<Void>.Continuation

  init(continuation: AsyncStream<Void>.Continuation) {
    self.continuation = continuation
  }

  func start() {
    controlQueue.async { self.performStart() }
  }

  /// Removes every listener. Safe to call from any thread, including from inside
  /// a HAL callback.
  func stop() {
    continuation.finish()
    controlQueue.async { self.performStop() }
  }

  // MARK: Control queue

  private func performStart() {
    // The default input moved, or a device arrived/left. The second one also
    // re-points the per-device listeners at whatever is attached now.
    addSystemListener(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
      self?.notify()
    }
    addSystemListener(kAudioHardwarePropertyDevices) { [weak self] in
      guard let self else { return }
      self.controlQueue.async { self.performRefreshDeviceListeners() }
      self.notify()
    }
    performRefreshDeviceListeners()
  }

  private func performStop() {
    let taken = state.withLockUnchecked { state -> [Registration] in
      state.isStopped = true
      let all = state.system + state.devices
      state.system = []
      state.devices = []
      return all
    }
    for registration in taken { remove(registration) }
  }

  private func addSystemListener(
    _ selector: AudioObjectPropertySelector, onChange: @escaping @Sendable () -> Void
  ) {
    guard !isStopped else { return }
    let address = CoreAudioHAL.address(selector)
    guard let registration = install(on: CoreAudioHAL.systemObject, address, onChange)
    else { return }
    state.withLockUnchecked { $0.system.append(registration) }
  }

  /// Re-points the per-device sample-rate listeners at the devices attached now.
  ///
  /// This is the listener that catches a Bluetooth link dropping into the
  /// hands-free profile: the device stays put, but its nominal sample rate falls
  /// to 8/16 kHz. Neither of the two system-level listeners fires for that.
  private func performRefreshDeviceListeners() {
    let previous = state.withLockUnchecked { state -> [Registration] in
      let devices = state.devices
      state.devices = []
      return devices
    }
    for registration in previous { remove(registration) }
    guard !isStopped, let ids = try? CoreAudioHAL.deviceIDs() else { return }

    let address = CoreAudioHAL.address(kAudioDevicePropertyNominalSampleRate)
    var installed: [Registration] = []
    for id in ids where CoreAudioHAL.inputChannelCount(id) > 0 {
      if let registration = install(on: id, address, { [weak self] in self?.notify() }) {
        installed.append(registration)
      }
    }
    state.withLockUnchecked { $0.devices.append(contentsOf: installed) }
  }

  private func install(
    on object: AudioObjectID,
    _ address: AudioObjectPropertyAddress,
    _ onChange: @escaping @Sendable () -> Void
  ) -> Registration? {
    var address = address
    let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
    let status = AudioObjectAddPropertyListenerBlock(object, &address, eventQueue, block)
    guard status == noErr else { return nil }
    return Registration(object: object, address: address, block: block)
  }

  private func remove(_ registration: Registration) {
    var address = registration.address
    _ = AudioObjectRemovePropertyListenerBlock(
      registration.object, &address, eventQueue, registration.block)
  }

  // MARK: Event queue

  private var isStopped: Bool { state.withLockUnchecked { $0.isStopped } }

  private func notify() {
    guard !isStopped else { return }
    continuation.yield(())
  }
}
