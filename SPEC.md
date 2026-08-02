# SPEC.md — Fala: Local Brazilian-Portuguese Dictation for macOS

Status legend: **[CONFIRMED]** = validated architectural decision, do not reopen.
**[INFERRED]** = reasonable default chosen from research; may be revised with evidence.
**[REVISED]** = was confirmed, but research forced a change; see the note inline.

## 1. Product summary
Fala is a push-to-talk, on-device dictation tool for macOS on Apple Silicon. Target
user: a highly technical Brazilian backend engineer who dictates in Brazilian
Portuguese mixed with English IT jargon ("deploy", "endpoint", "Kubernetes"). Hold a
global hotkey, speak, release; the transcript is inserted at the cursor in any app.

## 2. Scope of v1
- **[CONFIRMED]** v1 is BATCH-ONLY with ONE engine: NVIDIA Parakeet TDT 0.6B v3
  (CC-BY-4.0) via FluidAudio (Apache 2.0), running on the Apple Neural Engine (CoreML).
- **[CONFIRMED]** Transcription fires when the hotkey is released (no streaming in v1).
- **[CONFIRMED]** Streaming, on-device LLM cleanup, and signed/notarized distribution
  are OUT OF SCOPE for v1 (Phases 3+).

## 3. Functional requirements

### Capture & hotkey
- **FR-1 [CONFIRMED]** A configurable global hotkey via `CGEventTap` (requires
  Accessibility). Default: **right-Option**. Documented option: **Fn** (note the
  conflict with the system emoji picker and how it is handled).
- **FR-2 [CONFIRMED]** Audio is captured with `AVAudioEngine` in the mic's native
  format (44.1/48 kHz) and resampled to **16 kHz mono Float32** via `AVAudioConverter`.
- **FR-3 [CONFIRMED]** Voice processing (AGC, echo cancellation) is DISABLED. The app
  MUST NOT call `setVoiceProcessingEnabled(true)`.
- **FR-4 [CONFIRMED]** A ring buffer with ~60 s headroom holds captured audio so a key
  release never truncates the utterance.

### Transcription
- **FR-5 [CONFIRMED]** ASR runs behind `protocol TranscriptionEngine`; v1 implements
  `ParakeetEngine` only. WhisperKit large-v3-turbo is the designated future fallback.
- **FR-6 [CONFIRMED]** Models load via `AsrModels.downloadAndLoad(version: .v3)`;
  transcription via `AsrManager.transcribe(_:source:)` with 16 kHz mono Float32 input.
- **FR-7 [REVISED — was CONFIRMED "force language pt"]** The app requests Portuguese
  output but MUST NOT assume the engine can hard-force it. Research shows FluidAudio's
  `language` parameter is only a Latin/Cyrillic script filter and does not condition
  the Parakeet v3 decoder at inference level. Mitigations: (a) apply the available
  script/language filter; (b) use the deterministic jargon dictionary and vocab
  boosting to stabilize output; (c) measure WER (NFR-2) and trigger the WhisperKit-
  fallback evaluation if it fails. Confirm the exact field name/type in the pinned
  FluidAudio version before relying on it.

### Post-processing
- **FR-8 [CONFIRMED]** Inverse Text Normalization via FluidAudio's `TextNormalizer`.
- **FR-9 [CONFIRMED]** A configurable, deterministic substitution dictionary for PT-EN
  IT jargon (e.g., "deploy", "endpoint", "Kubernetes", library names). Ships with a
  default `Resources/dictionaries/it-jargon.json`; user-editable.
- **FR-10 [CONFIRMED]** No local LLM post-processing in v1.

### Text injection
- **FR-11 [CONFIRMED]** Default injection = clipboard + Cmd+V using `NSPasteboard`,
  with snapshot/restore of the previous clipboard contents.
- **FR-12 [CONFIRMED]** Fallback injection = `CGEventKeyboardSetUnicodeString` in
  chunks of ~20 UniChars with a short sleep between events.
