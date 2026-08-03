import Foundation
import os

@testable import FalaKit

/// Stands in for `SMAppService.mainApp` (FR-19).
///
/// It exists because the real thing writes to the login items of whatever Mac
/// runs the suite: a single honest test of `register()` would leave this
/// checkout's `Fala.app` starting at boot on the developer's machine, and a test
/// of `requiresApproval` would need a human to go and disable it in Ajustes do
/// Sistema first.
///
/// The three outcomes are modelled after how `SMAppService` actually behaves,
/// including the one that matters most: a `register()` that returns WITHOUT an
/// error and leaves the status unchanged.
final class FakeLoginItemRegistration: LoginItemRegistering {

  enum Outcome: Sendable {
    /// Registers/unregisters for real: the status becomes what was asked for.
    case succeeds

    /// Returns without throwing and changes nothing — what macOS does when the
    /// user has already made this decision in System Settings.
    case silentlyIgnored

    /// Throws. The status is whatever the test set it to.
    case fails(message: String)
  }

  struct State: Sendable {
    var status: LoginItemStatus
    var registerOutcome: Outcome = .succeeds
    var unregisterOutcome: Outcome = .succeeds
    var registerCalls = 0
    var unregisterCalls = 0
    /// How many times anything asked the system for the current status. The
    /// counter is the only way to prove the app is not answering from a cache.
    var statusReads = 0
  }

  private let state: OSAllocatedUnfairLock<State>

  init(status: LoginItemStatus = .notRegistered) {
    self.state = OSAllocatedUnfairLock(initialState: State(status: status))
  }

  // MARK: - LoginItemRegistering

  var status: LoginItemStatus {
    state.withLock {
      $0.statusReads += 1
      return $0.status
    }
  }

  func register() throws {
    let outcome = state.withLock {
      $0.registerCalls += 1
      return $0.registerOutcome
    }
    switch outcome {
    case .succeeds: state.withLock { $0.status = .enabled }
    case .silentlyIgnored: break
    case .fails(let message): throw Self.error(message)
    }
  }

  func unregister() throws {
    let outcome = state.withLock {
      $0.unregisterCalls += 1
      return $0.unregisterOutcome
    }
    switch outcome {
    case .succeeds: state.withLock { $0.status = .notRegistered }
    case .silentlyIgnored: break
    case .fails(let message): throw Self.error(message)
    }
  }

  // MARK: - Test control

  /// The system's answer, settable so a test can play "the user just changed
  /// this in Ajustes do Sistema".
  var currentStatus: LoginItemStatus {
    get { state.withLock { $0.status } }
    set { state.withLock { $0.status = newValue } }
  }

  var registerOutcome: Outcome {
    get { state.withLock { $0.registerOutcome } }
    set { state.withLock { $0.registerOutcome = newValue } }
  }

  var unregisterOutcome: Outcome {
    get { state.withLock { $0.unregisterOutcome } }
    set { state.withLock { $0.unregisterOutcome = newValue } }
  }

  var registerCalls: Int { state.withLock { $0.registerCalls } }
  var unregisterCalls: Int { state.withLock { $0.unregisterCalls } }
  var statusReads: Int { state.withLock { $0.statusReads } }

  private static func error(_ message: String) -> NSError {
    NSError(
      domain: "SMAppServiceErrorDomain", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }
}

/// A controller wired to `registration` and told it lives in a real `.app`.
///
/// Every test process runs from a bare executable, so without the injected
/// bundle URL `LoginItemController` would (correctly) refuse everything with
/// `.notBundled` and nothing else would ever be exercised.
func makeBundledController(_ registration: FakeLoginItemRegistration) -> LoginItemController {
  LoginItemController(
    registration: registration,
    bundleURL: { URL(fileURLWithPath: "/Applications/Fala.app") })
}
