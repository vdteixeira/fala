import CoreAudio
import Foundation
import Testing
import os

@testable import FalaKit

/// Input-device selection and the AirPods/HFP warning (SPEC.md FR-18, US-4;
/// TASKS.md T2.6).
///
/// The thing under test is a RULE, not a device: "this route is telephone-grade".
/// It cannot be exercised against real hardware here — the machine this was
/// written on has one microphone, built in, at 48 kHz — so every device below is
/// a value, and the values are chosen to be the ones that break a naive
/// implementation: AirPods that are fine, a headset with no "AirPods" in its
/// name, a device that is capable of 48 kHz but publishing 16 kHz, and a
/// non-Bluetooth device that is just as bad.
@Suite struct InputDeviceQualityTests {

  // MARK: - The rule (SPEC.md FR-18)

  @Test("AirPods on a full-bandwidth link are NOT warned about")
  func airPodsOverA2DPAreFine() {
    // The false positive a name match would produce: these really are AirPods,
    // really are Bluetooth, and are publishing full-bandwidth audio.
    let airPods = makeDevice(
      name: "AirPods Pro de Victor", transport: .bluetooth, nominal: 48_000,
      ceiling: 48_000)
    #expect(airPods.quality == .fullBandwidth)
    #expect(airPods.quality.isDegraded == false)
    #expect(AudioRouteWarning(device: airPods) == nil)
  }

  @Test("a Bluetooth headset with no 'AirPods' in its name IS caught")
  func handsFreeHeadsetIsCaught() {
    // The false negative a name match would produce. Real device, paired on this
    // machine; 16 kHz is HFP's wideband (mSBC) rate.
    let headset = makeDevice(
      name: "QCY H3 Pro", transport: .bluetooth, nominal: 16_000, ceiling: 16_000)
    #expect(headset.quality == .handsFree)
    #expect(headset.quality.isDegraded)
    let warning = AudioRouteWarning(device: headset)
    #expect(warning?.deviceName == "QCY H3 Pro")
    #expect(warning?.quality == .handsFree)
  }

  @Test("both HFP rates trip it, and no full-bandwidth rate does")
  func rateBoundaries() {
    // 8 kHz = CVSD narrowband, 16 kHz = mSBC wideband. Everything a real
    // microphone publishes is 32 kHz or more.
    for rate in [8_000.0, 16_000.0, 23_999.0] {
      let device = makeDevice(transport: .bluetooth, nominal: rate, ceiling: rate)
      #expect(device.quality == .handsFree, "\(rate) Hz should be hands-free")
    }
    // 24 000 Hz is Apple's HIGH-QUALITY Bluetooth capture rate, not a hands-free
    // one. It used to be classified degraded, which fired the warning on exactly
    // the device FR-18 names, in the mode that fixes the problem.
    for rate in [24_000.0, 32_000.0, 44_100.0, 48_000.0, 96_000.0] {
      let device = makeDevice(transport: .bluetooth, nominal: rate, ceiling: rate)
      #expect(device.quality == .fullBandwidth, "\(rate) Hz should be full")
    }
    #expect(InputRouteQuality.narrowbandCeilingHz == 24_000)
  }

  @Test("what the device is publishing NOW beats what it is capable of")
  func nominalRateWins() {
    // The AirPods case that matters: the device advertises 48 kHz among its
    // available rates, but the link has dropped into HFP and it is running at
    // 16 kHz. Reading only the capability list would call this healthy.
    let degradedNow = makeDevice(
      name: "AirPods Pro de Victor", transport: .bluetooth, nominal: 16_000,
      ceiling: 48_000)
    #expect(degradedNow.quality == .handsFree)

    let sameDeviceHealthy = makeDevice(
      name: "AirPods Pro de Victor", transport: .bluetooth, nominal: 48_000,
      ceiling: 48_000)
    #expect(sameDeviceHealthy.quality == .fullBandwidth)
  }

