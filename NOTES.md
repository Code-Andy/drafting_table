# Drawing App — Design Notes

## Goal

A custom technical-notebook / sketching app for the **Wacom MovinkPad 11** (standalone Android tablet, EMR pen). Used primarily for engineering drawings and notes. Responsiveness is the top priority — a small, well-tuned feature set beats a sprawling one that feels laggy.

Comparable apps tried: Autodesk Sketchbook (closest fit), Tayasui Sketches, Clip Studio Paint, Concepts. None hit the right combination.

## Required features (deliberate ceiling, not a floor)

- Multi-document; each document has multiple pages (slide-deck style)
- Per-page drawing surface
- Small selection of brushes
- Pressure + tilt sensitivity
- Paint bucket
- Transparency
- Layers
- Eraser
- Selection / transformation
- **Page background grid** — graph-paper lines or dots, toggleable per page, scalable spacing
- **Construction geometry** — straight lines, circles/ellipses, rectangles (parametric, editable, snap-aware)

## Tractability

Realistic. The *feel* of a drawing app is ~80% of the engineering effort and ~20% of the lines of code. Sketchbook/Procreate-class responsiveness is years of input-pipeline tuning, but you're targeting one device for one user with a small feature set — that changes the math.

Rough estimate:
- A working, *responsive* prototype with brushes + layers + erase: a few focused weeks.
- Bucket fill, selection/transform, polished UI: weeks more.
- Full feature parity with Sketchbook: months.

The thing that kills hobby drawing apps isn't features — it's input latency that feels "off" by 30 ms.

## Platform decisions

- **Host OS:** Android (MovinkPad 11 is standalone, no PC involved).
- **Dev environment:** stay on **Windows**, do not switch to WSL. Android Studio, ADB-to-device, NDK, and Vulkan/RenderDoc tooling are all first-class on Windows. WSL adds friction for USB passthrough and GPU tooling. Install WSL alongside Windows only if you end up doing heavy Linux-only build scripting.
- **Min SDK:** 33 (so `GLFrontBufferedRenderer` is available without backports).

## Stack

- **Language:** Kotlin for app shell + UI; **C++ via NDK** for the hot path (input handling, brush dab generation, tile compositor). Avoid Kotlin in the render loop — GC pauses surface as stroke hitches.
- **Graphics API:** **Vulkan** for best latency control, or **OpenGL ES 3.2** if you want easier debugging. Pick one and commit.
- **Live stroke rendering:** `androidx.graphics.lowlatency.GLFrontBufferedRenderer`. This is the single most important Android API for responsive drawing — renders the in-progress stroke directly to the front buffer, bypassing the normal compositor. Procreate-class apps on Android use the equivalent.
- **Input:** `View.onTouchEvent` filtering on `MotionEvent.TOOL_TYPE_STYLUS`. Walk historical samples (`getHistoricalX/Y/Pressure`, `getAxisValue(AXIS_TILT)`). Feed through `androidx.input.motionprediction.MotionEventPredictor` to claw back ~1 frame of latency.
- **Wacom EMR pen:** reports through standard Android stylus APIs — pressure, tilt, side button all surface as `MotionEvent` axes. No Wacom SDK needed for the basics. The Wacom Ink SDK is optional; consider only if you want their stroke-smoothing or cloud features later.
- **Skia:** OK for UI/icons. **Do not use Skia for the live stroke** — render brush dabs directly on GPU.

## Architecture

### Document model

```
Document
  └── Page[]
        └── Layer[]
              └── Tile grid (256×256 RGBA tiles)
```

Tiles are the unit of:
- Dirty tracking
- Undo/redo
- Disk I/O (autosave per dirty tile, not per document)
- Re-composition (only re-blend visible dirty tiles each frame)

### Threading

| Thread | Priority | Responsibility |
|---|---|---|
| Input | High | Reads pen samples, pushes to render queue. Never blocks on rendering. |
| Render | High | GL/Vulkan render loop. Composites tiles, draws live stroke overlay. |
| Main / UI | Normal | UI chrome only. |
| I/O | Background | Tile autosave, document load. |

Use a lock-free SPSC queue for input → render handoff.

### Stroke pipeline

1. Input thread reads pen samples (incl. historical samples between frames).
2. Samples are smoothed/resampled into a spline.
3. Brush dab generator emits textured quads along the spline, scaled by pressure.
4. Live stroke renders to a **transient front-buffer layer**.
5. On stroke end, the stroke is composited into the active layer's tile grid (only the tiles the stroke touched).

### Page background grid

Pure render-time overlay — never written into tiles, never part of any layer. Implemented as a fragment shader run before the layer composite step, parameters per page:

- `enabled: bool`
- `style: { lines, dots, none }`
- `spacing: float` (in document units)
- `subdivisions: int` (e.g., minor lines every 1 unit, major every 5)
- `color, opacity`

Because it's a shader, the grid is crisp at any zoom and costs essentially nothing. Toggle is instant. The grid does **not** affect undo/redo, save format (just store the params), or tile dirty-tracking.

### Construction geometry — vector layer type

Construction primitives (lines, circles, ellipses, rectangles) should **not** be rasterized into tiles like brush strokes. For an engineering use case you want them editable, snappable, and crisp at any zoom. This means introducing a second layer type:

```
Layer = RasterLayer | VectorLayer

RasterLayer
  └── Tile grid (brush strokes, eraser, bucket fill)

VectorLayer
  └── Shape[] (Line, Circle, Ellipse, Rect, ...)
```

Each shape is a parametric record: `Line { p0, p1, stroke, width }`, `Circle { center, radius, stroke, fill, width }`, etc. Renderer draws them directly on GPU each frame (cheap — there will rarely be more than dozens per page).

