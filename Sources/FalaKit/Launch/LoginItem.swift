import Foundation
import ServiceManagement

// FR-19 — "Iniciar no login" (opt-in autostart).
//
// WHY `SMAppService` AND NOT A HAND-WRITTEN LaunchAgent PLIST
// -----------------------------------------------------------
// SPEC.md words FR-19 as "LaunchAgent autostart", and the obvious reading is to
// write `~/Library/LaunchAgents/com.fala.dictation.plist` ourselves. Three facts
// make that the wrong implementation on macOS 13+:
//
//  1. A hand-written plist hardcodes an absolute path to the binary. The moment
//     the user drags Fala.app from Downloads to Aplicativos — which is exactly
//     what the .dmg tells them to do — the agent points at a file that no longer
//     exists and autostart silently stops working, with nothing in the UI saying
//     so. `SMAppService.mainApp` registers the BUNDLE; macOS tracks it across
//     moves.
//  2. macOS 13 moved login items into Ajustes do Sistema › Geral › Itens de
//     Início, and items registered through `SMAppService` appear there under the
//     app's own name, where the user can audit and revoke them. A stray plist is
//     a background item the user cannot reconcile with an app — precisely the
//     opacity this project's privacy stance exists to avoid.
//  3. Apple deprecated `SMLoginItemSetEnabled` and documents `SMAppService` as
//     the supported path. Writing the plist by hand also means removing it by
//     hand, and a `launchctl bootout` that races the write leaves a half state.
//
// The cost is that the registration lives in the system, not in a file we own —
// so the app can no longer be the authority on its own setting. That is the
// reason for the shape of everything below: the status is READ FROM THE SYSTEM
// on every query, never cached in a `Bool`.

/// Whether macOS will start Fala at login, as the SYSTEM reports it right now.
///
/// Deliberately not a `Bool`. Two of the four answers are neither "on" nor
/// "off": the user can turn the item off in Ajustes do Sistema, and macOS then
/// reports a state the app cannot override by calling `register()` again. A
/// toggle backed by a `Bool` would show "ligado" for a login item that will
/// never fire.
public enum LoginItemStatus: Sendable, Equatable, CaseIterable {

  /// Registered and approved: macOS opens Fala at the next login.
  case enabled

  /// Not registered. The normal "off" — the user has never opted in, or opted
  /// back out from inside the app.
  case notRegistered

  /// Registered, but the user has to approve (or re-approve) it in Ajustes do
  /// Sistema. The app CANNOT resolve this on its own: calling `register()`
  /// again does not override a choice the user made in System Settings.
  case requiresApproval

  /// `SMAppService` answered `.notFound`: it has no registration for this
  /// bundle.
  ///
  /// **MEASURED on this machine, 2026-08-03 (macOS 26.3).** A never-registered
  /// app reports `.notFound` (raw value 3), NOT `.notRegistered` (0) — verified
  /// with a throwaway ad-hoc-signed `.app`, launched three ways (directly by
  /// path, via `open` from a temp directory, and via `open` from
  /// `~/Applications`); all three answered 3. Developer reports say the same
  /// value comes back after a user removes the item in Ajustes do Sistema.
  ///
  /// That measurement is why this case is presented to the user as plain "off"
  /// (`summary` "Desativado", no caption, no deep link): it is the state EVERY
  /// user is in before they ever opt in, and dressing the default state up as an
  /// error would put a warning under a switch that is simply not on. When it
  /// genuinely means "macOS cannot manage this bundle", the user finds out at
  /// the moment they ask for it — `register()` fails and `LoginItemError`
  /// carries the full explanation.
  case unavailable

  /// True only for the one state that actually starts the app.
  public var isEnabled: Bool { self == .enabled }

  /// True when the user has to leave the app to fix it. Drives the deep link.
  ///
  /// Only `requiresApproval`: it is the one state where macOS is holding a
  /// switch the app is not allowed to touch. See `unavailable` for why that one
  /// is not in here.
  public var needsSystemSettings: Bool { self == .requiresApproval }

  /// Short label for the settings row and the CLI, pt-BR.
  public var summary: String {
    switch self {
    case .enabled: return "Ativado"
    case .notRegistered, .unavailable: return "Desativado"
    case .requiresApproval: return "Precisa da sua autorização"
    }
  }

  /// What is going on and what the user can do, pt-BR. `nil` for every state
  /// that needs no explanation — the mockup's row is a bare toggle, and a
  /// caption under a switch that is simply on or off is noise.
  public var explanation: String? {
    switch self {
    case .enabled, .notRegistered, .unavailable:
      return nil
    case .requiresApproval:
      return """
        O macOS está esperando sua autorização. Abra Ajustes do Sistema › Geral › \
        Itens de Início e ative o Fala. Enquanto isso não for feito, o app não \
        consegue se registrar sozinho.
        """
    }
  }

