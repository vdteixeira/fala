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

## Phase 2 features (2026-08-02)
T2.5 (history + undo), T2.6 (device selection + HFP), T2.8 (UnicodeInjector +
per-app strategy) plus the defect fixes. 580 tests / 54 suites.

**The same integration gap appeared again**, and it is now a pattern worth naming:
each build round ships correct, well-tested library code that NOTHING CALLS. This
round all three features were unreachable — `AudioCapture()` was still constructed
with no device, both injector call sites still said `ClipboardInjector()`, and the
history store existed with no writer. Wiring is the lead's job and has to be an
explicit step, not an assumption; the reviewers caught it all three times.

**"An actor prevents concurrent execution" was wrong AGAIN**, in a second module.
`InjectionUndoService.undoLastInjection()` carried the same claim
`ClipboardInjector` once did, and had the same defect: actors are reentrant across
`await`, the method suspends four times, and two concurrent callers both saw
`undoRequestedAt == nil`. A double click posted TWO ⌘Z chords — undoing the
dictation AND whatever the user had typed before it. Found by a test that failed
about one run in three; a flaky test hiding a real race is worse than a red one.
Fixed with the same predecessor-chaining pattern. **If a third module claims an
actor serialises a multi-suspension method, assume it does not.**

Two FR-18 defects fixed after review:
- `AudioCapture` never un-bound. `setDeviceID` is sticky and the engine outlives
  every dictation, so selecting "Padrão do sistema" after using a headset kept
  recording through the headset while the route reported the healthy built-in mic
  and the pill's warning disappeared — the warning going away while the problem
  stayed is the worst shape of this.
- 24 000 Hz Bluetooth was classified hands-free (the bound was inclusive). That is
  Apple's HIGH-QUALITY capture rate, so the warning fired hardest on AirPods in the
  mode that fixes the HFP problem, and 24 kHz is well above what a 16 kHz pipeline
  consumes. Bound is exclusive now, with a regression test.

`doctor` now reports what it checks: model readiness distinguishes "never
downloaded" from "downloaded and broken" (an interrupted transfer used to read as
ready), and the dictionary goes through `JargonDictionaryStore` so the user's
override file and its complaints actually surface.

## Phase 3 — distribution (2026-08-02)
`scripts/ship.sh` builds `dist/Fala-<version>.dmg`. Verified by mounting the image
and running the packaged binary.

**Notarization is blocked on a purchase, not on code.** `security find-identity`
reports 0 valid identities: there is no "Developer ID Application" certificate on
this machine, and getting one requires a paid Apple Developer account. The script
takes the real path the moment one exists (hardened runtime, `--options runtime`,
`notarytool submit --wait`, `stapler staple`) and otherwise signs ad-hoc and says
so plainly. `spctl --assess` → `rejected`, which is what a recipient hits.

**Two defects made the .dmg useless, and both were found by the docs agent reading
the code rather than by a test:**
- **Double-clicking Fala.app did nothing.** `main.swift` switched on
  `arguments.first`, and LaunchServices passes no argument, so a Finder launch fell
  to `default`, printed CLI usage to a stdout nobody sees, and exited. No argument
  now means `menubar`.
- **The menu-bar app never downloaded the model.** `prepareModel` returned early
  when the model was absent, and `ParakeetEngine` does not load lazily, so on a
  clean machine EVERY dictation failed with "A transcrição falhou." with no UI path
  to recover. It now fetches on first run and shows the popover's "baixando" state.

Neither is exotic; both are invisible to anyone whose `.build` and model cache
already exist. That is the recurring shape of this whole phase: the failures that
matter for distribution are the ones the author's machine cannot exhibit.

