# Fala — persistent project rules

Fala: push-to-talk on-device dictation for macOS (Apple Silicon), pt-BR. Privacy is the core identity.

- `fala-tokens.css` is the SINGLE SOURCE OF TRUTH. Every screen links it and references ONLY semantic tokens (`--color-*`, `--shadow-*`, `--space-*`, `--radius-*`, `--text-*`, `--motion-*`, `--ease-*`). Never primitives (`--fala-*`) in components, never hardcoded values.
- Themes: `data-theme="light"` / `data-theme="dark"` wrapper; show both when asked.
- Brand: violeta #5341CD (light accent) / #8A78EC (dark accent); warm accent âmbar #F28C26. No purple-on-white gradients.
- Fonts: Plus Jakarta Sans (display/brand), system-ui SF Pro (UI), SF Mono (shortcuts/code). UI strings in pt-BR; code/identifiers in English.
- 8px spacing grid (4px only for tight icon/text gaps).
- State vocabulary (shared everywhere): idle, recording, transcribing, success, error, warning → `--color-state-*` (+ `-soft`).
- Icons: Material Symbols Outlined glyphs, each annotated with SF Symbol name in a comment (e.g. /* SF Symbol: mic.fill */).
- Motion tokens: --motion-fast 120ms / base 200ms / slow 320ms; --ease-standard, --ease-spring. Respect prefers-reduced-motion (handled in fala-tokens.css).
- Hotkey: right-Option (⌥ direita). Logo: 4 waveform bars forming a speech quote mark; monochrome template version for menu bar.
- Reference doc: `Fala Design System.dc.html`.