  @Test("a device that can never exceed 16 kHz is degraded even if it says nothing")
  func capabilityCeilingIsTheFallback() {
    // `kAudioDevicePropertyNominalSampleRate` unreadable (0). The capability
    // list is the second opinion, so the answer is still not "unknown".
    let device = makeDevice(transport: .bluetooth, nominal: 0, ceiling: 16_000)
    #expect(device.quality == .handsFree)
  }

  @Test("narrowband over a link that is not Bluetooth is not called HFP")
  func nonBluetoothNarrowband() {
    let speakerphone = makeDevice(
      name: "Poly Sync 20", transport: .usb, nominal: 16_000, ceiling: 16_000)
    #expect(speakerphone.quality == .narrowband)
    #expect(speakerphone.quality.isDegraded)

    let warning = AudioRouteWarning(device: speakerphone)
    // Same advice, different diagnosis: a USB device is not running a Bluetooth
    // profile, and telling the user it is would send them to the wrong setting.
    #expect(warning?.message.contains("HFP") == false)
    #expect(warning?.message.contains(InputDeviceStrings.preferBuiltIn) == true)
    #expect(warning?.symbol == FalaSymbol.warning)
  }

  @Test("no rate at all is 'unknown' and never warns")
  func unknownNeverWarns() {
    let device = makeDevice(transport: .bluetooth, nominal: 0, ceiling: 0)
    #expect(device.quality == .unknown)
    #expect(device.quality.isDegraded == false)
    #expect(AudioRouteWarning(device: device) == nil)
    // And the no-device case, which is what an empty catalog produces.
    #expect(InputRoute.none.quality == .unknown)
    #expect(InputRoute.none.isDegraded == false)
    #expect(InputRoute.none.warning == nil)
  }

  @Test("wireless is not the signal — Continuity Capture and AirPlay are fine")
  func wirelessIsNotTheSignal() {
    // An iPhone used as a microphone is wireless and is BETTER than the built-in
    // mic. Keying off "wireless" instead of "Bluetooth + narrowband" would warn
    // about it.
    let iPhone = makeDevice(
      name: "iPhone de Victor", transport: .continuityCapture, nominal: 48_000,
      ceiling: 48_000)
    #expect(iPhone.quality == .fullBandwidth)
    #expect(AudioTransport.continuityCapture.canCarryHandsFreeProfile == false)
    #expect(AudioTransport.airPlay.canCarryHandsFreeProfile == false)
    #expect(AudioTransport.bluetooth.canCarryHandsFreeProfile)
    #expect(AudioTransport.bluetoothLE.canCarryHandsFreeProfile)
  }

  @Test("the built-in microphone is never degraded")
  func builtInIsFine() {
    let builtIn = makeDevice(
      name: "Microfone (MacBook Pro)", transport: .builtIn, nominal: 48_000,
      ceiling: 96_000)
    #expect(builtIn.quality == .fullBandwidth)
  }

  // MARK: - Transport decoding

  @Test("an unrecognized transport degrades to 'other', never to Bluetooth")
  func unknownTransport() {
    let future = AudioTransport(rawValue: 0x7A7A_7A7A)
    #expect(future == .other(0x7A7A_7A7A))
    #expect(future.canCarryHandsFreeProfile == false)
    // A narrowband device on an unnameable transport is still reported as bad
    // audio — just not blamed on a Bluetooth profile.
    let device = makeDevice(transport: future, nominal: 8_000, ceiling: 8_000)
    #expect(device.quality == .narrowband)
    #expect(AudioTransport(rawValue: 0) == .other(0))
  }

