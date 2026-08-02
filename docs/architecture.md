# Architecture notes

Running log of design decisions, HIG-vs-mockup deviations (per DESIGN.md), and
manual verification steps that cannot be unit-tested. Append per phase.

## Phase 0 (2026-08-02)
- SPM skeleton: `FalaKit` (library, testable, no GUI) + `Fala` (executable stub)
  + `FalaSpike` (throwaway Spike 0 WER harness — delete after GATE S0).
- FluidAudio pinned `exact: 0.15.5` (NFR-6). API surface verified against the
  checkout: `AsrModels.downloadAndLoad(version: .v3)`, `AsrManager.loadModels`,
  `transcribe(_:decoderState:language:)`, `TdtDecoderState.make()`,
  `Language.portuguese` (script filter only — confirms SPEC.md FR-7).
- Design sources moved from `docs/desing/` to `design/` (flat `mockups/` layout
  kept because the HTML files share relative assets; documented in DESIGN.md).

### Toolchain (bit us twice, do not re-litigate)
The machine default is CommandLineTools (Swift 6.2.x); full Xcode is 6.3.x. The two
cannot share `.build` — mixing them yields "module compiled with Swift X cannot be
imported by the Swift Y compiler" and forces a full rebuild each time the toolchain
flips. Resolution: everything (build, run, format, the post-edit hook) uses the
DEFAULT toolchain; only `scripts/test.sh` uses Xcode, and it builds into its own
`--scratch-path .build-test` so the shared `.build` is never touched. Do not set
`DEVELOPER_DIR` anywhere else.

## Spike 0 / GATE S0 (2026-08-02)
Run 1 did not close the gate. Full evidence in SPEC.md §6. Two findings shaped the
Phase 1 design:
- **The measured failure is English lexical borrowing, not Portuguese modelling.**
  Every error landed on an English jargon token; zero on Portuguese tokens. The
  European-vs-Brazilian Portuguese risk the spike was built to test is still
  unmeasured.
- **FR-20 (vocabulary boosting) is not free.** `VocabularyRescorer` is not
  referenced by `AsrManager` in the pinned FluidAudio 0.15.5, so it is unreachable
  from the batch `transcribe(_:decoderState:language:)` path this app uses. FR-9
  (the jargon dictionary) is the mitigation budget until proven otherwise.

## Phase 1 (in progress)
- **Engine decision deliberately deferred behind `protocol TranscriptionEngine`.**
  Building Phase 1 does not commit the project to Parakeet: everything except
  `ParakeetEngine` itself is engine-agnostic. `biasTerms: [String]` is intentionally
  opaque so neither FluidAudio's custom-vocabulary types nor WhisperKit's prompt
  tokens leak through the protocol.
- **Bundled resources live in `Sources/FalaKit/Resources/`**, not at the repo root as
  the original spec sketch showed — SwiftPM requires resources inside the target
  directory. Declared with `.process("Resources")`.