  /// Ajustes do Sistema › Geral › Itens de Início (macOS 13+).
  ///
  /// Only for the states the user has to fix themselves: sending someone to
  /// System Settings to confirm something the app already did is busywork.
  public var settingsURL: URL? {
    guard needsSystemSettings else { return nil }
    return LoginItemSettings.loginItemsURL
  }
}

/// The deep link, named once so no view or CLI branch spells it out.
public enum LoginItemSettings {
  /// The Login Items pane. Same family of `x-apple.systempreferences:` URLs the
  /// permission deep links use (`Permission.settingsURL`).
  public static let loginItemsURL = URL(
    string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
}

/// Why enabling or disabling autostart failed (FR-19).
///
/// Every case carries a pt-BR message, because every one of them can be produced
/// by a user doing something reasonable — dragging the app somewhere odd, or
/// switching the item off in System Settings and then flipping the toggle in the
/// app.
public enum LoginItemError: Error, Equatable, Sendable {

  /// The running process is not inside an `.app` bundle — `swift run Fala` from
  /// a terminal, or the raw binary in `.build/`. `SMAppService` registers a
  /// BUNDLE; there is nothing to register here.
  case notBundled

  /// The user turned the item off in Ajustes do Sistema. The app cannot
  /// override that, by design.
  case requiresApproval

  /// The user asked for autostart and macOS still reports `.notFound`. As a
  /// STATUS that answer is unremarkable (see `LoginItemStatus.unavailable`), but
  /// as the outcome of a register it means the system cannot manage this bundle.
  case unavailable

  /// `SMAppService` refused for some other reason. `message` is the system's
  /// own localized description — an API error string, never user content.
  case systemRefused(message: String)

  /// The write reported SUCCESS and the system still disagrees. This is the
  /// case that keeps the toggle honest: it exists so the UI can refuse to show
  /// "ligado" for a login item that will not fire.
  case didNotTakeEffect(LoginItemStatus)

  /// pt-BR, one or two sentences, aimed at the settings row and the CLI.
  public var message: String {
    switch self {
    case .notBundled:
      return """
        O início no login só funciona a partir do Fala.app. Você está rodando o \
        binário direto pelo Terminal — abra o Fala.app e tente de novo.
        """
    case .requiresApproval:
      return Self.explaining(.requiresApproval)
    case .unavailable:
      // Three causes, because `SMAppService` answers `.notFound` for all of them
      // and gives the app no way to tell them apart. Naming only one would send
      // most users down the wrong path. This text lives on the ERROR and not on
      // the status because `.notFound` is also the ordinary never-registered
      // state — see `LoginItemStatus.unavailable`.
      return """
        O macOS não conseguiu registrar o Fala como item de início. Mova o Fala \
        para a pasta Aplicativos e abra-o de novo, e verifique se você está \
        abrindo o Fala.app e não o binário pelo Terminal. Se o item foi removido \
        em Ajustes do Sistema › Geral › Itens de Início, ative-o por lá.
        """
    case .systemRefused(let message):
      return "O macOS recusou o registro: \(message)"
    case .didNotTakeEffect(let status):
      return status.explanation
        ?? "O macOS aceitou o pedido mas o item continua \(status.summary.lowercased())."
    }
  }

  /// The status's own words, so the same situation is never described twice in
  /// two slightly different ways. The fallback is unreachable for the one state
  /// that uses it, but the type does not know that.
  private static func explaining(_ status: LoginItemStatus) -> String {
    status.explanation ?? status.summary
  }

  /// Where to send the user, when leaving the app is part of the fix.
  public var settingsURL: URL? {
    switch self {
    case .requiresApproval, .unavailable:
      return LoginItemSettings.loginItemsURL
    case .didNotTakeEffect(let status):
      return status.settingsURL
    case .notBundled, .systemRefused:
      return nil
    }
  }
}

// MARK: - The seam

/// Read and write "start Fala at login".
///
/// Behind a protocol for one blunt reason: the real implementation changes the
/// developer's own login items. A test that exercised it would register this
/// checkout's `Fala.app` on the machine running the suite and leave it there.
///
/// `status` is a computed property on purpose — conformances MUST ask the system
/// every time. See `LoginItemController`.
public protocol LoginItemControlling: Sendable {
  var status: LoginItemStatus { get }
  func register() throws
  func unregister() throws
}

extension LoginItemControlling {

