# Drafting Table — original UI design system

This document records the visual contract for the iPad port.  It is a direct
translation of the upstream `bgkatz/drafting_table` Android Concept A v4
surface, not a new visual language.  The implementation may use UIKit layout
primitives, but the geometry, colors, icon paths, and typography below should
remain recognizable against the Android preview.

## Source of truth

The inspected upstream source is commit
`9a668cde44f5194db51df64a355a15af55f126a6`:

* `app/src/main/res/values/colors.xml` lines 8–19 — paper, ink, rule, accent,
  hot/sienna, bezel, and disabled tokens.
* `app/src/main/java/com/bk/drawing/MainActivity.kt` lines 34–45 — the Concept A
  shell diagram (56dp tool rail, 84dp page bar, 180dp layer panel, 28dp status).
* `MainActivity.kt` lines 238–250 — the 4×8, 32-cell palette.
* `MainActivity.kt` lines 352–452 — shell composition and the canvas inset.
* `MainActivity.kt` lines 560–710 — rail grouping, tile geometry, and labels.
* `MainActivity.kt` lines 781–1028 — layer panel, section headers, rows, and
  actions.
* `MainActivity.kt` lines 1249–1628 and 1684–1958 — brush/color controls,
  swatches, and spacing.
* `MainActivity.kt` lines 2418–2527 — status bar and status chip spacing.
* `app/src/main/res/drawable/ic_*.xml` — the 24×24 VectorDrawable icon paths.

`design/guides/ui-tokens.json` is the machine-readable token snapshot.
`design/guides/concept-a-v4-component-sheet.svg` is an importable visual
reference for Figma.  In Figma, choose **File → Import**, select that SVG, and
use the labeled component groups as the baseline for screenshots or UI review.
The sheet includes portrait and landscape iPad frames plus the tool tile, page
thumbnail, layer row, brush controls, color swatches, undo chip, and status bar.

## Surfaces and typography

| Token | Value | Use |
| --- | --- | --- |
| `paper` | `#F5F0E6` | canvas and paper dialog surface |
| `paperDeep` | `#EDE5D2` | rails, panel headers, active row, status bar |
| `ink` | `#2A2620` | primary glyphs and labels |
| `inkSoft` | `#6B6357` | secondary labels and controls |
| `inkFaint` | `#B8AE9B` | section labels, hints, disabled affordances |
| `rule` | `#D9CFB8` | one-pixel/one-point hairlines |
| `hot` | `#B5482E` | active tool/state and primary action |
| `accent` | `#3A4F6B` | reserved secondary ink-blue accent |
| `bezel` | `#1A1714` | outside the page/canvas |
| `inkDisabled` | `#C8BFA9` | disabled controls |

Labels and measurements use JetBrains Mono (400/600).  Inter (400/600) is the
prose/control face.  `DraftingTheme` resolves those names when installed and
falls back to Menlo/Helvetica Neue/system fonts without changing the layout.

## Geometry contract

The canonical landscape shell is:

```text
┌──────┬────────┬────────────┬──────────────────────────┐
│ rail │ pages  │ layers     │ canvas                   │
│ 56dp │ 84dp   │ 180dp      │ remaining width           │
└──────┴────────┴────────────┴──────────────────────────┘
status bar: 28dp pinned to the bottom
```

The rail uses 38×38dp tiles with 6dp icon padding and 1dp vertical margins.
Section labels are 8sp mono with 0.12 tracking; rules are 30dp wide with 3dp
vertical margins.  Layer and section rows are 32dp/28dp high.  The page
thumbnail fits a portrait page inside 60×78dp without letterboxing.  Panel
content uses 10/8/10/12dp leading/top/trailing/bottom insets.  Status text is
9sp mono with 18dp gaps and 12dp horizontal inset.  The floating undo/redo
chip begins 16dp from the visible panel edge and 16dp below the canvas top.

## Icon contract

The Android paths are copied into `Assets.xcassets/Chrome/dt_*.imageset` as
single-scale SVG template assets.  Every SVG keeps a 24×24 viewBox, source
group scale/rotation around the `(12,12)` pivot, stroke widths, caps, joins,
and source alpha.  Black Android paint becomes `currentColor`; transparent
paint remains `none`, so UIKit can tint active tiles `hot` and inactive tiles
`ink`.  `DraftingIcon.image(named:fallback:)` resolves these assets and falls
back to the closest SF Symbol if a catalog is unavailable in a test target.

The conversion is reproducible with:

```text
python tools/convert_android_vectors.py \
  --source <original>/app/src/main/res/drawable \
  --output platforms/ipad/Assets.xcassets/Chrome
```

The converter intentionally does not “improve” path geometry.  If the
upstream icon changes, update the source commit in `ui-tokens.json`, rerun the
converter, and review the generated SVGs in the component sheet.

## Behavior and parity boundaries

This is a visual system, not a promise that every Android implementation
detail is normative.  Android remains a behavior reference; known bugs and
platform-specific behaviors should be recorded before they are copied.  In
particular, Android bucket fill currently uses only the active raster layer as
its boundary; a visible-composite fill would be a deliberate product choice.
The iPad renderer may remain tile-backed and GPU-owned while presenting this
same shell.

The Android source currently comments “16-cell” in one color-section block
while the actual `MainActivity` palette is 32 cells (4×8).  The machine token
file and iPad reference use the actual 32-cell palette; this discrepancy is
recorded rather than silently “fixing” the upstream source.

The original repository has no redistribution license.  This port is intended
for the owner's personal sideloading workflow; no App Store/TestFlight
distribution or third-party asset redistribution is implied.
