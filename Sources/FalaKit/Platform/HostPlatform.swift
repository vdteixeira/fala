import Darwin
import Foundation

/// A macOS version, comparable and printable.
///
/// `Foundation.OperatingSystemVersion` is neither `Equatable` nor `Comparable`,
/// so a version floor written against it cannot be tested or compared without
/// re-implementing both — this is that value type, small enough to construct in
/// a test for an OS nobody here is running.
public struct HostOSVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(major: Int, minor: Int, patch: Int = 0) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public init(_ version: OperatingSystemVersion) {
    self.init(
      major: version.majorVersion,
      minor: version.minorVersion,
      patch: version.patchVersion)
  }

  public static func < (lhs: HostOSVersion, rhs: HostOSVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  /// How the user sees the version in Ajustes do Sistema: "14.0", "13.6.1".
  public var description: String {
    patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
  }
}

/// What kind of CPU this Mac has, as the kernel reports it.
public enum HostArchitecture: Sendable, Equatable {

  /// `hw.optional.arm64` reports 1 — an M-series machine.
  case appleSilicon

  /// The kernel reports 0 for `hw.optional.arm64`, or has no such key at all.
  /// The absent-key form is the one a real Intel Mac is expected to take.
  case intel

  /// The read failed for some reason OTHER than "no such key", so this machine
  /// could not be classified. Callers MUST NOT refuse on this — see the
  /// fail-open note on `HostPlatform.refusal`.
  case unknown
}

/// Why Fala cannot run on this Mac (SPEC.md NFR-4).
///
/// Every case carries a pt-BR explanation aimed at someone who has just
/// double-clicked the app and knows nothing about the build: it names what is
/// wrong and the one thing they can do about it, including when that is
/// "nothing".
public enum PlatformRefusal: Error, Equatable, Sendable {

  /// A Mac with an Intel CPU. There is no Neural Engine to run the model on and
  /// no setting that changes that.
  case intelMac

  /// Apple Silicon, but this process is being translated by Rosetta. Distinct
  /// from `intelMac` on purpose: the hardware is fine and the user can fix it
  /// in two clicks, so telling them "your Mac is unsupported" would be false.
  case rosettaTranslation

  /// macOS older than the floor. `found` is what this machine reports.
  case operatingSystemTooOld(found: HostOSVersion, required: HostOSVersion)

  /// One line, pt-BR — fits a dialog title or a menu-bar row.
  public var title: String {
    switch self {
    case .intelMac:
      return "O \(MenuBarStrings.brandName) não funciona em Macs com processador Intel."
    case .rosettaTranslation:
      return "O \(MenuBarStrings.brandName) está sendo aberto pela Rosetta."
    case .operatingSystemTooOld(_, let required):
      return "O \(MenuBarStrings.brandName) precisa do macOS \(required) ou mais recente."
    }
  }

  /// What is wrong and what to do about it, pt-BR. Shown when the app refuses
  /// to start, so it must be readable by someone who did not build it.
  public var explanation: String {
    switch self {
    case .intelMac:
      return """
        Este Mac tem processador Intel, e o Fala só funciona em Macs com chip \
        Apple (M1, M2, M3 ou M4): a transcrição roda no Neural Engine, que os \
        Macs Intel não têm.

        Não há ajuste que resolva. Para conferir qual é o seu, abra o menu \
        Apple › Sobre este Mac.
        """
    case .rosettaTranslation:
      return """
        O Fala está sendo executado pela Rosetta, o modo de compatibilidade \
        com apps feitos para Macs Intel. Assim ele não consegue usar o Neural \
        Engine do seu Mac, que é onde a transcrição acontece.

        Para corrigir: feche o Fala, clique nele com o botão direito no \
        Finder, escolha "Obter Informações" e desmarque "Abrir usando o \
        Rosetta". Depois abra o \(MenuBarStrings.brandName) de novo.
        """
    case .operatingSystemTooOld(let found, let required):
      return """
        Este Mac está com o macOS \(found), e o Fala precisa do macOS \
        \(required) ou mais recente.

        Atualize em \(Self.softwareUpdatePath(on: found)) e abra o Fala de novo.
        """
    }
  }

  /// Software Update moved and was renamed in macOS 13. Sending a user on
  /// macOS 12 to "Ajustes do Sistema" sends them to a menu item that does not
  /// exist on their machine, which is the one thing this message cannot afford.
  private static func softwareUpdatePath(on version: HostOSVersion) -> String {
    version.major >= 13
      ? "Ajustes do Sistema › Geral › Atualização de Software"
      : "Preferências do Sistema › Atualização de Software"
  }
}

/// The three questions NFR-4 turns on.
///
/// Behind a protocol because the interesting answers are the ones this project's
/// only hardware can never produce: every machine it is built and tested on is a
/// native Apple Silicon Mac, so "refuses on Intel" is unreachable in a test
/// unless the probe can be substituted.
public protocol HostPlatformProbing: Sendable {
  var architecture: HostArchitecture { get }
  var isTranslated: Bool { get }
  var osVersion: HostOSVersion { get }
}

/// One integer `sysctl` read.
///
/// Keeps "this kernel has no such key" separate from "the read failed", because
/// on this decision they mean opposite things: a missing `hw.optional.arm64` IS
/// the Intel answer, while a failed read means we learned nothing.
enum SysctlReading: Equatable, Sendable {
  case value(Int32)

  /// `ENOENT` — no such key on this kernel.
  case missing

  /// Any other failure, carrying the `errno` that caused it.
  case failed(errno: Int32)
}

