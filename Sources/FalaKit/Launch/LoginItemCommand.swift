import Foundation

/// The CLI half of FR-19: `fala install [--launch-at-login | --uninstall]`
/// (FR-21, TASKS.md T2.9).
///
/// The verb is parsed and executed HERE, in `FalaKit`, and the executable only
/// prints what it is handed. That keeps the CLI's behaviour under test — the
/// `Fala` target has no test target of its own — and keeps `main.swift`'s job to
/// one `for line in result.lines { say(line) }`.
public enum LoginItemCommand: Sendable, Equatable, CaseIterable {

  /// `--launch-at-login`
  case enable

  /// `--uninstall`
  case disable

  /// `install` with no option: report, change nothing. A verb that silently did
  /// something because an option was forgotten would be a bad surprise for a
  /// command whose name is "install".
  case report

  /// Parses the arguments that follow the `install` verb.
  ///
  /// Returns `nil` for anything unrecognised; the caller answers with `usage`.
  public static func parse(_ arguments: [String]) -> LoginItemCommand? {
    switch arguments {
    case []: return .report
    case ["--launch-at-login"]: return .enable
    case ["--uninstall"]: return .disable
    default: return nil
    }
  }

  /// pt-BR, printed for an unrecognised option.
  public static let usage = """
    Uso:
      fala install --launch-at-login   abre o Fala automaticamente no login
      fala install --uninstall         desfaz o início automático
      fala install                     mostra o estado atual
    """
}

/// What the CLI should print, and whether it should exit non-zero.
///
/// A value instead of `print` calls so the whole command is assertable: the
/// suite checks the exact lines a user would see, without a process, a TTY or a
/// real login item.
public struct LoginItemCommandResult: Sendable, Equatable {
  public let lines: [String]
  public let succeeded: Bool

  public init(lines: [String], succeeded: Bool) {
    self.lines = lines
    self.succeeded = succeeded
  }
}

/// Runs `fala install …` against the real (or a faked) login item.
public struct LoginItemCommandRunner: Sendable {
  private let item: any LoginItemControlling

  public init(item: any LoginItemControlling = LoginItemController()) {
    self.item = item
  }

  /// `arguments` are the ones AFTER the `install` verb.
  public func run(_ arguments: [String]) -> LoginItemCommandResult {
    guard let command = LoginItemCommand.parse(arguments) else {
      let option = arguments.first ?? ""
      return LoginItemCommandResult(
        lines: ["Opção desconhecida: \(option)", "", LoginItemCommand.usage],
        succeeded: false)
    }
    return run(command)
  }

  public func run(_ command: LoginItemCommand) -> LoginItemCommandResult {
    switch command {
    case .report: return report()
    case .enable: return write(enabled: true)
    case .disable: return write(enabled: false)
    }
  }

  private func report() -> LoginItemCommandResult {
    var lines = ["\(LaunchAtLoginStrings.title): \(item.status.summary)"]
    if let explanation = item.status.explanation {
      lines.append(explanation)
    }
    lines.append("")
    lines.append(LoginItemCommand.usage)
    // Reporting a problem is still a successful report: `install` with no option
    // is a query, and exiting non-zero would break `fala install && …`.
    return LoginItemCommandResult(lines: lines, succeeded: true)
  }

  private func write(enabled: Bool) -> LoginItemCommandResult {
    do {
      let observed = try item.setEnabled(enabled)
      let confirmation =
        enabled
        ? "✓ \(LaunchAtLoginStrings.title): ativado. O \(MenuBarStrings.brandName) vai abrir sozinho no próximo login."
        : "✓ \(LaunchAtLoginStrings.title): desativado."
      var lines = [confirmation]
      // The write succeeded and the status still says something worth reading —
      // the honest place to say so is right here, not two runs later.
      if let explanation = observed.explanation {
        lines.append(explanation)
      }
      return LoginItemCommandResult(lines: lines, succeeded: true)
    } catch let error as LoginItemError {
      return failed(enabled: enabled, message: error.message, url: error.settingsURL)
    } catch {
      let message = (error as NSError).localizedDescription
      return failed(enabled: enabled, message: message, url: nil)
    }
  }

  private func failed(enabled: Bool, message: String, url: URL?) -> LoginItemCommandResult {
    let verb = enabled ? "ativar" : "desativar"
    var lines = ["✗ Não foi possível \(verb) o início no login.", message]
    if let url {
      lines.append(url.absoluteString)
    }
    return LoginItemCommandResult(lines: lines, succeeded: false)
  }
}