**Entitlements** live in `Resources/Fala.entitlements` with the reasoning in
`Resources/README-entitlements.md` — the plist itself must carry no XML comments,
because `codesign` hands it to AMFI's stricter parser (`AMFIUnserializeXML: syntax
error`). The app is deliberately NOT sandboxed: the sandbox forbids `CGEventTap`
(FR-1) and synthesising the paste chord (FR-11), so a sandboxed build cannot
dictate at all. That rules out the App Store and makes Developer ID the only route.

**arm64-only, deliberately.** `ship.sh` does not build universal. The consequence,
measured: with an arm64-only binary an Intel Mac never execs it (macOS shows its
own dialog) and translation is impossible, so `HostPlatform`'s refusals are purely
defensive on this build. They become load-bearing only if the .dmg ever ships
universal — which would also require FluidAudio and CoreML to build x86_64.

## Settings and History windows (2026-08-03)
976 tests / 103 suites. Both windows exist, are wired to the menu, and neither has
ever been seen by a human.

Five capabilities had to be built before the settings window could mean anything:
the input level meter (a real change to `AudioCapture`, not a view), start-at-login
via `SMAppService`, a preferences store (showOverlay + hotkey), dictionary export,
and free-disk + a cancellable model download.

**The level meter forced a real decision.** Monitoring and dictation are mutually
EXCLUSIVE: starting a dictation tears the settings preview's session down, runs on
its own, and resumes the preview afterwards. The reason is `stop()`'s
drain-then-flush — the FR-4 path with a documented truncation history — which has
only ever been verified on a session that begins and ends with the utterance. The
cost is one engine restart per keypress while the settings window is open, and that
cycling has never run on hardware. Worth a T1.10-style manual item.

### Two severe defects found by review and fixed
- **DATA LOSS (settings).** A user dictionary file that failed to parse left the
  in-memory override EMPTY while every button stayed live; the next edit wrote that
  emptiness over the file atomically, with no backup. The type's own header already
  promised the opposite ("Reported instead of overwriting: the file may hold terms
  the user spent time on") — the report was there, the refusal was not. Every
  mutation now goes through one choke point that refuses while the source is
  unreadable. Pinned by a test that writes a genuinely malformed file and asserts
  the bytes on disk are unchanged after an attempted edit.
- **PRIVACY (history).** `forget()` runs synchronously from `windowWillClose`;
  `load()` suspends twice. Closing the window let the continuation repopulate the
  model afterwards, leaving every transcript and its folded search copy resident
  for the process lifetime — defeating the only guarantee `HistoryWindowModel`
  advertises. A generation counter was NOT enough: `show()` starts the load in an
  unstructured Task, so a fast close runs `forget()` before the load has even
  begun, and the token it later captured was one nothing had invalidated. Fixed
  with a session flag (`beginSession()` / `forget()`) checked BOTH before and after
  the suspensions. Two tests, each verified by mutation — the entry guard and the
  post-await guard fail independently.
- Also fixed: a second history row action arriving during the first was dropped
  silently, so the app reported "Ditada apagada." while the row the user clicked
  was still on screen.

### Integration, again
Same pattern as every previous round: both windows shipped as unreachable code with
`openSettings`/`openHistory` still nil. Now wired. The settings window is built
LAZILY on first open — every one of its presenters does synchronous disk work in
its initialiser (model directory enumeration, volume stat, dictionary reads,
`SMAppService` status), and doing that at launch is main-thread latency for a window
most launches never open. The Áudio tab observes the SAME `AudioCapture` the
pipeline dictates with; a second instance would be two `AVAudioEngine`s on one
microphone, which is the stacked-instance failure recorded above.

### The hotkey preference never reached the tap (2026-08-03)
Reported from real use: changing the hotkey in Ajustes did nothing. Two
independent gaps, both integration rather than logic — the recorder, the
preference store and the `hotkeyChanged` hook were all correct and all
unreachable:
- `DictationPipeline.bootstrap()` built `HotkeyManager()` with NO argument, so the
  DEFAULT key was installed every launch. A saved preference was ignored even
  after a relaunch.
- `SettingsWindowBuilder` constructed `SettingsWindowController` without a
  `SettingsActions`, so every hook the settings window exposes — `hotkeyChanged`,
  `hotkeyRecordingChanged`, `showOverlayChanged`, `dictionaryChanged`, `openURL` —
  was nil. The recorder wrote the preference and nothing acted on it.

Fixed, and three related gaps closed while the wiring was open:
- `applyHotkey(_:)` reinstalls the tap, because a live `CGEventTap` cannot be
  retargeted. `shutdown()` publishes a release first, so a key held across the
  swap cannot leave the microphone recording.
- `setHotkeySuppressed(_:)` disarms the live hotkey while the recorder listens.
  Without it, pressing keys at the recorder started a real dictation behind the
  settings window.
- `DictationCoordinator.dictionary` became a `var` with `setDictionary(_:)`. It was
  a `let` fixed at construction, so a term added in Ajustes › Dicionário did
  nothing until relaunch. The swap applies from the next dictation on, so an edit
  mid-utterance cannot produce half-substituted text.
- The pill overlay gained `setSuppressed(_:)` for FR-21's "Mostrar overlay".
  Presentation-only: dictation keeps working, the user simply sees nothing.

`Preferences` is now owned by the pipeline and shared with the settings window;
two instances would each hold their own hotkey and silently disagree.

### The pill kept advertising the old hotkey (2026-08-03)
Reported from real use, right after the rebind started working: the "gravando"
badge still read "⌥ direito". `PillOverlayController` took the hotkey once in its
initialiser and was constructed as `PillOverlayController()` — the default — with
no way to update it. The keycap is the app's instruction for HOW to dictate, so a
stale one tells the user to press a key that no longer does anything.

Fixed with `setHotkey(_:)`, called from `applyHotkey`, and the controller now
starts from `preferences.hotkey`. A sweep for the same mistake found two more:
`doctor` and the `run` verb both printed `Hotkey.rightOption` regardless of what
the app was listening for. `runDoctor()` had to become `@MainActor` to read
`Preferences`.

Worth naming as a pattern, because it has now happened three times in three
different forms: a value read ONCE at construction from a source that can change
later. `HotkeyManager`, `DictationCoordinator.dictionary` and the pill's keycap
were all built this way. When a preference exists, grep for every reader of its
default before declaring the feature wired.

## Second engine: Cohere Transcribe (2026-08-03)
SPEC.md FR-5's "future fallback" slot is filled — but with Cohere, not WhisperKit.
1024 tests / 109 suites.

**Why Cohere and not WhisperKit.** Both force the language in the decoder prefill,
which is the one thing Parakeet cannot do (FR-7: FluidAudio's `language` on the
Parakeet path is a Latin-vs-Cyrillic SCRIPT filter and cannot separate pt from
en). The difference is cost. WhisperKit was evaluated by building it: it resolves
at 0.18.0 via `argmax-oss-swift`, targets macOS 14+, compiles against this
toolchain, and `DecodingOptions(language: "pt", usePrefillPrompt: true)` really
does force the language — verified by compiling and running it. But it brings
**7 transitive dependencies** (swift-transformers, swift-jinja, swift-collections,
swift-crypto, swift-asn1, yyjson, swift-argument-parser) against the ONE this
project pins today, and a ~954 MB model. Cohere Transcribe ships inside the
FluidAudio version already pinned and audited, and its `promptSequence` injects
`<|pt|>` twice into the decoder prompt — the same mechanism, no new supply chain.

**Parakeet stays the default** (SPEC.md §2 is [CONFIRMED] on one engine for v1).
Cohere is selectable in Ajustes › Modelo so the choice can be made on measured
evidence rather than on argument.

### A download-path bug worth remembering
`ModelHub.download(_:to:)` takes the CACHE ROOT and appends the repo's own
`folderName`. For this repo the LOCAL folder (`cohere-transcribe/q8`) differs from
the REMOTE path (`cohere-transcribe-03-2026-coreml/q8`) — so a hand-written
constant made every first run download the model successfully and then fail to
find it, forever. `modelDirectory` is now DERIVED from
`Repo.cohereTranscribeCoreml.folderName`, and a test fails if the two diverge
again. Two agents found this independently while wiring different call sites.

### The spike measures the shipping engines, not copies
`FalaSpike` now links `FalaKit` and drives `TranscriptionEngine` directly through
one `ShippingSpikeEngine` adapter. It previously re-created each engine's
FluidAudio configuration by hand, with a "must match ParakeetEngine" comment — and
the gate decides which engine ships, so measuring a lookalike would let the two
drift on exactly the settings that matter (`melChunkContext`, forced language,
decoder variant). Regression check: after the rewrite AND after the switch to
delegation, `--engines parakeet` still reproduces SPEC.md §6 Run 1 exactly
(11.4% aggregate, 13.8% code-switching, the same seven lost terms).

### Still unmeasured
Nobody has run Cohere. Its model has never been downloaded on this machine, so its
size, latency and PT-BR accuracy are all unknown — which is why the settings copy
says "ainda não foi medida" and states no speed, and why `ModelLayout.cohere`
carries `nil` sizes. Running `swift run FalaSpike spike/audio` is what turns this
from an argument into a decision.

### Selecting an engine looked like a no-op (2026-08-03)
Reported from real use: picking Cohere in Ajustes did nothing visible while a
several-hundred-megabyte download was in fact running. Three gaps, in order of
how far the progress got:

1. **It did not exist.** `FluidAudioCohereLoader` never passed a `progressHandler`
   to `ModelHub.download`, so there was no progress to show. `ParakeetEngine` had
   the same hole in `AsrModels.downloadAndLoad`.
2. **The protocol had nowhere to put it.** `TranscriptionEngine.prepare()` reports
   nothing. Added `prepare(onStage:)` with a default implementation that forwards
   to `prepare()`, so a test double does not have to grow a download story.
   FluidAudio's `DownloadProgress` is mapped to the existing `ModelDownloadStage`
   inside FalaKit, so the third-party type never reaches a presenter and both
   engines report the same three stages regardless of which download API they use.
3. **It went to the wrong window.** `prepareModel` reported to the menu-bar
   presenter — the popover — while the click happened in the settings window.
   `DictationPipeline` now reports to both.

One detail that matters more than it looks: the bar is shown on the CLICK, not on
the first progress callback. HuggingFace takes seconds to answer, and the whole
complaint was about that silence. `ModelPanePresenter.selectEngine` sets
`.preparing` immediately when the chosen model is absent, and two tests pin both
the appearance and the clearing.

Note FluidAudio counts FILES, not bytes, in `.downloading(completed:total:)`. The
fraction it computes drives the bar; reporting file counts as bytes would draw
something that jumps in big steps and lies about how much is left.

### "Preparando" forever — the download was fine, the UI was frozen (2026-08-03)
Reported: selecting Cohere sat on "preparando" and never started downloading.
Measured with a throwaway probe against the real endpoint:

```
  0.0s  listing
  5.1s  downloading(completedFiles: 0, totalFiles: 21)   frac=0.000
  5.1s  downloading(completedFiles: 1, totalFiles: 21)   frac=0.000
  7.0s  downloading(completedFiles: 1, totalFiles: 21)   frac=0.000   ← stays here
