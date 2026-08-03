// What an audio input device is, and when it is too poor for ASR
// (SPEC.md FR-18, US-4; TASKS.md T2.6; design/DESIGN-HANDOFF.md §3).
//
// Deliberately Foundation-only. Everything that talks to the CoreAudio HAL lives
// in `InputDeviceCatalog.swift`; everything that DECIDES lives here, so the whole
// HFP rule is unit-testable on a machine with no Bluetooth headset attached —
// which is every machine this will ever be tested on.

import Foundation

// MARK: - Transport

/// How a device is attached to the Mac — CoreAudio's
/// `kAudioDevicePropertyTransportType`.
///
/// Modelled as its own enum rather than passing the raw `UInt32` around because
/// the HFP rule keys off "is this a Bluetooth link", and a four-character code
/// buried in an `if` is exactly the kind of thing that rots without anybody
/// noticing. The raw codes are in `Code` and are pinned against the real
/// CoreAudio constants by a test.
public enum AudioTransport: Sendable, Equatable, Hashable {
  case builtIn
  case bluetooth
  case bluetoothLE
  case usb
  case aggregate
  case virtual
  case airPlay
  /// iPhone used as a microphone (Continuity Camera). Wireless, but 48 kHz —
  /// the reason "wireless" alone is not the signal.
  case continuityCapture
  case hdmi
  case displayPort
  case thunderbolt
  case pci
  case fireWire
  case avb
  /// Anything the OS reports that this enum does not name, carried verbatim so a
  /// future transport type degrades to "unknown", never to "Bluetooth".
  case other(UInt32)

  /// The four-character codes CoreAudio uses. Written out here so this file stays
  /// free of the CoreAudio import; `InputDeviceTests` asserts every one of them
  /// still equals the constant it stands for.
  public enum Code {
    public static let builtIn: UInt32 = 0x626C_746E  // 'bltn'
    public static let bluetooth: UInt32 = 0x626C_7565  // 'blue'
    public static let bluetoothLE: UInt32 = 0x626C_6561  // 'blea'
    public static let usb: UInt32 = 0x7573_6220  // 'usb '
    public static let aggregate: UInt32 = 0x6772_7570  // 'grup'
    public static let virtual: UInt32 = 0x7669_7274  // 'virt'
    public static let airPlay: UInt32 = 0x6169_7270  // 'airp'
    public static let continuityCaptureWired: UInt32 = 0x6363_7764  // 'ccwd'
    public static let continuityCaptureWireless: UInt32 = 0x6363_776C  // 'ccwl'
    public static let hdmi: UInt32 = 0x6864_6D69  // 'hdmi'
    public static let displayPort: UInt32 = 0x6470_7274  // 'dprt'
    public static let thunderbolt: UInt32 = 0x7468_756E  // 'thun'
    public static let pci: UInt32 = 0x7063_6920  // 'pci '
    public static let fireWire: UInt32 = 0x3133_3934  // '1394'
    public static let avb: UInt32 = 0x6561_7662  // 'eavb'
  }

  public init(rawValue: UInt32) {
    switch rawValue {
    case Code.builtIn: self = .builtIn
    case Code.bluetooth: self = .bluetooth
    case Code.bluetoothLE: self = .bluetoothLE
    case Code.usb: self = .usb
    case Code.aggregate: self = .aggregate
    case Code.virtual: self = .virtual
    case Code.airPlay: self = .airPlay
    case Code.continuityCaptureWired, Code.continuityCaptureWireless:
      self = .continuityCapture
    case Code.hdmi: self = .hdmi
    case Code.displayPort: self = .displayPort
    case Code.thunderbolt: self = .thunderbolt
    case Code.pci: self = .pci
    case Code.fireWire: self = .fireWire
    case Code.avb: self = .avb
    default: self = .other(rawValue)
    }
  }

