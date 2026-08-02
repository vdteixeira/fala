#!/usr/bin/env bash
# Mirror the Parakeet TDT v3 CoreML models locally (NFR-6, bus-factor mitigation).
#
# Why: FluidAudio downloads models from Hugging Face at first run. If the
# upstream repo disappears or changes, the app must still be installable
# offline. This script clones the exact model repo into ./models/ (git-ignored)
# so a copy exists outside any cache.
#
# FluidAudio 0.15.5 runtime cache lives under:
#   ~/Library/Application Support/FluidAudio/Models/
# To install offline, copy the mirrored repo content into that directory
# (verify the exact subpath against the pinned FluidAudio version before
# relying on it — see .claude/skills/fluidaudio-asr/SKILL.md).
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="FluidInference/parakeet-tdt-0.6b-v3-coreml"
DEST="models/parakeet-tdt-0.6b-v3-coreml"

mkdir -p models
if command -v hf >/dev/null 2>&1; then
  hf download "$REPO" --local-dir "$DEST"
elif command -v huggingface-cli >/dev/null 2>&1; then
  huggingface-cli download "$REPO" --local-dir "$DEST"
elif command -v git >/dev/null 2>&1 && git lfs version >/dev/null 2>&1; then
  git clone "https://huggingface.co/$REPO" "$DEST"
else
  echo "Need either the 'hf'/'huggingface-cli' tool or git-lfs to mirror models." >&2
  echo "  brew install huggingface-cli   # or: brew install git-lfs" >&2
  exit 1
fi

echo "Mirrored $REPO -> $DEST"
du -sh "$DEST"
