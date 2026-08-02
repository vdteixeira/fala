#!/usr/bin/env bash
# Run the test suite.
#
# Why this wrapper exists: swift-testing's `Testing` module ships only with the
# full Xcode toolchain, not with CommandLineTools (the machine default here).
# But compiling the package with a second toolchain poisons the shared .build
# directory — every subsequent `swift build` from the shell then fails with
# "module compiled with Swift X cannot be imported by the Swift Y compiler".
# So tests build with Xcode into their OWN scratch directory, leaving the
# regular .build (CommandLineTools) untouched.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d /Applications/Xcode.app/Contents/Developer ]; then
  echo "Full Xcode is required to run tests (swift-testing's Testing module)." >&2
  exit 1
fi

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
exec swift test --scratch-path .build-test "$@"
