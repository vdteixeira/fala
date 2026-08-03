import Foundation
import ServiceManagement
import Testing

@testable import FalaKit

/// FR-19 — "Iniciar no login", the part that talks to macOS.
///
/// The whole suite runs against `FakeLoginItemRegistration` because the real
/// `SMAppService.mainApp` would register THIS checkout as a login item on the
/// machine running the tests. What is asserted here is the policy that sits on
/// top of it, and that policy exists for one reason: `SMAppService` can report
/// success for a registration that will never fire.
@Suite struct LoginItemControllerTests {

  // MARK: - Turning it on

  @Test("Registering reports enabled once the system agrees")
  func registerEnables() throws {
    let registration = FakeLoginItemRegistration(status: .notRegistered)
    let controller = makeBundledController(registration)

    #expect(controller.status == .notRegistered)
    let observed = try controller.setEnabled(true)

    #expect(observed == .enabled)
    #expect(controller.status == .enabled)
    #expect(registration.registerCalls == 1)
  }

  @Test("Unregistering reports disabled")
  func unregisterDisables() throws {
    let registration = FakeLoginItemRegistration(status: .enabled)
    let controller = makeBundledController(registration)

    let observed = try controller.setEnabled(false)

    #expect(observed == .notRegistered)
    #expect(controller.status == .notRegistered)
    #expect(registration.unregisterCalls == 1)
  }

  // MARK: - The state that must not be papered over

