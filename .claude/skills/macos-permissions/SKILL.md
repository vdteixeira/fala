---
name: macos-permissions
description: TCC, Accessibility, secure input, and microphone permission handling on macOS — required reading before touching HotkeyManager, TextInjector, AudioCapture, or PermissionChecker.
---

# macOS permissions (TCC) for Fala

## The trap that invalidates naive testing
Permissions attach to the **responsible process**. A binary run from Terminal
(`swift run`, `.build/debug/Fala`) inherits Terminal's TCC identity — Accessibility
grants go to Terminal, not to Fala. **All CGEventTap/injection testing must happen
from a signed .app bundle.** `swift run Fala doctor` exists to diagnose this.

## APIs (verify availability at use time)
- Accessibility: `AXIsProcessTrusted()`, `AXIsProcessTrustedWithOptions()` with
  `kAXTrustedCheckOptionPrompt` to trigger the system prompt once.
- Secure input: `IsSecureEventInputEnabled()` (Carbon). When true: never inject,
  never retain the transcript; surface the PT-BR warning (FR-13, US-3).
- Microphone: `AVCaptureDevice.authorizationStatus(for: .audio)` +
  `requestAccess(for:)`.
- Input monitoring (CGEventTap): creation fails silently without Accessibility —
  check the returned tap for nil and report through `doctor`.

## Rules
- Detect at runtime, degrade gracefully, explain in PT-BR (user-facing) with a
  deep link to System Settings (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`).
- Everything permission-dependent sits behind a protocol seam so tests mock it
  (`PermissionChecker`, `SecureInputMonitor`).
- Never loop-poll TCC APIs aggressively; check on activation events.
