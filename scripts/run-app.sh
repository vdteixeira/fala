#!/usr/bin/env bash
# Launches Fala.app through LaunchServices and shows its output.
#
# WHY NOT JUST RUN THE BINARY: macOS attributes TCC permissions to the
# *responsible process*. Executing Fala.app/Contents/MacOS/Fala from a shell makes
# the TERMINAL responsible, so Accessibility is checked against Terminal's grant,
# not Fala.app's — `doctor` reports Acessibilidade ✗ even after you have ticked
# Fala.app in System Settings. `open` hands the launch to LaunchServices, which
# makes the app responsible for itself.
#
# The cost of `open` is that the process has no terminal, so its output goes
# nowhere; the app mirrors it to ~/Library/Logs/Fala/fala.log, which this script
# tails.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Fala.app"
LOG="$HOME/Library/Logs/Fala/fala.log"

if [ ! -d "$APP" ]; then
  echo "$APP not found — run ./scripts/make-app.sh first." >&2
  exit 1
fi

mkdir -p "$(dirname "$LOG")"
: > "$LOG"

# Terminate anything already running FIRST. `Fala run` never exits on its own, and
# `-n` below forces a new instance, so without this every invocation stacks another
# copy. Each copy installs its own event tap, microphone capture and ASR engine, so
# one hotkey press is captured, transcribed and injected N times — the injectors
# then race for the clipboard and all but one report "Não consegui inserir o texto".
# Observed for real: two instances produced doubled output where one line came from
# a stale binary.
if pgrep -f "$APP/Contents/MacOS/Fala" >/dev/null 2>&1; then
  echo "Encerrando instância(s) anterior(es) do Fala…"
  pkill -f "$APP/Contents/MacOS/Fala" || true
  # Give the tap and the audio engine a moment to tear down.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$APP/Contents/MacOS/Fala" >/dev/null 2>&1 || break
    /bin/sleep 0.2
  done
fi

# Absolute path: `open -a` resolves a bare relative path as an application NAME
# and fails with "Unable to find application named".
#
# `-n` forces a NEW instance, so a rebuilt binary is actually the one that runs
# instead of LaunchServices reactivating a stale copy (and silently dropping the
# arguments). Safe now that the previous instance is gone.
open -n -a "$(pwd)/$APP" --args "$@"

echo "Fala.app lançado com: $*"
echo "Saída (Ctrl+C para parar de acompanhar):"
echo
# The app writes asynchronously; give it a moment before following.
exec tail -f "$LOG"
