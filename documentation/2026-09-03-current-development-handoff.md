# 2026-09-03 — current development handoff

This is the exact resume point as of 2026-09-03 in Toronto.

## Repository state

- Local checkout: `D:\Vibe Code\Drafting Table Fork`
- Branch: `ipad-native-port`
- HEAD: `87f92f0` — `v0.9.1 prerelease: visible color tool, smooth joins, live grid snap`
- Tracking: `origin/ipad-native-port` is up to date with HEAD
- Fork: <https://github.com/Code-Andy/drafting_table>
- Upstream: <https://github.com/bgkatz/drafting_table>
- Upstream push URL: disabled as `no_push`
- Project version in `project.yml`: `0.9.1` build `13`
- Latest released versions: `v0.7.2`, `v0.8.0`, `v0.9.0`, `v0.9.1`
- Deployment target: iOS 17.5

## What HEAD contains

HEAD brings the iPad port to the `v0.9.1` stabilization baseline:

1. **v0.7.2 Launch Watchdog & Heap Overflow Fix**:
   - Resolved the beige-screen crash reproduced under AddressSanitizer: an ODR violation occurred because `core/include/DTDocument.hpp` and `platforms/ipad/Bridge/DTEngine.hpp` both defined `drafting_table::Page` with differing sizes (48 vs 56 bytes). The bridge types were moved into `namespace drafting_table::ipad`.
   - Replaced continuous display link renders with on-demand rendering (`enableSetNeedsDisplay = true`, `isPaused = true`, 60 fps cap).
   - Added a 220,000-vertex per-frame budget to prevent watchdog timeout kills on large documents.
   - Added file-based launch breadcrumbs and uncaught-exception logs for diagnostic capture.

2. **v0.8.0 Original UI Parity & Circle Tool**:
   - Replaced horizontal rail with left vertical tool rail divided into DRAW, SHAPE, and SELECT sections mirroring the original Android app layout and glyphs.
   - Added bottom status bar with interactive and staged chips: document name, current tool, `grid:` (live), `snap:` (live for shapes), `predict:` (live), `px:`, `angle:`, and `preview:`.
   - Added Circle tool end-to-end (`DTTool` enum value 5, `validTool` bound update, Metal outline drawing, archive serialization, portable test coverage).

3. **v0.9.0 Stroke De-dotting, HSV Color Picker, and Background Thumbnails**:
   - Removed intermediate 4th-sample round cap fans that caused beading artifacts along variable-pressure curves.
   - Added `ColorPickerViewController.swift` featuring an HSV saturation/value square, hue slider, RGB/HEX display, the upstream 32-color drafting palette, an 8-color LRU recents row, and 4 long-press user slots.
   - Re-enabled page thumbnails using an asynchronous background cache rendered on a utility dispatch queue with epoch invalidation to protect main-thread startup.

4. **v0.9.1 Visible Color Tool, Six-Slice Joins, and Live Shape Snapping**:
   - Added visible color swatch button at the top of DRAW that displays live brush color and opens the HSV picker.
   - Added six-slice exact-radius round joins at interior curve points to eliminate wedge gaps on tight turns without causing beading.
   - Enabled live grid snapping in `CanvasView.makeSample` for Line, Rectangle, Ellipse, and Circle when `snap:` is toggled on.
   - Resolved Swift type-checker timeouts with explicit CGFloat arithmetic in color conversions.

## Portable validation

All 5 test suites pass on Windows MSVC via CMake/CTest:

- `drafting_table_core_tests` (sample canonicalization, pressure, transforms, tile math)
- `drafting_table_document_tests` (document serialization, vector shapes, malformed inputs)
- `drafting_table_brush_tests` (brush emission, coverage math)
- `drafting_table_metal_layout_tests` (C++/Metal layout parity)
- `drafting_table_ipad_engine_tests` (all 6 tools round-trip, layer/page ownership, undo/redo)

## Release history & IPAs

- `v0.2.0`: First interactive canvas
- `v0.3.0`: Pencil curve-quality and pressure activation filter
- `v0.4.0`: Retained session, Undo/Redo, atomic autosave
- `v0.5.0`: Document coordinate space and two-finger gestures
- `v0.6.0`: Retained pages and layers
- `v0.7.0`: Colors, hardness, outline tools, grid, export
- `v0.7.1`: Metal vertex ABI hotfix
- `v0.7.2`: ODR namespace fix and launch watchdog budget
- `v0.8.0`: Left rail sections, status bar chips, Circle tool
- `v0.9.0`: De-dotting, HSV color picker, background thumbnails
- `v0.9.1`: Color swatch tool, six-slice smooth joins, live grid snap

All releases and unsigned IPAs: <https://github.com/Code-Andy/drafting_table/releases>

## Next dependency-ordered work

1. **M2 / M11 Sparse Metal Tile Compositor & True Eraser**:
   - Wire `drafting_table::metal::Backend` tile renderer to drawing path.
   - Implement destination-out raster eraser instead of paper-colored replay.
   - Connect `BrushEmitter` to 256×256 tiles with 258×258 aprons.
2. **M5 Vector Layers & Editable Shapes**:
   - Promote retained outline shapes to selectable, editable vector entities with handle manipulation and geometric snapping.
3. **M7 Document Packages**:
   - Files-compatible `.drafttable` package format, lazy tile loading, multi-document management.