  /// The one that makes the toggle honest. `SMAppService.register()` returns
  /// without an error when the user has switched the item off in Ajustes do
  /// Sistema, and the login item still does not fire. Believing the absence of
  /// an error is how a toggle ends up showing "ligado" for an app that will
  /// never start.
  @Test("A register that returns success but leaves the item unapproved fails")
  func silentFailureToRegisterIsReported() {
    let registration = FakeLoginItemRegistration(status: .requiresApproval)
    registration.registerOutcome = .silentlyIgnored
    let controller = makeBundledController(registration)

    #expect(throws: LoginItemError.requiresApproval) {
      try controller.setEnabled(true)
    }
    #expect(controller.status == .requiresApproval)
  }

  @Test("A register that throws while the system says requiresApproval says so")
  func throwingRegisterPrefersTheSystemState() {
    let registration = FakeLoginItemRegistration(status: .requiresApproval)
    registration.registerOutcome = .fails(message: "Operation not permitted")
    let controller = makeBundledController(registration)

    // The system's own word beats the API's error string: "precisa da sua
    // autorização" tells the user which switch to flip, "Operation not
    // permitted" does not.
    #expect(throws: LoginItemError.requiresApproval) {
      try controller.setEnabled(true)
    }
  }

  @Test("The app cannot override a user who disabled the item")
  func requiresApprovalCannotBeOverridden() {
    let registration = FakeLoginItemRegistration(status: .requiresApproval)
    registration.registerOutcome = .silentlyIgnored
    let controller = makeBundledController(registration)

    for _ in 0..<3 {
      #expect(throws: LoginItemError.requiresApproval) {
        try controller.setEnabled(true)
      }
    }
    // Calling register() again did not flip it, and the reported state never
    // pretended otherwise.
    #expect(controller.status == .requiresApproval)
    #expect(!controller.status.isEnabled)
    #expect(controller.status.needsSystemSettings)
    #expect(controller.status.settingsURL == LoginItemSettings.loginItemsURL)
  }

  @Test("A registration macOS cannot manage is reported as unavailable")
  func notFoundIsReported() {
    let registration = FakeLoginItemRegistration(status: .unavailable)
    registration.registerOutcome = .silentlyIgnored
    let controller = makeBundledController(registration)

    #expect(throws: LoginItemError.unavailable) {
      try controller.setEnabled(true)
    }
  }

  @Test("An unexplained refusal carries the system's message")
  func otherFailuresCarryTheSystemMessage() {
    let registration = FakeLoginItemRegistration(status: .notRegistered)
    registration.registerOutcome = .fails(message: "Unable to read plist")
    let controller = makeBundledController(registration)

    #expect(throws: LoginItemError.systemRefused(message: "Unable to read plist")) {
      try controller.setEnabled(true)
    }
  }

  @Test("A silent no-op that leaves the item unregistered is not called success")
  func silentNoOpIsNotSuccess() {
    let registration = FakeLoginItemRegistration(status: .notRegistered)
    registration.registerOutcome = .silentlyIgnored
    let controller = makeBundledController(registration)

    #expect(throws: LoginItemError.didNotTakeEffect(.notRegistered)) {
      try controller.setEnabled(true)
    }
  }

  // MARK: - Turning it off

  /// Unregistering something that was never registered throws on some macOS
  /// versions. The user's goal is "off", and it is already off — reporting an
  /// error would put a red caption under a correctly-off switch.
  @Test("Unregistering something already off is not an error")
  func unregisteringWhenAlreadyOffSucceeds() throws {
    let registration = FakeLoginItemRegistration(status: .notRegistered)
    registration.unregisterOutcome = .fails(message: "No such service")
    let controller = makeBundledController(registration)

    try controller.unregister()
    #expect(controller.status == .notRegistered)
    #expect(registration.unregisterCalls == 1)
  }

  @Test("An unregister that leaves the item enabled fails")
  func unregisterMustActuallyTakeEffect() {
    let registration = FakeLoginItemRegistration(status: .enabled)
    registration.unregisterOutcome = .silentlyIgnored
    let controller = makeBundledController(registration)

    #expect(throws: LoginItemError.didNotTakeEffect(.enabled)) {
      try controller.setEnabled(false)
    }
  }

  // MARK: - Not an app bundle

  /// `swift run Fala install --launch-at-login` from a terminal. There is no
  /// bundle for `SMAppService` to register, and the failure has to name the fix.
  @Test("Outside an .app bundle, enabling refuses before calling the system")
  func refusesOutsideABundle() {
    let registration = FakeLoginItemRegistration(status: .notRegistered)
    let controller = LoginItemController(
      registration: registration,
      bundleURL: { URL(fileURLWithPath: "/Users/someone/Projetos/tracker/.build/debug") })

    #expect(!controller.isAppBundle)
    #expect(throws: LoginItemError.notBundled) {
      try controller.setEnabled(true)
    }
    #expect(registration.registerCalls == 0)
    #expect(LoginItemError.notBundled.message.contains("Fala.app"))
  }

  /// Asymmetric on purpose: turning autostart OFF must work in every situation
  /// where it could have been turned on, including from a terminal after the
  /// bundle moved.
  @Test("Outside an .app bundle, disabling still goes through")
  func disablingWorksOutsideABundle() throws {
    let registration = FakeLoginItemRegistration(status: .enabled)
    let controller = LoginItemController(
      registration: registration,
      bundleURL: { URL(fileURLWithPath: "/tmp") })

    try controller.setEnabled(false)
    #expect(registration.unregisterCalls == 1)
    #expect(controller.status == .notRegistered)
  }

  // MARK: - No cached boolean

  /// The requirement in one test: nothing in the app remembers this setting.
  /// The user can turn it off in Ajustes do Sistema › Geral › Itens de Início
  /// while Fala is running, and the next read has to see it.
  @Test("The status always comes from the system, never from a cache")
  func statusIsNeverCached() throws {
    let registration = FakeLoginItemRegistration(status: .notRegistered)
    let controller = makeBundledController(registration)

    try controller.setEnabled(true)
    #expect(controller.status == .enabled)

    // The user opens System Settings and switches it off behind the app's back.
    registration.currentStatus = .requiresApproval

    #expect(controller.status == .requiresApproval)
    #expect(!controller.status.isEnabled)
  }

  @Test("Every status query hits the system")
  func everyQueryHitsTheSystem() {
    let registration = FakeLoginItemRegistration(status: .enabled)
    let controller = makeBundledController(registration)

    let before = registration.statusReads
    _ = controller.status
    _ = controller.status
    _ = controller.status
    #expect(registration.statusReads == before + 3)
  }
}

/// The mapping of `SMAppService`'s four answers, and the pt-BR each one shows.
@Suite struct LoginItemStatusTests {

