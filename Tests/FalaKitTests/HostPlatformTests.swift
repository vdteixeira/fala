import Darwin
import Foundation
import Testing

@testable import FalaKit

/// NFR-4's refusal half: macOS 14.0+, Apple Silicon only, refuse on Intel.
///
/// The difficulty this suite exists to solve is that the requirement is about
/// hardware nobody here has. Every machine this package is built and tested on
/// is a native Apple Silicon Mac on a current macOS, so an Intel refusal, a
/// Rosetta refusal and an old-OS refusal are all unreachable through the real
/// `sysctl` calls. Two seams make them reachable: `HostPlatformProbing` (for the
/// policy) and `SysctlHostPlatformProbe`'s injected kernel reads (for the
/// decoding of what a non-Apple-Silicon kernel actually returns).
///
/// The numbers the fakes are built from are not invented. They were measured on
/// this machine on 2026-08-02 (macOS 26.3, Apple Silicon) by compiling one C
/// probe for both architectures and running the x86_64 one under Rosetta:
///
/// | key                      | native arm64 | under Rosetta |
/// |--------------------------|--------------|---------------|
/// | `hw.optional.arm64`      | 1            | 1             |
/// | `sysctl.proc_translated` | 0            | 1             |
///
/// The Intel column could NOT be measured — there is no Intel Mac here — so the
/// tests below pin the two shapes an Intel kernel could plausibly take (absent
/// key, or the key reporting 0) and require both to refuse.
@Suite struct HostPlatformTests {

  // MARK: - The supported machine

  @Test("A native Apple Silicon Mac on macOS 14 or newer is supported")
  func nativeAppleSiliconIsSupported() {
    for version in [
      HostOSVersion(major: 14, minor: 0),
      HostOSVersion(major: 15, minor: 4, patch: 1),
      HostOSVersion(major: 26, minor: 3),
    ] {
      let platform = HostPlatform(probe: MockHostPlatformProbe.appleSiliconNative.running(version))
      #expect(platform.refusal == nil)
      #expect(platform.isSupported)
    }
  }

  // MARK: - Intel

  @Test("An Intel Mac is refused")
  func intelMacIsRefused() {
    let platform = HostPlatform(probe: MockHostPlatformProbe.intel)
    #expect(!platform.isSupported)
    #expect(platform.refusal == .intelMac)
  }

  /// Both problems are real on an Intel Mac running macOS 12, but only one of
  /// them has a remedy, and it is not the OS: updating macOS would leave the
  /// user exactly where they started. The unfixable reason has to win.
  @Test("An old Intel Mac is told about the CPU, not about the macOS version")
  func intelMacOnOldOSReportsTheCPU() {
    let probe = MockHostPlatformProbe.intel.running(HostOSVersion(major: 12, minor: 7))
    #expect(HostPlatform(probe: probe).refusal == .intelMac)
  }

  // MARK: - Rosetta

  /// THE case an architecture-only check gets wrong. Measured: a translated
  /// process still reads `hw.optional.arm64 == 1`, so the hardware looks native
  /// and nothing but `sysctl.proc_translated` separates it from the real thing.
  @Test("A translated process is refused even though the hardware reports Apple Silicon")
  func rosettaIsRefusedDespiteAppleSiliconHardware() {
    let probe = MockHostPlatformProbe.rosetta
    #expect(probe.architecture == .appleSilicon)
    #expect(HostPlatform(probe: probe).refusal == .rosettaTranslation)
  }

  /// Worth its own case: the binary runs, the Mac is fine, and the remedy is two
  /// clicks in the Finder. Collapsing it into `.intelMac` would tell a user with
  /// a perfectly good M-series Mac that their computer is unsupported.
  @Test("Rosetta is a distinct refusal from Intel, with a distinct message")
  func rosettaIsNotReportedAsIntel() throws {
    let refusal = try #require(HostPlatform(probe: MockHostPlatformProbe.rosetta).refusal)
    #expect(refusal != .intelMac)
    #expect(refusal.explanation != PlatformRefusal.intelMac.explanation)
    #expect(refusal.title != PlatformRefusal.intelMac.title)
  }

  /// Defensive ordering. Rosetta 2 exists only on Apple Silicon, so if a future
  /// version masked `hw.optional.arm64` and the machine looked Intel, "you are
  /// running under Rosetta" would still be the true and fixable answer.
  @Test("Translation is reported even if the architecture probe claims Intel")
  func translationWinsOverAnIntelLookingArchitecture() {
    let probe = MockHostPlatformProbe(architecture: .intel, isTranslated: true)
    #expect(HostPlatform(probe: probe).refusal == .rosettaTranslation)
  }

  // MARK: - The OS floor

