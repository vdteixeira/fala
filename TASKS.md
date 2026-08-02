# TASKS.md — Phased Implementation Plan (human gate between every phase)

Rules: complete tasks top-to-bottom. Each task lists its Definition of Done (DoD) and
dependencies. At each PHASE GATE, STOP, post evidence, and wait for human approval
before starting the next phase. Do not pull work forward across a gate.

## Spike 0 — Engine risk validation (BEFORE production code)
De-risks FR-7/NFR-2 (Parakeet v3 trained on European Portuguese; FluidAudio cannot
force PT at the decoder). Throwaway code — lives in `Sources/FalaSpike`, deleted after
the decision.
- [x] S0.1 WER harness: `swift run FalaSpike spike/audio` transcribes each `NNN.wav`
      against `NNN.txt` reference, prints per-file and aggregate WER + latency.
      DoD: harness builds and runs; WER math unit-verifiable by inspection.
- [ ] S0.2 User records 15–20 PT-BR + IT-jargon fixture phrases (see
      `spike/README.md`). DoD: `spike/audio/` populated (git-ignored).
- [ ] S0.3 Run harness, record decision in SPEC.md §6 (Spike 0 row).
      DoD: aggregate WER number + engine decision written down.
**GATE S0:** engine decision (Parakeet stays / WhisperKit evaluation) approved by human.

## Phase 0 — Project skeleton
- [x] T0.1 Create SPM package with `FalaKit` (library) + `Fala` (executable) targets.
      DoD: `swift build` clean; `swift test` runs an empty suite green.
- [x] T0.2 Add FluidAudio as a PINNED dependency; add `scripts/mirror-models.sh`.
      DoD: exact version pinned in Package.swift; script documented; build resolves.
- [x] T0.3 Wire `.claude/settings.json` hooks: run `swift build` + `swift format lint`
      after edits. DoD: hook fires on a trial edit.
- [x] T0.4 Add `swift-testing` + `macos-permissions` + `fluidaudio-asr` +
      `design-translation` SKILL.md stubs. DoD: files exist with frontmatter.
**GATE 0:** skeleton builds, dependency pinned, model-mirror script explained. Human OK.

## Phase 1 — MVP batch (hotkey + capture + Parakeet + injection + dictionary)
Depends on Phase 0 + GATE S0 (engine decision).
- [ ] T1.1 `protocol TranscriptionEngine` + `MockTranscriptionEngine`.
      DoD: protocol compiles; mock returns canned text; unit test uses it.
- [ ] T1.2 `AudioCapture` (AVAudioEngine, VP OFF) + `RingBuffer` (~60 s).
      DoD: RingBuffer unit-tested (wrap/overflow); capture uses native format.
- [ ] T1.3 `Resampler` (AVAudioConverter → 16 kHz mono F32).
      DoD: fixture test converts a known buffer to the exact target format.
- [ ] T1.4 `ParakeetEngine`: `AsrModels.downloadAndLoad(version: .v3)`,
      `AsrManager.transcribe(_:source:)`. Apply the available language/script filter.
      DoD: with a bundled PT-BR WAV fixture, returns non-empty text (integration test,
      may be gated behind a flag if it needs the model download).
- [ ] T1.5 `TextNormalizerAdapter` (FluidAudio ITN).
      DoD: wrapper unit-tested with a spoken→written fixture.
- [ ] T1.6 `JargonDictionary` (deterministic PT-EN IT substitutions from JSON).
      DoD: unit tests for exact, case, and word-boundary handling; loads default JSON.
- [ ] T1.7 `HotkeyManager` (CGEventTap, right-Option default, configurable).
      DoD: logic separated from CGEventTap so key-mapping is unit-testable; manual
      verification from a signed .app documented in `docs/architecture.md`.
- [ ] T1.8 `ClipboardInjector` (NSPasteboard snapshot/restore + Cmd+V).
      DoD: pasteboard snapshot/restore unit-tested; injection verified manually.
- [ ] T1.9 CLI `doctor` + `setup`.
      DoD: `swift run Fala doctor` reports mic/AX/model/hotkey status.
- [ ] T1.10 End-to-end manual test: hold key → speak PT-BR → text at cursor.
      DoD: recorded steps; NO audio/transcript in any log (grep proof).
**GATE 1:** MVP dictates end-to-end; WER spot-checked on user audio (see NFR-2). If WER
> 12–15% or code-switching breaks, OPEN the WhisperKit-fallback decision BEFORE Phase 2.
Human OK required.

## Phase 2 — Productization
Depends on Phase 1 + DESIGN.md tokens available in `/design`.
- [ ] T2.1 Extract design tokens from `/design/mockups` → `DesignSystem.swift`
      (follow DESIGN.md). DoD: tokens compile; a snapshot of one component matches.
- [ ] T2.2 Menu-bar app (LSUIElement, NSStatusItem) + popover from mockup.
- [ ] T2.3 Pill overlay (`NSPanel` .nonactivatingPanel/.floating) with recording/
      transcribing/idle states from mockup. DoD: states match mockup; behavior HIG-safe.
- [ ] T2.4 Vocabulary boosting via FluidAudio CTC `VocabularyRescorer` fed by jargon
      dictionary (batch). DoD: boosted term recognized in a fixture where baseline missed.
- [ ] T2.5 History + undo of last injection. DoD: persistence + undo unit-tested.
- [ ] T2.6 Input-device selection + AirPods/HFP warning. DoD: device list; warning shown.
- [ ] T2.7 `SecureInputMonitor` (IsSecureEventInputEnabled) blocks injection + PT-BR
      warning. DoD: simulated secure-input path unit-tested via protocol seam.
- [ ] T2.8 `UnicodeInjector` fallback (chunked ~20 UniChars + sleep) + app allowlist.
      DoD: chunking logic unit-tested; fallback selectable per app.
- [ ] T2.9 LaunchAgent autostart (opt-in) via CLI `install --launch-at-login`.
- [ ] T2.10 PT-BR user docs: `docs/pt-BR/instalacao.md`, `permissoes.md`, `uso.md`.
**GATE 2:** UI matches mockups (visual diff), permissions handled gracefully, docs in
PT-BR complete. Human OK required.

## Phase 3 — Optional / distribution
Depends on Phase 2.
- [ ] T3.1 (Optional) Streaming engine behind a flag (Parakeet EOU / SlidingWindow).
- [ ] T3.2 (Optional) Local LLM cleanup behind a flag (off by default).
- [ ] T3.3 Developer ID signing + notarization + `.dmg` via `scripts/ship.sh`.
      DoD: Gatekeeper opens the notarized app on a clean machine.
**GATE 3:** signed, notarized, distributable. Human OK required.
