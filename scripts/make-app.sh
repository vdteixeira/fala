#!/usr/bin/env bash
# Builds Fala.app and ad-hoc signs it, so TCC-dependent features can be tested.
#
# WHY THIS EXISTS: macOS grants Accessibility to the *responsible process*. Run
# from a terminal, `.build/debug/Fala` inherits Terminal's TCC identity — the
# permission goes to Terminal, not to Fala, and CGEventTap/injection silently do
# nothing. A bundle with its own identity is the only way to exercise FR-1 and
# FR-11 (see CLAUDE.md "Known traps" and TASKS.md T1.10).
#
# CAVEAT: ad-hoc signing (`-`) gives a new code identity every time the binary
# changes, so macOS may drop the granted permission after a rebuild. If the app
# stops responding to the hotkey after you rebuild, remove it from
# System Settings › Privacy & Security › Accessibility and add it again. A real
# Developer ID certificate fixes this permanently — that is Phase 3, T3.3.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="build/Fala.app"

if [ "$CONFIG" = "release" ]; then
  swift build -c release
  BINARY=".build/release/Fala"
else
  swift build
  BINARY=".build/debug/Fala"
fi

# Only replace the binary if it actually changed. Ad-hoc signing derives the code
# identity from the bytes, so re-signing an identical binary still produces the
# same identity — but rebuilding the bundle from scratch (rm -rf) and re-signing
# on every invocation was enough churn that macOS kept dropping the Accessibility
# grant. Skipping the no-op case keeps a granted permission alive across runs.
mkdir -p "$APP/Contents/MacOS"
if [ -f "$APP/Contents/MacOS/Fala" ] \
  && cmp -s "$BINARY" "$APP/Contents/MacOS/Fala" \
  && [ -d "$APP/Contents/Resources/Fala_FalaKit.bundle" ] \
  && [ -f "$APP/Contents/Resources/Fala.icns" ]; then
  echo "Binary unchanged — keeping the existing signature (and your TCC grant)."
  echo "Built $APP"
  exit 0
fi
cp "$BINARY" "$APP/Contents/MacOS/Fala"

# Copy SwiftPM's resource bundle. WITHOUT THIS THE APP CRASHES on any machine but
# this one: `Bundle.module` looks next to the executable, misses, falls back to a
# hardcoded absolute path into .build, and then `fatalError`s — a trap, so the
# `try? JargonDictionary.loadDefault()` at the call site cannot catch it. It only
# appeared to work here because that .build directory still exists.
BUNDLE_SRC="$(dirname "$BINARY")/Fala_FalaKit.bundle"
if [ -d "$BUNDLE_SRC" ]; then
  mkdir -p "$APP/Contents/Resources"
  rm -rf "$APP/Contents/Resources/Fala_FalaKit.bundle"
  cp -R "$BUNDLE_SRC" "$APP/Contents/Resources/"
else
  echo "WARNING: $BUNDLE_SRC not found — the app will crash on JargonDictionary." >&2
fi

# The app icon. Regenerate it with `swift scripts/make-icon.swift` — it is drawn
# from the brand mark and the design tokens, so it cannot drift from the UI.
if [ -f Resources/Fala.icns ]; then
  cp Resources/Fala.icns "$APP/Contents/Resources/Fala.icns"
else
  echo "WARNING: Resources/Fala.icns missing — the app will use the generic icon." >&2
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Fala</string>
  <key>CFBundleDisplayName</key>       <string>Fala</string>
  <key>CFBundleIdentifier</key>        <string>com.fala.dictation</string>
  <key>CFBundleExecutable</key>        <string>Fala</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>CFBundleIconFile</key>          <string>Fala</string>
  <!-- Menu-bar app: no Dock icon, no main window (SPEC.md FR-15). -->
  <key>LSUIElement</key>               <true/>
  <!-- Shown in the microphone permission prompt. pt-BR: the user reads this. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>O Fala usa o microfone para transcrever sua voz localmente, no seu Mac.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

echo "Built $APP"
echo
echo "IMPORTANTE: rodar $APP/Contents/MacOS/Fala pelo Terminal NÃO usa a permissão"
echo "do Fala.app — o macOS atribui a Acessibilidade ao processo responsável, que"
echo "nesse caso é o Terminal. Use ./scripts/run-app.sh, que lança via 'open'."
echo
echo "  ./scripts/run-app.sh doctor   # diagnóstico como app"
echo "  ./scripts/run-app.sh run      # ditado por atalho"
echo
echo "Conceda Acessibilidade a Fala.app em:"
echo "  Ajustes do Sistema › Privacidade e Segurança › Acessibilidade"
