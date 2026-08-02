---
name: fluidaudio-asr
description: Exact FluidAudio 0.15.5 batch ASR API for Parakeet TDT v3 — model loading, transcription, language filter semantics, ITN, vocabulary boosting. Use before touching any ASR code.
---

# FluidAudio ASR (pinned: 0.15.5)

Verified against the checked-out source at `.build/checkouts/FluidAudio` (2026-08-02).

## Batch API (the only mode v1 uses)
```swift
import FluidAudio

let models = try await AsrModels.downloadAndLoad(version: .v3)   // ~1.1 GB first run

// NOT `.default` — it sets `melChunkContext: true`, which makes the decoder drift
// back to its English-biased prior on v3 multilingual long-form batch audio
// (FluidAudio's own doc says to use `false` for exactly this case). Only bites on
// utterances past the 15 s chunk threshold, so short fixtures will not reveal it.
let manager = AsrManager(config: ASRConfig(melChunkContext: false))
try await manager.loadModels(models)

// NOT `TdtDecoderState.make()` — it `fatalError`s when the ANE-aligned allocation
// fails, and library code must never kill the host app (CLAUDE.md). Use the
// throwing initializer that `make()` wraps.
var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
let result = try await manager.transcribe(url, decoderState: &state, language: .portuguese)
// also: transcribe(_ samples: [Float], ...), transcribe(_ buffer: AVAudioPCMBuffer, ...)
// ASRResult: text, confidence, duration, processingTime, tokenTimings?, ctc*Terms?
```

## Critical semantics
- `language: .portuguese` is a **script filter only** (Latin vs Cyrillic token
  filtering in top-K decoding). It does NOT condition the decoder and CANNOT
  pin PT-BR vs EN/FR (all Latin). See SPEC.md FR-7. Doc comment on
  `transcribe`: "Optional language hint for script-aware token filtering (v3 only)".
- Input must be **16 kHz mono Float32**. `AudioConverter` (Shared/) does the
  resampling: `resampleBuffer(_:)`, `resampleAudioFile(_:)`, `resample(_:from:)`.
  The URL/buffer `transcribe` overloads already resample internally.
- Fresh `TdtDecoderState.make()` per independent utterance; reuse state only for
  continuation within one dictation.
- Voice processing must stay OFF upstream (CLAUDE.md trap): capture native
  format, let AudioConverter resample.

## ITN & vocabulary
- `TextNormalizer` — **DO NOT USE.** SPEC.md FR-8 is [REJECTED as specified]:
  measured here, `isNativeAvailable == false` makes it a pure no-op (it returned
  six probe inputs byte-identical, including its own English examples), and it is
  English-only by design anyway. Wiring it in ships a call that does nothing.
- CTC vocabulary boosting (batch only): `VocabularyRescorer` / CTC keyword
  spotting under `ASR/Parakeet/SlidingWindow/CustomVocabulary/`. Feed from the
  jargon dictionary (FR-20 / T2.4). `ASRResult.ctcDetectedTerms/ctcAppliedTerms`
  report what fired.

## Model cache / mirroring
- Runtime cache: `~/Library/Application Support/FluidAudio/Models/` (confirm
  subpath in `ModelHub`/`ModelRegistry` before scripting against it).
- Local mirror: `scripts/mirror-models.sh` → `models/` (git-ignored). NFR-6.

## Version bumps
Never float. To bump: change `exact:` in Package.swift, re-verify (a) the
`language` parameter semantics, (b) `transcribe`/`loadModels` signatures,
(c) cache path, (d) **that no FluidAudio log line on the batch TDT path
interpolates decoded text** — grep every `logger.*` under
`ASR/Parakeet/SlidingWindow/TDT/`. 0.15.5 already ships such a line on the
STREAMING path (`SlidingWindowAsrManager.swift`), which this app does not use; if
one lands on the batch path it silently breaks NFR-1/LGPD, and this checklist is
the only thing guarding it (it is not unit-testable). Then update this skill.
