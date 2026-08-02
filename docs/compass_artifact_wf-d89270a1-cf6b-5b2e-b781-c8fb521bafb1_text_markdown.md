# Especificação Completa para Claude Code — Ferramenta de Ditado Local PT-BR (macOS Apple Silicon)

## TL;DR
- Este pacote entrega os quatro artefatos prontos para colar no repositório (`CLAUDE.md`, `SPEC.md`, `TASKS.md`, `DESIGN.md`) mais a estrutura de diretórios, todos em inglês, seguindo os padrões do Victor (pipeline em fases com gates, checkpoints humanos, `[CONFIRMED]` vs `[INFERRED]`, handbooks em `SKILL.md`).
- **Descoberta crítica que a spec codifica como risco de topo:** o FluidAudio NÃO força idioma de verdade no Parakeet TDT v3 — o parâmetro `language` é apenas um filtro de script (latino vs. cirílico) e não condiciona o decoder. Conforme inspeção de código publicada pelo Thoth Blog (2026-05-19): *"The `language` parameter in the Swift API controls a script filter (Latin versus Cyrillic). It does not condition the decoder. There is no way to force the model into a language at the inference level."* Como o português é latino, ele não distingue PT de EN/FR; a mitigação real é token-blocklist (PR #630 — *"fix(asr): reduce English drift on French recordings via token blocklist"*, incluída no release v0.14.8) + validação de WER com áudio próprio e gate para trocar por WhisperKit como motor primário.
- Arquitetura confirmada permanece válida: binário Swift/SPM menu-bar+CLI, 100% on-device, Parakeet TDT v3 via FluidAudio (ANE/CoreML), batch-only na v1, injeção via clipboard+Cmd+V, voice processing DESLIGADO, e uma "design translation layer" que consome mockups do Claude Design em `/design` e os traduz para um `Theme.swift` em SwiftUI.

## Key Findings

1. **CLAUDE.md deve ser curto e operacional.** A doc oficial da Anthropic recomenda incluir só o que o Claude não consegue inferir do código (comandos de build/test, convenções que divergem do default, gotchas, decisões arquiteturais) e mover conhecimento sob demanda para Skills. Regra de ouro: "para cada linha, pergunte se removê-la faria o Claude errar; se não, corte". Arquivos inchados fazem o Claude ignorar instruções.
2. **Dar ao Claude uma forma de verificar o próprio trabalho é o princípio central** (testes, build exit code, script que compara com fixture). Isso fecha o loop agêntico sem o humano no meio. Para app Swift/macOS, o testável sem GUI é a lógica pura por trás de protocolos (dicionário, ITN, ring buffer, chunking), com injeção de dependência para mockar áudio/Accessibility.
3. **FluidAudio está maduro mas com riscos de bus factor concentrado.** O projeto tem ~2.3k stars e 316 forks, ~1 ano de desenvolvimento com 639 commits e 62 releases (Swift Package Index) e 15+ apps em produção — evidência de tração, mas também de dependência de poucos mantenedores. Última release **v0.15.5 (07 jul 2026, por Alex-Wengg)**; v0.15.2 saiu em 07 jun 2026. É Apache 2.0, exige **macOS 14.0+/iOS 17.0+** (CocoaPods: *"Support for macOS 14.0+ and iOS 17.0+ and Apple Silicon device"*); Swift 6+ é exigido só para contribuidores (swift-format), não para consumidores da lib (README: *"Users of the library don't need Swift 6"*), embora esta spec adote Swift 6 no app por rigor de concorrência. API batch: `AsrModels.downloadAndLoad(version: .v3)`, `AsrManager`, `transcribe(_:source:)`, `AudioConverter`, `TextNormalizer` (ITN), e boosting de vocabulário CTC (batch only) via `VocabularyRescorer`/`CtcTokenizer`.
4. **O Parakeet v3 foi treinado majoritariamente em português europeu** — a model card oficial `nvidia/parakeet-tdt-0.6b-v3` (Hugging Face), Note 2, diz: *"Performance differences may be partly attributed to Portuguese variant differences — our training data uses European Portuguese while most benchmarks use Brazilian Portuguese."* Isso confirma o risco de WER elevado em PT-BR. A WER de **6.34%** é a média multilíngue nas 25 línguas europeias no HuggingFace Open ASR Leaderboard (Together AI: *"a 6.34% average word error rate"*) — não é uma métrica "clean" de PT-BR e não deve ser assumida como o desempenho esperado para este produto.
5. **`setVoiceProcessingEnabled(true)` quebra o pipeline de ASR** — muda o formato do mic para 5–9 canais e faz o `AVAudioConverter` produzir silêncio/crashar. Isso confirma a decisão de manter voice processing DESLIGADO.
6. **Secure input e Accessibility são frágeis e devem ser detectados em runtime.** `IsSecureEventInputEnabled()` (Carbon) detecta campos seguros; `AXIsProcessTrusted()`/`AXIsProcessTrustedWithOptions()` verificam Accessibility; ao rodar de terminal a permissão vai ao processo pai, então a spec exige app bundle assinado para dev de features TCC.
7. **Claude Design gera HTML/CSS/JS/React como código real** (não imagens), exportável e importável de GitHub/Figma — o que torna viável a design translation layer proposta: os mockups chegam como arquivos em `/design`, extraem-se tokens para `Theme.swift`, e mapeiam-se componentes HTML/React → SwiftUI/AppKit.
8. **Desempenho de referência:** a model card `FluidInference/parakeet-tdt-0.6b-v3-coreml` reporta *"~110× RTF on M4 Pro for batch ASR (1 min audio ≈ 0.5 s)"* — ou seja, latências na casa de dezenas a centenas de ms para utterances curtas são plausíveis, mas devem ser medidas neste app, não assumidas.

## Details

A seguir estão os artefatos completos. **Copie cada bloco para o arquivo indicado na raiz do repositório.** Comentários em português explicam decisões; o conteúdo dos artefatos está em inglês, conforme requisito.

---

### Estrutura de diretórios proposta (E)

```
faladictation/                      # repo root (nome sugerido: "fala" — ajuste à vontade)
├── CLAUDE.md                       # project memory (artefato A)
├── SPEC.md                         # PRD / requirements (artefato B)
├── TASKS.md                        # phased implementation plan (artefato C)
├── DESIGN.md                       # design translation layer (artefato D)
├── README.md                       # user-facing docs — PT-BR
├── docs/
│   ├── pt-BR/
│   │   ├── instalacao.md           # user install guide (PT-BR)
│   │   ├── permissoes.md           # TCC/Accessibility/mic guide (PT-BR)
│   │   └── uso.md                  # usage & hotkeys (PT-BR)
│   └── architecture.md             # design notes (EN)
├── design/                         # SOURCE OF TRUTH for visuals (from Claude Design)
│   ├── mockups/                    # raw HTML/React exports
│   │   ├── pill-overlay/
│   │   ├── menubar-popover/
│   │   ├── settings-window/
│   │   └── history-window/
│   ├── tokens/
│   │   └── tokens.json             # W3C DTCG design tokens (extracted/authored)
│   └── DESIGN-HANDOFF.md           # notes from designer → Claude Code
├── Package.swift                   # SPM manifest (executable + library targets)
├── Sources/
│   ├── FalaKit/                    # library target (testable, no GUI)
│   │   ├── Transcription/
│   │   │   ├── TranscriptionEngine.swift        # protocol (fallback seam)
│   │   │   ├── ParakeetEngine.swift             # FluidAudio impl
│   │   │   └── ModelMirror.swift                # local CoreML mirror + version pin
│   │   ├── Audio/
│   │   │   ├── AudioCapture.swift               # AVAudioEngine, VP OFF
│   │   │   ├── RingBuffer.swift                 # ~60s headroom
│   │   │   └── Resampler.swift                  # AVAudioConverter → 16k mono F32
│   │   ├── Hotkey/
│   │   │   └── HotkeyManager.swift              # CGEventTap
│   │   ├── Injection/
│   │   │   ├── TextInjector.swift               # protocol
│   │   │   ├── ClipboardInjector.swift          # NSPasteboard + Cmd+V (default)
│   │   │   ├── UnicodeInjector.swift            # CGEvent fallback, chunked
│   │   │   └── SecureInputMonitor.swift         # IsSecureEventInputEnabled
│   │   ├── PostProcess/
│   │   │   ├── TextNormalizerAdapter.swift      # FluidAudio ITN wrapper
│   │   │   └── JargonDictionary.swift           # deterministic PT-EN IT terms
│   │   ├── Permissions/
│   │   │   └── PermissionChecker.swift          # AX + mic + input monitoring
│   │   └── Theme/
│   │       ├── DesignSystem.swift               # generated tokens (see DESIGN.md)
│   │       └── Theme.swift                      # semantic token surface
│   └── Fala/                       # executable target (menu-bar + CLI)
│       ├── main.swift
│       ├── AppDelegate.swift                    # LSUIElement, NSStatusItem
│       ├── UI/
│       │   ├── PillOverlayPanel.swift           # NSPanel .nonactivatingPanel
│       │   ├── MenuBarPopover.swift
│       │   ├── SettingsView.swift
│       │   └── HistoryView.swift
│       └── CLI/
│           └── Commands.swift                   # setup, doctor, models, install
├── Tests/
│   └── FalaKitTests/
│       ├── JargonDictionaryTests.swift
│       ├── RingBufferTests.swift
│       ├── ResamplerTests.swift
│       ├── ChunkingTests.swift
│       └── Mocks/
│           ├── MockTranscriptionEngine.swift
│           └── MockTextInjector.swift
├── Resources/
│   └── dictionaries/
│       └── it-jargon.json          # default substitution dictionary
├── .claude/
│   ├── skills/
│   │   ├── design-translation/SKILL.md
│   │   ├── fluidaudio-asr/SKILL.md
│   │   ├── macos-permissions/SKILL.md
│   │   └── swift-testing/SKILL.md
│   ├── agents/
│   │   └── phase-gate-reviewer.md
│   └── settings.json               # hooks (swift build/test/format gates)
└── scripts/
    ├── dev-run.sh
    ├── mirror-models.sh            # pin + mirror CoreML models locally
    └── ship.sh                     # Phase 3: sign + notarize + dmg
```

---

### A. `CLAUDE.md` (colar na raiz)

```markdown
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
- ASR engine is behind `protocol TranscriptionEngine` to allow a future WhisperKit
  fallback. v1 ships ONE engine: `ParakeetEngine` (FluidAudio → Parakeet TDT v3 on
  ANE/CoreML), BATCH-only, transcription fires on hotkey release.
- Text injection is behind `protocol TextInjector`: `ClipboardInjector` (default) and
  `UnicodeInjector` (fallback).

## Build / test / run (commands you can't guess)
```bash
swift build                                   # debug build
swift build -c release                        # release binary
swift test                                    # runs FalaKitTests (no GUI needed)
swift test --filter JargonDictionaryTests     # single suite (prefer this in a loop)
./scripts/dev-run.sh                          # build + run the menu-bar app locally
swift run Fala doctor                         # check permissions + hotkey + model
swift run Fala --help                         # CLI reference
swift format lint --recursive Sources/ Tests/ # style check (Swift 6 toolchain)
```
- Minimum deployment target: **macOS 14.0** (FluidAudio requirement). Swift **6.0+**.
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
```

---

### B. `SPEC.md` — PRD (colar na raiz)

```markdown
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
```

---

### C. `TASKS.md` — plano em fases com gates (colar na raiz)

```markdown
# TASKS.md — Phased Implementation Plan (human gate between every phase)

Rules: complete tasks top-to-bottom. Each task lists its Definition of Done (DoD) and
dependencies. At each PHASE GATE, STOP, post evidence, and wait for human approval
before starting the next phase. Do not pull work forward across a gate.

## Phase 0 — Project skeleton
- [ ] T0.1 Create SPM package with `FalaKit` (library) + `Fala` (executable) targets.
      DoD: `swift build` clean; `swift test` runs an empty suite green.
- [ ] T0.2 Add FluidAudio as a PINNED dependency; add `scripts/mirror-models.sh`.
      DoD: exact version pinned in Package.swift; script documented; build resolves.
- [ ] T0.3 Wire `.claude/settings.json` hooks: run `swift build` + `swift format lint`
      after edits. DoD: hook fires on a trial edit.
- [ ] T0.4 Add `swift-testing` + `macos-permissions` + `fluidaudio-asr` +
      `design-translation` SKILL.md stubs. DoD: files exist with frontmatter.
**GATE 0:** skeleton builds, dependency pinned, model-mirror script explained. Human OK.

## Phase 1 — MVP batch (hotkey + capture + Parakeet + injection + dictionary)
Depends on Phase 0.
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
```

---

### D. `DESIGN.md` — Design Translation Layer (colar na raiz)

```markdown
# DESIGN.md — Design Translation Layer (Claude Design mockups → native SwiftUI/AppKit)

## Purpose
The user builds visuals in **Claude Design** (which emits real HTML/CSS/JS, sometimes
React). Those exports land in `/design/mockups/**`. This document tells Claude Code how
to translate them faithfully into the native app.

## Prime directive
- **The mockup is the SOURCE OF TRUTH for VISUALS** (color, type, spacing, radius,
  shadow, states, layout intent).
- **macOS Human Interface Guidelines win on BEHAVIOR** (focus, key window rules,
  vibrancy/materials, menu semantics, keyboard nav, reduce-motion/-transparency,
  Dynamic Type equivalents, Dark Mode). When mockup and HIG conflict on behavior, HIG
  wins and you MUST note the deviation in `docs/architecture.md`.
- Never hardcode raw values in views. Everything flows through semantic tokens in
  `Theme.swift` / `DesignSystem.swift`.

## Expected `/design` structure
```
design/
├── mockups/
│   ├── pill-overlay/         index.html (+ assets)   # recording/transcribing/idle
│   ├── menubar-popover/      index.html
│   ├── settings-window/      index.html
│   └── history-window/       index.html
├── tokens/tokens.json        # W3C DTCG tokens (authored or extracted)
└── DESIGN-HANDOFF.md         # designer notes, intended states, motion specs
```

## Token extraction process (mockup → `DesignSystem.swift`)
1. Read each mockup's CSS custom properties (`--color-*`, `--space-*`, `--radius-*`,
   `--shadow-*`, font-family/size/weight/line-height) and/or `tokens/tokens.json`.
2. Normalize into a single semantic token set (primitives → semantic aliases).
3. Generate `Sources/FalaKit/Theme/DesignSystem.swift` with typed tokens. Prefer a
   Style-Dictionary-style deterministic mapping; if a token bridge tool is available,
   use it, but the generated Swift is committed and reviewed.
4. Expose tokens through `Theme.swift` as a semantic surface consumed via
   `@Environment(\.theme)`; views never reference raw hex or numbers.

### Unit conversions & pitfalls (MUST handle)
- **px → pt:** CSS px are not AppKit points. Treat the mockup's base as 1px = 1pt at
  @1x for layout, but verify against the mockup's intended density; do not multiply by
  the backing scale. Round to the 8pt grid where the mockup implies it.
- **Colors:** convert hex/rgb(a) to `Color(red:green:blue:opacity:)` (or an asset
  catalog) with explicit light/dark variants. Do NOT reuse a single color across modes.
- **Dark Mode:** every color token needs a light and dark value; wire to
  `@Environment(\.colorScheme)` / asset catalog appearances.
- **Materials/vibrancy:** a flat CSS background often should become an AppKit material
  (`.regularMaterial`, `NSVisualEffectView`) for a native feel — this is a BEHAVIOR/HIG
  decision that overrides the flat mockup fill; document it.
- **Shadows:** CSS box-shadow (possibly multi-layer) → `.shadow(color:radius:x:y:)`;
  approximate multi-layer shadows with the dominant layer and note it.
- **Fonts:** map to SF Pro / system font by default (`.system(size:weight:)`); only use
  a bundled custom font if the mockup ships one and licensing allows.
- **Icons:** prefer **SF Symbols** over exported PNG/SVG icons when a close symbol
  exists (better scaling, weight matching, accessibility); fall back to bundled assets
  only when no symbol fits. Record each substitution.
- **Motion:** honor `prefers-reduced-motion` → `accessibilityReduceMotion`.

## Component mapping table (HTML/React → SwiftUI/AppKit)
| Mockup element                     | Native target                                             | Notes |
|-----------------------------------|----------------------------------------------------------|-------|
| Bottom-of-screen pill overlay     | `NSPanel` (.nonactivatingPanel, .floating, becomesKeyOnlyIfNeeded) hosting SwiftUI via `NSHostingView` | Must not steal focus; `.canJoinAllSpaces`; LSUIElement app |
| Menu-bar dropdown / popover       | `NSStatusItem` + `MenuBarExtra(.window)` or `NSPopover`   | Start with MenuBarExtra; graduate to NSPanel only if it hits a wall |
| Settings window (tabs)            | SwiftUI `Settings` scene / `TabView`                     | Native tab semantics, standard toolbar |
| History list                      | SwiftUI `List` / `Table`                                 | Native selection, keyboard nav |
| Buttons / toggles                 | `Button`, `Toggle` styled by tokens                      | Native control sizes; don't reinvent |
| Text inputs                       | `TextField` / `SecureField`                              | Use SecureField semantics where relevant |
| Card / container `div`            | `VStack`/`ZStack` + token padding/radius/material        | Material may override flat fill (HIG) |
| CSS `:hover` / `:active` / focus  | SwiftUI hover/pressed/focus states                       | Map each mockup state 1:1 |
| Waveform / recording indicator    | Custom SwiftUI `Canvas`                                   | Drive from audio RMS; respect reduce-motion |

## Conflict-resolution rule (write it in code review)
For each screen, produce a short note: "Visual per mockup: <what>. Behavior per HIG:
<what overrode the mockup and why>." Attach it to the PR and to `docs/architecture.md`.

## Verification
- Build the screen, take a screenshot, and compare to the mockup; list differences and
  fix them (this is the agent's self-check loop for UI). Match tokens exactly; treat
  behavior deviations as intentional and documented.
```

---

### Notas de implementação que sustentam a spec (contexto para o Victor)

- **FluidAudio API batch (fixar na Skill `fluidaudio-asr`):** `AsrModels.downloadAndLoad(version: .v3)` para o bundle multilíngue (use `.v2` para inglês); `AsrManager(config: .default)` + `initialize(models:)`/`loadModels(models)`/`configure(models:)` (a doc atual mostra mais de um nome — confirme na versão fixada); `transcribe(_ samples: [Float], source: .microphone) -> ASRResult`; entrada obrigatória 16 kHz mono Float32; `AudioConverter.resampleBuffer(_:)`/`resampleAudioFile(path:)` para conversão; `TextNormalizer` para ITN; boosting de vocabulário CTC (batch only) via `VocabularyRescorer`/`CtcTokenizer`.
- **O ponto mais importante e mais frágil** é o FR-7 revisado: como o `language` do FluidAudio é só filtro de script, não há como fixar PT-BR de verdade no decoder do Parakeet v3; o gate de WER (NFR-2) é o mecanismo que protege o produto e aciona a avaliação do WhisperKit como motor primário.
- **Esqueletos MIT de referência** que o Claude Code pode consultar: `digimata/parrot` (o parrot MIT citado, base menu-bar/CLI, hold-to-talk, um único target SPM) e `rcourtman/parakey`/`presspeech` (mesmíssima stack Parakeet TDT v3 + FluidAudio + ANE, um SPM target, AppKit menu-bar, AVFoundation, CoreGraphics events). São mapas quase 1:1 para as fases 1–2. O `parakey`/`presspeech` reportam ~100 ms do release da tecla até o texto colado e ~80 MB de RAM — bons pontos de referência, não garantias.

## Recommendations

1. **Comece pelo Gate 0 e trate o FR-7 como o maior risco técnico.** Antes de investir na UI (Fase 2), rode a Fase 1 até o Gate 1 e meça WER com áudio real do Victor (PT-BR + jargão). Benchmark de decisão: **WER ≤ 12% e code-switching estável → siga com Parakeet; WER > 12–15% ou jargão quebrando → avalie WhisperKit large-v3-turbo como motor primário** (o protocolo `TranscriptionEngine` já existe justamente para isso). A model card da NVIDIA confirma o risco: o treino é em português europeu, não brasileiro.
2. **Pin + mirror obrigatórios.** Fixe uma versão explícita do FluidAudio — a linha atual é ~0.15.x (v0.15.5 em 07/07/2026), enquanto o snippet de instalação do README ainda cita `0.12.4`; escolha uma versão, valide nela a API `language`/vocab/`transcribe`, e espelhe os modelos CoreML localmente antes de qualquer coisa. Isso neutraliza o bus factor da FluidInference (projeto de ~1 ano, 639 commits, 62 releases, mantido por poucas pessoas).
3. **Teste TCC a partir de um .app assinado, nunca de `swift run` no Terminal.** Adote cedo um dev signing e valide CGEventTap/injeção pelo bundle; o `doctor` deve ser a primeira coisa a funcionar.
4. **Use os esqueletos MIT como referência de estrutura, não como cópia.** `parakey`/`presspeech` já resolvem o caminho Parakeet+FluidAudio+ANE num único target SPM; use-os para acelerar as Fases 1–2 mantendo a arquitetura de protocolos desta spec.
5. **Congele o contrato de design cedo.** Peça ao Claude Design os quatro mockups (pill, popover, settings, history) com estados explícitos e um `tokens.json` DTCG; isso torna a design translation layer determinística e o self-check por screenshot confiável.
6. **Gates humanos de verdade.** Não deixe o agente atravessar um gate sozinho — o subagente `phase-gate-reviewer` revisa o diff contra SPEC/TASKS e reporta lacunas, mas a aprovação é sua.

## Caveats

- **A "decisão confirmada" de forçar idioma 'pt' não é sustentada pela API atual do FluidAudio.** A pesquisa (inspeção de código publicada no Thoth Blog em 2026-05-19 — *"There is no way to force the model into a language at the inference level"* — e a própria issue #303, fechada sem expor forcing real de decoder, tendo sido endereçada por mitigação via token-blocklist no PR #630/v0.14.8) indica que o parâmetro `language` é um filtro de script latino/cirílico; como o português é latino, ele não separa PT de EN/FR. Por isso o FR-7 foi rebaixado de `[CONFIRMED]` para `[REVISED]` e o gate de WER virou obrigatório. Não foi possível citar a assinatura exata de `ASRConfig.swift`/`ASRResult.swift` diretamente da fonte (o fetch do raw foi bloqueado), então confirme o nome/tipo exato do campo na versão fixada.
- **Versões do FluidAudio divergem entre fontes:** o README cita `0.12.4` no snippet de instalação, mas a página de Releases mostra a linha 0.15.x (v0.15.5 em 07/07/2026; v0.15.2 em 07/06/2026). Verifique a versão real no momento da implementação e fixe-a.
- **Números de latência/RAM são de apps comparáveis** (parakey/presspeech reportam ~100 ms e ~80 MB; a model card CoreML reporta ~110× RTF em M4 Pro), não medições deste app; trate NFR-3/NFR-7 como metas a validar, não garantias. A WER de 6.34% é média multilíngue no Open ASR Leaderboard, não uma métrica de PT-BR.
- **Claude Design está em research preview** com cotas semanais e sem export de arquivo de design nativo; o handoff é via código (HTML/CSS/React) — o que serve à design translation layer, mas a qualidade/estrutura dos exports pode variar.
- **`swift format` como binário embutido exige toolchain Swift 6**; em toolchains mais antigas é preciso instalar `swift-format` separadamente. Ajuste o hook `.claude/settings.json` conforme o ambiente do Victor.
- **Custom slash commands migraram para Skills** nas versões recentes do Claude Code (Skills têm precedência sobre comandos de mesmo nome); por isso esta spec usa `.claude/skills/**` em vez de `.claude/commands/**` para os handbooks reutilizáveis, alinhado ao padrão SKILL.md do Victor.