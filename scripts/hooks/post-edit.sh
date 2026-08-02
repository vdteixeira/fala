#!/usr/bin/env bash
# Claude Code PostToolUse hook (T0.3): after any Edit/Write of a Swift source,
# run `swift build` + `swift format lint` and fail loudly so the agent fixes
# breakage immediately. Non-Swift edits are ignored (exit 0).
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}"

# Deliberately does NOT set DEVELOPER_DIR: the hook must compile with the same
# toolchain as the user's shell, or the two clobber each other's .build modules
# ("module compiled with Swift X cannot be imported by the Swift Y compiler").
# Tests, which need Xcode's Testing module, use an isolated scratch path —
# see scripts/test.sh.

input="$(cat)"
file_path="$(printf '%s' "$input" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null)"

case "$file_path" in
  *.swift) ;;
  *) exit 0 ;;
esac

build_out="$(swift build 2>&1)"
if [ $? -ne 0 ]; then
  echo "swift build FAILED after editing $file_path:" >&2
  echo "$build_out" | tail -20 >&2
  exit 2
fi

lint_out="$(swift format lint --recursive Sources/ Tests/ 2>&1)"
if [ -n "$lint_out" ]; then
  echo "swift format lint findings after editing $file_path:" >&2
  echo "$lint_out" | tail -20 >&2
  exit 2
fi

exit 0