  @Test("Every SMAppService status maps to one of ours")
  func mapsSystemStatus() {
    #expect(LoginItemStatus(SMAppService.Status.enabled) == .enabled)
    #expect(LoginItemStatus(SMAppService.Status.notRegistered) == .notRegistered)
    #expect(LoginItemStatus(SMAppService.Status.requiresApproval) == .requiresApproval)
    #expect(LoginItemStatus(SMAppService.Status.notFound) == .unavailable)
  }

  @Test("Only enabled counts as on")
  func onlyEnabledIsOn() {
    for status in LoginItemStatus.allCases {
      #expect(status.isEnabled == (status == .enabled))
    }
  }

  /// The one state where macOS is holding a switch the app may not touch.
  @Test("requiresApproval explains itself and links to System Settings")
  func requiresApprovalExplainsItself() throws {
    let status = LoginItemStatus.requiresApproval
    let explanation = try #require(status.explanation)
    #expect(explanation.contains("Itens de Início"))
    #expect(status.needsSystemSettings)
    #expect(status.settingsURL == LoginItemSettings.loginItemsURL)
  }

  /// The mockup's row is a bare toggle. A caption under a switch that is simply
  /// on or off would be noise the design does not ask for.
  ///
  /// `.unavailable` is in this list because of what was MEASURED on macOS 26.3:
  /// `SMAppService` answers `.notFound` for an app that has simply never
  /// registered, so it is the state every user starts in. A caption there would
  /// warn everyone, on first run, about a problem almost none of them have.
  @Test("The states that need no action say nothing extra")
  func settledStatesAreQuiet() {
    for status in [LoginItemStatus.enabled, .notRegistered, .unavailable] {
      #expect(status.explanation == nil)
      #expect(status.settingsURL == nil)
      #expect(!status.needsSystemSettings)
    }
    // …and the never-registered pair reads as plain "off", not as an error.
    #expect(LoginItemStatus.unavailable.summary == LoginItemStatus.notRegistered.summary)
    #expect(!LoginItemStatus.unavailable.isEnabled)
  }

  /// The same condition, once the user has actually asked for autostart: now it
  /// is a failure, and now it gets the full explanation.
  @Test("Unavailable becomes actionable only as an error")
  func unavailableIsActionableAsAnError() {
    let message = LoginItemError.unavailable.message
    #expect(message.contains("Aplicativos"))
    #expect(message.contains("Terminal"))
    #expect(LoginItemError.unavailable.settingsURL == LoginItemSettings.loginItemsURL)
  }

  @Test("Every status and every error speaks pt-BR")
  func everythingIsPortuguese() {
    for status in LoginItemStatus.allCases {
      #expect(!status.summary.isEmpty)
    }
    let errors: [LoginItemError] = [
      .notBundled, .requiresApproval, .unavailable,
      .systemRefused(message: "x"), .didNotTakeEffect(.notRegistered),
    ]
    for error in errors {
      #expect(!error.message.isEmpty)
    }
    // Sampled words rather than a language detector: the point is that these
    // strings were written for the user, not copied from the API.
    #expect(LoginItemStatus.requiresApproval.summary.contains("autorização"))
    #expect(LoginItemError.notBundled.message.contains("Terminal"))
  }

  @Test("Deep links point at Ajustes do Sistema, not at a made-up scheme")
  func deepLinkIsASystemSettingsURL() throws {
    let url = try #require(LoginItemSettings.loginItemsURL)
    #expect(url.scheme == "x-apple.systempreferences")
    #expect(url.absoluteString.contains("LoginItems"))
  }
}

/// The settings row's model (Ajustes › Geral › "Iniciar no login").
@MainActor
@Suite struct LaunchAtLoginModelTests {

  @Test("The switch follows the system, both ways")
  func togglesBothWays() {
    let registration = FakeLoginItemRegistration(status: .notRegistered)
    let model = LaunchAtLoginModel(item: makeBundledController(registration))

    #expect(!model.isOn)
    model.setOn(true)
    #expect(model.isOn)
    #expect(model.lastError == nil)
    #expect(model.caption == nil)

    model.setOn(false)
    #expect(!model.isOn)
    #expect(model.lastError == nil)
    #expect(registration.registerCalls == 1)
    #expect(registration.unregisterCalls == 1)
  }

