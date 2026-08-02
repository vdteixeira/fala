# DESIGN.md — Design Translation Layer (Claude Design mockups → native SwiftUI/AppKit)

## Purpose
The user builds visuals in **Claude Design** (which emits real HTML/CSS/JS, sometimes
React). Those exports land in `/design/mockups/**`. This document tells Claude Code how
to translate them faithfully into the native app.

## Prime directive
- **The mockup is the SOURCE OF TRUTH for VISUALS** (color, type, spacing, radius,
  shadow, states, layout intent).
- **macOS Human Interface Guidelines win on BEHAVIOR** (focus, key window rules,
  vibrancy/materials, menu semantics, keyboard nav, reduce-motion/-transparency,
  Dynamic Type equivalents, Dark Mode). When mockup and HIG conflict on behavior, HIG
  wins and you MUST note the deviation in `docs/architecture.md`.
- Never hardcode raw values in views. Everything flows through semantic tokens in
  `Theme.swift` / `DesignSystem.swift`.

## Actual `/design` structure (differs from the generic template: mockups are FLAT
## because they share relative assets — do not split them into per-surface folders)
```
design/
├── CLAUDE.md                    # designer's persistent rules (tokens, brand, states)
├── DESIGN-HANDOFF.md            # designer notes, states, motion spec, icon map
├── mockups/
│   ├── pill-overlay.dc.html     # HUD: recording/transcribing/idle/success/error/warning
│   ├── menubar-popover.dc.html
│   ├── settings-window.dc.html
│   ├── handoff.dc.html          # visual handoff sheet
│   ├── Fala Design System.dc.html
│   ├── fala-tokens.css          # CSS custom properties — token source of truth
│   ├── support.js               # mockup runtime support (decorative)
│   └── _ds/…                    # Claude Design bundle assets (decorative)
└── tokens/
    └── tokens.json              # W3C DTCG tokens (same names/values as fala-tokens.css)
```
`history-window` (Surface 4) is specified in DESIGN-HANDOFF.md §1 but not yet rendered.

## Token extraction process (mockup → `DesignSystem.swift`)
1. Read each mockup's CSS custom properties (`--color-*`, `--space-*`, `--radius-*`,
   `--shadow-*`, font-family/size/weight/line-height) and/or `tokens/tokens.json`.
2. Normalize into a single semantic token set (primitives → semantic aliases).
3. Generate `Sources/FalaKit/Theme/DesignSystem.swift` with typed tokens. Prefer a
   Style-Dictionary-style deterministic mapping; if a token bridge tool is available,
   use it, but the generated Swift is committed and reviewed.
4. Expose tokens through `Theme.swift` as a semantic surface consumed via
   `@Environment(\.theme)`; views never reference raw hex or numbers.

### Unit conversions & pitfalls (MUST handle)
- **px → pt:** CSS px are not AppKit points. Treat the mockup's base as 1px = 1pt at
  @1x for layout, but verify against the mockup's intended density; do not multiply by
  the backing scale. Round to the 8pt grid where the mockup implies it.
- **Colors:** convert hex/rgb(a) to `Color(red:green:blue:opacity:)` (or an asset
  catalog) with explicit light/dark variants. Do NOT reuse a single color across modes.
- **Dark Mode:** every color token needs a light and dark value; wire to
  `@Environment(\.colorScheme)` / asset catalog appearances.
- **Materials/vibrancy:** a flat CSS background often should become an AppKit material
  (`.regularMaterial`, `NSVisualEffectView`) for a native feel — this is a BEHAVIOR/HIG
  decision that overrides the flat mockup fill; document it.
- **Shadows:** CSS box-shadow (possibly multi-layer) → `.shadow(color:radius:x:y:)`;
  approximate multi-layer shadows with the dominant layer and note it.
- **Fonts:** map to SF Pro / system font by default (`.system(size:weight:)`); only use
  a bundled custom font if the mockup ships one and licensing allows.
- **Icons:** prefer **SF Symbols** over exported PNG/SVG icons when a close symbol
  exists (better scaling, weight matching, accessibility); fall back to bundled assets
  only when no symbol fits. Record each substitution. (DESIGN-HANDOFF.md §5 already
  maps every Material glyph used in the mocks to its SF Symbol.)
- **Motion:** honor `prefers-reduced-motion` → `accessibilityReduceMotion`.

## Component mapping table (HTML/React → SwiftUI/AppKit)
| Mockup element                     | Native target                                             | Notes |
|-----------------------------------|----------------------------------------------------------|-------|
| Bottom-of-screen pill overlay     | `NSPanel` (.nonactivatingPanel, .floating, becomesKeyOnlyIfNeeded) hosting SwiftUI via `NSHostingView` | Must not steal focus; `.canJoinAllSpaces`; LSUIElement app |
| Menu-bar dropdown / popover       | `NSStatusItem` + `MenuBarExtra(.window)` or `NSPopover`   | Start with MenuBarExtra; graduate to NSPanel only if it hits a wall |
| Settings window (tabs)            | SwiftUI `Settings` scene / `TabView`                     | Native tab semantics, standard toolbar |
| History list                      | SwiftUI `List` / `Table`                                 | Native selection, keyboard nav |
| Buttons / toggles                 | `Button`, `Toggle` styled by tokens                      | Native control sizes; don't reinvent |
| Text inputs                       | `TextField` / `SecureField`                              | Use SecureField semantics where relevant |
| Card / container `div`            | `VStack`/`ZStack` + token padding/radius/material        | Material may override flat fill (HIG) |
| CSS `:hover` / `:active` / focus  | SwiftUI hover/pressed/focus states                       | Map each mockup state 1:1 |
| Waveform / recording indicator    | Custom SwiftUI `Canvas`                                   | Drive from audio RMS; respect reduce-motion |

## Conflict-resolution rule (write it in code review)
For each screen, produce a short note: "Visual per mockup: <what>. Behavior per HIG:
<what overrode the mockup and why>." Attach it to the PR and to `docs/architecture.md`.

## Verification
- Build the screen, take a screenshot, and compare to the mockup; list differences and
  fix them (this is the agent's self-check loop for UI). Match tokens exactly; treat
  behavior deviations as intentional and documented.
