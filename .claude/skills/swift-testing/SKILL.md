---
name: swift-testing
description: How to test FalaKit without a GUI — protocol seams, mocks for audio/permissions/injection, fixture strategy, and what is intentionally NOT unit-testable. Use when writing or reviewing tests.
---

# Swift testing strategy (FalaKit)

Framework: swift-testing (`import Testing`, `@Test`, `#expect`) — bundled with
the Swift 6 toolchain. Run: `swift test` or `swift test --filter <Suite>`.

## What is unit-testable (pure logic behind protocols)
- `RingBuffer` — wrap-around, overflow, exact-capacity reads.
- `Resampler` — fixture buffer in → exact 16 kHz mono F32 out (golden file).
- `JargonDictionary` — exact/case/word-boundary substitution rules.
- Hotkey key-mapping logic — decoupled from CGEventTap (the tap itself is not
  unit-testable; only manual verification from a signed bundle).
- Pasteboard snapshot/restore logic — behind a pasteboard protocol.
- Chunking logic of `UnicodeInjector` (chunk size, ordering, sleep boundaries).
- Secure-input policy — via `SecureInputMonitor` protocol seam.

## What is NOT unit-testable (document manual steps instead)
CGEventTap registration, actual TCC prompts, real ASR inference (integration
test behind a flag — needs the 1.1 GB model), actual Cmd+V injection.

## Rules
- Constructor injection everywhere; every hardware/permission dependency has a
  `Mock*` in `Tests/FalaKitTests/Mocks/`.
- Mocks return canned data; no sleeps, no timers — inject a clock.
- Audio fixtures are tiny generated buffers (sine/silence), never recorded
  speech committed to the repo.
- A test that needs the network or the model download is an integration test:
  gate it behind an env flag (e.g. `FALA_INTEGRATION=1`), skipped by default.