  @Test("Toggling to the value it already has writes nothing")
  func idempotentSet() {
    let registration = FakeLoginItemRegistration(status: .enabled)
    let model = LaunchAtLoginModel(item: makeBundledController(registration))

    model.setOn(true)
    #expect(registration.registerCalls == 0)
  }

  /// The requires-approval path, seen from the row: the user flips the switch,
  /// macOS refuses, and the switch has to snap back rather than lie.
  @Test("A refused enable leaves the switch off and explains why")
  func refusedEnableDoesNotLie() throws {
    let registration = FakeLoginItemRegistration(status: .requiresApproval)
    registration.registerOutcome = .silentlyIgnored
    let model = LaunchAtLoginModel(item: makeBundledController(registration))

    model.setOn(true)

    #expect(!model.isOn)
    #expect(model.status == .requiresApproval)
    #expect(model.lastError == .requiresApproval)
    let caption = try #require(model.caption)
    #expect(caption.contains("Itens de Início"))
    #expect(model.isCaptionAProblem)
    #expect(model.settingsURL == LoginItemSettings.loginItemsURL)
  }

  @Test("A later success clears the earlier complaint")
  func successClearsTheError() {
    let registration = FakeLoginItemRegistration(status: .requiresApproval)
    registration.registerOutcome = .silentlyIgnored
    let model = LaunchAtLoginModel(item: makeBundledController(registration))
    model.setOn(true)
    #expect(model.lastError != nil)

    // The user approves it in Ajustes do Sistema and comes back.
    registration.currentStatus = .notRegistered
    registration.registerOutcome = .succeeds
    model.refresh()
    model.setOn(true)

    #expect(model.isOn)
    #expect(model.lastError == nil)
    #expect(model.caption == nil)
    #expect(!model.isCaptionAProblem)
  }

  /// The user turns the item off in System Settings while Ajustes is open. A
  /// model backed by a cached `Bool` would still show the switch on.
  @Test("refresh() picks up a change made outside the app")
  func refreshSeesExternalChanges() {
    let registration = FakeLoginItemRegistration(status: .enabled)
    let model = LaunchAtLoginModel(item: makeBundledController(registration))
    #expect(model.isOn)

    registration.currentStatus = .notRegistered
    #expect(model.isOn)  // not observed yet — the model does not poll

    model.refresh()
    #expect(!model.isOn)
  }

  @Test("Outside an .app bundle the row says so instead of failing silently")
  func outsideABundleTheRowExplains() throws {
    let registration = FakeLoginItemRegistration(status: .notRegistered)
    let controller = LoginItemController(
      registration: registration, bundleURL: { URL(fileURLWithPath: "/tmp") })
    let model = LaunchAtLoginModel(item: controller)

    model.setOn(true)

    #expect(!model.isOn)
    #expect(model.lastError == .notBundled)
    let caption = try #require(model.caption)
    #expect(caption.contains("Fala.app"))
    // Nothing to open in System Settings: the fix is on this side.
    #expect(model.settingsURL == nil)
  }

  /// First run on a real Mac. macOS answers `.notFound` for an app that never
  /// registered (measured on macOS 26.3), and the row has to look like an
  /// ordinary off switch — not like something is broken.
  @Test("A never-registered app shows an ordinary off switch")
  func neverRegisteredLooksLikePlainOff() {
    let model = LaunchAtLoginModel(
      item: makeBundledController(FakeLoginItemRegistration(status: .unavailable)))

    #expect(!model.isOn)
    #expect(model.caption == nil)
    #expect(!model.isCaptionAProblem)
    #expect(model.settingsURL == nil)
  }

  /// …and it is not a dead end: turning it on from there is the normal path.
  @Test("Turning it on from the never-registered state works")
  func enablingFromTheDefaultStateWorks() {
    let registration = FakeLoginItemRegistration(status: .unavailable)
    let model = LaunchAtLoginModel(item: makeBundledController(registration))

    model.setOn(true)

    #expect(model.isOn)
    #expect(model.lastError == nil)
  }

  @Test("The row uses the handoff's icon and label")
  func rowUsesDesignTokens() {
    let model = LaunchAtLoginModel(item: makeBundledController(FakeLoginItemRegistration()))
    #expect(model.symbol == FalaSymbol.power)
    #expect(LaunchAtLoginStrings.title == "Iniciar no login")
  }
}