### Defects found in adversarial review and fixed
- **The transcript was being published off-device.** `NSPasteboard.general` +
  `clearContents()` puts every dictation on the ordinary system clipboard, which
  macOS pushes to Universal Clipboard (the user's other iCloud devices) and which
  clipboard-history apps archive. That directly violates NFR-1 and CLAUDE.md's
  "transcripts NEVER leave the machine". Fixed with
  `prepareForNewContents(with: .currentHostOnly)` plus an
  `org.nspasteboard.ConcealedType` marker — the treatment password managers use.
  Both are needed: the first blocks cross-device sync, the second asks history
  apps not to record.
- **`actor` does not prevent reentrancy.** Swift actors are reentrant across
  `await`, so two overlapping injections interleaved: the second snapshotted while
  the first held the clipboard, captured the first's transcript as "the user's
  clipboard", and restored that — destroying the user's data and leaving a
  transcript resident. Fixed by chaining each injection onto its predecessor.
  Regression test verified to fail when the chaining is removed.
- **Cancellation collapsed the paste settle window.** `Task.sleep` throws
  immediately on cancellation, and `try?` swallowed it, restoring the clipboard
  microseconds after Cmd+V — pasting the user's OLD clipboard into their document.
  The settle wait is now cancellation-immune.
- **Secure input was checked once, ~150 ms before the paste.** Now re-checked
  immediately before posting the chord; FR-13 is a hard refusal.
- **`.skippedClipboardChanged` was reported as success**, hiding the case where the
  user's clipboard was never restored. It now throws.
- **`AsrManager(config: .default)` was wrong for this app.** FluidAudio 0.15.5's own
  documentation says `melChunkContext` must be `false` for v3 multilingual
  long-form batch, because the 80 ms mel prepend can make the decoder "drift back
  to its English-biased prior". Only affects utterances past the 15 s chunk
  threshold, which is why Spike 0's ~7 s fixtures never exposed it — but FR-4 sizes
  the ring buffer for 60 s. Fixed in both `ParakeetEngine` and `FalaSpike` so the
  measurement describes the shipping system.

### Known gaps carried into T1.10 / Phase 2
- ~~`ParakeetEngine` has no integration test (T1.4 DoD unmet)~~ **CLOSED.**
  `ParakeetEngineIntegrationTests` constructs it and, when pointed at a fixture via
  env var, transcribes real audio on the ANE; it skips cleanly by default so no
  normal run downloads 1.1 GB. Unit coverage uses the `ParakeetModelLoading` seam.
- ~~`SystemPasteboard` hardcodes `NSPasteboard.general`~~ **CLOSED.** It now takes an
  `NSPasteboard` (default `.general`) and stores its `Name` — `NSPasteboard` is not
  `Sendable`, a `Name` is. Tests drive it against `NSPasteboard.withUniqueName()`:
  a private pasteboard, no TCC, no `NSApplication`, never touches the user's
  clipboard. 8 tests in `@Suite("SystemPasteboard")`.
- ~~Pasteboard type ORDER is lost on restore~~ **CLOSED.** `Item.representations` is
  now an ordered `[Representation]`, captured and rewritten in `NSPasteboardItem.types`
  order (= reader-preference order), so RTF still outranks plain text after a restore.
  Verified by mutation: reversing the restore order fails the round-trip test.
- ~~Lazily-provided pasteboard items can empty the clipboard while reporting success~~
  **CLOSED.** `data(forType:) == nil` is now recorded as `Item.unreadableTypes`
  instead of being silently dropped, which is what made an unfulfilled promise
  indistinguishable from an empty clipboard. Policy: an item captured in full →
  `.restored`; captured in part → `.restoredWithLoss(unreadableTypes:)` (the item
  survives, degraded; not an injection failure); captured not at all →
  `ClipboardInjector` REFUSES before writing, because that is the last moment the
  user's data still exists. `SystemPasteboard.restore` additionally never calls
  `clearContents()` when it has nothing to write back. Trade-off accepted: a refusal
  costs one dictation (repeatable); proceeding costs clipboard content nothing can
  bring back. FR-12's clipboard-free `UnicodeInjector` is the eventual route for
  this case, and T2.7 owes the refusal a PT-BR message.
- The default `SecureInputMonitor` probe's polarity cannot be asserted in a unit
  test — it needs a documented manual check in T1.10. Getting it backwards would
  paste a transcript into a password field.
- ~~`InjectionError` has no PT-BR messages~~ **CLOSED.** `DictationCoordinator.message(for:)` maps all four cases to pt-BR, tested. T2.7 only owes the refusal-on-uncapturable-clipboard case its own error case and message.

## T1.10 manual verification (needs a real keyboard, a microphone, and TCC)

Everything below is unreachable from a unit test: it needs Accessibility, which
macOS grants to the *responsible process*, so it must be exercised from the signed
bundle (`./scripts/make-app.sh`), never from `swift run` in a terminal.

Setup: `./scripts/make-app.sh`, then grant Accessibility to `build/Fala.app` in
System Settings › Privacy & Security › Accessibility. Then
`./scripts/run-app.sh run` — NOT `build/Fala.app/Contents/MacOS/Fala run`, which
re-triggers the responsible-process trap described at the end of this file.

1. ~~**Happy path (US-1).**~~ **DONE 2026-08-02.** Ran twice from the signed
   bundle; `~/Library/Logs/Fala/fala.log` recorded
   `● gravando… → … transcrevendo → ✓ inserido` on both cycles, and `doctor`
   reports both permissions granted. This is the first real execution of the
   whole TCC surface — `CGEventTap`, the Cmd+V chord, and the coordinator wired
   to live components had never run before this.
   NOT yet checked within this item: whether the jargon dictionary actually fired
   (`posterg` → `Postgres`), and whether the injected text was correct rather than
   merely injected — `✓ inserido` only means the injector reported success.
2. **Passivity — the one that can break every app you type in.** Hold ⌥ direita and
   press `n`, then `c`, in TextEdit: `ñ` and `ç` must still appear. If they do not,
   the tap is swallowing events it must only observe.
3. **Left vs right Option.** Left ⌥ alone must do nothing. Then hold BOTH and
   release the right one first — recording must STOP. This is the bug that left the
   microphone running forever; the unit test pins the logic, but the key codes
   themselves (0x3D/0x3A) have never been checked against physical hardware.
4. **Secure input (FR-13, US-3).** Focus a password field, dictate. Nothing must be
   injected and the message must be "Campo protegido — injeção bloqueada." Getting
   the probe's polarity backwards would paste a transcript into a password field,
   and no unit test can catch that.
5. **Clipboard restore.** Copy something, dictate, then Cmd+V — the ORIGINAL
   clipboard must come back. Repeat with styled text copied from Pages and paste
   into Mail: it must still be styled, not flattened to plain text.
6. **Privacy, off-device.** With Handoff on and an iPhone nearby, dictate, then check
   the iPhone clipboard: the transcript must NOT be there. This is the one check for
   `.currentHostOnly`; there is no read-back API, so it cannot be asserted in code.
   If a clipboard manager (Maccy/Raycast) is installed, confirm the transcript is
   absent from its history too.
7. **Input Monitoring.** Open question: it is not established whether a `.listenOnly`
   keyboard tap needs Input Monitoring separately from Accessibility on this OS. If
   it does, `Permission` needs a third case and `doctor` currently under-reports.
8. **Tap recovery.** Block the main thread while holding the key (or trigger
   `.tapDisabledByTimeout` some other way). The mic must stop and
   `tapDisabledRecoveries` must increment. A non-zero counter in normal use means
   the main run loop is being blocked and `SystemEventTap` should move to a
   dedicated run-loop thread — the `EventTapControlling` seam makes that a
   single-file change.
9. **Fn key.** Untested on hardware; the emoji-picker conflict (FR-1) is flagged in
   `Hotkey` but its real behaviour under a tap is unverified.

### Decisions from the hotkey work
- The tap's run-loop source is pinned to the MAIN run loop, and the C callback uses
  `MainActor.assumeIsolated`. That buys a lock-free, `@unchecked`-free design where
  install, teardown, and callback all run on one thread, so use-after-free on
  teardown is impossible by construction. The cost is real: a blocked main thread is
  *how* `.tapDisabledByTimeout` happens, and this design sits on the thread most
  likely to block (model load, overlay animation). Item 8 above is how we find out.
- `HotkeyRecognizer` reads the DEVICE-specific modifier bit (`NX_DEVICERALTKEYMASK`
  0x40 / `NX_DEVICELALTKEYMASK` 0x20), not the shared `.maskAlternate`. Reading the
  shared bit lost the release whenever the other Option key was held — an unbounded,
  unindicated recording. Pinned by `releaseDetectedWhileOtherOptionKeyHeld`.

### TCC and the ad-hoc signature (cost us a debugging session)
Two independent traps, both of which make `doctor` report Acessibilidade ✗ while
System Settings shows Fala ticked:

1. **Responsible process.** Executing `build/Fala.app/Contents/MacOS/Fala` from a
   shell makes the TERMINAL the responsible process, so `AXIsProcessTrusted()` is
   evaluated against Terminal's grant and the app's own grant is never consulted.
   Confirmed empirically: from the terminal the microphone read ✓ (Terminal has it)
   while the same binary launched with `open` reported ✗ for both permissions,
   because the APP had neither. `scripts/run-app.sh` launches via LaunchServices so
   the app is responsible for itself.
2. **Ad-hoc identity churn.** There is no signing identity on this machine
   (`security find-identity` → 0 valid), so signing is ad-hoc, and an ad-hoc code
   identity is derived from the binary. Every rebuild that changes a byte produces
   a new identity and macOS silently drops the grant. `make-app.sh` now skips the
   copy+re-sign entirely when the binary is unchanged (verified: cdhash identical
   across two consecutive runs), so a grant survives repeat invocations. Rebuilding
   after a real code change still invalidates it — the entry must be REMOVED and
   re-added, since the stale entry points at the old identity. `tccutil reset
   Accessibility com.fala.dictation` clears it cleanly.

Launched with `open`, the process has no TTY and everything it prints is lost, so
the app mirrors status output to `~/Library/Logs/Fala/fala.log` (status lines only;
transcripts stay TTY-only). A Developer ID certificate removes trap 2 permanently —
Phase 3, T3.3.

### Stacked instances (observed 2026-08-02, mistaken for a model failure)
`Fala run` never exits, and `run-app.sh` used `open -n` (a new instance every
launch), so repeated invocations accumulated live copies. Two were running at once.
Each instance owns an event tap, a microphone capture and an ASR engine, so ONE
hotkey press was captured, transcribed and injected twice. Symptoms, all of which
read as app bugs rather than as duplication:
- Every state line printed twice — and, tellingly, one copy came from a stale
  binary (`… transcrevendo` with no duration next to `… transcrevendo (7.3s)`),
  which is what identified the cause.
- The dictated text landed in the terminal twice.
- One injector reported `✗ Não consegui inserir o texto` while the other reported
  `✓ inserido`: the loser saw the pasteboard change count move under it and
  correctly refused rather than restoring stale contents over the winner's write.
  The clipboard-safety guard worked exactly as designed, in the wild.

`run-app.sh` now `pkill`s any running instance before launching. Any measurement
taken while more than one instance was live is void — including the truncation
figures that prompted the capture-duration instrumentation, since two
`AVAudioEngine`s were competing for the same input device.

### Live dictation quality, single instance (2026-08-02)
With the duplication fixed, one utterance of the Spike 0 stress sentence produced:
`"Sobe o container no postergress com o Docker Compose no cluster de Staging."`
— 9.5 s captured for a ~9 s utterance (NO truncation), and only `Postgres` wrong.
`Docker Compose`, `cluster` and `Staging` all came through.

This retires two earlier conclusions:
- The truncation ("Sobin.", 1.9 s captured) was entirely the stacked-instance
  artifact, not the event tap. No `.tapDisabledByTimeout` was observed once a
  single instance was running, so moving the tap off the main run loop is NOT
  currently justified.
- The catastrophic jargon quality (`Posthuglis`, `doque compôs`, `câncer de
  staging`) was measured while two `AVAudioEngine`s shared the microphone. Live
  quality with one instance is materially better than that data suggested.

Still open for GATE S0: `postergress` is a real miss, and FR-9 cannot catch it —
the dictionary matches whole word tokens, so the entry `posterg` does not fire on
`postergress`. The observed manglings form an open set (postergis, Posthuglis,
postergress, post, proced), which a fixed substitution table cannot enumerate.

## Phase 2 foundation (2026-08-02)
T2.1 (tokens), T2.2 (menu bar), T2.3 (pill overlay) and FR-9's user-editable half
landed together. 366 tests / 27 suites.

**Integration was the gap the build phase left.** Both UI surfaces shipped as
unreachable code: nothing called `FalaMenuBarApp.run()` (no `menubar` verb existed),
and `DictationPipeline.bootstrap()` never attached `PillOverlayController`. Since
the status icon deliberately collapses success/failure to idle, that combination
left a blocked injection (US-3) with NO user-visible surface at all. Now wired: the
`menubar` verb exists, the overlay is attached and retained for the process
lifetime, and the coordinator is built from `JargonDictionaryStore` so the user's
override file actually takes effect.

**Two dictionary entries were corrupting correct Portuguese** and shipped marked
`safe`. Measured, not theorised:
- `brand → branch` turned "A brand da empresa mudou." into "A branch da empresa
  mudou." — `brand` is everyday Brazilian business vocabulary.
- `station → staging` turned "A station de trabalho travou." into "A staging de
  trabalho travou.", and "Play Station" into "Play staging".
Both are `contextual` now, gated on DOMAIN vocabulary only. The first attempt at the
gate failed for an instructive reason: including articles ("a", "uma") in
`contextBefore` matched "**A** brand da empresa" and fired anyway. Generic function
words are not context. Regression tests pin four correct-Portuguese sentences AND
that the jargon reading still fires with git/deploy neighbours.

`postergis → Postgres` stays `safe` with the PostGIS ambiguity recorded honestly in
its note: PostGIS is a real PostgreSQL extension in this user's register, context
cannot separate them (both take database neighbours), and the error stays
jargon-to-jargon rather than corrupting Portuguese.

### Open defects from the Phase 2 review (not yet fixed)
- `ModelStatus.isPresent` is true for ANY existing directory, so an interrupted
  download renders "Modelo pronto · Zero KB". Needs a size floor or a manifest check.
- A `substitutions` map in a user override file is silently discarded whenever
  `entries` is present — and the seeded template always writes `entries: []`, so the
  documented flat-map path is unreachable from a seeded file.
- Override decode errors interpolate raw ENGLISH decoder text into pt-BR warnings,
  and an entry-level failure names neither the entry nor its index while discarding
  the whole file.
- `doctor` does not yet report the dictionary store (which file is in use, how many
  entries, warnings) — the API exists.
- The menu-bar defects listed under T2.2 in TASKS.md.