- **FR-13 [CONFIRMED]** Detect secure input via `IsSecureEventInputEnabled()`; when
  active, do not attempt injection and show a graceful warning (PT-BR).
- **FR-14 [CONFIRMED]** Maintain an allowlist/denylist of apps where injection is known
  to misbehave; choose strategy per active app.

### UI / lifecycle (Phase 2)
- **FR-15 [CONFIRMED]** Menu-bar app (`LSUIElement`, `NSStatusItem`).
- **FR-16 [CONFIRMED]** Visual feedback via a pill overlay (floating `NSPanel`).
- **FR-17 [CONFIRMED]** Dictation history with undo of the last injection.
- **FR-18 [CONFIRMED]** Input-device selection with a warning when AirPods/HFP is
  selected (degraded audio for ASR).
- **FR-19 [CONFIRMED]** LaunchAgent autostart (opt-in).
- **FR-20 [INFERRED]** Vocabulary boosting (FluidAudio CTC `VocabularyRescorer`) fed by
  the jargon dictionary; batch-only, so compatible with v1's batch design.

### CLI
- **FR-21 [INFERRED]** CLI verbs mirroring the parrot skeleton: `setup`, `doctor`,
  `models list|download`, `install [--launch-at-login|--uninstall]`, plus flags
  `--hotkey`, `--no-overlay`, `--model`.

## 4. Non-functional requirements
- **NFR-1 [CONFIRMED]** 100% on-device at runtime; no network except one-time,
  mirrorable model download. No audio/transcript ever logged or transmitted (LGPD).
- **NFR-2 [CONFIRMED]** PT-BR accuracy gate: measure WER on the user's own recorded
  PT-BR + code-switching audio. If WER > 12–15% OR code-switching breaks materially,
  evaluate WhisperKit large-v3-turbo as the PRIMARY engine before shipping. (Rationale:
  Parakeet v3's training data is European Portuguese, per NVIDIA's model card.)
- **NFR-3 [CONFIRMED]** Latency: transcription of a short utterance should complete in
  the tens-to-hundreds-of-ms range on M-series (Parakeet batch RTF is ~110× on M4 Pro
  per the FluidInference CoreML model card); must be MEASURED, not assumed; never block
  the main thread.
- **NFR-4 [CONFIRMED]** Minimum OS: macOS 14.0; Apple Silicon only (refuse on Intel).
- **NFR-5 [CONFIRMED]** Swift 6.0+, strict concurrency, no `@unchecked Sendable`.
- **NFR-6 [CONFIRMED]** FluidAudio version is pinned; CoreML models mirrored locally.
- **NFR-7 [INFERRED]** Memory footprint modest (comparable Parakeet menu-bar apps run
  in the tens of MB of RAM between dictations); 0% CPU when idle. Validate; don't assume.

## 5. User stories (dictation flow)
- **US-1** As the user, I hold right-Option, speak a sentence in PT-BR, release, and see
  the text appear at my cursor within a moment, so I can dictate into any app.
- **US-2** As the user, when I dictate "fazer o deploy no endpoint do Kubernetes", the IT
  jargon is spelled correctly (English terms preserved), so I don't fix words manually.
- **US-3** As the user, when I'm focused on a password field, the app refuses to inject
  and tells me why (in PT-BR), so my keystrokes stay private.
- **US-4** As the user, I can pick my microphone and I'm warned if I pick AirPods, so I
  understand why accuracy might drop.
- **US-5** As the user, I can undo the last injection, so a bad transcription is one
  keystroke away from gone.

