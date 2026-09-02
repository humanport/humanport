# HumanPort design tokens

The visual language of HumanPort as CSS custom properties. Framework-agnostic on
purpose: these files declare roles, and Tailwind exposes them as utilities.

## Files

| File | What it holds |
| --- | --- |
| `colors.css` | The 13 colour roles, in both themes, with contrast ratios in comments |
| `typography.css` | The type split, weights, sizes, tracking and leading |
| `geometry.css` | Two radii, the hairline, the focus ring, the pane column width |
| `theme.css` | The Tailwind v4 `@theme` block mapping roles to utilities |
| `fonts.css` | **Placeholder** — currently loads from Google Fonts, must be self-hosted |

Load order: `fonts` → `colors` → `typography` → `geometry` → `theme`.

## Themes

Dark is the default. `prefers-color-scheme: light` switches to the light sibling, and
`[data-theme="dark"|"light"]` overrides the system preference in both directions.

The light theme is **not an inversion**. Its values were chosen against their own
contrast targets: `#2BE8B0` is a glow colour that fails on paper, so the actionable
role becomes the ink-dark `#0B6E50` in light. `focus.ring` is the one role whose hue
changes between themes — a green ring on paper reads as a border, so light uses blue.

## Rules these tokens exist to enforce

**Risk is never carried by hue.** The sigils `[!!!]` / `[!!·]` / `[!··]` differ in glyph
count and weight, and the spelled form (`risk:high 3/3 · reversible:false`) sits beside
them. This holds in both themes. No risk level, and no state, may be identifiable by
colour alone.

**Type is split by job.** `--hp-font-mono` carries structure and data — every token,
key, value, title, table cell, sigil and keyboard hint. `--hp-font-prose` carries
running sentences only. A value never sets in prose; a paragraph never sets in mono.

**Focus is always visible.** 2px ring at 2px offset on every focusable element.

## One documented exception

`--hp-text-disabled` is 3.5:1 in dark, below WCAG AA. This is deliberate and bounded:
it marks a *state*, never information, and every control that uses it also states its
condition in words beside it — a locked approve button is accompanied by the sentence
that says what would unlock it. If you find this token carrying meaning that is not
also written out, that is a bug in the usage, not in the token.
