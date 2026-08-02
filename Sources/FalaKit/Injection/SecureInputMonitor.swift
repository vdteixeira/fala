import Carbon.HIToolbox
import Foundation

/// Production `SecureInputMonitoring`, backed by Carbon's
/// `IsSecureEventInputEnabled()` (SPEC.md FR-13, US-3).
///
/// Secure input is a *system-wide* mode: any process (Terminal with secure
/// keyboard entry, a password field, a VPN prompt, the login window) can turn it
/// on, and while it is on no synthesised keyboard event reaches the focused
/// field. Reading it is a cheap, non-blocking C call with no TCC requirement, so
/// callers may probe it on every injection instead of caching a stale answer.
///
/// The probe is injected so the wrapper itself stays testable; tests of the
/// *policy* should substitute their own `SecureInputMonitoring` instead.
public struct SecureInputMonitor: SecureInputMonitoring {
  private let probe: @Sendable () -> Bool

  /// - Parameter probe: overrides the system call. Defaults to Carbon's
  ///   `IsSecureEventInputEnabled()`; only tests should pass anything else.
  public init(probe: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }) {
    self.probe = probe
  }

  public var isSecureInputActive: Bool { probe() }
}
