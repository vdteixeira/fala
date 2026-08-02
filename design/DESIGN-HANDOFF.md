# Fala — Design Handoff (SwiftUI)

App: **Fala** — push-to-talk dictation, 100% on-device, macOS Apple Silicon, pt-BR. Menu-bar app (LSUIElement, no Dock icon). Privacy is the brand's core: the violet "vault" + amber warmth identity and the ever-present privacy line are deliberate, not decoration.

**Sources of truth (mutually consistent, verified):** `fala-tokens.css` (CSS custom properties) ⟷ `tokens.json` (DTCG, same names/values; mapping documented in its top-level `$description`). Surfaces: `pill-overlay.dc.html`, `menubar-popover.dc.html`, `settings-window.dc.html`. `history-window` is specified below but not yet rendered (Surface 4 pending).

---

## 1 · Surfaces — intent & hierarchy

### pill-overlay (HUD)
- Floating pill, bottom-center, above all apps. Always the **dark HUD material** (`--color-pill-bg` ≈ 88–92% dark plum + blur) in BOTH system appearances — like macOS volume/dictation HUDs.
- Hierarchy: state icon → (waveform) → short label → hotkey keycap. One line when it fits; wraps to a rounded rect (`--radius-xl`) when narrow.
- Hidden = collapsed 28×5px sliver at 35% opacity; disappears entirely after ~2s idle.
- Enter: `fala-appear` 320ms spring. Exit: `fala-dismiss` 200ms standard. Success auto-dismisses after 1.2s; error after 2.5s; warning persists while HFP route is active.

### menubar-popover
- NSPopover, 340pt wide, arrow to status item, vibrancy background.
- Hierarchy: header (logo + dictation on/off toggle) → [permissions banner, only when pending] → model status block → "Recentes" (3–4 truncated transcriptions with timestamp + destination app + copy) → quick actions (Abrir Ajustes ⌘, · Abrir Histórico) → **fixed privacy footer** "100% no seu Mac · sem telemetria" (violet soft band, always visible).
- Model block variants: pronto (green cpu icon + "1,1 GB local") / baixando (progress bar + % + MB) / erro (red border, "Tentar novamente").

### settings-window
- Standard macOS Settings window, 520pt, toolbar-style tabs (icon over label): Geral, Áudio, Dicionário, Modelo, Privacidade.
- Geral: shortcut recorder (default "⌥ direito", pencil to re-record; border pulses while recording), Iniciar no login, Mostrar overlay.
- Áudio: input device picker; amber HFP warning row appears (spring, 320ms) only when a Bluetooth/HFP device is selected; 12-segment input level meter (top segments amber).
- Dicionário: PT-EN jargon list (deploy, endpoint, Kubernetes, commit, pull request), per-row delete, "Adicionar termo" input+button, Importar/Exportar JSON.
- Modelo: Parakeet v3 · pt-BR, disk used, "Baixar novamente" + in-progress variant (progress bar, Cancelar), free-disk line.
- Privacidade: emotional core — centered lock+waveform mark, "Sua voz não sai do seu Mac.", three reassurance rows (local no Apple Silicon / offline · sem telemetria, sem contas / LGPD), trust badge.

### history-window (Surface 4 — pending render)
- Intent: standard window listing full transcriptions; search field, day grouping, per-row: text, timestamp, destination app, duration; row actions copy (`doc.on.doc`), re-inject (`arrow.uturn.left`), delete (`trash`). Uses the same list-row pattern as the popover "Recentes" at comfortable density. Privacy note: history is stored locally only; offer "Apagar tudo".

---

## 2 · The six states (shared vocabulary)

| State | Token | Communicates | Icon (SF Symbol) |
|---|---|---|---|
| idle | `--color-state-idle` | resting, ready, no capture | `mic.fill` |
| recording | `--color-state-recording` | live capture (rose, animated waveform) | `waveform` |
| transcribing | `--color-state-transcribing` | on-device processing (violet, spinner) | `arrow.triangle.2.circlepath` |
| success | `--color-state-success` | text injected at cursor | `checkmark.circle.fill` |
| error | `--color-state-error` | blocked/failed (e.g. secure field) | `exclamationmark.triangle.fill` (secure field cause: `lock.fill`) |
| warning | `--color-state-warning` | degraded but working (AirPods/HFP) | `exclamationmark.circle` / `airpods` |

