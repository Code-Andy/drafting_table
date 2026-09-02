# Drafting Table
<img src="tools/drafting_table.png">

> **iPad port:** local development is on the `ipad-native-port` branch. See
> [IOS_PORT.md](IOS_PORT.md) for iPad implementation status,
> [PORTING.md](PORTING.md) for the extraction plan, and
> [FEATURE_ROADMAP.md](FEATURE_ROADMAP.md) for the full milestone DAG, and
> [AGENTIC_SETUP.md](AGENTIC_SETUP.md) for the current orchestration workflow.
> The dated development history, decisions, build runbook, and exact handoff
> state are indexed in [documentation/README.md](documentation/README.md).

Ben's notes:

I wanted a drawing app for my [Wacom MovinkPad 11](https://estore.wacom.com/en-us/wacom-movinkpad-11-dtha116cl0z.html) tablet that combines features from conventional drawing programs, slide decks, and paper engineering notebooks.  This is a  attempt at creating that.  This is *not* intended to be a full-blown painting program: it's designed for making technical sketches.

"Documents" are organized into pages, with a sidebar for previewing and navigating between pages, like a slide deck.  Tapping on a page in the sidebar loads that page onto the canvas.  Each page has its own set of layers.  

In addition to raster brush tools, vector primitives (lines, rectangles, circles, ellipses) can be constructed on vector layers. I find these useful for creating construction geometry in technical sketches.  Vector objects can be transformed after creation, or rastered down to the raster layer below. Vector "snapping" can be toggled, so the start/end/midpoints of vector objects snap to points on other vector objects, or to nodes on the (toggleable) graph paper background.  Snapping can be toggled from the pen, so it's easy to snap one end of a vector but not the other, mid-creation.

Pen-to-glass latency is significantly less than other drawig apps I've measured (25-35ms, vs ~75ms for other programs)

I have only tested on the MovinkPad 11, and it will almost certainly not work out-of-the-box on any other tablet. But Claude can probably fix it for you :P

Beware:  100% of the code is written by Claude.  

Claude Code generated Readme below:

## Features

**Document model**
- Multi-page documents, each with its own layer stack and on-disk subdirectory.
- Per-doc page sizes (presets: device default, US Letter, A4, hi-res, custom).
- Documents persist on tablet storage; the last-opened doc reopens on launch.
- Multiple documents (new / open / delete from the docs button).
- Export current page to PNG, full document to PDF.

**Layers**
- Raster and vector layers, mixed freely.
- Per-layer name, visibility, opacity.
- Drag-to-reorder, delete, rename (long-press a row).
- Rasterize a vector layer in place, or rasterize a single selected vector shape onto the layer below.

**Tools**
- Brush (size, opacity, hardness sliders).
- "Uniform α" toggle in the brush panel — when on, overlapping dabs within a single stroke clamp to the brush alpha instead of building up. Useful for shading and color blending at low opacity. Stacking mode (off) is the historical behavior; α in stacking mode is compensated so its spine alpha reads as the slider value too, so both modes look comparable at the same setting.
- Eraser.
- Bucket fill (with adjustable bleed).
- Shade — closed-path fill for quickly blocking in a region. Traces a brush stroke like the pen, joins the start and end points with a straight bridge line that follows the pen as you draw, and fills the enclosed area live; the whole outline + fill commits on lift. The bridge itself isn't stroked, so no line is laid over whatever you close against — but its edge still fades with the hardness slider, on the same falloff curve the brush uses, so a soft brush gives a soft edge all the way around the shape. The fill also reaches just past the bridge, by the dab radius at each endpoint, so the stroke's own ends sit inside the straight edge instead of poking through it. Self-crossing scribbles fill solid (nonzero winding), and outline + fill are one flat coverage mask, so at partial opacity the shape reads as a single tone with no darker rim at the border. Uses the current brush color / size / opacity / hardness.
- Vector shapes: line, rectangle, ellipse, circle. Rendered as single-quad SDFs so circles/ellipses/rectangles at sub-1 alpha are uniformly translucent — no segment-cap darkening at corners or around the rim.
- Selection — rectangular, lasso. Lifts pixels into a floating raster selection with move / scale / rotate handles. Copy / paste / delete.
- Vector selection — tap a shape to select; same transform handles. Marquee uses proper segment / SDF intersection (not AABB), so parallel diagonal lines don't all select together.
- Eyedropper — sample any pixel under the pen as the active color.
- Image import as a floating raster selection on a fresh layer (with fixed-aspect scaling).

**Color**
- Color picker dialog with HSV square + hue slider + editable HEX/RGB readout, 16-color default palette, recents, user "my-slots", eyedropper.
- Primary / secondary color swap.

**Snapping**
- Snap to grid intersections and other vector geometry.
- Velocity-gated engagement: snap activates when the pen settles near a target, not when sweeping past.
- Wide release radius when slow / stationary (so hand tremor doesn't break the lock); tight release when moving deliberately.

**Input**
- EMR stylus + pressure.
- Stylus side buttons: middle = toggle brush/eraser, far = undo, near = toggle snap.
- 2-finger pan / pinch / rotate of the canvas.
- Palm rejection.

**Other**
- Undo / redo, 50 entries / 200 MB, covers raster strokes, vector add/delete/mutate, layer clear, layer add.
- Status bar with quick toggles for grid, pixel grid, snap, angle snap, brush preview, and motion prediction.
- Pixel-grid overlay (`px` chip): 1-buffer-px lines at every doc-pixel boundary, auto-gated on zoom (only renders at ≥ 4× so it doesn't fill the screen at normal zoom).
- Reset-view fits the page edge-to-edge.
- PNG / PDF export of the active page or full document. Export drops the on-screen page-edge anchor outline so saved images have no border at the bitmap edges.

## Build & run (first time)

1. Open this directory in Android Studio (File -> Open -> select `drawing_app`).
2. Android Studio will prompt to sync Gradle and download the wrapper jar (the wrapper jar is intentionally not in this repo). Let it run.
3. If prompted, install the requested SDK / NDK / CMake versions via the SDK Manager.
4. Connect the MovinkPad over USB (or via wireless ADB — see `NOTES.md`).
5. Hit **Run** (Shift+F10). The app installs and launches.

If `adb devices` doesn't show the tablet from inside Android Studio, accept the host-key prompt on the tablet.

## Build & run (CLI)

```powershell
.\gradlew.bat installDebug
adb shell am start -n com.bk.drawing/.MainActivity
adb logcat -s DrawingApp        # native log tag for renderer.cpp
```

If `gradlew.bat` is missing, run `gradle wrapper --gradle-version 8.7` from a Gradle install once (or just open in Android Studio, which regenerates it).

## Project layout

```
drawing_app/
├── settings.gradle.kts
├── build.gradle.kts                # Root: AGP + Kotlin plugin versions
├── gradle.properties
├── gradle/wrapper/                 # Wrapper config (jar fetched on import)
├── app/
│   ├── build.gradle.kts            # App module: SDKs, NDK, deps
│   ├── proguard-rules.pro
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── java/com/bk/drawing/
│       │   ├── MainActivity.kt          # Activity, panels, key/button handling
│       │   ├── DrawingSurfaceView.kt    # Touch dispatch, view transform, GL callbacks
│       │   ├── NativeRenderer.kt        # JNI surface
│       │   ├── ColorPickerDialog.kt     # HSV picker UI
│       │   └── ColorPickerViews.kt      # HSV square + hue slider custom views
│       ├── cpp/
│       │   ├── CMakeLists.txt
│       │   └── renderer.cpp             # Single-TU native renderer
│       └── res/                         # icons, fonts, themes, strings
├── CLAUDE.md                       # Architecture + invariants for code work
└── NOTES.md                        # Original design intent
```

## Architecture (one-liner)

Two-language split: Kotlin owns lifecycle, UI, touch dispatch, and the doc->view transform; C++ owns all GL state, persistence, undo, and pixel work. The interesting code is concentrated in the four files under `app/src/main/`. Tiles are 256x256 RGBA8, premultiplied, lazily allocated, sparse-mapped per layer; vector layers store parametric shapes. See `CLAUDE.md` for the full breakdown (coordinate spaces, threading model, page-bounds clipping, undo apply order, things-easy-to-break).

## Build details

- **arm64-v8a only** (`abiFilters` in `app/build.gradle.kts`); the MovinkPad is the sole target.
- **min SDK 33** so `GLFrontBufferedRenderer` is available without backports.
- **C++20**, NDK side-by-side, OpenGL ES 3.2.

## Testing & debugging

The bulk of validation is still done by running the app on the tablet — UI feel, latency, and rendering are all things that have to be seen on real hardware. But there's a small instrumented test suite for the parts where bit-exactness matters, plus a perfetto trace pipeline for latency / flash investigations.

### Instrumented tests (`app/src/androidTest/`)

A device or emulator with arm64 is required (the renderer is arm64-only). Run from Android Studio (right-click the `androidTest` source set → Run) or from the command line:

```powershell
.\gradlew.bat connectedDebugAndroidTest
```

Test files:

- **`GLTestContext.kt`** — spins up an offscreen EGL 3.x context on a dedicated thread so the renderer can be driven without a SurfaceView. Tests dispatch every `NativeRenderer` call onto this thread via `gl { ... }`. Not a test itself; it's the harness the others build on.
- **`RendererTestBase.kt`** — base class wiring up the context + utilities (clean document directories, pixel-readback helpers).
- **`BakeFidelityTest.kt`** — 6 tests verifying that the raster-stroke bake is bit-deterministic: draw a stroke, snapshot the layer's pixels, undo, redo, snapshot again, assert byte-identical. This is the invariant the `rebakeStroke`-from-samples redo path depends on; if a future change to dab rasterization, blending, or page clipping breaks determinism, these fail.

### Perfetto trace capture (`tools/`)

For investigating GL-thread latency, dropped frames, or the occasional commit-time flash. Captures app ATRACE slices (`DrawingApp.*`) alongside SurfaceFlinger frame timeline, layer composition, and transaction tracks.

```powershell
.\tools\capture-trace.ps1
```

Gives a 10-second window — draw a few strokes during it. The resulting `.perfetto-trace` opens at [ui.perfetto.dev](https://ui.perfetto.dev). See `tools/README.md` for which slices to look at, and the buffer-level pipeline tracks that surface "fits in vsync but still flashes" cases.

### Native log channel

`renderer.cpp` logs under the `DrawingApp` tag — tile lifecycle, layer/page mutations, undo apply, persistence errors, etc. Useful for confirming an in-game action actually fired and didn't drop silently.

```powershell
adb logcat -s DrawingApp
```