  @Test("the four-character codes still match CoreAudio's own constants")
  func transportCodesMatchCoreAudio() {
    // A tripwire, not a tautology: `AudioTransport` hard-codes these so the rule
    // stays testable without importing CoreAudio. If Apple ever renumbers one,
    // this fails here instead of silently classifying a Bluetooth headset as
    // `.other` and dropping the warning in the field.
    #expect(AudioTransport.Code.builtIn == kAudioDeviceTransportTypeBuiltIn)
    #expect(AudioTransport.Code.bluetooth == kAudioDeviceTransportTypeBluetooth)
    #expect(AudioTransport.Code.bluetoothLE == kAudioDeviceTransportTypeBluetoothLE)
    #expect(AudioTransport.Code.usb == kAudioDeviceTransportTypeUSB)
    #expect(AudioTransport.Code.aggregate == kAudioDeviceTransportTypeAggregate)
    #expect(AudioTransport.Code.virtual == kAudioDeviceTransportTypeVirtual)
    #expect(AudioTransport.Code.airPlay == kAudioDeviceTransportTypeAirPlay)
    #expect(AudioTransport.Code.hdmi == kAudioDeviceTransportTypeHDMI)
    #expect(AudioTransport.Code.displayPort == kAudioDeviceTransportTypeDisplayPort)
    #expect(AudioTransport.Code.thunderbolt == kAudioDeviceTransportTypeThunderbolt)
    #expect(AudioTransport.Code.pci == kAudioDeviceTransportTypePCI)
    #expect(AudioTransport.Code.fireWire == kAudioDeviceTransportTypeFireWire)
    #expect(AudioTransport.Code.avb == kAudioDeviceTransportTypeAVB)
    #expect(
      AudioTransport.Code.continuityCaptureWired
        == kAudioDeviceTransportTypeContinuityCaptureWired)
    #expect(
      AudioTransport.Code.continuityCaptureWireless
        == kAudioDeviceTransportTypeContinuityCaptureWireless)
  }
}

// MARK: - Copy

@Suite struct AudioRouteWarningTests {

  @Test("the warning is pt-BR and ends with the handoff's sentence")
  func copyMatchesTheHandoff() {
    let device = makeDevice(
      name: "AirPods de Victor", transport: .bluetooth, nominal: 16_000,
      ceiling: 16_000)
    let warning = AudioRouteWarning(device: device)
    // design/DESIGN-HANDOFF.md §3 and settings-window.dc.html, with the device's
    // real name in place of the mockup's hard-coded "AirPods".
    #expect(
      warning?.message
        == "Qualidade reduzida com AirPods de Victor (HFP). Prefira o microfone interno.")
    #expect(warning?.advice == "Prefira o microfone interno.")
    #expect(warning?.symbol == FalaSymbol.headphones)
    #expect(FalaSymbol.headphones == "airpods")
  }

  @Test("a healthy route cannot produce a warning at all")
  func noWarningWithoutDegradation() {
    #expect(AudioRouteWarning(deviceName: "x", quality: .fullBandwidth) == nil)
    #expect(AudioRouteWarning(deviceName: "x", quality: .unknown) == nil)
    #expect(AudioRouteWarning(deviceName: "x", quality: .handsFree) != nil)
    #expect(AudioRouteWarning(deviceName: "x", quality: .narrowband) != nil)
  }

  @Test("the pill's existing warning state renders a real degraded route")
  func routeReachesThePill() {
    // The wiring T2.6 owes T2.3: a real route, not a hand-set Bool, must light
    // up the pill's sixth state with the same glyph the warning carries.
    let route = InputRoute(
      device: makeDevice(transport: .bluetooth, nominal: 8_000, ceiling: 8_000))
    let input = PillInput(state: .idle, audioRouteDegraded: route.isDegraded)
    #expect(input.kind == .warning)
    #expect(PillPresentation(input).symbol == route.warning?.symbol)
    // And it persists, because the route is a condition and not an event.
    #expect(PillDismissPolicy.standard.dismissal(for: .warning) == .persists)
  }

  @Test("the doctor line is pt-BR, names the rate, and carries the warning")
  func doctorSummary() {
    let healthy = InputRoute(
      device: makeDevice(
        name: "Microfone (MacBook Pro)", transport: .builtIn, nominal: 48_000,
        ceiling: 96_000))
    #expect(healthy.summary == "Microfone: Microfone (MacBook Pro) · 48 kHz")

    let degraded = InputRoute(
      device: makeDevice(
        name: "AirPods de Victor", transport: .bluetooth, nominal: 16_000,
        ceiling: 16_000))
    #expect(
      degraded.summary == "Microfone: AirPods de Victor · 16 kHz — "
        + "Qualidade reduzida com AirPods de Victor (HFP). Prefira o microfone interno.")

    #expect(InputRoute.none.summary == "Microfone: Nenhum microfone disponível.")
    // pt-BR decimal comma, and it must not follow the machine's region setting.
    #expect(makeDevice(nominal: 44_100).sampleRateLabel == "44,1 kHz")
    #expect(makeDevice(nominal: 8_000).sampleRateLabel == "8 kHz")
    #expect(makeDevice(nominal: 0).sampleRateLabel == "")
  }

  @Test("picker labels are pt-BR and mark the system default")
  func pickerLabels() {
    let device = makeDevice(name: "Microfone (MacBook Pro)", isDefault: true)
    #expect(device.pickerLabel == "Microfone (MacBook Pro) (padrão)")
    #expect(makeDevice(name: "Yeti", isDefault: false).pickerLabel == "Yeti")
    #expect(InputDeviceStrings.followSystemDefault == "Padrão do sistema")
    #expect(
      InputDeviceStrings.selectionUnavailable(device: "Yeti")
        == "Yeti não está disponível — usando o padrão do sistema.")
    #expect(
      InputDeviceStrings.selectionUnavailable(device: nil)
        == "O microfone escolhido não está disponível — usando o padrão do sistema.")
  }
}

