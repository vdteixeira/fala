---
name: design-translation
description: How to translate the Claude Design mockups in /design into Theme.swift + SwiftUI/AppKit. Use before any UI work (Phase 2). DESIGN.md is the contract; this skill is the how-to.
---

# Design translation (mockups → native)

Read DESIGN.md first (prime directive: mockup wins on visuals, HIG wins on
behavior). This skill adds the mechanics.

## Sources (all under /design)
- `design/mockups/fala-tokens.css` — semantic tokens, SOURCE OF TRUTH.
- `design/tokens/tokens.json` — same values, DTCG format (machine-friendly).
- `design/mockups/*.dc.html` — pill-overlay, menubar-popover, settings-window
  (+ design system sheet). history-window is spec-only (DESIGN-HANDOFF.md §1).
- `design/DESIGN-HANDOFF.md` — states table, motion spec, icon→SF Symbol map.
- `design/CLAUDE.md` — designer's persistent rules (brand, grid, naming).

## Process
1. Parse `tokens.json` (prefer it over scraping CSS) → emit
   `Sources/FalaKit/Theme/DesignSystem.swift` (generated, committed, reviewed).
2. `Theme.swift` exposes ONLY semantic tokens (`color.state.recording`,
   `space.md`, `radius.xl`, `motion.base`...). Views never see primitives or hex.
3. Every color token gets explicit light AND dark values (`data-theme` wrappers
   in the mocks tell you both). Pill overlay is ALWAYS dark HUD material in both
   appearances.
4. Icons: use the exact SF Symbol names from DESIGN-HANDOFF.md §5 — the mapping
   is already done, do not re-derive it.
5. Motion: 120/200/320 ms tokens + standard/spring easings; gate every animation
   on `accessibilityReduceMotion` (handoff §6 defines the reduced behavior).
6. Self-check loop: build screen → screenshot → diff against mockup → list and
   fix differences → record HIG-driven deviations in docs/architecture.md.

## Fixed vocabulary
Six states everywhere: idle, recording, transcribing, success, error, warning
(`--color-state-*` + `-soft`). Recording is rose, error is firm red — never merge
them. Brand accent: violet #5341CD (light) / #8A78EC (dark); amber #F28C26 warm.
