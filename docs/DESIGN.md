# Openband design language (v4)

One accent, a warm neutral ground, two faces of type, and no decoration that does not carry a
number. The palette and the voice come from the Creaphic identity system; the discipline — one
container, one accent, one motion curve — is Openband's own.

The tokens are not written in Swift. They live in [`design/tokens.json`](../design/tokens.json)
and reach the app through `scripts/gen_tokens.py`:

```bash
python3 -I scripts/gen_tokens.py   # rewrites ios/Openband/UI/Design/Tokens.generated.swift
```

CI fails if the generated file and the JSON have drifted apart. Views never read the raw table;
they use the semantic API in `Tokens.swift`, `Typography.swift` and `Motion.swift`.

## 1. Colour

| Token | Light | Dark | What it is for |
|---|---|---|---|
| `canvas` | `#F5F4EF` | `#121310` | The screen behind everything. Paper, and graphite. |
| `surface` | `#ECEAE2` | `#1C1D1A` | Cards. The only container. |
| `raised` | `#FFFFFF` | `#262724` | Sheets, the selected segment, a pressed row. |
| `hairline` / `hairlineStrong` | `#E2E0D7` / `#C8CBC5` | `#2E2F2B` / `#44453F` | Separators; arc and chart tracks. |
| `textPrimary` → `textTertiary` | `#20211F` → `#8E9089` | `#F5F4EF` → `#71736C` | Four steps, in that order. `textTertiary` fails 4.5:1 on purpose and is for placeholders only. |
| `action` | `#E0541F` | `#FF6535` | Gün doğumu. Buttons, on-state toggles, the selected sport. |
| `onAction` | `#FFFFFF` | `#20211F` | What sits on an orange block. In dark mode that is **graphite, not white** — small white text on orange fails contrast, and the brand guide says so. |
| `actionSoft` | `#FBE4D8` | `#33211A` | The fill behind a chip or a badge. Never behind body text. |
| `good` / `fair` / `low` | — | — | Verdict words only, always next to the word itself. |
| `sleep` / `activity` / `heart` | — | — | The three domains: Ufuk blue, Gün doğumu, a deep red. |
| `zone1…zone5` | — | — | One heat ramp, Sis → orange → red. Colour never carries a zone alone: the bar is gapped and every zone is labelled. |

Two rules decide almost every colour question:

1. **Orange is you, moving.** It is both the accent and the activity colour, which is the same
   idea said twice. Filled blocks of orange are buttons; everything else that is orange is a
   measurement of effort. Body text is never orange.
2. **Colour is never the only signal.** A score has a word, a zone has a label, a delta has an
   arrow. Both themes and Increase Contrast resolve from the same token, so nothing is checked
   in one appearance and broken in the other.

## 2. Type

**Plus Jakarta Sans** (400 / 500 / 600) carries the interface. **IBM Plex Mono** carries
technical readouts — the workout clock, pace, splits, coordinates, the share card's footer. The
second face is not the first one's rival: it never sets a paragraph.

| Style | Size / line | Weight | Used for |
|---|---|---|---|
| `figureXL` | 56 / 58 | 600 | The one number a screen is about |
| `figureL` | 40 / 44 | 600 | Sleep duration, a calorie total |
| `title` | 28 / 34 | 600 | Screen titles, the day's verdict |
| `figureM` | 28 / 32 | 600 | Card figures, score arcs |
| `headline` | 17 / 22 | 500 | Section and sheet titles |
| `body` | 16 / 24 | 400 | Paragraphs, row titles |
| `button` / `figureS` | 16 / 20 | 500 | Buttons; row values |
| `subhead` | 14 / 20 | 400 | Status lines, footnotes |
| `caption` | 12 / 16 | 400 | Axes, units, labels |
| `timer` | 56 / 58 | mono | The running workout clock |
| `monoM` / `monoS` | 17 / 12 | mono | Splits and paces; dates and coordinates |

Everything scales with Dynamic Type. Bold Text steps each weight up once. Figures are tabular,
so a changing number does not shift the layout under it. Sentence case throughout, tracking 0.

Fonts are bundled under the SIL Open Font License; the notices sit beside them in
`ios/Openband/Resources/Fonts/`. The three Plus Jakarta Sans weights are static instances cut
from the variable font, because `UIFont(name:)` cannot pick a weight out of a variable face.

## 3. Shape and space

Spacing is a 4/8 grid: 4, 8, 16, 24, 32, 48. The screen gutter is 20, card padding 16, and 32
between sections. Radii: 3 on chart marks, 14 on controls, 20 on cards, and a full pill on chips
and the sport picker. Circles are for quick actions, the close button and status dots.

**One container.** A `Card` is surface, radius 20, 16pt padding, no border and no shadow: the
separation is the step from canvas to surface. Nothing floats on the canvas without one, and
cards are never nested.

Touch targets are 44pt; the primary button is 52.

## 4. Motion

One curve — `timingCurve(0.33, 0, 0, 1)` — over 0.32 s, and it animates colour. No springs, no
pulsing, no scaling on press. Two exceptions, both earned: a score arc trims to its value the
first time it appears (0.7 s), and numbers roll with `.numericText()`. Under Reduce Motion the
arc is drawn at once and numbers swap in place.

This is Creaphic's "one dominant movement per scene" at app scale: the screen settles, then you
read it.

## 5. Voice

Short, clear, curious, confident. Say what the app did and what it could not; never promise a
result. "Energy is an estimate: no heart rate was recorded" beats a number with no caveat.
Units are spelled the way the reader's locale spells them. Estimates say they are estimates —
in the Coach, on the strain score, on every calorie figure.

English is the source language for everything in the repository, including UI strings; Turkish
is a full translation in `Localizable.xcstrings`, not an afterthought.

## 6. Checking it

- `DesignGallery` — launch the app with `-freeband-gallery` for every token, type style and
  component on one screen.
- `FBPreviewMatrix` — the preview helper that renders a component in light, dark, and both at
  AX3 text size. New components get one.
- `python3 -I scripts/gen_tokens.py && git diff --exit-code` — the check CI runs.