  /// What a toggle calls. Returns the status OBSERVED AFTER the write, so the UI
  /// binds to what the system says rather than to what the user asked for.
  @discardableResult
  public func setEnabled(_ enabled: Bool) throws -> LoginItemStatus {
    if enabled {
      try register()
    } else {
      try unregister()
    }
    return status
  }
}

/// The slice of `SMAppService` this feature uses.
///
/// Internal, and narrower than `LoginItemControlling` on purpose: it is the raw
/// system call, with no policy. All the policy that can go wrong — the bundle
/// check, re-reading after a write, deciding that a "successful" register did
/// not take — lives in `LoginItemController`, which this seam makes testable
/// without touching the tester's login items.
protocol LoginItemRegistering: Sendable {
  var status: LoginItemStatus { get }
  func register() throws
  func unregister() throws
}

/// `SMAppService.mainApp`, and nothing else.
///
/// The only untestable code in this file, kept to three lines for that reason:
/// there is no way to assert on it without registering a real login item on the
/// machine running the suite.
struct MainAppRegistration: LoginItemRegistering {
  var status: LoginItemStatus { LoginItemStatus(SMAppService.mainApp.status) }
  func register() throws { try SMAppService.mainApp.register() }
  func unregister() throws { try SMAppService.mainApp.unregister() }
}

extension LoginItemStatus {

  /// Maps `SMAppService`'s four answers onto ours.
  ///
  /// Pure, and internal rather than private, so the mapping is covered by tests
  /// even though the thing that produces the input is not.
  init(_ status: SMAppService.Status) {
    switch status {
    case .enabled: self = .enabled
    case .notRegistered: self = .notRegistered
    case .requiresApproval: self = .requiresApproval
    case .notFound: self = .unavailable
    @unknown default:
      // A status this build has never heard of is not evidence that autostart
      // works. Claiming `.enabled` here would be the lie the whole type exists
      // to prevent.
      self = .unavailable
    }
  }
}

// MARK: - The shipping implementation

/// FR-19's real behaviour: ask the system, write through to the system, and
/// verify the write by asking the system again.
///
/// **There is no stored `Bool` anywhere in this type.** The user can change this
/// setting outside the app (Ajustes do Sistema › Geral › Itens de Início), and a
/// cached value would go stale the moment they do — showing a toggle that is on
/// for an app that will never launch, which is worse than shipping no toggle.
public struct LoginItemController: LoginItemControlling {
  private let registration: any LoginItemRegistering
  private let bundleURL: @Sendable () -> URL

  public init() {
    self.init(registration: MainAppRegistration())
  }

  /// Test seam. `bundleURL` is injected too, because "we are not inside an
  /// `.app`" is the state of every `swift build` product and therefore of every
  /// test process — without the seam the bundled path could never be exercised.
  init(
    registration: any LoginItemRegistering,
    bundleURL: @escaping @Sendable () -> URL = { Bundle.main.bundleURL }
  ) {
    self.registration = registration
    self.bundleURL = bundleURL
  }

  /// Straight from `SMAppService`, every single time.
  public var status: LoginItemStatus { registration.status }

  /// True when this process runs from an `.app` bundle. `SMAppService.mainApp`
  /// registers a bundle; from a bare executable `Bundle.main.bundleURL` is just
  /// the directory holding the binary, and there is nothing for launchd to point
  /// at.
  var isAppBundle: Bool { bundleURL().pathExtension == "app" }

  public func register() throws {
    guard isAppBundle else { throw LoginItemError.notBundled }
    do {
      try registration.register()
    } catch {
      throw Self.failure(from: error, observing: registration.status)
    }
    // `register()` can return without throwing and STILL leave the item off —
    // that is what happens when the user has switched it off in System Settings.
    // Trusting the absence of a thrown error here is exactly how a toggle starts
    // lying.
    let observed = registration.status
    guard observed == .enabled else {
      throw Self.failure(observing: observed)
    }
  }

  public func unregister() throws {
    // Not gated on `isAppBundle`: turning autostart OFF must work in every
    // situation where it could have been turned on, including after the app was
    // moved. `SMAppService` no-ops or throws harmlessly when there is nothing
    // registered, and the status check below absorbs that.
    do {
      try registration.unregister()
    } catch {
      // Already off is the goal state, not a failure. Unregistering something
      // that was never registered throws on some macOS versions, and surfacing
      // that as an error would put a red caption under a switch that is
      // correctly off.
      let observed = registration.status
      guard observed != .notRegistered else { return }
      throw Self.failure(from: error, observing: observed)
    }
    let observed = registration.status
    guard observed != .enabled else {
      throw LoginItemError.didNotTakeEffect(observed)
    }
  }

  /// Prefers what the SYSTEM says over what the call threw: an
  /// `SMAppService` error string is opaque, while `requiresApproval` tells the
  /// user precisely which switch to flip.
  private static func failure(from error: any Error, observing status: LoginItemStatus)
    -> LoginItemError
  {
    switch status {
    case .requiresApproval: return .requiresApproval
    case .unavailable: return .unavailable
    case .enabled, .notRegistered:
      return .systemRefused(message: (error as NSError).localizedDescription)
    }
  }

  private static func failure(observing status: LoginItemStatus) -> LoginItemError {
    switch status {
    case .requiresApproval: return .requiresApproval
    case .unavailable: return .unavailable
    case .enabled, .notRegistered: return .didNotTakeEffect(status)
    }
  }
}