  /// Whether this link can carry a telephony (hands-free) profile at all.
  ///
  /// Only the two Bluetooth transports can. Everything else that happens to be
  /// wireless — AirPlay, Continuity Capture — carries full-bandwidth audio, so
  /// treating "wireless" as the signal would warn about an iPhone microphone
  /// that is better than the built-in one.
  public var canCarryHandsFreeProfile: Bool {
    self == .bluetooth || self == .bluetoothLE
  }
}

// MARK: - Quality

/// How good the current input route is FOR SPEECH RECOGNITION — not for music,
/// and not for the user's ears (SPEC.md FR-18).
///
/// ## The signal, and why it is not the device name
/// A Bluetooth headset used as a microphone forces the link into the Hands-Free
/// Profile: 8 kHz narrowband (CVSD) or 16 kHz wideband (mSBC), heavily
/// compressed. Parakeet is trained on full-bandwidth speech decimated to 16 kHz,
/// so HFP audio is out of distribution and the word error rate rises sharply.
/// Matching `"AirPods"` in the device name would (a) miss every Sony, Bose, Jabra
/// and QCY headset and (b) fire on AirPods that are NOT in HFP.
///
/// What is actually measured is the **sample rate the device is publishing**,
/// qualified by the transport:
/// - at or below `narrowbandCeilingHz`, the route is telephone-grade, full stop;
/// - if the link is also Bluetooth, the cause is the hands-free profile and the
///   fix is "use another microphone", which is what the user is told.
///
/// Note that "16 kHz" is not benign just because `Resampler` targets 16 kHz. The
/// pipeline's 16 kHz comes from decimating a 48 kHz capture; HFP's comes from a
/// codec that never had the bandwidth. The rate is the detectable symptom, not
/// the damage.
public enum InputRouteQuality: Sendable, Equatable {
  /// Full-bandwidth speech. Nothing to warn about.
  case fullBandwidth
  /// A Bluetooth device in a hands-free/telephony profile.
  case handsFree
  /// Telephone-grade audio over a link that is not Bluetooth — a USB
  /// speakerphone, a conferencing virtual device, an aggregate built on one.
  /// Just as bad for ASR; the cause, and therefore the wording, differs.
  case narrowband
  /// No device, or the device published no usable rate. Never warns: claiming a
  /// degraded route when there is no route at all would be a lie the user cannot
  /// act on.
  case unknown

  /// The highest sample rate that still counts as telephone-grade.
  ///
  /// HFP tops out at 16 kHz (mSBC wideband); its narrowband mode is 8 kHz. Every
  /// full-bandwidth capture device on macOS publishes 32 kHz or more — the
  /// built-in MacBook Pro microphone offers 44.1/48/88.2/96 kHz.
  ///
  /// The bound is EXCLUSIVE, and that matters: Apple's high-quality Bluetooth
  /// recording path publishes exactly 24 000 Hz. An inclusive `<=` classified
  /// that as hands-free, so the warning fired hardest on AirPods in the very mode
  /// that FIXES the HFP problem — and 24 kHz is comfortably above what a 16 kHz
  /// ASR pipeline consumes, so there is nothing to warn about. Anything strictly
  /// below 24 kHz is still in the telephone-grade population.
  public static let narrowbandCeilingHz: Double = 24_000

  /// - Parameters:
  ///   - nominalSampleRate: what the device is publishing right now
  ///     (`kAudioDevicePropertyNominalSampleRate`). This is the primary signal:
  ///     a device that *can* do 48 kHz but is currently at 16 kHz is degraded
  ///     right now.
  ///   - highestSupportedSampleRate: the top of
  ///     `kAudioDevicePropertyAvailableNominalSampleRates`. Used as the fallback
  ///     when the nominal rate is unreadable, and as a second opinion: a device
  ///     that can never exceed 16 kHz is degraded whatever it reports today.
  public init(
    transport: AudioTransport,
    nominalSampleRate: Double,
    highestSupportedSampleRate: Double
  ) {
    let observed = nominalSampleRate > 0 ? nominalSampleRate : highestSupportedSampleRate
    let ceiling = highestSupportedSampleRate > 0 ? highestSupportedSampleRate : observed
    guard observed > 0 else {
      self = .unknown
      return
    }
    let limit = Self.narrowbandCeilingHz
    // Strictly below the ceiling — see `narrowbandCeilingHz` on why 24 kHz
    // exactly must NOT count as degraded.
    guard observed < limit || ceiling < limit else {
      self = .fullBandwidth
      return
    }
    self = transport.canCarryHandsFreeProfile ? .handsFree : .narrowband
  }