  @Test("macOS below 14.0 is refused, and the refusal names what was found")
  func oldOperatingSystemIsRefused() {
    let found = HostOSVersion(major: 13, minor: 6, patch: 1)
    let platform = HostPlatform(probe: MockHostPlatformProbe.appleSiliconNative.running(found))
    #expect(
      platform.refusal
        == .operatingSystemTooOld(found: found, required: HostOSVersion(major: 14, minor: 0)))
  }

  @Test("The floor is 14.0 exactly: 13.7.9 refuses, 14.0.0 does not")
  func floorIsInclusiveAtFourteenPointZero() {
    let justBelow = MockHostPlatformProbe.appleSiliconNative
      .running(HostOSVersion(major: 13, minor: 7, patch: 9))
    let exactly = MockHostPlatformProbe.appleSiliconNative
      .running(HostOSVersion(major: 14, minor: 0, patch: 0))
    #expect(HostPlatform(probe: justBelow).refusal != nil)
    #expect(HostPlatform(probe: exactly).refusal == nil)
    #expect(HostPlatform.minimumOS == HostOSVersion(major: 14, minor: 0))
  }

  // MARK: - Failing open

  /// The worst outcome this feature can produce is not letting an Intel Mac
  /// through — that machine fails anyway. It is refusing a working M-series Mac,
  /// because there is no workaround for that user. An unclassifiable CPU must
  /// therefore run.
  @Test("A CPU the probe could not classify does NOT refuse")
  func unknownArchitectureDoesNotRefuse() {
    #expect(HostPlatform(probe: MockHostPlatformProbe.unclassifiable).refusal == nil)
  }

  // MARK: - What the user is told

  @Test("The Intel refusal explains itself in pt-BR and says nothing can be done")
  func intelExplanationIsActionablePortuguese() {
    let explanation = PlatformRefusal.intelMac.explanation
    #expect(explanation.contains("Intel"))
    #expect(explanation.contains("chip Apple"))
    #expect(explanation.contains("Sobre este Mac"))
    #expect(explanation.contains("Não há ajuste que resolva"))
    #expect(PlatformRefusal.intelMac.title.contains("Intel"))
  }

  @Test("The Rosetta refusal explains the two clicks that fix it, in pt-BR")
  func rosettaExplanationNamesTheFix() {
    let explanation = PlatformRefusal.rosettaTranslation.explanation
    #expect(explanation.contains("Rosetta"))
    #expect(explanation.contains("Obter Informações"))
    #expect(explanation.contains("Abrir usando o Rosetta"))
  }

  @Test("The OS refusal names both versions and where to update")
  func operatingSystemExplanationNamesBothVersions() {
    let refusal = PlatformRefusal.operatingSystemTooOld(
      found: HostOSVersion(major: 13, minor: 6, patch: 1),
      required: HostOSVersion(major: 14, minor: 0))
    #expect(refusal.explanation.contains("13.6.1"))
    #expect(refusal.explanation.contains("14.0"))
    #expect(refusal.explanation.contains("Atualização de Software"))
    #expect(refusal.title.contains("macOS 14.0"))
  }

  /// System Settings was renamed and rearranged in macOS 13. Sending a user on
  /// macOS 12 to "Ajustes do Sistema" names a menu item that does not exist on
  /// their machine.
  @Test("The update instructions match the macOS the user is actually on")
  func updateInstructionsMatchTheUsersOS() {
    let required = HostOSVersion(major: 14, minor: 0)
    let ventura = PlatformRefusal.operatingSystemTooOld(
      found: HostOSVersion(major: 13, minor: 6), required: required)
    let monterey = PlatformRefusal.operatingSystemTooOld(
      found: HostOSVersion(major: 12, minor: 7), required: required)
    #expect(ventura.explanation.contains("Ajustes do Sistema"))
    #expect(monterey.explanation.contains("Preferências do Sistema"))
    #expect(!monterey.explanation.contains("Ajustes do Sistema"))
  }

  // MARK: - Decoding what the kernel returns

  @Test("hw.optional.arm64 reporting 1 is Apple Silicon")
  func armFlagOneIsAppleSilicon() {
    #expect(Self.probe(arm64: .value(1)).architecture == .appleSilicon)
  }

  /// The expected Intel signature: the key does not exist on that kernel.
  @Test("A missing hw.optional.arm64 is an Intel Mac")
  func missingArmKeyIsIntel() {
    #expect(Self.probe(arm64: .missing).architecture == .intel)
    #expect(HostPlatform(probe: Self.probe(arm64: .missing)).refusal == .intelMac)
  }

  /// Belt and braces for the column that could not be measured: if an Intel
  /// kernel publishes the key with a 0 instead of omitting it, that must refuse
  /// too.
  @Test("hw.optional.arm64 reporting 0 is also an Intel Mac")
  func armFlagZeroIsIntel() {
    #expect(Self.probe(arm64: .value(0)).architecture == .intel)
  }

  @Test("A failed read is 'unknown', not 'Intel' — it is not evidence of anything")
  func failedArmReadIsUnknown() {
    let probe = Self.probe(arm64: .failed(errno: EINVAL))
    #expect(probe.architecture == .unknown)
    #expect(HostPlatform(probe: probe).refusal == nil)
  }

  @Test("sysctl.proc_translated of 1 is translation, 0 is not")
  func translationFlagIsDecoded() {
    #expect(Self.probe(translated: .value(1)).isTranslated)
    #expect(!Self.probe(translated: .value(0)).isTranslated)
  }

  /// Apple's own sample code documents `ENOENT` as "not translated" — that is
  /// what an Intel kernel returns, and reading it as "translated" would hand an
  /// Intel user the Rosetta message instead of the truth.
  @Test("A missing sysctl.proc_translated means not translated")
  func missingTranslationKeyIsNotTranslated() {
    #expect(!Self.probe(translated: .missing).isTranslated)
    #expect(!Self.probe(translated: .failed(errno: EPERM)).isTranslated)
  }

  /// A kernel that answers ONLY the two documented key names and reports every
  /// other key as absent. If the production probe asked for anything else, both
  /// reads would come back `.missing` and this Mac would be misread as a
  /// native-but-Intel machine — so the assertions below pin the literal strings.
  @Test("The probe reads exactly the two documented sysctl keys")
  func probeReadsTheDocumentedKeys() {
    #expect(SysctlHostPlatformProbe.appleSiliconKey == "hw.optional.arm64")
    #expect(SysctlHostPlatformProbe.translationKey == "sysctl.proc_translated")

    let probe = SysctlHostPlatformProbe(read: { name in
      switch name {
      case "hw.optional.arm64", "sysctl.proc_translated": return .value(1)
      default: return .missing
      }
    })
    #expect(probe.architecture == .appleSilicon)
    #expect(probe.isTranslated)
  }

  // MARK: - The real kernel

  /// The only test here that touches the real `sysctl` calls, and the reason the
  /// rest are not tautologies: it proves the production probe is wired to the
  /// kernel at all, rather than that a fake returns what it was told to.
  ///
  /// It asserts NFR-4's own premise — this project is built and tested only on
  /// native Apple Silicon — so it necessarily encodes the hardware it runs on.
  /// If it ever fails on a supported Mac, the wiring broke.
  @Test("On this machine the real probe reports a native, supported Apple Silicon Mac")
  func realProbeClassifiesThisMachine() {
    let probe = SysctlHostPlatformProbe()
    #expect(probe.architecture == .appleSilicon)
    #expect(!probe.isTranslated)
    #expect(probe.osVersion >= HostPlatform.minimumOS)
    #expect(HostPlatform().isSupported)
  }

  /// Cross-checks the real read against the same value obtained independently,
  /// so a probe that silently returned a constant would be caught.
  @Test("The real read agrees with an independent sysctl of the same key")
  func realReadAgreesWithAnIndependentSysctl() {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let status = sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0)
    #expect(status == 0)
    #expect(SysctlHostPlatformProbe().isTranslated == (value == 1))
  }

  // MARK: - Version arithmetic

  @Test("Versions compare component by component, not as decimals")
  func versionsCompareByComponent() {
    #expect(HostOSVersion(major: 13, minor: 10) < HostOSVersion(major: 14, minor: 0))
    // 14.10 is NEWER than 14.9 — a decimal comparison would get this backwards.
    #expect(HostOSVersion(major: 14, minor: 9) < HostOSVersion(major: 14, minor: 10))
    #expect(HostOSVersion(major: 14, minor: 0) < HostOSVersion(major: 14, minor: 0, patch: 1))
    #expect(!(HostOSVersion(major: 14, minor: 0) < HostOSVersion(major: 14, minor: 0)))
  }

  @Test("Versions print the way the user sees them in Ajustes do Sistema")
  func versionDescriptionMatchesSystemSettings() {
    #expect(HostOSVersion(major: 14, minor: 0).description == "14.0")
    #expect(HostOSVersion(major: 13, minor: 6, patch: 1).description == "13.6.1")
  }

  @Test("A Foundation OperatingSystemVersion converts component for component")
  func conversionFromFoundationKeepsComponents() {
    let version = HostOSVersion(
      OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 2))
    #expect(version == HostOSVersion(major: 15, minor: 4, patch: 2))
  }

  // MARK: - Helpers

  /// A production probe with the kernel reads faked. Whichever key the test does
  /// not care about answers the way a healthy Apple Silicon Mac does.
  private static func probe(
    arm64: SysctlReading = .value(1),
    translated: SysctlReading = .value(0)
  ) -> SysctlHostPlatformProbe {
    SysctlHostPlatformProbe(
      read: { name in
        name == SysctlHostPlatformProbe.appleSiliconKey ? arm64 : translated
      },
      currentOSVersion: { HostOSVersion(major: 14, minor: 0) })
  }
}
