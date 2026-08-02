# CLAUDE.md — Fala (local PT-BR dictation for macOS Apple Silicon)

Keep this file short. If a rule isn't needed to prevent a mistake, it lives in a
Skill (`.claude/skills/`) or in SPEC.md — not here.

## What we're building
Push-to-talk, 100% on-device dictation daemon for macOS on Apple Silicon (M1–M4).
Hold a hotkey, speak Brazilian Portuguese (with PT-EN IT code-switching), release,
and the transcript is injected at the cursor in any app. Menu-bar app + CLI, one
SwiftPM package. Privacy is a hard product constraint (LGPD): audio and transcripts
NEVER leave the machine and are NEVER logged.

## Golden rules (YOU MUST follow)
- **On-device only.** No network calls at runtime except the one-time model download
  (and that must be mirrorable/offline-installable). No telemetry, no analytics.
- **Never log audio samples or transcript text.** Not to stdout, not to os_log, not
  to files. Log lengths, durations, and error codes only. This is non-negotiable.
  Two documented exceptions, both in EXECUTABLE targets, never in `FalaKit`:
  (1) `FalaSpike`, the throwaway WER harness, prints hypothesis vs reference for the
  user's own fixture recordings; (2) `Fala listen`, the manual end-to-end check,
  prints the transcript it just produced. Both write only to the terminal of a user
  who explicitly asked for that output — never to a file, never to os_log, never
  automatically. Adding a third exception means editing this list first.
- **Language of artifacts:** ALL code, comments, identifiers, commits, CLAUDE.md,
  SPEC.md, TASKS.md, DESIGN.md, and `docs/architecture.md` are in ENGLISH.
  ALL user-facing docs (`README.md`, `docs/pt-BR/**`) are in BRAZILIAN PORTUGUESE.
- **Phased gated pipeline.** Do not start a phase until the previous phase's gate is
  approved by a human. See TASKS.md. At each gate, STOP and summarize evidence.
- **The mockup is the source of truth for VISUALS; macOS HIG wins on BEHAVIOR.**
  See DESIGN.md before touching any UI.
- **Do not silently reopen confirmed architectural decisions.** They are marked
  [CONFIRMED] in SPEC.md. If you believe one is wrong, STOP and raise it explicitly.

## Architecture (one screen)
- `Sources/FalaKit` = pure, testable library (no GUI). All macOS-permission- and
  hardware-dependent work sits behind protocols so it can be mocked in tests.
- `Sources/Fala` = executable: menu-bar UI (NSStatusItem + AppKit/SwiftUI) and CLI.
- `Sources/FalaSpike` = throwaway Spike 0 WER harness (see TASKS.md). Delete after
  the engine decision is made.
- ASR engine is behind `protocol TranscriptionEngine` to allow a future WhisperKit
  fallback. v1 ships ONE engine: `ParakeetEngine` (FluidAudio → Parakeet TDT v3 on
  ANE/CoreML), BATCH-only, transcription fires on hotkey release.
- Text injection is behind `protocol TextInjector`: `ClipboardInjector` (default) and
  `UnicodeInjector` (fallback).

## Build / test / run (commands you can't guess)
```bash
swift build                                   # debug build
swift build -c release                        # release binary
./scripts/test.sh                             # runs FalaKitTests (NOT bare `swift test`)
./scripts/test.sh --filter JargonDictionaryTests  # single suite (prefer this in a loop)
./scripts/dev-run.sh                          # build + run the menu-bar app locally
swift run Fala doctor                         # check permissions + hotkey + model
swift run Fala --help                         # CLI reference
swift run FalaSpike spike/audio               # Spike 0: WER on fixture recordings
swift format lint --recursive Sources/ Tests/ # style check (Swift 6 toolchain)
```
- Minimum deployment target: **macOS 14.0** (FluidAudio requirement). Swift **6.0+**.
- **Toolchain rule (do not violate):** build/run/format with the DEFAULT toolchain
  (CommandLineTools, Swift 6.2.x here). NEVER set `DEVELOPER_DIR` for `swift build`
  or `swift run` — mixing toolchains poisons `.build` and every later build fails
  with "module compiled with Swift X cannot be imported by the Swift Y compiler",
  forcing a full rebuild. Tests are the one exception: they need Xcode's `Testing`
  module, so `scripts/test.sh` uses Xcode with an ISOLATED `--scratch-path`.
- Prefer running a SINGLE test suite over the whole set while iterating.

## Definition of Done (every task)
1. Code compiles: `swift build` is clean.
2. New logic behind a protocol has a unit test with a mock; `swift test` passes.
3. No secrets, no audio/transcript logging (grep your diff before finishing).
4. `swift format lint` is clean.
5. You showed EVIDENCE (test output / command output), not just "done".
6. User-facing strings you added exist in PT-BR docs if they surface to the user.

## Swift conventions
- Swift 6 strict concurrency. Prefer `actor` for the ASR manager and capture pipeline;
  never `@unchecked Sendable` to silence warnings — fix the data race.
- Constructor injection for all dependencies (audio, engine, injector, clock).
- Errors are typed enums; no `fatalError` in library code paths.
- No force-unwraps outside tests. No `print()` in `FalaKit` — use a `Logger` category
  that is hard-wired to never receive audio/text payloads.

## Known traps (read before you code these areas)
- **Language forcing is NOT real in FluidAudio for Parakeet v3.** The `language`
  parameter is a script filter (Latin vs Cyrillic); it does NOT condition the decoder,
  so it cannot pin Brazilian Portuguese. Treat "force pt" as best-effort mitigation
  (script filter + token blocklist + vocab boosting), and gate on measured WER — see
  SPEC.md NFR-2 and the WhisperKit fallback trigger.
- **Never enable voice processing.** `setVoiceProcessingEnabled(true)` silently
  changes the mic format to 5–9 channels and breaks `AVAudioConverter`. Keep AGC and
  echo cancellation OFF; capture the mic's native format and resample yourself.
- **Accessibility from a terminal binary attaches to the PARENT process.** TCC-
  dependent features (CGEventTap, injection) must be tested from a signed .app bundle,
  not `swift run` in Terminal. Use `swift run Fala doctor` to diagnose.
- **FluidInference bus factor.** Pin the FluidAudio version and mirror the CoreML
  models locally (`scripts/mirror-models.sh`). Do not float the dependency.

## Skills (loaded on demand — don't inline their content here)
- `design-translation` — how to turn `/design` mockups into `Theme.swift` + SwiftUI.
- `fluidaudio-asr` — exact FluidAudio batch API, model versions, vocab boosting.
- `macos-permissions` — TCC, Accessibility, secure input, mic selection.
- `swift-testing` — how to mock audio/permissions and what is testable without a GUI.

## Workflow
- Use plan mode for anything spanning multiple files. Write the plan to the relevant
  TASKS.md phase before coding.
- After finishing a task, use a subagent (`phase-gate-reviewer`) to review the diff
  against SPEC.md and TASKS.md before declaring the phase gate ready.
- @SPEC.md and @TASKS.md are the contract. Re-read the relevant FR/NFR before coding.
