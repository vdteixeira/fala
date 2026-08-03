import Foundation
import Observation

/// Every fixed string of the "Iniciar no login" row, in one place (pt-BR).
///
/// The title is the mockup's own label (settings-window.dc.html:78); the icon is
/// the handoff's `power_settings_new → power` substitution (DESIGN-HANDOFF.md §5).
public enum LaunchAtLoginStrings {
  public static let title = "Iniciar no login"
  public static let toggleHelp =
    "Abrir o \(MenuBarStrings.brandName) automaticamente quando você entrar no Mac"
  /// Button under the row when the fix lives in System Settings.
  public static let openSystemSettings = "Abrir Ajustes do Sistema"
}

/// The model behind Ajustes › Geral › "Iniciar no login" (FR-19).
///
/// **The switch reflects the SYSTEM, not the user's last click.** `setOn` writes
/// through and then re-reads `LoginItemControlling.status`; if macOS refuses —
/// the user disabled the item in Ajustes do Sistema › Geral › Itens de Início,
/// or the app is not in a bundle — the switch stays where it was and `caption`
/// says why. Optimistically flipping first and reconciling later would show
/// "ligado" for an app that will never start, which is the one failure this
/// feature cannot afford.
///
/// The view keeps NO `@State` of its own; it binds straight through:
/// ```swift
/// Toggle(LaunchAtLoginStrings.title, isOn: Binding(
///   get: { model.isOn },
///   set: { model.setOn($0) }))
/// ```
@MainActor
@Observable
public final class LaunchAtLoginModel {

  /// What macOS said the last time it was asked.
  public private(set) var status: LoginItemStatus

  /// The last write that failed, cleared by the next successful one.
  public private(set) var lastError: LoginItemError?

  @ObservationIgnored private let item: any LoginItemControlling

  public init(item: any LoginItemControlling = LoginItemController()) {
    self.item = item
    self.status = item.status
  }

  /// The switch position.
  public var isOn: Bool { status.isEnabled }

  /// Re-reads the system.
  ///
  /// The settings window MUST call this when it appears and when the app becomes
  /// active again: Itens de Início is one System Settings pane away, so the user
  /// can turn this off behind the app's back and come straight back to the
  /// window.
  public func refresh() {
    status = item.status
  }

  /// Writes the user's choice through to macOS and adopts whatever macOS then
  /// reports — which may not be what was asked for.
  public func setOn(_ wanted: Bool) {
    guard wanted != isOn else { return }
    do {
      status = try item.setEnabled(wanted)
      lastError = nil
    } catch let error as LoginItemError {
      lastError = error
      // Still re-read: a failed register can leave the system in a state the
      // error alone does not describe (`requiresApproval`, most often).
      status = item.status
    } catch {
      lastError = .systemRefused(message: (error as NSError).localizedDescription)
      status = item.status
    }
  }

  public func toggle() {
    setOn(!isOn)
  }

  /// The caption under the row, or `nil` when the row needs none.
  ///
  /// A failed write wins over the status text: the user just acted, and the
  /// answer to "why did nothing happen" is the more urgent of the two.
  public var caption: String? {
    lastError?.message ?? status.explanation
  }

  /// True when the caption describes a problem, so the row can style it as a
  /// warning instead of a hint. The view decides which token that is.
  public var isCaptionAProblem: Bool {
    lastError != nil || status.needsSystemSettings
  }

  /// Deep link for the "Abrir Ajustes do Sistema" button, `nil` when there is
  /// nothing for the user to do there.
  public var settingsURL: URL? {
    lastError?.settingsURL ?? status.settingsURL
  }

  /// SF Symbol for the row (handoff §5).
  public var symbol: String { FalaSymbol.power }
}
