import FalaKit

/// Test double for `HostPlatformProbing` (SPEC.md NFR-4).
///
/// It exists because every machine this project is built and tested on is a
/// native Apple Silicon Mac running a current macOS — so the three answers that
/// actually matter (Intel, Rosetta, an OS below the floor) cannot be produced by
/// the hardware under the test. Without this seam the refusal path would ship
/// having never once executed.
///
/// ```swift
/// let platform = HostPlatform(probe: MockHostPlatformProbe.intel)
/// #expect(platform.refusal == .intelMac)
/// ```
struct MockHostPlatformProbe: HostPlatformProbing {
  var architecture: HostArchitecture = .appleSilicon
  var isTranslated = false
  var osVersion = HostOSVersion(major: 14, minor: 0)

  /// The supported machine: native M-series, current OS.
  static let appleSiliconNative = MockHostPlatformProbe()

  /// A real Intel Mac. `hw.optional.arm64` is absent there, which
  /// `SysctlHostPlatformProbe` maps to `.intel`.
  static let intel = MockHostPlatformProbe(architecture: .intel)

  /// The combination MEASURED under Rosetta on this machine on 2026-08-02:
  /// `hw.optional.arm64` still reports 1, so the hardware looks native and only
  /// `sysctl.proc_translated` gives the process away.
  static let rosetta = MockHostPlatformProbe(architecture: .appleSilicon, isTranslated: true)

  /// A machine the architecture probe could not classify — a `sysctl` failure
  /// that is not "no such key".
  static let unclassifiable = MockHostPlatformProbe(architecture: .unknown)

  /// The same machine, on an older OS.
  func running(_ version: HostOSVersion) -> MockHostPlatformProbe {
    var copy = self
    copy.osVersion = version
    return copy
  }
}