// MARK: - Resolution

@Suite struct InputDeviceResolutionTests {
  private let builtIn = makeDevice(
    name: "Microfone (MacBook Pro)", uid: "BuiltInMicrophoneDevice",
    transport: .builtIn, nominal: 48_000, ceiling: 96_000, isDefault: true,
    hardwareID: 79)
  private let headset = makeDevice(
    name: "AirPods de Victor", uid: "C0-95-6D-AD-A4-BA:input",
    transport: .bluetooth, nominal: 16_000, ceiling: 16_000, hardwareID: 91)

  @Test("no choice follows the system default")
  func systemDefault() {
    let resolution = InputDeviceResolution.resolve(
      .systemDefault, in: [builtIn, headset])
    #expect(resolution == .systemDefault(builtIn))
    #expect(resolution.device == builtIn)
    // Nothing to bind: the engine keeps doing what it did before T2.6.
    #expect(resolution.explicitDeviceID == nil)
    #expect(resolution.route.isDegraded == false)
  }

  @Test("a chosen device that is attached is used, and is bound explicitly")
  func chosenDevicePresent() {
    let choice = InputDeviceChoice(headset)
    let resolution = InputDeviceResolution.resolve(choice, in: [builtIn, headset])
    #expect(resolution == .selected(headset))
    #expect(resolution.explicitDeviceID == 91)
  }

  @Test("the warning describes the CHOSEN device, not the system default")
  func warningFollowsTheSelection() {
    // The default is the healthy built-in mic; the user picked the headset. A
    // warning computed from the default would say everything is fine while the
    // recording goes through HFP.
    let route = InputDeviceResolution.resolve(
      InputDeviceChoice(headset), in: [builtIn, headset]
    ).route
    #expect(route.isDegraded)
    #expect(route.warning?.deviceName == "AirPods de Victor")
  }

  @Test("an unplugged choice falls back to the default and says so in pt-BR")
  func chosenDeviceGone() {
    let choice = InputDeviceChoice(headset)
    let resolution = InputDeviceResolution.resolve(choice, in: [builtIn])
    #expect(resolution == .unavailable(choice: choice, fallback: builtIn))
    // Falls back rather than refusing: a dictation still happens, on the mic
    // that is actually there.
    #expect(resolution.device == builtIn)
    #expect(resolution.explicitDeviceID == nil)
    let route = resolution.route
    #expect(route.isDegraded == false)
    #expect(
      route.substitutionNotice
        == "AirPods de Victor não está disponível — usando o padrão do sistema.")
  }

  @Test("no devices, or no default flagged, resolves to nothing rather than a guess")
  func noUsableDefault() {
    #expect(InputDeviceResolution.resolve(.systemDefault, in: []) == .systemDefault(nil))
    // Every device present, none flagged default: CoreAudio is saying there is no
    // default input. Picking "the first one" would attribute a warning to a
    // microphone nothing is recording from.
    let undefaulted = makeDevice(transport: .bluetooth, nominal: 8_000, ceiling: 8_000)
    let resolution = InputDeviceResolution.resolve(.systemDefault, in: [undefaulted])
    #expect(resolution == .systemDefault(nil))
    #expect(resolution.route.isDegraded == false)
  }
}