/// Production `HostPlatformProbing`, backed by `sysctl`.
///
/// **Why `sysctl` and not `#if arch(arm64)`.** The conditional is answered by
/// the COMPILER, so it describes the slice being built, not the machine the
/// binary ends up on. An arm64 slice inside a universal app can be relaunched
/// under Rosetta (Finder's "Abrir usando o Rosetta"), and an x86_64-only build
/// always is; in both cases `#if arch(arm64)` gives an answer about the wrong
/// thing. `sysctl` asks the running kernel about the running process.
///
/// **Measured on this machine, 2026-08-02** (macOS 26.3, M-series), with the
/// same C probe compiled for both architectures:
///
/// | key                      | native arm64 | under Rosetta |
/// |--------------------------|--------------|---------------|
/// | `hw.optional.arm64`      | 1            | 1             |
/// | `sysctl.proc_translated` | 0            | 1             |
/// | `hw.cputype`             | 16777228     | 7             |
///
/// The first row is the trap: `hw.optional.arm64` still reports 1 under
/// translation, so it CANNOT distinguish a translated process from a native
/// one. `sysctl.proc_translated` is the only signal that separates them, which
/// is why `HostPlatform` consults it first.
public struct SysctlHostPlatformProbe: HostPlatformProbing {

  /// 1 on Apple Silicon. Absent on Intel Macs (unverified here — no Intel Mac
  /// to read it on; `.missing` and a literal 0 are both treated as Intel so
  /// either shape lands on the same answer).
  static let appleSiliconKey = "hw.optional.arm64"

  /// 1 when this process is running under Rosetta, 0 when native. Apple's own
  /// sample code documents `ENOENT` as "not translated", which is what an Intel
  /// kernel returns.
  static let translationKey = "sysctl.proc_translated"

  private let read: @Sendable (String) -> SysctlReading
  private let currentOSVersion: @Sendable () -> HostOSVersion

  public init() {
    self.init(read: Self.readInteger, currentOSVersion: Self.systemVersion)
  }

  /// Test seam: substitutes the raw kernel reads, so the decoding of an absent
  /// key or a failed call can be exercised without the hardware that produces
  /// them.
  init(
    read: @escaping @Sendable (String) -> SysctlReading,
    currentOSVersion: @escaping @Sendable () -> HostOSVersion = SysctlHostPlatformProbe
      .systemVersion
  ) {
    self.read = read
    self.currentOSVersion = currentOSVersion
  }

  public var architecture: HostArchitecture {
    switch read(Self.appleSiliconKey) {
    case .value(let flag):
      return flag == 1 ? .appleSilicon : .intel
    case .missing:
      return .intel
    case .failed:
      return .unknown
    }
  }

  public var isTranslated: Bool {
    switch read(Self.translationKey) {
    case .value(let flag):
      return flag == 1
    case .missing, .failed:
      // Apple documents ENOENT as "not translated"; a failed read is not
      // evidence of translation either, and claiming it would refuse a working
      // native Mac.
      return false
    }
  }

  public var osVersion: HostOSVersion { currentOSVersion() }

  private static let readInteger: @Sendable (String) -> SysctlReading = { name in
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
      let code = errno
      return code == ENOENT ? .missing : .failed(errno: code)
    }
    return .value(value)
  }

  private static let systemVersion: @Sendable () -> HostOSVersion = {
    HostOSVersion(ProcessInfo.processInfo.operatingSystemVersion)
  }
}

/// Whether this Mac can run Fala at all, and the pt-BR reason when it cannot
/// (SPEC.md NFR-4: macOS 14.0+, Apple Silicon only, refuse on Intel).
///
/// This is the first thing the app should ask, before any permission prompt and
/// well before the ~480 MB model download: on unsupported hardware the download
/// is a several-minute wait whose reward is a crash inside CoreML.
public struct HostPlatform: Sendable {

  /// NFR-4's floor, which is also FluidAudio 0.15.5's own minimum.
  public static let minimumOS = HostOSVersion(major: 14, minor: 0)

  private let probe: any HostPlatformProbing

  public init(probe: any HostPlatformProbing = SysctlHostPlatformProbe()) {
    self.probe = probe
  }

  /// Why the app must refuse, or `nil` when this Mac is supported.
  ///
  /// **Order matters.** Translation is checked first because a translated
  /// process still reports `hw.optional.arm64 == 1` (measured — see
  /// `SysctlHostPlatformProbe`), so an architecture-first test would wave it
  /// through as native. Checking it first is also the more robust order if a
  /// future Rosetta masks that key: the process would look Intel, and
  /// "you are running under Rosetta" is still the true, fixable answer, since
  /// Rosetta exists only on Apple Silicon.
  ///
  /// **This fails OPEN on `.unknown`.** If the architecture read fails in a way
  /// that is not "no such key", the app runs. Refusing a working Apple Silicon
  /// Mac because a `sysctl` misbehaved would leave the user with a dead app and
  /// no workaround, which is strictly worse than the pre-existing behaviour on
  /// hardware that cannot work anyway.
  ///
  /// Cheap enough to ask repeatedly: two `sysctl` reads and a `ProcessInfo`
  /// lookup, no allocation, no TCC, no I/O.
  public var refusal: PlatformRefusal? {
    if probe.isTranslated { return .rosettaTranslation }
    if probe.architecture == .intel { return .intelMac }
    let version = probe.osVersion
    if version < Self.minimumOS {
      return .operatingSystemTooOld(found: version, required: Self.minimumOS)
    }
    return nil
  }

  public var isSupported: Bool { refusal == nil }
}
