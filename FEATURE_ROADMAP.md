# iPad feature roadmap

This roadmap converts the Android feature set into dependency-ordered iPad
milestones. A checked milestone means its acceptance gate has passed on both
portable tests and a real Xcode device build; it does not imply that downstream
features are complete.

## Dependency path

```text
M1 engine/bridge
 ├─> M2 raster tools ────────┐
 ├─> M3 pages/layers/docs ───┼─> M6 selections
 ├─> M4 gestures/input ──────┤
 │    └─> M9 Pencil Pro      │
 ├─> M10 diagnostics         │
 └─> M11 Metal parity ───────┴─> M12 release/performance

M3 + M4 -> M5 vectors/snapping -> M6
M3 -> M7 document packages/migration -> M8 import/export -> M12
```

## M1 — engine and bridge foundation

Status: **in progress; retained-session slice implemented**

- Canonical Pencil samples, coalescing, prediction, and estimated corrections
- Pressure activation/lift-off hysteresis
- Brush/Eraser retained styles, size, opacity, Undo/Redo
- Versioned stroke archive and atomic autosave
- Objective-C++ bridge and deterministic portable tests

Remaining gate: replace the single retained stroke list with real
Document/Page/Layer ownership and an ordered render-command queue.

## M2 — raster tool parity

- Connect `BrushEmitter` batches to sparse Metal tiles
- True destination-out eraser
- Hardness, alpha, uniform-alpha MAX coverage
- Shade closed-path nonzero fill and chord behavior
- Bucket fill with bleed
- Deterministic raster undo/redo

Acceptance: pressure strokes and eraser are seamless across tile boundaries;
shade/bucket match Android fixtures; undo→redo is byte-deterministic.

## M3 — documents, pages, and layers

- Dynamic page/layer rails and active selection
- Add/delete/rename/reorder pages and layers
- Visibility, opacity, raster/vector layer types, rasterize/merge
- Page size presets and thumbnails
- Multi-document new/open/rename/delete

Acceptance: indices and thumbnails stay correct across reorder/delete and the
entire structure survives relaunch.

## M4 — canvas gestures and input separation

Status: **initial implementation complete; awaiting device validation**

- Two-finger pan, pinch, and rotation
- Reset/fit view and persistent canvas transform
- Strict Pencil drawing versus finger gesture routing
- Palm rejection and interruption-safe stroke lifecycle

Acceptance: the document point under the gesture centroid remains stable and
gestures never create accidental marks.

## M5 — vector tools and snapping

- Metal SDF line, rectangle, ellipse, and circle
- Shape previews, vector color/width, rasterize
- Grid and pixel-grid overlays
- Grid/vector/angle snapping with velocity engagement and release hysteresis

Acceptance: uniform translucent geometry, stable snap locks, and correct
15-degree angle snapping at every zoom.

## M6 — selections and transforms

- Raster rectangle/lasso lift, move, scale, rotate, fixed aspect
- Vector tap/marquee selection and oriented handles
- Copy, cut, paste, delete, rasterize below

Acceptance: transformed pixels/shapes and undo bounds are exact; diagonal
marquee tests do not over-select.

## M7 — document packages and Android migration

- Files-compatible `.drafttable` packages
- Lazy sparse-tile load, deferred atomic writes, crash recovery
- Android `page_*`, `layer_*`, tile, `VEC0`, and `VEC1` import

Acceptance: interrupted writes recover; large documents remain lazy; Android
golden fixtures open without geometry or color changes.

## M8 — import and export

- System photo/file image import into floating selection
- Page PNG and multi-page PDF export
- Share sheet and export without UI/page-border overlays

Acceptance: dimensions, page count, premultiplied color, and cancel paths are
verified by automated fixtures.

## M9 — Pencil Pro, hover, and haptics

- Hover location/altitude/azimuth/roll previews
- Double-tap and squeeze action mappings
- Context palette and snap/tool haptics

Acceptance: hover never marks, haptics fire once per lock transition, and
non-Pro Pencil devices retain clean fallbacks.

## M10 — diagnostics

- Input/coalesced/predicted rates and correction counts
- CPU/GPU frame time, input age, tile residency, memory, queue depth
- Dropped-frame/prediction counters and exportable logs

Acceptance: metrics update without affecting the drawing hot path and can be
hidden in normal use.

## M11 — Metal renderer parity and performance

- Ordered live/predicted/committed render surfaces
- Sparse tile residency, apron dirtiness, persistence upload/readback
- Vector/grid/page/selection passes and memory-pressure reload

Acceptance: no seams or commit flashes, Android golden-image tolerance passes,
and ProMotion frame/input latency targets are measured on device.

## M12 — product release gate

- Windows core/codec regression suite
- Xcode/Metal offscreen tests and UIKit interaction tests
- Install, draw, save, reopen, export, update, and data-retention device test
- Tagged unsigned IPA and checksum on GitHub Releases

The port is feature-complete only when every milestone gate passes.
