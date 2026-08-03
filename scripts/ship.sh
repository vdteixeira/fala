#!/usr/bin/env bash
# Builds a distributable Fala.dmg (TASKS.md T3.3).
#
# Release build → .app bundle → hardened-runtime signature → notarization →
# staple → .dmg. Every step that CAN run on this machine does; the ones that need
# an Apple Developer account are skipped loudly rather than faked.
#
# WHAT DECIDES THE OUTCOME: whether a "Developer ID Application" certificate is in
# the keychain.
#   - Present  → hardened runtime, real signature, notarization (with credentials),
#                stapled ticket. Recipients double-click and it just opens.
#   - Absent   → ad-hoc signature. The .dmg is still shareable, but Gatekeeper
#                blocks it on first launch on every other Mac and the recipient
#                must right-click → Abrir. See docs/pt-BR/instalacao.md.
# The script never pretends the second case is the first.
#
# Notarization credentials (one-time, needs a paid Apple Developer account):
#   xcrun notarytool store-credentials fala \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Fala"
BUNDLE_ID="com.fala.dictation"
VERSION="$(sed -n 's/.*version = "\(.*\)"/\1/p' Sources/FalaKit/FalaKitInfo.swift | head -1)"
VERSION="${VERSION:-0.1.0}"
KEYCHAIN_PROFILE="${FALA_NOTARY_PROFILE:-fala}"

DIST="dist"
APP="$DIST/$APP_NAME.app"
STAGE="$DIST/stage"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
ENTITLEMENTS="Resources/Fala.entitlements"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- build

say "Compilando em release"
swift build -c release
BINARY=".build/release/$APP_NAME"
[ -f "$BINARY" ] || { echo "Binário não encontrado: $BINARY" >&2; exit 1; }

say "Montando $APP"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

# The resource bundle. Without it `Bundle.module` traps at runtime — and it traps,
# so no `try?` at the call site can catch it. It only ever "worked" during
# development because the .build directory happened to still exist on that Mac.
BUNDLE_SRC=".build/release/${APP_NAME}_FalaKit.bundle"
if [ -d "$BUNDLE_SRC" ]; then
  cp -R "$BUNDLE_SRC" "$APP/Contents/Resources/"
else
  echo "ERRO: $BUNDLE_SRC ausente — o app travaria ao carregar o dicionário." >&2
  exit 1
fi

# The app icon. Regenerate it with `swift scripts/make-icon.swift` — it is drawn
# from the brand mark and the design tokens, so it cannot drift from the UI.
if [ -f Resources/Fala.icns ]; then
  cp Resources/Fala.icns "$APP/Contents/Resources/Fala.icns"
else
  echo "WARNING: Resources/Fala.icns missing — the app will use the generic icon." >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>CFBundleIconFile</key>          <string>Fala</string>
  <key>LSUIElement</key>               <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>O Fala usa o microfone para transcrever sua voz localmente, no seu Mac.</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------- sign

# `|| true` is load-bearing: with `set -o pipefail`, the grep exiting 1 because
# there is no certificate would kill the script — i.e. it would break in exactly
# the no-certificate case this branch exists to handle.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"

if [ -n "$IDENTITY" ]; then
  say "Assinando com Developer ID: $IDENTITY"
  # --options runtime is mandatory: Apple refuses to notarize without it.
  codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"
  SIGNED_PROPERLY=1
else
  say "SEM certificado Developer ID — assinando ad-hoc"
  echo "O .dmg vai funcionar, mas o Gatekeeper vai bloquear na primeira abertura"
  echo "em qualquer outro Mac. O destinatário precisa clicar com o botão direito"
  echo "e escolher Abrir (veja docs/pt-BR/instalacao.md)."
  echo
  echo "Para assinar de verdade: conta Apple Developer paga (99 USD/ano) e um"
  echo "certificado 'Developer ID Application' no Chaveiro."
  # No --options runtime here: the hardened runtime without a real signature buys
  # nothing and makes local ad-hoc testing harder.
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
  SIGNED_PROPERLY=0
fi

codesign --verify --deep --strict "$APP"
say "Assinatura verificada"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier" || true

# ---------------------------------------------------------------- dmg

# Detach any earlier mount of this volume FIRST. A leftover mount keeps
# /Volumes/Fala, so the new image gets mounted at "/Volumes/Fala 1" — and any
# check run against the old path silently inspects the PREVIOUS build. That
# nearly shipped a report saying the icon was missing when it was not.
for volume in /Volumes/"$APP_NAME"*; do
  [ -d "$volume" ] || continue
  hdiutil detach "$volume" -force -quiet 2>/dev/null || true
done

say "Criando $DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# The Applications symlink is what makes the window a drag-to-install target.
ln -s /Applications "$STAGE/Applications"
cp docs/pt-BR/instalacao.md "$STAGE/LEIA-ME.md" 2>/dev/null || true

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# ---------------------------------------------------------------- notarize

if [ "$SIGNED_PROPERLY" -eq 1 ]; then
  if xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    say "Enviando para notarização (pode levar alguns minutos)"
    xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    say "Grampeando o ticket"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    say "Notarizado e grampeado"
  else
    say "Certificado presente, mas sem credenciais de notarização"
    echo "Rode uma vez:"
    echo "  xcrun notarytool store-credentials $KEYCHAIN_PROFILE \\"
    echo "    --apple-id SEU_APPLE_ID --team-id SEU_TEAM_ID --password SENHA_DE_APP"
    echo "e execute este script de novo."
  fi
fi

# ---------------------------------------------------------------- report

say "Pronto: $DMG"
ls -lh "$DMG" | awk '{print "  tamanho:", $5}'
echo
if [ "$SIGNED_PROPERLY" -eq 1 ]; then
  echo "  Assinado com Developer ID."
else
  echo "  ⚠︎ Assinado ad-hoc, NÃO notarizado."
  echo "  Em outro Mac o Gatekeeper vai bloquear na primeira abertura."
  echo "  Envie docs/pt-BR/instalacao.md junto (já vai dentro do .dmg como LEIA-ME.md)."
fi
echo
echo "  Verifique o que o destinatário vai ver:"
echo "    spctl --assess --type execute -vv $APP"
echo
echo "  Conteúdo do .dmg:"
MOUNT="$(hdiutil attach "$DMG" -nobrowse | grep -o '/Volumes/.*' | tail -1)"
if [ -n "$MOUNT" ]; then
  ls "$MOUNT" | sed 's/^/    /'
  if [ -f "$MOUNT/$APP_NAME.app/Contents/Resources/$APP_NAME.icns" ]; then
    echo "    (ícone presente)"
  else
    echo "    ⚠︎ SEM ícone — rode: swift scripts/make-icon.swift" >&2
  fi
  hdiutil detach "$MOUNT" -quiet || true
fi
