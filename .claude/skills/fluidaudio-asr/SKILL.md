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
let manager = AsrManager(config: .default)
try await manager.loadModels(models)

var state = TdtDecoderState.make()
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
- `TextNormalizer` — inverse text normalization (spoken → written), FR-8.
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
(c) cache path, then update this skill.