## 6. Acceptance criteria by phase
- **Spike 0 (engine risk):** aggregate WER measured on the user's own PT-BR +
  code-switching fixture recordings with the pinned FluidAudio/Parakeet v3 stack.
  Decision recorded: WER ≤ 12% and stable code-switching → Parakeet stays primary;
  WER > 12–15% or jargon materially broken → WhisperKit large-v3-turbo evaluated as
  PRIMARY before Phase 1 proceeds.

  **RUN 1 — 2026-08-02: GATE NOT CLOSED (measurement not trustworthy).**
  6 fixtures / 70 reference words, FluidAudio 0.15.5 + Parakeet TDT 0.6B v3
  (CoreML/ANE, batch, `language: .portuguese`).
  - Aggregate WER **11.4%** (8 errors / 70 words). Jargon-bearing fixtures only:
    **13.8%** (8/58). WER arithmetic cross-verified against an independent
    implementation; both agree per fixture.
  - **Latency 94–149 ms** per utterance over 44.3 s of audio → **NFR-3 PASSES**
    with roughly an order of magnitude of margin. NFR-7 (memory) not yet measured.
  - **Code-switching criterion FAILED:** 7 distinct English terms lost —
    deploy, merge, branch, commit, postgres, compose, staging.
  - **Errors are perfectly stratified:** every error landed on an English jargon
    token; zero errors on Portuguese tokens. The observed failure is English
    lexical borrowing, NOT the European-vs-Brazilian Portuguese risk this spike
    was designed to test. That risk remains UNMEASURED.
  - **Defects that invalidate Run 1:** (a) `Audio_5.txt` and `Audio_6.txt` were
    never edited after `FalaSpike --suggest` generated them (modification time ==
    creation time, verified), so 22 of 70 reference words are the model's own
    output graded against itself — and they are exactly the words creating the
    margin below 12%. (b) S0.2 asks for 15–20 fixtures; 6 were recorded.
    (c) `Audio_1` — which carries the two hardest errors (deploy→"depois",
    merge→"me") — was recorded 91 minutes earlier at ~238 kbps versus ~63 kbps
    for the rest, so it is not comparable and has no replication.
  - **DECISION: GATE S0 STAYS OPEN.** Run 1 justifies neither switching engines
    nor committing Phase 1 to Parakeet. Re-measure (Run 2) with hand-written
    references, 15+ sentences recorded in one sitting, and repeated takes of the
    failing sentences.
  - **Open question for the human at the gate:** NFR-2's WER threshold was
    written against the aggregate, but the aggregate is diluted by jargon-free
    fixtures (11.4% vs 13.8% here — opposite sides of the line). `FalaSpike` now
    scores the WER arm on the jargon-bearing subset. Confirm or overrule.
  - **FR-20 [AT RISK]:** verified that `VocabularyRescorer` / custom vocabulary is
    not referenced anywhere in `AsrManager` in the pinned 0.15.5, so it is NOT
    reachable from the batch `transcribe(_:decoderState:language:)` path this app
    uses. It is not a free mitigation; treat FR-9 as the mitigation budget until
    someone demonstrates a working integration.
- **Phase 1 (MVP batch):** hotkey down/up detected; audio captured at native rate and
  resampled to 16 kHz mono F32 (verified by a fixture test on the resampler); Parakeet
  returns non-empty text for a known PT-BR WAV fixture; jargon dictionary applied
  deterministically (unit-tested); clipboard injection round-trips and restores the
  prior clipboard (unit-tested on the pasteboard logic). No audio/text in logs.
- **Phase 2:** pill overlay reflects recording/transcribing/idle states matching the
  mockup; history persists and undo restores prior state; device selection lists inputs
  and warns on HFP; secure-input detection blocks injection with a PT-BR message;
  LaunchAgent installs/uninstalls cleanly.
- **Phase 3:** optional streaming and/or local LLM behind flags; Developer ID signing +
  notarization + .dmg produced by `scripts/ship.sh`; Gatekeeper opens the app cleanly.

## 7. Out of scope (v1)
Streaming ASR; Nemotron (pending a clean CoreML bundle license); local LLM cleanup;
Windows/Linux; iOS; cloud anything.
