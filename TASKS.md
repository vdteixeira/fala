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
      Scores the WER arm on jargon-bearing fixtures, flags self-graded references,
      warns below 300 reference words.
- [ ] S0.2 User records 15–20 PT-BR + IT-jargon fixture phrases (see
      `spike/README.md`). DoD: `spike/audio/` populated (git-ignored).
      **Run 1 recorded only 6 — still open.** For Run 2: write the reference `.txt`
      BY HAND FIRST, then read it aloud. Do NOT use `--suggest` for the scoring set;
      it produced two self-graded references in Run 1.
- [ ] S0.2b Record 3 takes each of the two failing sentences (deploy/merge and
      Postgres/Docker Compose/staging), in one sitting with one microphone, so a
      systematic defect can be told apart from a bad take.
- [ ] S0.2c Decide and document the ITN convention for references: does the target
      text read "300" (post-ITN, matching FR-8) or "trezentos" (as spoken)? Run 1's
      `Audio_5` reference says "300"; the script said "trezentos". This choice alone
      moves the measured WER across the gate threshold.
- [ ] S0.3 Run harness, record decision in SPEC.md §6 (Spike 0 row).
      DoD: aggregate WER number + engine decision written down.
      **Run 1 recorded — gate NOT closed; see SPEC.md §6.**
**GATE S0:** engine decision (Parakeet stays / WhisperKit evaluation) approved by human.
Run 1 did not close it. Also pending the human's ruling on whether the NFR-2 WER
threshold applies to the aggregate or to the jargon-bearing subset.

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
- [x] T1.1 `protocol TranscriptionEngine` + `MockTranscriptionEngine`.
      Uses an opaque `biasTerms: [String]` so no engine's vocabulary API leaks.
- [x] T1.2 `AudioCapture` (AVAudioEngine, VP OFF) + `RingBuffer` (~60 s).
      RingBuffer 21 tests; `CapturedChunk` (the Sendable copy carrying tap audio
      across isolation) 5 tests. `stop()` always routes through
      `Resampler.finish()`, so the last ~60 ms is never dropped. `AudioCapture`
      itself needs a real microphone — verified via `swift run Fala listen`.
- [x] T1.3 `Resampler` (AVAudioConverter → 16 kHz mono F32). 16 tests.
- [x] T1.4 `ParakeetEngine` (actor, idempotent prepare, typed errors,
      `melChunkContext: false`). 24 tests. The integration test transcribes real
      audio on the ANE and skips cleanly unless pointed at a fixture by env var, so
      no ordinary run downloads 1.1 GB.
- [x] T1.5 `TextNormalizerAdapter` — **CANCELLED, not deferred.** FluidAudio's
      `TextNormalizer` is a measured no-op here (`isNativeAvailable == false`) and
      is English-only by design. Wrapping it would ship a call that does nothing.
      See SPEC.md FR-8 [REJECTED as specified] for the probe evidence.
- [x] T1.6 `JargonDictionary` (deterministic PT-EN IT substitutions from JSON).
      34 tests. Safety tiers (safe/contextual/risky) keep `depois`→`deploy` and
      `me`→`merge` OFF by default: those two corrupt correct Portuguese, so the two
      hardest Spike 0 errors are deliberately NOT auto-fixed.
- [x] T1.7 `HotkeyRecognizer` + `HotkeyManager` (passive CGEventTap, right-Option
      default). 28 tests. A review found — and a regression test now pins — that both
      Option keys share `.maskAlternate`, so reading only that bit LOST the release
      whenever the other Option key was held, leaving the microphone recording
      forever; detection is now on the device-specific bit. `deinit` is
      `@MainActor` and calls `stop()`, so dropping the manager also releases the key
      and uninstalls the tap. Tap-disabled recovery re-arms and forces a release.
- [x] T1.8 `ClipboardInjector` (NSPasteboard snapshot/restore + Cmd+V). 35 tests.
      Nine defects found across two review rounds and fixed — see
      `docs/architecture.md`, including the transcript leaking to Universal
      Clipboard, overlapping injections destroying the clipboard, and a mixed
      snapshot silently discarding the item it could not capture.