Why a separate layer type rather than a vector overlay on a raster layer:
- Editable: select a circle weeks later, change its radius — impossible if it was rasterized.
- Snap targets: endpoints, centers, intersections are queryable from the data structure.
- Crisp at any zoom: no resolution lock-in.
- Cheap undo: shape add/remove/edit is a tiny diff.

A page can mix raster and vector layers freely. Default new page: one raster layer for sketching + one vector layer for construction, but the user can add more of either.

### Snapping (for construction tools)

When drawing a construction primitive, snap targets in priority order:

1. Existing shape endpoints, centers, midpoints (from vector layers on this page)
2. Shape intersections (computed on demand for visible shapes)
3. Grid intersections (if grid enabled)
4. Free placement (no snap)

Snap radius in screen pixels, not document units, so it feels consistent at any zoom. Show a small visual indicator (different glyph per snap type) while the pen hovers near a target.

### Persistence

SQLite with tile blobs (raster layers), or a flat directory of tile files. Autosave per dirty tile. Vector layers serialize as small JSON/CBOR blobs (shape lists are tiny). Document format = a manifest (page list, layer metadata, per-page grid params) + tile blob references + vector layer blobs.

## Responsiveness tricks (in order of impact)

1. **Front-buffered live stroke** — bypass the vsync compositor for the active dab.
2. **Predicted input** — `MotionEventPredictor` to hide ~1 frame of latency.
3. **GPU brush dabs** — one textured/instanced quad per dab, never CPU rasterization.
4. **Pinned threads, no GC in hot path** — C++ for input + render, dedicated thread priorities.
5. **Cap at native refresh rate, never miss a frame** — jank is worse than latency.

## Build order

Get the first three feeling *right* before adding anything else. If the stroke doesn't feel good, no feature pile will save it.

1. Input plumbing (stylus events → render thread)
2. Live stroke rendering (front-buffered)
3. Tile grid + single layer
4. Multiple layers
5. Save/load
6. Second brush
7. Eraser
8. Multi-page documents
9. **Grid overlay shader** (cheap, satisfying, validates the per-page params pipeline)
10. **Vector layer type + line tool** (smallest viable construction primitive)
11. Circle, ellipse, rectangle tools
12. Snapping (endpoints first, intersections later)
13. UI chrome (brush picker, layer panel, page navigator, tool palette)
14. Bucket fill, selection/transform, and the rest

## First two spikes

Validate the input → render path before any feature work.

**Spike 1:** A `View` that draws a colored dot under the pen, zero other logic. Measure perceived latency by drawing along a physical ruler — the dab should track very close to the pen tip.

**Spike 2:** Replace the dot with proper textured brush dabs along the input path; pressure scales dab size.

Only after Spike 2 feels right: tile grid, layers, undo, etc.

## Setup / infrastructure

Default first-pass renderer: **OpenGL ES 3.2** (faster to debug; the Android low-latency renderer supports it natively). Vulkan can replace it later if needed.

### On the Windows dev machine

1. **Android Studio** (latest stable) — bundles a compatible JDK and the Android SDK manager. Download from developer.android.com/studio.
2. **Inside Android Studio → SDK Manager** install:
   - Android SDK Platform **34** (or latest stable; min SDK 33 is what we'll target).
   - Android SDK Platform-Tools (provides `adb`).
   - Android SDK Build-Tools (latest).
   - **NDK (Side by side)** — latest LTS.
   - **CMake** (Android Studio's bundled version is fine).
3. **Add Platform-Tools to PATH** so `adb` works from any PowerShell window: `%LOCALAPPDATA%\Android\Sdk\platform-tools`.
4. **Git for Windows** if not already installed.
5. **Optional but useful:**
   - **scrcpy** — mirrors the tablet to your monitor over USB/Wi-Fi. Big quality-of-life win during dev. (`winget install Genymobile.scrcpy`)
   - **RenderDoc** — GPU frame capture/debug. Skip until you actually need it.
   - **Vulkan SDK from LunarG** — only if you take the Vulkan path. Skip for now.

### On the MovinkPad 11

1. **Enable Developer Options:** Settings → About tablet → tap **Build number** 7 times.
2. **Enable USB debugging** (and **Wireless debugging** if you want cable-free dev): Settings → System → Developer options.
3. Plug into the PC via USB, accept the ADB host key prompt on the tablet.
4. **Recommended developer-options tweaks** for drawing-app work:
   - "Stay awake" while charging (so the screen doesn't sleep mid-test).
   - "Don't keep activities" **off** (you want normal lifecycle for now).
   - Later: "Profile GPU rendering" and "Show refresh rate" are useful.

### Verify everything works

```powershell
adb devices                                                  # should list the MovinkPad
adb shell getprop ro.build.version.release                   # confirms Android version
adb shell dumpsys SurfaceFlinger | findstr "refresh-rate"    # native refresh rate
```

If `adb devices` shows `unauthorized`, re-accept the prompt on the tablet.

### Wireless ADB

USB cables on a drawing tablet during dev get in the way. After the first USB-tethered run:

```powershell
adb tcpip 5555
adb connect <tablet-ip>:5555
```

Or use Settings → Developer options → **Wireless debugging** → Pair with code (Android 11+).

### Project layout we'll create

```
drawing_app/
├── settings.gradle.kts
├── build.gradle.kts
├── app/
│   ├── build.gradle.kts
│   ├── src/main/
│   │   ├── AndroidManifest.xml
│   │   ├── java/...           # Kotlin: Activity, View, plumbing
│   │   ├── cpp/               # NDK: input, brush, compositor
│   │   │   ├── CMakeLists.txt
│   │   │   └── *.cpp / *.h
│   │   └── res/
└── NOTES.md
```
