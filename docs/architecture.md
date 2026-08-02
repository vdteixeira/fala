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
- `ParakeetEngine` has no integration test (T1.4 DoD unmet) — it needs the 1.1 GB
  model, so it must be flag-gated. Nothing currently constructs it in a test.
- `SystemPasteboard` hardcodes `NSPasteboard.general`, so its real snapshot/restore
  logic is uncovered. `NSPasteboard.withUniqueName()` would make it testable.
- Pasteboard type ORDER is lost on restore (`[String: Data]` is unordered), which
  can silently downgrade styled content (e.g. Pages RTF) to plain text.
- Lazily-provided pasteboard items (Excel ranges, Finder promised files) yield no
  data, so restore can empty the clipboard while reporting success.
- The default `SecureInputMonitor` probe's polarity cannot be asserted in a unit
  test — it needs a documented manual check in T1.10. Getting it backwards would
  paste a transcript into a password field.
- `InjectionError` has no PT-BR messages; FR-13's user-facing warning is T2.7.
