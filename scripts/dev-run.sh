#!/usr/bin/env bash
# Build and run the Fala executable locally (debug).
# NOTE: TCC-dependent features (CGEventTap, injection) will NOT work from a
# terminal-spawned binary — permissions attach to the parent process. Use a
# signed .app bundle for those (see CLAUDE.md "Known traps"). This script is
# for CLI/logic iteration only.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
exec .build/debug/Fala "$@"
