import Foundation
import Testing

@testable import FalaKit

/// `fala install [--launch-at-login | --uninstall]` (FR-21, TASKS.md T2.9).
///
/// The verb lives in `FalaKit` precisely so it can be asserted here: the `Fala`
/// executable has no test target, and everything that used to be written inline
/// in `main.swift` could only be checked by running the binary — which, for this
/// command, would register a login item on the machine running the suite.
@Suite struct LoginItemCommandTests {

  // MARK: - Parsing

  @Test("The two documented options parse")
  func parsesDocumentedOptions() {
    #expect(LoginItemCommand.parse(["--launch-at-login"]) == .enable)
    #expect(LoginItemCommand.parse(["--uninstall"]) == .disable)
  }

  /// `install` with no option must not install anything. A verb that guesses
  /// what a forgotten flag meant is a bad surprise from a command called
  /// "install".
  @Test("Bare install only reports")
  func bareInstallOnlyReports() {
    #expect(LoginItemCommand.parse([]) == .report)

    let registration = FakeLoginItemRegistration(status: .notRegistered)
    let result = LoginItemCommandRunner(item: makeBundledController(registration)).run([])

    #expect(result.succeeded)
    #expect(registration.registerCalls == 0)
    #expect(registration.unregisterCalls == 0)
    #expect(result.lines.first == "Iniciar no login: Desativado")
  }

  @Test("An unknown option prints the usage and fails")
  func unknownOptionFails() {
    let registration = FakeLoginItemRegistration()
    let result = LoginItemCommandRunner(item: makeBundledController(registration)).run(["--now"])

    #expect(!result.succeeded)
    #expect(result.lines.first == "Opção desconhecida: --now")
    #expect(result.lines.contains(LoginItemCommand.usage))
    #expect(registration.registerCalls == 0)
  }

  @Test("Extra arguments are refused rather than half-understood")
  func extraArgumentsAreRefused() {
    #expect(LoginItemCommand.parse(["--launch-at-login", "--uninstall"]) == nil)
    #expect(LoginItemCommand.parse(["--launch-at-login", "sim"]) == nil)
  }

  // MARK: - Running

  @Test("Enabling reports success and says what will happen")
  func enableSucceeds() {
    let registration = FakeLoginItemRegistration(status: .notRegistered)
    let runner = LoginItemCommandRunner(item: makeBundledController(registration))

    let result = runner.run(["--launch-at-login"])

    #expect(result.succeeded)
    #expect(registration.registerCalls == 1)
    #expect(registration.currentStatus == .enabled)
    #expect(result.lines.first?.hasPrefix("✓") == true)
    #expect(result.lines.first?.contains("próximo login") == true)
  }

  @Test("--uninstall turns it off")
  func uninstallDisables() {
    let registration = FakeLoginItemRegistration(status: .enabled)
    let runner = LoginItemCommandRunner(item: makeBundledController(registration))

    let result = runner.run(["--uninstall"])

    #expect(result.succeeded)
    #expect(registration.unregisterCalls == 1)
    #expect(registration.currentStatus == .notRegistered)
    #expect(result.lines == ["✓ Iniciar no login: desativado."])
  }

  /// The exit code matters: `fala install --launch-at-login` in a setup script
  /// that silently "succeeds" while autostart stays off is worse than no verb.
  @Test("A refusal explains itself, links to System Settings, and exits non-zero")
  func refusalIsLoud() throws {
    let registration = FakeLoginItemRegistration(status: .requiresApproval)
    registration.registerOutcome = .silentlyIgnored
    let runner = LoginItemCommandRunner(item: makeBundledController(registration))

    let result = runner.run(["--launch-at-login"])

    #expect(!result.succeeded)
    #expect(result.lines.first == "✗ Não foi possível ativar o início no login.")
    #expect(result.lines.contains { $0.contains("Itens de Início") })
    let url = try #require(LoginItemSettings.loginItemsURL)
    #expect(result.lines.contains(url.absoluteString))
  }

  @Test("Run from a terminal instead of the app, it says exactly that")
  func outsideABundleTheCLIExplains() {
    let registration = FakeLoginItemRegistration(status: .notRegistered)
    let controller = LoginItemController(
      registration: registration, bundleURL: { URL(fileURLWithPath: "/tmp") })

    let result = LoginItemCommandRunner(item: controller).run(["--launch-at-login"])

    #expect(!result.succeeded)
    #expect(result.lines.contains { $0.contains("Fala.app") })
  }