// MARK: - Persistence

@Suite struct InputDeviceSelectionStoreTests {

  @Test("the choice round-trips, and clearing it really clears it")
  func roundTrip() {
    let suite = "com.fala.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let store = UserDefaultsInputDeviceStore(suiteName: suite)

    // Absent means "never chose one", not "chose nothing".
    #expect(store.loadChoice() == .systemDefault)

    store.save(.device(uid: "uid-1", name: "AirPods de Victor"))
    #expect(store.loadChoice() == .device(uid: "uid-1", name: "AirPods de Victor"))

    store.save(.systemDefault)
    #expect(store.loadChoice() == .systemDefault)
    // The name must go with the uid, or the next unplugged-device message names
    // a microphone the user no longer has selected.
    #expect(UserDefaults(suiteName: suite)?.string(forKey: "fala.inputDevice.name") == nil)
  }

  @Test("a uid with no name is still a valid choice")
  func nameIsOptional() {
    let suite = "com.fala.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let store = UserDefaultsInputDeviceStore(suiteName: suite)
    store.save(.device(uid: "uid-2", name: nil))
    #expect(store.loadChoice() == .device(uid: "uid-2", name: nil))
    store.save(.device(uid: "uid-2", name: ""))
    #expect(store.loadChoice() == .device(uid: "uid-2", name: nil))
  }

  @Test("the capture seam answers nil unless a present device was chosen")
  func captureSeam() {
    let present = makeDevice(uid: "uid-present", hardwareID: 42)
    let catalog = FakeCatalog([present])
    let store = MemorySelectionStore()

    let selection = StoredInputDeviceSelection(store: store, catalog: catalog)
    // Nothing chosen: AVAudioEngine keeps following the system default.
    #expect(selection.currentInputDeviceID() == nil)

    store.save(.device(uid: "uid-present", name: "x"))
    #expect(selection.currentInputDeviceID() == 42)

    // Chosen but unplugged: nil, so `AudioCapture` falls back instead of
    // refusing to record.
    store.save(.device(uid: "uid-gone", name: "x"))
    #expect(selection.currentInputDeviceID() == nil)
  }
}

// MARK: - Center

@Suite struct InputDeviceCenterTests {
  private static let builtIn = makeDevice(
    name: "Microfone (MacBook Pro)", uid: "BuiltInMicrophoneDevice",
    transport: .builtIn, nominal: 48_000, ceiling: 96_000, isDefault: true,
    hardwareID: 79)
  private static let headset = makeDevice(
    name: "AirPods de Victor", uid: "airpods", transport: .bluetooth,
    nominal: 16_000, ceiling: 16_000, hardwareID: 91)

  @Test("a subscriber gets the current route immediately")
  @MainActor
  func immediateRoute() async {
    let center = InputDeviceCenter(
      catalog: FakeCatalog([Self.builtIn]), watcher: FakeWatcher(),
      store: MemorySelectionStore())
    center.start()
    var routes = center.routes().makeAsyncIterator()
    let first = await routes.next()
    #expect(first?.device == Self.builtIn)
    #expect(first?.isDegraded == false)
    center.stop()
  }

  @Test("plugging in a hands-free headset raises the warning while idle")
  @MainActor
  func routeFollowsTheHardware() async {
    // The FR-18 scenario end to end: nothing is happening, the user puts their
    // AirPods in, and the warning has to appear without a dictation to trigger
    // it.
    let catalog = FakeCatalog([Self.builtIn])
    let watcher = FakeWatcher()
    let center = InputDeviceCenter(
      catalog: catalog, watcher: watcher, store: MemorySelectionStore())
    center.start()
    var routes = center.routes().makeAsyncIterator()
    #expect(await routes.next()?.isDegraded == false)

    catalog.devices = [makeDefault(Self.headset)]
    watcher.fire()

    let degraded = await routes.next()
    #expect(degraded?.isDegraded == true)
    #expect(degraded?.warning?.deviceName == "AirPods de Victor")
    center.stop()
  }