```

The download was working. Three findings, none of them what the symptom suggested:

1. **The UI was never told.** `enginePreparation` and `enginePreparationFailure`
   were declared `@ObservationIgnored`, copying the annotation the type's injected
   collaborators use. `@Observable` therefore excluded them, SwiftUI never
   re-rendered, and the tab stayed on the first state it drew — `.preparing`.
   That single annotation is the whole reported bug.
2. **`fractionCompleted` is always 0.000 on this path**, so the fraction FluidAudio
   computes is useless here. File counts are the only real signal.
3. **File counts are coarse and were being rendered as bytes.** One of the 21
   files is the encoder at several hundred MB, so the count sits at 1/21 for
   minutes — and `ModelDownloadProgress.detail` formats with `ByteCountFormatter`,
   so it would have read "1 byte de 21 bytes". `ModelDownloadProgress` now carries
   a `Unit` (bytes | files): file progress renders "arquivo 1 de 21" and shows no
   percentage, because a number frozen at 5% reads as broken while a file count
   reads as working on something big.

Listing genuinely takes ~5 s, which is why the bar is shown on the CLICK rather
than on the first callback.

### What choosing Cohere actually costs (measured 2026-08-03, M3 Pro)

The engine picker previously said Cohere's speed and size "have not been measured
here". Both are measured now, over the same six GATE S0 fixtures.

| | Parakeet TDT v3 | Cohere Transcribe |
|---|---|---|
| latency per utterance | 113–144 ms | 3,3–4,7 s |
| first utterance in a process | 144 ms | **92 s** (see below) |
| on disk | 461 MB | 4,98 GB (4 984 768 322 bytes, 21 files) |
| code-switching WER | 13,8 % | 5,2 % |
| jargon terms lost | 7 | 1 |

Three consequences:

1. **Cohere is ~30× slower.** That is not a footnote for a push-to-talk app: 3,4 s
   of holding still after releasing the key is a different product from 0,1 s.
   `TranscriptionEngineChoice.summary` now says so in the picker, in those words,
   and a test forbids the string "rápido" appearing next to this engine.
2. **The first inference in a process cost 92 s** — a per-process ANE warm-up, not
   a one-time compile; three separate runs each paid it. Left alone, the user would
   select Cohere, sit through a 5 GB download, press the hotkey and watch the pill
   say "transcrevendo" for a minute and a half. `CohereEngine` now warms up with
   one second of silence at the END of loading, while the settings pane is still
   showing progress. Measured after: first utterance 3,3 s, output byte-identical.
3. **The download is 4,98 GB, and roughly half of it is never opened.** FluidAudio
   fetches the `.mlpackage` AND the pre-compiled `.mlmodelc` for three models; this
   app loads two `.mlmodelc`. Upstream packaging, not something to trim here — so
   the user is quoted the number they actually pay.

Accuracy is deliberately NOT in the picker. Cohere is well ahead on the numbers
above, but they come from 70 reference words with two self-graded fixtures. GATE S0
is open precisely because that cannot support a claim.

#### Two bugs this measurement exposed

**`ModelPane.selectEngine` read the filesystem directly**, via
`ModelStatus.current(choice.modelLayout)`, while every row on the same tab rendered
from the injected `engineStatus` map. So the click could disagree with the display —
and the test covering that line passed or failed depending on whether the
developer's own `~/Library/Application Support` happened to hold a Cohere cache.
It passed for weeks; it broke the moment the spike downloaded the model. Now it
reads the same map the rows do.

That is the project's recurring pattern in a new dress: not "a value read once from
a source that can change later", but **a value read from a source OTHER than the one
the rest of the type reads**. Both produce a UI that contradicts itself.

**The download sheet hardcoded "4,7 GB"** — a `du -h` reading, so GiB — next to a
status line that formats the same directory in decimal GB as "4,98 GB". Two numbers
for one thing in one window. The sheet now formats
`ModelLayout.expectedDownloadBytes` with the same formatter `ModelStatus` uses.

### "Aparece uma mensagem de erro depois da transcrição" (2026-08-03)

Reported with Cohere selected. The message was the pill's catch-all, "A
transcrição falhou.", and the cause was the warm-up added earlier the same day.

`CohereEngine.prepare()` timed end to end on a machine that ALREADY holds the
4,98 GB model:

```
   0.0s  preparing
   3.9s  installing        ← bytes present, CoreML opening the bundles
   8.8s  installing        ← warm-up inference starts
  97.1s  prepare() returns
  1.84s  first real transcribe