  /// Whether this route hurts recognition enough to tell the user about it.
  public var isDegraded: Bool {
    self == .handsFree || self == .narrowband
  }
}

// MARK: - Device

/// One microphone the user could dictate through.
///
/// PRIVACY: `name` is a user-chosen device label ("AirPods Pro de Victor") and
/// `id` is a hardware UID. Neither is audio or transcript text, but neither is
/// logged either — they exist to be RENDERED, and nothing in FalaKit writes them
/// anywhere.
public struct InputDevice: Sendable, Equatable, Identifiable {
  /// `kAudioDevicePropertyDeviceUID`. Stable across reboots and re-pairing, which
  /// is what makes it the thing to persist.
  public let id: String
  /// The name macOS shows, already localized by the OS.
  public let name: String
  /// This is the system's current default input.
  public let isDefault: Bool
  public let transport: AudioTransport
  public let nominalSampleRate: Double
  public let highestSupportedSampleRate: Double
  public let inputChannelCount: Int
  /// CoreAudio's `AudioDeviceID`. **Ephemeral** — it is reassigned when a device
  /// is unplugged and reconnected, so it is what you bind an engine to and never
  /// what you persist. `id` is the persistable identity.
  public let hardwareID: UInt32

  public init(
    id: String,
    name: String,
    isDefault: Bool,
    transport: AudioTransport,
    nominalSampleRate: Double,
    highestSupportedSampleRate: Double,
    inputChannelCount: Int,
    hardwareID: UInt32
  ) {
    self.id = id
    self.name = name
    self.isDefault = isDefault
    self.transport = transport
    self.nominalSampleRate = nominalSampleRate
    self.highestSupportedSampleRate = highestSupportedSampleRate
    self.inputChannelCount = inputChannelCount
    self.hardwareID = hardwareID
  }

  public var quality: InputRouteQuality {
    InputRouteQuality(
      transport: transport,
      nominalSampleRate: nominalSampleRate,
      highestSupportedSampleRate: highestSupportedSampleRate)
  }

  /// The picker row's label (design/mockups/settings-window.dc.html: the default
  /// device reads "Microfone interno (padrão)").
  public var pickerLabel: String {
    isDefault ? "\(name) \(InputDeviceStrings.defaultSuffix)" : name
  }

  /// "48 kHz" / "44,1 kHz". pt-BR decimal comma, and never locale-dependent —
  /// `%.1f` formats in the C locale, so the separator is substituted rather than
  /// left to the machine's region setting.
  public var sampleRateLabel: String {
    guard nominalSampleRate > 0 else { return "" }
    let kHz = ((nominalSampleRate / 1_000) * 10).rounded() / 10
    if kHz == kHz.rounded() { return "\(Int(kHz)) kHz" }
    return String(format: "%.1f", kHz).replacingOccurrences(of: ".", with: ",") + " kHz"
  }
}

// MARK: - Warning

/// The amber row / warning pill for a degraded route (DESIGN-HANDOFF.md §3).
///
/// A value rather than a bare string so the settings window, the pill and
/// `doctor` all say the same thing, and so a test can assert the wording without
/// a screen.
public struct AudioRouteWarning: Sendable, Equatable {
  public let deviceName: String
  public let quality: InputRouteQuality

  /// `nil` for a route that is fine — constructing a warning for a healthy route
  /// is the bug this initializer exists to make impossible.
  public init?(deviceName: String, quality: InputRouteQuality) {
    guard quality.isDegraded else { return nil }
    self.deviceName = deviceName
    self.quality = quality
  }

