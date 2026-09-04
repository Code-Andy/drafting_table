# 2026-09-03 — current development handoff

This is the exact resume point as of 2026-09-03 in Toronto.

## Repository state

- Local checkout: `D:\Vibe Code\Drafting Table Fork`
- Branch: `ipad-native-port`
- HEAD: `8e28ee1` — `v0.9.7: gap-closing bucket fill, paper space maximization, Pencil Pro radial wheel`
- Tracking: `origin/ipad-native-port` is up to date with HEAD
- Fork: <https://github.com/Code-Andy/drafting_table>
- Upstream: <https://github.com/bgkatz/drafting_table>
- Upstream push URL: disabled as `no_push`
- Project version in `project.yml`: `0.9.7` build `16`
- Latest released versions: `v0.7.2`, `v0.8.0`, `v0.9.0`, `v0.9.1`, `v0.9.2`, `v0.9.6`, `v0.9.7`
- Deployment target: iOS 17.5

## What HEAD contains

HEAD brings the iPad port to the **v0.9.7** feature baseline:

1. **v0.9.7 Gap-Closing Bucket Fill & Paper Space Maximization**:
   - Offscreen morphological obstacle dilation ($\lceil \text{gapSize} / 2 \rceil$) and BFS flood fill to bridge gaps between drawn strokes.
   - Under-stroke bleed dilation to eliminate white halos.
   - Moore-neighbor border tracing with RDP simplification and ear-clipping concave polygon triangulation in Metal (`DTMetalRenderer.mm`).
   - Floating `bucketSubToolBar` sub-tool menu for gap margin (`0px`–`16px`) and bleed (`0px`–`4px`).
   - Paper space maximized: top navigation bar and 40pt ribbon eliminated; canvas pinned to `root.topAnchor`.
   - Apple Pencil Pro squeeze: custom `CircularRadialMenuView` dial centered around pen hover/touch point on glass with 12 radial tools.
   - Tool rail restructured with top hamburger `≡` menu, active swatch, and 8 quick-palette pen colors.
   - Parity with `tools/drafting_table.png`: floating `undoRedoChip` (`↶`/`↷`) over top-left paper and `DOCS ∨` button at top of Pages rail.

2. **v0.9.6 Notebook Gallery & SF Symbols Line Art**:
   - Multi-notebook shelf gallery with thumbnail previews and document lifecycle.
   - High-contrast vector SF Symbols line art on all buttons.
   - Diagnostics switch and photo import.

3. **v0.9.2 Apple Pencil Pro Suite & Drafting Table Parity**:
   - Sibling `HoverOverlayView` (outer ring, tilt needle, barrel roll tick, snap reticle).
   - Shade tool (`DTTool::Shade = 6`) with polygon fill and antialiased outline.
   - Selection & transform tools (Select and Lasso) for translating and duplicating strokes.
   - 15-degree angle snapping (`π / 12`).
   - Document rename modal.

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
- `v0.9.2`: Apple Pencil Pro suite, Shade tool, selection & transform, 15° snap
- `v0.9.6`: Notebooks gallery, line art symbols, photo import, center toggle
- `v0.9.7`: Gap-closing bucket fill, paper space maximization, Pencil Pro radial wheel

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
