import AVFoundation
import ApplicationServices
import Foundation

/// One permission the app needs, and whether it currently has it.
public enum Permission: String, Sendable, CaseIterable {
  case microphone
  case accessibility

  /// User-facing name, pt-BR.
  public var displayName: String {
    switch self {
    case .microphone: return "Microfone"
    case .accessibility: return "Acessibilidade"
    }
  }

  /// Why the app needs it, pt-BR — shown when the permission is missing.
  public var rationale: String {
    switch self {
    case .microphone: return "para capturar sua voz"
    case .accessibility: return "para detectar a tecla de atalho e inserir o texto"
    }
  }

  /// Deep link into the relevant System Settings pane.
  public var settingsURL: URL? {
    switch self {
    case .microphone:
      return URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    case .accessibility:
      return URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
  }
}

/// Behind a protocol so the "permission denied" paths are testable without
/// triggering real TCC prompts (see the `swift-testing` skill).
public protocol PermissionChecking: Sendable {
  func isGranted(_ permission: Permission) -> Bool
}

extension PermissionChecking {
  public var missingPermissions: [Permission] {
    Permission.allCases.filter { !isGranted($0) }
  }

  public var allGranted: Bool { missingPermissions.isEmpty }
}

/// Real TCC checks. Read the `macos-permissions` skill before changing this.
///
/// These are pure queries: none of them prompts. Prompting is a deliberate,
/// user-initiated action (`requestMicrophoneAccess`, `promptForAccessibility`) so
/// `doctor` can report status without side effects.
public struct SystemPermissionChecker: PermissionChecking {
  public init() {}

  public func isGranted(_ permission: Permission) -> Bool {
    switch permission {
    case .microphone:
      return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    case .accessibility:
      return AXIsProcessTrusted()
    }
  }

  public func requestMicrophoneAccess() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  /// Shows the system Accessibility prompt. Note the trap documented in CLAUDE.md:
  /// run from a terminal, the grant attaches to the PARENT process (Terminal), not
  /// to Fala — TCC-dependent features must be exercised from a signed .app bundle.
  @discardableResult
  public func promptForAccessibility() -> Bool {
    // The literal key rather than `kAXTrustedCheckOptionPrompt`: that C global is
    // imported as a `var`, which Swift 6 strict concurrency rejects as shared
    // mutable state. Silencing it would need `@unchecked Sendable`, which CLAUDE.md
    // forbids. The string is the documented, stable value of that constant.
    let options = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue as Any] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }
}
