import AppKit
import Foundation

/// "Which app is the text going into?", behind a protocol so no test needs a
/// real frontmost application (see the `swift-testing` skill).
///
/// `async` for the same reason `PasteboardAccessing` is: the production
/// implementation hops to the main actor, because `NSWorkspace` is not
/// documented as thread safe, and a fake can then be a plain `actor` instead of
/// an `@unchecked Sendable` class.
public protocol FrontmostApplicationProviding: Sendable {
  /// The application currently in front, or `nil` if none could be identified.
  func current() async -> DestinationApp?
}

/// Brings an application back to the front.
///
/// Needed only by undo, and only for one situation: the user triggers undo from
/// Fala's own popover, which made **Fala** the frontmost app, so a Cmd+Z posted
/// right then would go nowhere. See `InjectionUndoService` for the policy —
/// this seam is never used to steal focus from a third app.
public protocol ApplicationActivating: Sendable {
  /// Asks the app with `bundleIdentifier` to activate. Returns `false` when it
  /// is not running or refused. A `true` return does NOT mean it is already
  /// frontmost — activation is asynchronous, and the caller must re-check.
  func activate(bundleIdentifier: String) async -> Bool
}

/// `NSWorkspace.frontmostApplication` behind `FrontmostApplicationProviding`.
///
/// Not unit-testable (there is no frontmost app in a test process, and what it
/// returns is whatever the user happens to be looking at). The logic that
/// CONSUMES it is fully tested through the protocol.
public struct SystemFrontmostApplication: FrontmostApplicationProviding {
  public init() {}

  public func current() async -> DestinationApp? {
    await MainActor.run {
      guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
      return DestinationApp(bundleIdentifier: app.bundleIdentifier, name: app.localizedName)
    }
  }
}

/// `NSRunningApplication.activate()` behind `ApplicationActivating`.
public struct SystemApplicationActivator: ApplicationActivating {
  public init() {}

  public func activate(bundleIdentifier: String) async -> Bool {
    await MainActor.run {
      let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier)
      // More than one process can share a bundle identifier (a relaunch that has
      // not exited yet). Any of them activating puts that app in front, which is
      // all the caller asked for; the caller then verifies who is actually
      // frontmost before posting anything.
      guard let app = running.first else { return false }
      return app.activate()
    }
  }
}