  @Test("duplicate hardware notifications do not re-publish the same route")
  @MainActor
  func deduplicated() async {
    // The HAL fires several times for one physical event. Without the dedup the
    // pill rebuilds itself on each of them, which is a visible flicker.
    let catalog = FakeCatalog([Self.builtIn])
    let watcher = FakeWatcher()
    let center = InputDeviceCenter(
      catalog: catalog, watcher: watcher, store: MemorySelectionStore())
    center.start()
    var routes = center.routes().makeAsyncIterator()
    _ = await routes.next()

    watcher.fire()
    watcher.fire()
    watcher.fire()
    catalog.devices = [makeDefault(Self.headset)]
    watcher.fire()

    // If the three no-op notifications had published, this would be the first of
    // them and would not be degraded.
    #expect(await routes.next()?.isDegraded == true)
    center.stop()
  }

  @Test("choosing a device republishes and persists, with no hardware change")
  @MainActor
  func selection() async {
    let store = MemorySelectionStore()
    let catalog = FakeCatalog([Self.builtIn, Self.headset])
    let center = InputDeviceCenter(
      catalog: catalog, watcher: FakeWatcher(), store: store)
    center.start()
    var routes = center.routes().makeAsyncIterator()
    _ = await routes.next()

    center.select(Self.headset)
    #expect(await routes.next()?.warning?.deviceName == "AirPods de Victor")
    #expect(store.loadChoice() == .device(uid: "airpods", name: "AirPods de Victor"))
    // The capture side reads the same store, so the next utterance binds it
    // without anybody having to push the choice across.
    #expect(center.captureSelection.currentInputDeviceID() == 91)

    // And it survives a relaunch.
    let relaunched = InputDeviceCenter(
      catalog: catalog, watcher: FakeWatcher(), store: store)
    #expect(relaunched.choice == .device(uid: "airpods", name: "AirPods de Victor"))
    center.stop()
  }

  @Test("stop() closes the route streams")
  @MainActor
  func stopFinishes() async {
    let center = InputDeviceCenter(
      catalog: FakeCatalog([Self.builtIn]), watcher: FakeWatcher(),
      store: MemorySelectionStore())
    center.start()
    var routes = center.routes().makeAsyncIterator()
    _ = await routes.next()
    center.stop()
    #expect(await routes.next() == nil)
  }

  @Test("a Mac with no microphone reports nothing rather than a warning")
  @MainActor
  func noDevices() async {
    let center = InputDeviceCenter(
      catalog: FakeCatalog([]), watcher: FakeWatcher(), store: MemorySelectionStore())
    center.start()
    #expect(center.devices.isEmpty)
    #expect(center.route == .none)
    #expect(center.warning == nil)
  }
}

// MARK: - Real hardware

/// One smoke test against the real CoreAudio HAL. It asserts only what is true of
/// every Mac, because it runs on whatever machine happens to be building.
@Suite struct CoreAudioInputDeviceCatalogTests {

  @Test("the real HAL describes this Mac's microphones")
  func realCatalog() throws {
    let devices = try CoreAudioInputDeviceCatalog().inputDevices()
    // A machine with no input at all is a legitimate configuration (a headless
    // build box), so an empty list is not a failure.
    try #require(!devices.isEmpty)

    for device in devices {
      #expect(!device.id.isEmpty)
      #expect(!device.name.isEmpty)
      #expect(device.inputChannelCount > 0)
      #expect(device.hardwareID != 0)
    }
    #expect(devices.filter(\.isDefault).count <= 1)
    #expect(Set(devices.map(\.id)).count == devices.count)

    // The built-in microphone must never be classified as degraded — if it is,
    // the rule is broken in the direction that shows a permanent warning.
    if let builtIn = devices.first(where: { $0.transport == .builtIn }) {
      #expect(builtIn.quality == .fullBandwidth)
      #expect(builtIn.nominalSampleRate > InputRouteQuality.narrowbandCeilingHz)
      #expect(AudioRouteWarning(device: builtIn) == nil)
    }
  }