- [x] T1.9 CLI in PT-BR: `doctor` (permissions/hotkey/model), `listen [s]`
      (microphone → ASR → dictionary, no TCC needed), `run` (full push-to-talk).
      `scripts/make-app.sh` produces the signed bundle TCC features require.
      A separate `setup` verb was not built: `doctor` already prints what is missing
      and the System Settings deep link, so it would only restate it.
- [~] T1.10 End-to-end manual test: hold key → speak PT-BR → text at cursor.
      **Automated half DONE:** 193 tests / 13 suites green; grep proof recorded —
      `Sources/FalaKit` contains 0 `print(`, 0 `os_log`/`NSLog`/`Logger(`, and 0
      real `@unchecked Sendable`. The two transcript-printing paths (`FalaSpike`,
      `Fala listen`) are executable-only and are listed as explicit exceptions in
      CLAUDE.md. The ParakeetEngine integration test was RUN (not just written)
      against a real fixture on the ANE.
      **Human half: item 1 of 9 DONE (2026-08-02).** The happy path ran twice from
      the signed bundle with both permissions granted — `fala.log` records
      `● gravando… → … transcrevendo → ✓ inserido` twice, so `CGEventTap`,
      `AudioCapture`, `ParakeetEngine` and `ClipboardInjector` have all now
      executed for real. **Items 2–9 still PENDING** — see the checklist in
      `docs/architecture.md`; several of them fail SILENTLY, which is why a
      working happy path does not close them.
**GATE 1:** MVP dictates end-to-end; WER spot-checked on user audio (see NFR-2). If WER
> 12–15% or code-switching breaks, OPEN the WhisperKit-fallback decision BEFORE Phase 2.
Human OK required.

## Phase 2 — Productization
Depends on Phase 1 + DESIGN.md tokens available in `/design`.
- [x] T2.1 Design tokens → `DesignSystem.swift` + `Theme.swift`. All 156 DTCG
      tokens translated and verified against `tokens.json`; 29 tests pin the values
      DESIGN-HANDOFF.md §8 fixes. `tokens.json` and `fala-tokens.css` were diffed
      programmatically and agree. Motion returns `nil` under Reduce Motion at the
      token level, so a view cannot forget the check.
- [~] T2.2 Menu-bar app (LSUIElement, NSStatusItem) + popover. Built, wired to the
      `menubar` verb, 68 tests. Status icon drawn in code as a template image.
      The on/off toggle really gates capture (`CaptureGate`).
      **NEVER RUN — needs the human check.** Open defects in `docs/architecture.md`:
      ⌘Q is advertised but not bound, disabled rows do not look disabled, the
      Reduce-Transparency fallback is still 78% translucent, and a failed dictation
      has no surface in the popover.
- [~] T2.3 Pill overlay (`NSPanel` .nonactivatingPanel/.floating). Built and now
      attached to the coordinator, 24 tests. Dismiss timings read from the theme, so
      a token change moves the behaviour. Warning never auto-dismisses (pinned 3
      ways). Multi-display geometry tested including negative-origin screens.
      **NEVER RUN — needs the human check** (focus stealing and reduce-motion are
      not assertable in a unit test).
- [ ] T2.4 Vocabulary boosting via FluidAudio CTC `VocabularyRescorer` fed by jargon
      dictionary (batch). DoD: boosted term recognized in a fixture where baseline missed.
- [ ] T2.5 History + undo of last injection. DoD: persistence + undo unit-tested.
- [ ] T2.6 Input-device selection + AirPods/HFP warning. DoD: device list; warning shown.
- [x] T2.7 `SecureInputMonitor` blocks injection + PT-BR warning. Shipped early
      with T1.8: checked twice (before the snapshot and again before the chord), and
      `DictationCoordinator.message(for:)` maps all four `InjectionError` cases to
      pt-BR. Only the probe's POLARITY remains unverifiable in a test — T1.10 item 4.
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
