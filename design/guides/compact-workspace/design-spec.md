# Canvas-first workspace · study 03

Status: interactive design proposal, revised from the owner's color-wheel
reference and feedback. Native implementation remains a separate step.
This specification supersedes study 02's layout. The complete earlier feature
inventory remains in [study-02-design-spec.md](study-02-design-spec.md); its
panel placements and geometry are historical, not current instructions.

## Main changes

- Tools and color belong on the left, beside the drawing tools. Neither is a
  right-inspector tab. The right side contains only **Layers** and **Pages**.
- Remove the entire second toolbar / context strip. The single header is 36
  px high in the pointer preview, with 34 px controls and 15 px icons. Coarse
  input expands the header buttons to 40 px. Native sizing must be reviewed
  with actual Pencil and finger input.
- Remove the bottom status strip, including grid / pixel / snap state text.
  View settings remain available through the existing header View control;
  there is no replacement bottom menu bar.
- Use a 208 px right inspector (adjustable 190–230), 6 px content insets,
  36 px layer rows, 28 × 38 px page thumbnails, and 3–6 px gaps.
- Keep 10–14 px between the drawing viewport and surrounding chrome. These
  are deliberate small margins, not an edge-to-edge zero-margin canvas.
- Tool settings appear in a 220 px anchored window. Color editing appears in
  a 228 px window above the bottom-left wheel. Both overlay the canvas rather
  than consuming a permanent column.

The mockup's fixed 704 px work-area height is for browser comparison. Native
layout must fill the actual safe area. The illustrated white surface is the
drawing viewport, not a measured preview of an exported A4 page.

## Tool windows

Each tool tile retains direct tool selection. A small bottom-right chevron
toggles its options. The window appears on the canvas side of the left rail,
beside the selected tool, and clamps vertically to stay inside the workspace.
"Beside it on the left" is interpreted as the left side of the app, immediately
to the right of the rail; there is no screen space outside the left edge.

The corner indicator is a small Pencil/pointer affordance, not a full finger
target. Tapping the already-active tool again opens/closes the same window.
The main tool target remains 44 px. Native accessibility must expose an
equivalent Options action, so using the tiny corner is never required.

Window header: tool name, pin toggle, close. Pinned windows follow tool
changes. Unpinned windows close on a different tool selection. Closing a
window leaves it closed until the user opens it again. Opening another tool's
corner selects that tool and opens its window. Only one tool window exists.

Brush / eraser: size, opacity, hardness, pressure, uniform opacity. Secondary
stabilization and prediction controls use one **Stroke feel** disclosure.
Shade adds closure. Bucket contains source, tolerance, gap, bleed, opacity.
Shapes retain width/fill/opacity/constraints and explicit vector-layer creation
when necessary. Select/lasso retain combine, feather, clipboard and transform.
Eyedropper retains sampling source. Existing tool options are relocated rather
than dropped from the design inventory.

Opening the palette editor closes the tool window. At narrow widths, opening
a right panel closes left windows, and opening left options collapses the
right panel. Avoid stacking two opaque inspectors over a small drawing area.

## Corner wheel

The reference's useful idea is a wheel that continues beyond the viewport,
revealing an arc instead of occupying a full disk of screen space. The study
uses a clipped 248 × 228 px area beside the bottom of the tool rail, with a
176 px outer radius and an accessible 56 px center button. Only several hue
families are visible at a time. Transparent space outside the arc passes
through to the drawing surface.

### Basic palette

**RGB** starts with 12 basics: red, orange, yellow, green, cyan, blue, violet,
magenta, brown, gray, black, and white. Each has base and light shades, giving
24 swatches total. It intentionally avoids hundreds of labeled swatches.
The outer band is the base color; the inner band is the lighter shade.

Drag the arc, scroll over it, or press its previous/next arrows to rotate.
The arrows advance 30 degrees, one basic family. Click/tap a visible swatch
to choose it. Offscreen sectors are not keyboard-focus targets. Named controls
and the color editor provide alternatives to precise wheel selection.

**Marker** offers the same small family structure with muted, marker-inspired
tones. It reflects the organizational idea of the supplied reference. It is
not an exact COPIC catalogue, calibrated marker simulation, or verified
mapping from brand codes to sRGB colors. Exact branded swatches would need an
appropriate source and a separate color-management decision.

### Custom override

Pressing the center switches to **My colors** and opens the small palette
editor. Six initial editable colors replace the basic wheel. Select a custom
slot, choose a new color, and press **Replace slot**. **Add color** supports up
to twelve slots. A lighter shade is generated for each custom base color.

Press the center again to restore the last RGB/Marker mode. The editor also
provides direct RGB / Marker / My colors controls. Custom colors remain in
preview state when switching modes, but reload resets the preview. Native
implementation should persist the custom wheel as an app preference.

The center shows the current ink and mode. A small collapse action reduces
the wheel to its center button; pressing the collapsed center restores the
arc without unexpectedly changing the palette.

### Continuous color editing

The editor has a continuous hue ring and saturation/brightness square, plus
numeric slider alternatives, hex input, eyedropper, and foreground/previous
swap. Changing hue or saturation updates current ink. Custom wheel changes
are explicit slot replacements; dragging a hue must not overwrite the user's
stored palette automatically.

The ring is a color-selection control, not an illustration-only graphic.
Its HSV changes and slot replacements are interactive in the preview.

## Compact right panels

Layers: add raster/vector, select, show/hide, actions, selected-layer opacity,
lock, duplicate. Rows use compact icon spacing; long names truncate at the
trailing edge and remain fully readable in rename/actions.

Pages: add, setup, thumbnails, selection, rename, duplicate, reorder, delete.
Actions retain independent width so they cannot squeeze names into awkward
word wrapping. No permanent page-thumbnail rail is added.

At widths at or below the preview's 820 px breakpoint, the right inspector
becomes an overlay and starts collapsed. The breakpoint is illustrative;
native code must use usable safe-area width and selected text size. Mirrored
left-handed mode moves the rail, tool windows, and wheel together.

## What stays available

The study retains the existing document gallery, new/open/rename, page setup,
layer actions, selections/transforms, Files/Photos placement, export forms,
Pencil mappings, quick palette, preferences, diagnostics, and save/recovery
flows. These are described in study 02's feature inventory. Their document /
renderer operations are still simulated; no native source or IPA changes are
part of this delivery.

Tool and palette settings apply to the same future renderer contracts:
active-raster-layer bucket boundaries by default, explicit visible-layer fill,
true alpha eraser, grouped layer opacity, serial document mutation and
versioned save/undo transactions. UI reorganization does not change them.

## Density tradeoff and assumptions

- Page space is the priority. Smaller secondary controls are intentional.
  Main tool access remains 44 px; header/secondary targets are denser and must
  be tried on the iPad before native sizes are frozen. Do not claim every
  control in this compact study is 44 × 44.
- Essential control labels remain 11–12 px; shrinking empty space gives a
  larger gain than pushing essential text below that range.
- The center button means palette override/editing, not a new document action.
- Use 12 base families with two shades, not a full marker catalogue.
- The wheel occupies an overlay only. It does not reserve a square of canvas
  layout, and it can collapse to the center button.
- The provided image is a visual reference. No labels or instructions inside
  it are treated as instructions to change application behavior.
- This is design work by the orchestrator; no Luna visual delegation. All
  guides remain together under `design/guides/compact-workspace`.