  @Test("A report of a state the user must fix includes the explanation")
  func reportIncludesTheExplanation() {
    let registration = FakeLoginItemRegistration(status: .requiresApproval)
    let result = LoginItemCommandRunner(item: makeBundledController(registration)).run([])

    #expect(result.lines.first == "Iniciar no login: Precisa da sua autorização")
    #expect(result.lines.contains { $0.contains("Itens de Início") })
  }

  /// `.notFound` is what macOS answers for an app that never registered
  /// (measured, macOS 26.3), so the report has to read as plain "off" — not as
  /// a fault the user has to go and investigate.
  @Test("A never-registered app reports as simply off")
  func neverRegisteredReportsAsOff() {
    let registration = FakeLoginItemRegistration(status: .unavailable)
    let result = LoginItemCommandRunner(item: makeBundledController(registration)).run([])

    #expect(result.succeeded)
    #expect(result.lines.first == "Iniciar no login: Desativado")
    #expect(!result.lines.contains { $0.contains("não conseguiu registrar") })
  }

  /// `main.swift` mirrors everything it prints to `~/Library/Logs/Fala/fala.log`
  /// when there is no terminal. Nothing this command emits may be user content
  /// (CLAUDE.md), so every line is either a fixed string or a system error
  /// message — asserted by construction: the runner is given no text to echo.
  @Test("Every line is a fixed string or a system message")
  func emitsOnlyFixedStrings() {
    let registration = FakeLoginItemRegistration(status: .enabled)
    let runner = LoginItemCommandRunner(item: makeBundledController(registration))
    for command in LoginItemCommand.allCases {
      #expect(!runner.run(command).lines.isEmpty)
    }
  }
}

/// The argv sanitiser a login-item launch depends on (FR-19).
@Suite struct LaunchArgumentsTests {

  @Test("A plain launch has no arguments, which main.swift reads as menubar")
  func plainLaunchIsEmpty() {
    #expect(LaunchArguments.user(["/Applications/Fala.app/Contents/MacOS/Fala"]) == [])
  }

  /// The failure this type exists to prevent: LaunchServices puts a process
  /// serial number in front of the user's arguments, `main.swift` does not
  /// recognise it, prints the usage text to a stdout nobody can see and exits —
  /// autostart that appears to do nothing at all.
  @Test("A LaunchServices process serial number is dropped")
  func dropsProcessSerialNumber() {
    #expect(LaunchArguments.sanitize(["-psn_0_774521"]) == [])
    #expect(LaunchArguments.sanitize(["-psn_0_774521", "doctor"]) == ["doctor"])
  }

  @Test("NSUserDefaults-style injected pairs are dropped with their value")
  func dropsInjectedPairs() {
    #expect(LaunchArguments.sanitize(["-NSDocumentRevisionsDebugMode", "YES"]) == [])
    #expect(
      LaunchArguments.sanitize(["-AppleLanguages", "(pt-BR)", "listen", "3"]) == ["listen", "3"])
  }

  @Test("A trailing injected flag with no value does not read past the end")
  func toleratesAMalformedInjectedPair() {
    #expect(LaunchArguments.sanitize(["run", "-NSDocumentRevisionsDebugMode"]) == ["run"])
  }

  @Test("Real arguments and Fala's own flags survive untouched")
  func keepsRealArguments() {
    let arguments = ["install", "--launch-at-login"]
    #expect(LaunchArguments.sanitize(arguments) == arguments)
    #expect(LaunchArguments.sanitize(["--version"]) == ["--version"])
    #expect(LaunchArguments.sanitize(["--no-overlay"]) == ["--no-overlay"])
    #expect(LaunchArguments.sanitize(["listen", "5"]) == ["listen", "5"])
  }

  @Test("The mode a login-item launch resolves to is menubar")
  func loginLaunchResolvesToMenuBar() {
    // Mirrors main.swift's `arguments.first ?? "menubar"` for the two shapes a
    // login launch can take.
    for commandLine in [
      ["/Applications/Fala.app/Contents/MacOS/Fala"],
      ["/Applications/Fala.app/Contents/MacOS/Fala", "-psn_0_774521"],
    ] {
      #expect((LaunchArguments.user(commandLine).first ?? "menubar") == "menubar")
    }
  }
}
