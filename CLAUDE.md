# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Custom Android sketching / technical-notebook app for the Wacom MovinkPad 11 (standalone Android tablet, EMR pen). Single-developer, single-device target. The user's overriding priority is **input responsiveness** — feature breadth is secondary. See `NOTES.md` for the original design intent and `README.md` for first-time setup.

## Build & run

Builds and runs are driven from Android Studio. There is no Gradle wrapper checked in; if `gradlew.bat` is missing, opening the project in Android Studio regenerates it (or run `gradle wrapper --gradle-version 8.7` once).

```powershell
.\gradlew.bat installDebug
adb shell am start -n com.bk.drawing/.MainActivity
adb logcat -s DrawingApp        # native log tag for renderer.cpp
```

There is no test suite. Validation is done by running on the tablet and observing behavior. UI-impacting changes need to be tested on-device — type-checking and "compiles" do not constitute validation for this codebase.

Build details that bite if you forget them:
- **arm64-v8a only** (`abiFilters` in `app/build.gradle.kts`); the MovinkPad is the sole target. Don't add other ABIs.
- **min SDK 33** so `GLFrontBufferedRenderer` is available without backports.
- **C++20**, NDK side-by-side, OpenGL ES 3.2.

## Architecture

Two-language split: Kotlin owns lifecycle, UI, and touch dispatch; C++ owns all GL state and pixel work. The interesting code is concentrated in four files.

### Source layout

```
app/src/main/
├── java/com/bk/drawing/
│   ├── MainActivity.kt          Activity, button panel, key handling, layer-state mirror
│   ├── DrawingSurfaceView.kt    Touch dispatch, view transform, gesture handling, GLFrontBufferedRenderer callbacks
│   └── NativeRenderer.kt        JNI surface (object NativeRenderer; loads libdrawing.so)
└── cpp/
    ├── CMakeLists.txt
    └── renderer.cpp             Single-TU native renderer (~4000 lines). All shaders, persistence, undo, etc.
```

### Document model (mirror in `renderer.cpp` top comment)

```
Document
  └── Layer[]                  z-ordered, bottom-up
        ├── Raster: sparse map<(tx,ty), Tile>   256×256 RGBA8 tiles, lazily allocated
        └── Vector: Line[] / Rect[] / Ellipse[] / Circle[]
```

Tiles are stored **premultiplied alpha** on disk and on the GPU; both bake and composite use `glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)`. On-disk layout is `<docDir>/layer_<idx>/tile_<tx>_<ty>.bin` (raw RGBA bytes) plus `shapes.bin` for vector layers.

The "paper" is implicit — the multi-buffer is cleared to off-canvas gray, then a paper-white quad is drawn over the page bounds, then layers composite on top.

### Coordinate spaces — critically important

There are three coordinate spaces and confusing them is the most common bug in this codebase:

- **doc-px**: document coordinates. The natural unit for shapes, tiles, snap targets, stroke samples, and persistence.
- **view-px**: on-screen pixels in the SurfaceView (`MotionEvent.x/y`).
- **buffer-px**: pixels of the GL buffer; may be rotated relative to view-px on some device orientations (the framework provides a `view→buffer` mat4 in each callback).

**Kotlin owns the doc→view view transform** (scale/rotation/pan from 2-finger gestures) and converts touch coords to doc-px before any JNI call. **The `transform: FloatArray` parameter passed into render JNIs is always doc→buffer**, composed in `DrawingSurfaceView.composedTransform()` via `Matrix.multiplyMM`. Native consumes only this composed matrix, so the view transform is invisible to most native code.

The current view scale is mirrored into native via `setViewScale` so snap radii, selection handle sizes, and hit-test thresholds stay constant in *screen* pixels (constants ending in `ViewPx` are divided by `currentViewScale()` at use time).

### Threading & cross-thread mutation

- **GL thread** (managed by `GLFrontBufferedRenderer`): runs both `onDrawFrontBufferedLayer` and `onDrawMultiBufferedLayer`. All GL state — texture creation, FBO binds, draw calls — must happen here.
- **UI thread**: runs touch dispatch and JNI calls invoked by buttons.

JNI methods that mutate `g_layers` from the UI thread (`addLayer`, `cycleActiveLayer`, `clearActiveLayer`, `addVectorLayer`, `addLine`/`addRectangle`/etc., `undo`, `redo`) **enqueue actions** rather than mutating directly. The GL thread drains the queue at the start of every operation via `applyPendingLayerActions()` and `applyPendingShapes()`. Constants:

```
kActionAddLayer / kActionCycleActive / kActionClearActive
kActionAddVectorLayer / kActionUndo / kActionRedo
```

`undo`/`redo` go through this queue specifically because the inverse mutations may touch GPU textures and disk — they must run on the GL thread.

Selection mutations (`hitTestActiveVectorLayer`, `deleteSelection`, transform drags) read/write `g_selection` under `g_selectionMutex` and *do* mutate from the UI thread directly (a pre-existing race that is acceptable for this single-user app).

### Front-buffer / multi-buffer pipeline

`GLFrontBufferedRenderer<StrokeAction>` provides:
- `renderFrontBufferedLayer(action)` — low-latency render for live stroke / shape preview.
- `commit()` — flushes to multi-buffer; framework calls `onDrawMultiBufferedLayer` with the accumulated actions.

`StrokeAction` is a sealed class: `Sample(x, y, pressure, isNewStroke)` for brush/eraser, `ShapePreview(shapeType, x0..y1, snapped)` for shape tools. Sample coordinates are doc-px (Kotlin converts before constructing the action).

