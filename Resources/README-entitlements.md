# Fala.entitlements

Why the plist next door is three lines and carries no XML comments: `codesign`
hands entitlements to AMFI's parser, which is stricter than a normal plist reader
and rejects comments with `AMFIUnserializeXML: syntax error`. So the reasoning
lives here.

## `com.apple.security.device.audio-input`

Required by the hardened runtime, which is itself required for notarization —
Apple refuses to notarize a bundle not signed with `codesign --options runtime`,
and the hardened runtime then denies microphone access unless this entitlement is
present. `NSMicrophoneUsageDescription` in `Info.plist` is also required: the
entitlement grants the capability, the string explains it to the user.

## Why the app is NOT sandboxed

The App Sandbox forbids `CGEventTap`, which is how the push-to-talk hotkey works at
all (FR-1), and forbids synthesising the paste chord into another application
(FR-11). **A sandboxed build of this app cannot dictate.** That rules out the Mac
App Store and makes Developer ID + notarization the only distribution route — which
is exactly what T3.3 is.

## What is deliberately absent

No JIT, no unsigned-executable-memory, no library-validation exception, no network
entitlement. The app makes no network call after the one-time model download, and
CoreML needs none of those relaxations. Adding any of them weakens the hardened
runtime for no gain, and each one is something a reviewer would have to justify.
