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