  @Test("the real watcher registers HAL listeners and tears them down", .timeLimit(.minutes(1)))
  func realWatcherLifecycle() async {
    // What this proves is a LIFECYCLE, not a detection: no device can be plugged
    // in from a test, so the notifications themselves are unobservable here. It
    // does exercise the deadlock this design had to be written around —
    // `AudioObjectRemovePropertyListenerBlock` blocks until an in-flight
    // callback returns, and that callback wants the same lock `stop()` holds.
    // If `stop()` ever holds the lock across the removal again, this hangs.
    let watcher = CoreAudioInputDeviceWatcher()
    let task = Task {
      for await _ in watcher.changes() {}
    }
    // Long enough for registration to complete on the watcher's own queue.
    try? await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await task.value
  }
}

// MARK: - Fixtures

private func makeDevice(
  name: String = "Device",
  uid: String = "uid",
  transport: AudioTransport = .builtIn,
  nominal: Double = 48_000,
  ceiling: Double = 48_000,
  isDefault: Bool = false,
  hardwareID: UInt32 = 1
) -> InputDevice {
  InputDevice(
    id: uid,
    name: name,
    isDefault: isDefault,
    transport: transport,
    nominalSampleRate: nominal,
    highestSupportedSampleRate: ceiling,
    inputChannelCount: 1,
    hardwareID: hardwareID)
}

/// The same device, flagged as the system default.
private func makeDefault(_ device: InputDevice) -> InputDevice {
  InputDevice(
    id: device.id,
    name: device.name,
    isDefault: true,
    transport: device.transport,
    nominalSampleRate: device.nominalSampleRate,
    highestSupportedSampleRate: device.highestSupportedSampleRate,
    inputChannelCount: device.inputChannelCount,
    hardwareID: device.hardwareID)
}

/// A catalog whose contents the test can change between reads, so "the user
/// plugged something in" is expressible.
private final class FakeCatalog: InputDeviceCataloging {
  private let state = OSAllocatedUnfairLock(initialState: [InputDevice]())

  init(_ devices: [InputDevice]) {
    state.withLock { $0 = devices }
  }

  var devices: [InputDevice] {
    get { state.withLock { $0 } }
    set { state.withLock { $0 = newValue } }
  }

  func inputDevices() throws -> [InputDevice] { devices }
}

/// Stands in for the CoreAudio property listeners: `fire()` is "the HAL said
/// something changed".
private final class FakeWatcher: InputDeviceChangeWatching {
  private let state = OSAllocatedUnfairLock(
    initialState: [AsyncStream<Void>.Continuation]())

  func changes() -> AsyncStream<Void> {
    AsyncStream { continuation in
      state.withLock { $0.append(continuation) }
    }
  }

  func fire() {
    for continuation in state.withLock({ $0 }) { continuation.yield(()) }
  }
}

private final class MemorySelectionStore: InputDeviceSelectionStoring {
  private let state = OSAllocatedUnfairLock(initialState: InputDeviceChoice.systemDefault)

  func loadChoice() -> InputDeviceChoice { state.withLock { $0 } }
  func save(_ choice: InputDeviceChoice) { state.withLock { $0 = choice } }

  /// The regression: AirPods on Apple's high-quality capture path publish exactly
  /// 24 000 Hz. Warning there told the user to switch away from a device that was
  /// working fine, and 24 kHz is well above what a 16 kHz ASR pipeline consumes.
  @Test("AirPods at 24 kHz are not warned about")
  func highQualityBluetoothIsNotDegraded() {
    let airpods = makeDevice(
      name: "AirPods Pro de Victor", transport: .bluetooth, nominal: 24_000, ceiling: 24_000)
    #expect(airpods.quality == .fullBandwidth)
    #expect(!airpods.quality.isDegraded)
    #expect(AudioRouteWarning(device: airpods) == nil)
  }
}
