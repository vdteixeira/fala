import Foundation

public enum InjectionError: Error, Equatable, Sendable {
  /// A secure text field (password) has focus. Never inject, never retain
  /// (SPEC.md FR-13, US-3).
  case secureInputActive
  /// Accessibility permission missing — injection cannot synthesise events.
  case accessibilityDenied
  /// The pasteboard rejected the write, or its contents could not be restored.
  case pasteboardFailure(reason: String)
  /// Nothing to inject.
  case emptyText
}

/// The seam that lets injection strategy vary per app (SPEC.md FR-11/FR-12/FR-14).
///
/// `ClipboardInjector` is the default; `UnicodeInjector` is the fallback for apps
/// where pasteboard-driven paste misbehaves.
public protocol TextInjector: Sendable {
  /// Inserts `text` at the current cursor position in the frontmost app.
  ///
  /// Implementations MUST check secure input before touching the pasteboard or
  /// synthesising events, and MUST leave the user's clipboard as they found it.
  func inject(_ text: String) async throws
}

/// Runtime check for macOS secure input state, behind a protocol so the blocked
/// path is testable without a real password field (see the `swift-testing` skill).
public protocol SecureInputMonitoring: Sendable {
  var isSecureInputActive: Bool { get }
}