Stroke lifecycle:
1. `ACTION_DOWN` → `Sample(isNewStroke=true)` → native `beginStroke` clears `g_current.samples`.
2. `ACTION_MOVE` → `Sample`s → native `extendStroke` appends to samples and renders the live preview.
3. `ACTION_UP` → `r.commit()` → native `commitStroke` bakes samples into tile FBOs, snapshots tiles for undo, saves to disk.

### Undo / redo

Single global stack on the native side (`g_undoStack` / `g_redoStack`, `std::deque<UndoEntry>`, mutex-guarded). Bounded by **50 entries / 200 MB combined**; oldest entries evict first. Not persisted across app restart.

Six op types (`UndoOp`): `RasterStroke`, `VectorAdd`, `VectorDelete`, `VectorMutate`, `LayerClear`, `LayerAdd`. Each entry stores enough to apply forward and reverse — for raster strokes that's tile snapshots before+after the bake (the dominant memory cost). For vector ops it's a `ShapeData` tagged union.

Push points (search for `pushUndoEntry`):
- `commitStroke` after bake (RasterStroke)
- `applyPendingShapes` per shape applied (VectorAdd)
- `deleteSelection` (VectorDelete)
- `endInteraction` if shape changed during a transform drag (VectorMutate)
- `applyPendingLayerActions` for `kActionClearActive` and add-layer paths

### Page bounds (canvas rectangle)

The doc is mathematically infinite, but `setPageBounds(x0, y0, x1, y1)` defines a fixed-size canvas. When active:

- Tiles fully outside the page are not created or baked.
- Boundary tiles use intersected dab clip bounds AND fragment-shader-level discard (`vDocPos` varying + `uPageMin/Max/Active` uniforms in dab/line/grid programs) for clean truncation.
- Compositor clears to gray and paints paper-white over the page rect via a tiny `kFillVS/FS` program.
- UI affordances (selection handles, snap markers, the page outline itself) explicitly **un-set** the page-clip uniforms so they stay visible at edges.

Default page bounds = initial surface dimensions, set once from `onSizeChanged`.

### renderer.cpp navigation

The file is single-TU and order-sensitive. When adding helpers, watch the forward-declaration block around line ~830 (`saveVectorLayer`, `loadVectorLayerShapes`, the tile-snapshot helpers, `applyUndo` / `applyRedo` / `applyPendingShapes`). The undo apply functions (`applyEntryReverse`/`Forward`/`applyUndo`/`applyRedo`) live near the bottom of the anonymous namespace so all their dependencies are defined.

Major sections, roughly:
- Tunables, shaders (kDabVS/FS, kCompVS/FS, kPreviewVS/FS, kGridVS/FS, kLineVS/FS, kFillVS/FS)
- POD types (Tile, Line, Rect, Ellipse, Circle, Layer, Selection, DragState, UndoEntry, TileSnap, ShapeData)
- Globals + `currentViewScale()`, `readPageClip()`, `vpxToDoc()`
- Pending action drain
- `ensureInited` (program linking + uniform lookup) — must add new uniforms here
- Persistence (tile load/save, vector layer save/load with V0→V1 migration)
- Tile management + snapshot helpers
- Bake (`bakeCurrentStrokeIntoTiles`)
- Compose (`compositeAllLayers`, `compositeRasterLayer`, `compositeVectorLayer`)
- Selection / OBB / hit-test / handles
- Snapping (`forEachShapeSnapTarget`, `findSnap`, `drawSnapMarker`)
- Shape rendering helpers (`drawLineSegment`, `drawRectangleAsLines`, `drawEllipseAsLines`)
- Undo/redo apply (`applyEntryReverse`, `applyEntryForward`, `applyUndo`, `applyRedo`)
- `extern "C"` JNI exports

### Things that are easy to break

- **Forward declarations**: this file has had several rounds of "undeclared identifier" build errors when helpers were added in the wrong order. If you call something not yet visible, add a forward decl in the block around line ~830.
- **FBO leaks**: any helper that binds a tile FBO via `glReadPixels` / `glReadPixels`-style work must save and restore `GL_DRAW_FRAMEBUFFER_BINDING` — otherwise calls inside `applyPendingLayerActions` (drained at the *start* of `compositeAllLayers`) will leave the multi-buffer FBO replaced, and the subsequent clear/grid/composite go to a tile. Symptom: canvas turns black after undo until the next stroke commit. `saveTileToDisk` and `uploadTileBytesAndSave` already do this — preserve it.
- **`shapes.bin` format**: tagged with `kShapesMagicV1`. The V0→V1 migration (rotation field added to Rect/Ellipse) is in `loadVectorLayerShapes`. Bumping the format requires adding a new magic and a migration path.
- **Premultiplied alpha**: don't accidentally output straight RGBA in a fragment shader and blend it premultiplied — the `*color * alpha, alpha` pattern is everywhere on purpose.
- **View-px constants**: anything that needs to feel constant on screen at any zoom is named `*ViewPx` and divided by `currentViewScale()` at use time. Don't hard-code doc-px sizes for UI affordances.
- **Bake performance at low zoom**: `bakeCurrentStrokeIntoTiles` skips bbox cells that no sample's brush radius touches, AND `DabEmitter::emit` skips dabs whose footprint is fully outside the per-tile clip bounds. Both optimizations are critical — without them, a long stroke at 0.25× zoom can allocate thousands of tile FBOs and lock up the GL thread.

## Memory

There is a `.claude/projects/.../memory/` directory with prior-session notes about user preferences and project context. Use it via the auto-memory protocol — check `MEMORY.md` for relevance before doing major work.