```

**97 seconds, at every launch** — 88 s of it the ANE warm-up. Moving that cost
into `prepare()` was right (it lands in the background instead of on the first
dictation), but it opened a 97-second window in which `models` was nil, and
`transcribe` answered that with `throw .notReady`. Hold the hotkey inside that
window and the utterance was lost to an error, having done nothing wrong.

Four fixes, in order of how much each one mattered:

1. **`transcribe` now JOINS an in-flight `prepare()` instead of failing fast.**
   Waiting is legible — the pill already says "transcrevendo" — and losing the
   utterance is not. A transcription with no preparation *ever started* still
   throws `.notReady`: turning the hotkey path into a lazy 4,98 GB download is
   the thing `prepare()` exists to prevent. Applied to `ParakeetEngine` too,
   where the same window exists at 461 MB on a first run.
2. **The four `TranscriptionError` cases now have four messages.** They all
   arrived as "A transcrição falhou.". A model that never downloaded and an
   utterance too short to decode need opposite actions from the user, and since
   nothing about a dictation may be logged, if the pill does not distinguish
   them then nothing does. That is why this report could only say "an error
   appeared".
3. **The menu-bar app now writes dictation states to `fala.log`**, the same
   status lines `Fala run` already wrote. Only the CLI did; the mode people
   actually use left no record at all. States and messages only — never the
   transcript, never audio.
4. **The popover reports preparation even when nothing is downloaded.** The
   condition was `allowDownload || mustFetch`, so with the model already present
   the whole 97 s passed behind a popover saying nothing.

A joiner also never cached its result — only the caller that created the load
task stored it, so a second caller got models the actor immediately forgot.
Fixed in both engines.

**Is the warm-up still worth it?** Yes, and the reason is where the wait lands,
not how long it is. Without it the cost is identical but always falls on the
first dictation. With it, a user who dictates a couple of minutes after launch
never sees it at all — and one who dictates immediately now waits instead of
failing. The picker states the recurring 1,5 min, because a minute and a half of
silence at every start would otherwise read as a broken app.

### The popover named the wrong engine (2026-08-03)

Reported as "na tela de destaque aparece Parakeet e vem de Cohere". With Cohere
selected the popover read **"Modelo Parakeet · pronto"** — over a status measured
in Cohere's directory. The status was right; only the name was wrong, which is
worse than either half being wrong alone: it reads as the engine switch having
silently failed, when it had in fact worked.

`ModelBlock.title` interpolated `static let modelName = "Parakeet"` into three of
its four cases. `title` is now `title(engine:)` with **no default**, and
`MenuBarPresenter` resolves the name through the same closure it reads the status
from, so the two halves cannot describe different engines.

`TranscriptionEngineChoice.shortName` exists because `displayName` ("Parakeet
v3", "Cohere Transcribe") would stretch the popover row onto a second line, and
DESIGN.md makes the mockup the authority on visuals — the mockup's string is
"Modelo Parakeet · pronto", which `shortName` reproduces exactly for the default
engine.

**Ajustes › Modelo was deliberately NOT changed.** Its top row shows Parakeet's
directory and its button runs `AsrModels.download(version: .v3)`, so it manages
that engine and no other; making its title follow the selection would put
Cohere's name over Parakeet's status and a button that re-downloads Parakeet. The
title now derives from `TranscriptionEngineChoice.parakeet.displayName` so the
intent is stated at the source rather than left as a bare constant.

#### The default parameter was the actual hazard

`engineName` first shipped with `= { ModelBlock.modelName }`. Deleting the wiring
in `MenuBarApp` then **still compiled and still passed all 1037 tests** — the
tests inject their own name — so the popover would have quietly reverted to
"Parakeet" over Cohere. Removing the default makes the compiler the guard:
dropping the wiring is now a build error at `MenuBarApp.swift:84`, verified by
doing it.

This is the third form of the project's recurring defect. First it was "a value
read ONCE at construction from a source that can change later". Then "a value
read from a source OTHER than the one the rest of the type reads". Now: **a
default that makes forgetting to wire something look like success.** All three
produce a UI that contradicts itself, and only the third is preventable by the
type system — so it should be.

### Selecting an installed model looked like re-downloading it (2026-08-03)

Reported: "quando seleciono um modelo que já foi baixado ele fica processando
como se tivesse baixando novamente."

It was not re-downloading. Two separate reasons it looked like it was:

1. **FluidAudio runs its listing → `downloading(21/21)` sequence either way.**
   With the files already present that is an existence check that completes
   instantly, but the stages it emits are the same ones a real transfer emits.
   Reported verbatim, they rendered as "Baixando modelo…".
2. **The wait after that is real, and it is not a transfer.** For Cohere it is
   the 97 s ANE warm-up. So the user saw a download bar, for a minute and a half,
   over a model already on disk.

`ModelDownloadStage.loading` and `ModelBlock.loading` now name that state:
"Carregando o modelo…", the processor symbol instead of the download arrow, an
indeterminate bar, no byte detail, and not cancellable (there is no transfer to
stop, and the CoreML open plus warm-up have no cancellation check to reach).

The download-or-load question is answered **once, before anything starts**, from
`ModelStatus.isPresent` — FluidAudio's own stages cannot answer it, per (1).
`loading` ranks BELOW `preparing` in `supersedes`, so an on-disk copy that turns
out to be incomplete still hands over to the real download stages.

`ModelBlock.isDownloading` deliberately stays narrow — a caller that means "bytes
are moving" must not catch a load — so `isBusy` was added for callers that mean
"work in progress of any kind".

### "Apagar tudo" fechava o alerta e não apagava nada (2026-08-03)

Reported with 45 real transcripts still on disk, spanning the whole day, after
confirming the destructive alert.

Every layer below the view was already correct, and provably so: a real
`DictationHistoryStore` on disk erases both files, empties its cache, survives
being reopened, and does not resurrect anything on the next `record()`. The
`HistoryWindowModel` clears its index, its day groups and its counts. New tests
pin all of that against a real store rather than `FakeHistory`.

The defect was one interaction in `HistoryWindow.swift`:

```swift
Button(confirmation.confirmTitle, role: .destructive) {
  Task { await model.confirmEraseAll() }        // ← async
}
...
private var eraseBinding: Binding<Bool> {
  Binding(
    get: { model.eraseConfirmation != nil },
    set: { if !$0 { model.cancelEraseAll() } }) // ← runs on ANY button tap
}
```

SwiftUI clears an alert's `isPresented` the moment any of its buttons is tapped —
including the destructive one. That runs the binding's setter, which calls
`cancelEraseAll()` and nils `eraseConfirmation`. By the time the button's `Task`
started, `confirmEraseAll()`'s first line

```swift
guard eraseConfirmation != nil else { return }
```

found nil and returned. The alert closed, a success notice never appeared, and
the history was completely intact.

**The guard was written to make the promise structural** — "no view can erase
without having shown the alert". It did the opposite: it made the erase depend on
mutable state that the view layer clears as part of normal dismissal.

The fix keeps the guarantee and moves it into the type system. `eraseAllConfirmed(_:)`
takes the `HistoryEraseConfirmation` **by value** — the one the alert was built
with, captured before any dismissal — and `HistoryEraseConfirmation.init` is no
longer public, so only `requestEraseAll()` can mint one. Ordering stops mattering:
there is no shared mutable state left for the dismissal to win a race against.

The regression test drives the two in the order SwiftUI actually uses — dismissal
first, action second — and fails with `eraseCount == 0` against the old code.

#### Why 1047 tests missed it

Every existing test called `requestEraseAll()` and then `confirmEraseAll()` back
to back, which is the order the *model* defines, not the order the *view*
produces. Nothing exercised the binding. This is the fourth shape of the same
recurring defect: correct library code, and a call site that does something the
tests never model. The first three are recorded above.

### "Fica marcando baixando" — a segunda vez, e o ícone era a causa (2026-08-03)

Reported again after `ModelDownloadStage.loading` had already fixed the wording.
The label really did say "Carregando o modelo…". Three other things in the same
row still said download, and they won:

1. **A pulsing download arrow.** `SettingsModelTab.downloadRow` drew
   `DownloadPulseIcon()` — hardcoded `FalaSymbol.download` — for every stage. An
   icon beats a label; the row read as a transfer no matter what the text said.
2. **A "Cancelar" button**, permanently disabled during a load (there is nothing
   to cancel). A dead control beside a moving bar does not read as "no transfer
   is running"; it reads as "a transfer you may not stop".
3. **`ModelPane.isDownloading` was `stage != nil`** — true during a load. Every
   caller asking "is this a download?" got yes.

Split into two questions instead of one: `isBusy` (any stage — drives whether the
row is on screen) and `isDownloading` (bytes are actually moving — drives
everything that says "download" to the user). `progressSymbol` follows the second
one, so the glyph is `cpu` for a load and `arrow.down.circle` for a transfer, and
`isCancelOffered` removes the control entirely rather than disabling it.

The popover's indeterminate bar now runs on `isBusy` rather than `isDownloading`:
a 97 s load with no motion at all looks frozen, and the label and glyph are what
say which kind of work it is.

**And the two surfaces were deciding it from different sources.** The tab read the
CACHED `engineStatus` map while the popover read `ModelStatus.current(...)` fresh
off disk, so a model downloaded after the settings window opened could have the
tab calling the same click a download and the popover calling it a load. The tab
now reads fresh through the same injected reader its rows are built from — the
"value read from a source OTHER than the one the rest of the type reads" pattern,
which this file already records twice.

### "Somente fica Carregando o modelo… e não libera" (2026-08-03)

The loading state introduced earlier the same day could get stuck on screen
forever. The preparation itself completed fine — the INDICATOR outlived it.

Every stage report crosses to the main actor in its own unstructured `Task`, and
the finish (`clearModelDownload` + `finishEnginePreparation`) arrives by a
different path: the continuation of `await engine.prepare(onStage:)`. "Later" is
undefined between independent tasks, so a report spawned just before `prepare()`
returned could land AFTER the finish. Applying it re-showed the stage — and
nothing was left to clear it, because the finish had already run. In the
installed-model case every report maps to `.loading`, so losing that race once
froze "Carregando o modelo…" permanently. Parakeet's ~1 s preparation emits its
last report microseconds before completing, which is why the race was lost
consistently rather than occasionally.

`ModelDownloadController.apply` has guarded against exactly this since it was
written — `guard task != nil` — because its reports arrive the same way. The
engine-preparation path was newer and lacked the guard. The classic shape:
the OLD path knew the trap, the NEW path reintroduced it.

Three layers now enforce ordering, two of them tested:

1. **`ModelPanePresenter.reportEnginePreparation`** drops reports while no
   preparation is active (`enginePreparation == nil`). A legitimate first report
   can never precede `selectEngine`, which sets the stage synchronously.
2. **`MenuBarPresenter`** separates *beginning* an activity
   (`reportModelLoading` / `reportModelProgress`) from *updating* one
   (`updateModelLoading` / `updateModelProgress`, which drop when nothing is on
   screen). The pipeline's report closure uses only the update forms.
3. **`DictationPipeline` keeps an activity epoch.** Reports and finishes both
   re-check it on the main actor, so a superseded preparation — a launch-time
   `prepareModel` completing after the user already switched engines, or a
   double engine switch — can neither repaint nor wipe the newer activity's bar.
   (The epoch lives in the executable target; the presenter guards are the
   testable invariant, and both were verified by mutation.)