Each has a `-soft` background companion. Recording ≠ error on purpose: rose (live) vs firm red (failure).

## 3 · Behavior / interaction notes
- **Push-to-talk:** hold right-Option (⌥ direito) → pill appears (spring) + recording; release → transcribing → success (auto-insert at cursor) → dismiss. Hotkey re-recordable in Ajustes › Geral.
- **Secure field:** if focus is a secure text field, never inject nor retain: pill shows error "Campo protegido — injeção bloqueada", exits after 2.5s.
- **AirPods/HFP:** when input route is Bluetooth HFP, show warning pill + amber row in Ajustes › Áudio ("Prefira o microfone interno."); dictation still works.
- **Permissions:** Accessibility + Microphone pending → amber banner in popover with "Conceder" (deep-link to System Settings). Healthy state hides the banner entirely.
- **Model:** first-run download with % + MB; failure offers "Tentar novamente"; re-download available in Ajustes › Modelo.
- **Dictation toggle** in popover header disables capture globally (subtitle switches Ditado ativado/desativado).

## 4 · Decorative vs functional
- **Functional:** state icons, waveform (voice level), all labels, hotkey keycap, toggles, progress bars, permissions banner + CTA, device picker + HFP warning, dictionary add/remove, privacy line/badge.
- **Decorative only:** blurred backdrop windows in mocks, vibrancy/blur materials, traffic lights, popover arrow, download-icon pulse, lock+waveform illustration, `--shadow-pop`.

## 5 · Icon map (Material glyph used in mocks → SF Symbol)
mic→`mic.fill` · graphic_eq→`waveform` · autorenew→`arrow.triangle.2.circlepath` · check_circle→`checkmark.circle.fill` · warning→`exclamationmark.triangle.fill` · error→`exclamationmark.circle` · headphones→`airpods` · lock→`lock.fill` · shield_lock/verified_user→`lock.shield.fill` / `checkmark.shield` · settings→`gearshape.fill` · history→`clock.arrow.circlepath` · menu_book→`character.book.closed.fill` · memory→`cpu` · download→`arrow.down.circle` · hard_drive→`internaldrive` · content_copy→`doc.on.doc` · undo→`arrow.uturn.left` · delete→`trash` · keyboard→`keyboard` · power_settings_new→`power` · pill→`capsule.fill` · edit→`pencil` · wifi_off→`wifi.slash` · upload/download (JSON)→`square.and.arrow.up` / `square.and.arrow.down`.
Menu-bar status icon: 4 waveform bars forming a speech quote mark — monochrome template image.

## 6 · Motion spec
- Tokens: `--motion-fast` 120ms (hover, toggle knob w/ spring, icon swap) · `--motion-base` 200ms (surface hover, focus ring, progress width, dismiss) · `--motion-slow` 320ms (pill/popover enter, theme cross-fade).
- Easings: `--ease-standard` cubic-bezier(0.2, 0, 0, 1) · `--ease-spring` cubic-bezier(0.34, 1.4, 0.64, 1).
- Keyframes: `fala-wave` 900ms standard loop (staggered negative delays) · `fala-pulse` 1.6s standard loop · `fala-spin` 900ms linear loop · `fala-appear` 320ms spring · `fala-dismiss` 200ms standard.
- **prefers-reduced-motion / Reduce Motion:** all animation/transition effectively disabled (see media query in fala-tokens.css). Waveform renders as static bars, spinner as static icon, pill appears/disappears without transition. State stays legible via color + icon + text.

## 7 · Language & naming
- ALL user-facing strings are pt-BR (short, calm). Code identifiers/tokens/files in English.
- "Fala" is a placeholder name: it appears only in the popover header lockup, window title "Ajustes — Fala", and marketing copy — swap via a single brand-name constant (mocks expose it as the `brandName` tweak). Logo mark is name-independent.

## 8 · Consistency statement
`fala-tokens.css`, `tokens.json`, the three rendered surfaces, and this note use the same token names and values (spot-check: violet.600 #5341CD = `--fala-violet-600` = light `--color-accent`; rose.500 #F43F6E = light `--color-state-recording`; space 8/16/24; radii 6/10/14/20/999; durations 120/200/320ms). Components never reference primitives or hardcoded values — semantic tokens only.