  public init?(device: InputDevice) {
    self.init(deviceName: device.name, quality: device.quality)
  }

  /// DESIGN-HANDOFF.md §5: a warning caused by the audio route uses `airpods`.
  public var symbol: String {
    quality == .handsFree ? FalaSymbol.headphones : FalaSymbol.warning
  }

  /// First sentence — what is wrong, naming the actual device.
  ///
  /// The mockup writes "Qualidade reduzida com AirPods (HFP)."; the device's own
  /// name is substituted so a Sony or a Jabra is named correctly instead of being
  /// called AirPods.
  public var title: String {
    quality == .handsFree
      ? InputDeviceStrings.handsFreeTitle(device: deviceName)
      : InputDeviceStrings.narrowbandTitle(device: deviceName)
  }

  /// Second sentence — what to do about it (DESIGN-HANDOFF.md §3, verbatim).
  public var advice: String { InputDeviceStrings.preferBuiltIn }

  /// The whole amber row, as the mockup writes it.
  public var message: String { "\(title) \(advice)" }
}

// MARK: - Route

/// The input route as it stands right now: which device dictation would use, and
/// whether that is a problem.
public struct InputRoute: Sendable, Equatable {
  /// `nil` when the Mac has no usable input at all.
  public let device: InputDevice?
  /// Set when the user's chosen device is gone and the system default is standing
  /// in for it. Carries a pt-BR line for the settings window; it is not a warning
  /// about quality, so it never lights up the pill.
  public let substitutionNotice: String?

  public init(device: InputDevice?, substitutionNotice: String? = nil) {
    self.device = device
    self.substitutionNotice = substitutionNotice
  }

  /// No device at all.
  public static let none = InputRoute(device: nil)

  public var quality: InputRouteQuality { device?.quality ?? .unknown }

  /// Non-nil exactly when the route degrades recognition.
  public var warning: AudioRouteWarning? {
    device.flatMap(AudioRouteWarning.init(device:))
  }

  /// What `PillOverlayController.setAudioRouteDegraded(_:)` takes.
  public var isDegraded: Bool { quality.isDegraded }

  /// One pt-BR line for `Fala doctor`, which is the only surface this feature has
  /// until Ajustes › Áudio exists. Carries no path and no serial number.
  public var summary: String {
    guard let device else { return "Microfone: \(InputDeviceStrings.noInputDevice)" }
    var line = "Microfone: \(device.name)"
    if !device.sampleRateLabel.isEmpty { line += " · \(device.sampleRateLabel)" }
    if let warning { line += " — \(warning.message)" }
    if let substitutionNotice { line += " — \(substitutionNotice)" }
    return line
  }
}

// MARK: - Copy

/// Every pt-BR string this feature can show, in one place (CLAUDE.md: user-facing
/// strings are Brazilian Portuguese).
public enum InputDeviceStrings {
  /// DESIGN-HANDOFF.md §3, verbatim.
  public static let preferBuiltIn = "Prefira o microfone interno."

  public static func handsFreeTitle(device: String) -> String {
    "Qualidade reduzida com \(device) (HFP)."
  }

  /// Not in the mockup — the mockup only draws the AirPods case. Same shape, and
  /// it deliberately does NOT say HFP, because a USB speakerphone at 16 kHz is
  /// not running a Bluetooth profile.
  public static func narrowbandTitle(device: String) -> String {
    "Qualidade reduzida com \(device) (áudio em banda estreita)."
  }

  /// The picker's first row: follow whatever macOS is using.
  public static let followSystemDefault = "Padrão do sistema"
  /// Appended to the device that currently IS the system default.
  public static let defaultSuffix = "(padrão)"
  public static let noInputDevice = "Nenhum microfone disponível."

  /// Shown when the persisted device is not attached right now.
  public static func selectionUnavailable(device: String?) -> String {
    guard let device, !device.isEmpty else {
      return "O microfone escolhido não está disponível — usando o padrão do sistema."
    }
    return "\(device) não está disponível — usando o padrão do sistema."
  }
}
