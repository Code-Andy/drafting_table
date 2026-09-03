# 2026-09-03 — UI parity with the original Drafting Table (v0.8.0)

Reference: upstream `bgkatz/drafting_table` (`MainActivity.kt`, tool rail,
status bar, layer/color panels). Target product is defined by the original
README; this doc records what the iPad port now mirrors and what is still
engine-blocked.

## Original UI structure (source of truth)

- Left vertical tool rail: menu, DRAW (brush, eraser, bucket, shade),
  VECTOR (line, rectangle, circle, ellipse), SELECT (select, lasso), panel
  toggles (layers, pages, color), reset view.
- Right column: layers panel, brush panel, color mini-panel.
- Page sidebar with thumbnails, slide-deck style.
- Bottom status bar: doc name, current tool, grid/px/snap chips, angle snap,
  brush preview, motion prediction chips (tap to toggle).
- Color picker dialog: HSV square, hue slider, HEX/RGB readout, 16-color
  palette, recents, user slots, eyedropper; primary/secondary swap.
- Layer rows: name, visibility, opacity, reorder, rename, delete, rasterize.
- Overflow menu plus docs button for multi-document new/open/delete.

## What v0.8.0 ties over

- Left vertical rail with the original DRAW / SHAPE / SELECT sections,
  glyphs, and order, including circle. Page sidebar stays left-of-canvas,
  layer column stays right.
- Bottom status bar with the original chips: doc name, current tool,
  grid (live), px/snap/angle (persisted, arming M5/M11), preview
  (persisted), predict (live, gates Pencil predicted samples).
- Circle tool end to end: Bridge DTTool Circle value 5, widened validTool,
  Metal outline (bounding-square circle), archive round-trip, portable test
  coverage. No format bump: the tool byte was reserved-compatible.
- Tools with no retained-stroke representation yet (bucket, shade, select,
  lasso) get no enum values on purpose: unknown tool bytes fail archive
  decode, so placeholders must never persist. Tapping them shows which
  milestone delivers them instead of silently doing nothing.

## Known divergences (engine-blocked, not forgotten)

- Bucket/shade need the sparse tile backend (M2); selection plus
  transform/copy/paste need M6; snapping needs M5; pixel grid needs the
  tile compositor (M11).
- Undo/redo/clear live in the iPad rail (the original leans on stylus
  buttons); Pencil double-tap/squeeze already toggle brush/eraser.
- Color lives in the settings sheet; the HSV picker dialog, palettes,
  recents, eyedropper, and primary/secondary swap are still pending.
- Page thumbnails, page size presets, multi-document browser, image import,
  and rasterize/merge are still pending (M3/M7/M8).
- Rails stay visible (no collapse toggles yet); reset view stays in the
  navigation bar.

## Validation notes

- Circle round-trip caught a real bug locally before CI: validTool was
  still bounded by Ellipse, so circle archives failed decode. The portable
  test_ipad_engine now covers all six tools and passes under local MSVC
  as well as CI.
