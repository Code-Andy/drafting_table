# Drafting Table iPad port

This document tracks implementation work specific to the native iPad port.
The original Android architecture and invariants remain documented in
`CLAUDE.md`; the portable extraction plan remains in `PORTING.md`.

## Product target

The end product is a native iPad drawing application using UIKit for input,
an Objective-C++ bridge into a portable C++20 document engine, and Metal for
low-latency raster/vector rendering. GitHub Actions must produce an unsigned
IPA that SideStore can sign and install.

## Current user-visible milestone

Version 0.2.x is the first interactive-canvas iteration. Its acceptance gate is:

- a real home-screen icon and light launch appearance;
- a visibly paper-colored canvas rather than a black frame;
- obvious page, layer, and tool chrome even where features remain placeholders;
- Apple Pencil drawing plus direct-touch drawing when the system does not
  request Pencil-only input;
- thick pressure-aware graphite strokes, predicted-tail correction, Undo, and
  Clear;
- a public GitHub Release containing the exact CI-built unsigned IPA.

Passing this gate does **not** imply feature parity with Android. It establishes
a useful on-device feedback loop for subsequent renderer and document work.

Version 0.3 adds the first device-tuning control: a persistent 0–20% Pencil
activation-pressure threshold with a lower 55% release threshold. This is an
app-level contact/lift-off filter for light-touch noise and different screen
feel. UIKit does not expose a way for an app to change Apple Pencil's physical
hover or hardware detection height.

Version 0.4 establishes the retained drawing-session layer used by later
document milestones:

- Brush and Eraser tools with per-stroke size and opacity snapshots;
- Undo and Redo stacks;
- versioned, bounded, little-endian stroke archives;
- atomic autosave in Application Support and restore on launch;
- a dedicated Settings sheet for activation pressure, brush size, and opacity;
- Catmull-Rom curve subdivision before thick Metal join/cap generation.

The current eraser replays paper-colored geometry in retained stroke order. It
is useful on the single paper canvas, but it is not the final destination-out
tile eraser. The archive likewise stores retained strokes for this milestone;
Files document packages and Android tile migration remain separate work.

Version 0.5 introduces the document/view coordinate boundary required by
snapping, selections, and vector tools:

- all new Pencil/finger samples are converted from view points to document
  coordinates before entering C++;
- Metal applies the matching document-to-view scale/rotation/translation;
- simultaneous two-finger pan, pinch, and rotation preserve the document point
  under the gesture centroid;
- a direct-finger drawing stroke is cancelled when a two-finger gesture takes
  ownership, while active Pencil strokes block transform changes;
- the view transform persists in UserDefaults and can be reset from the
  navigation bar.

Version 0.6 replaces the placeholder rails with a retained multi-page,
multi-layer document session:

- dynamic selectable page cards and layer rows;
- add, rename, and guarded delete actions for pages and layers;
- active-page/active-layer drawing ownership;
- per-layer visibility and opacity;
- per-layer Undo/Redo and Clear Layer behavior;
- active-page rendering that flattens visible layers bottom-up;
- `DTAR` archive v2 with page/layer names, active indices, visibility, opacity,
  styles, and samples;
- migration of v1 flat-stroke archives into `Page 1 / Ink`;
- real v1/v2 round-trip and malformed-data tests.

These are retained stroke pages/layers. They are the interaction and archive
model needed by later milestones, not yet Files document packages backed by
sparse raster/vector tiles.

Version 0.7 is a broad workspace feature batch:

- stored brush color and hardness with Settings controls;
- retained Line, Rectangle, and Ellipse outline tools;
- document-space grid following the persisted canvas transform;
- page/layer duplicate and move-up/down operations;
- generated page thumbnails with active-page invalidation caching;
- Apple Pencil hover preview, double-tap tool toggle, and de-duplicated squeeze;
- current-page PNG and all-page PDF export;
- `.drafttable` Files type registration plus validated Open and Save Copy;
- `DTAR` archive v3 with real v1/v2 migration fixtures.

The new outline tools are persistent and exportable, but are not yet editable
vector-layer shapes with snapping/selection. The Files document is a flat DTAR
archive, not yet the final lazy sparse-tile package.

Version 0.7.1 fixes the v0.7 beige-screen launch abort. It restores the compact
Metal vertex ABI, moves style to aligned fragment uniforms, bounds display and
geometry allocations, guards Metal buffer creation, and adds a clean-simulator
process-survival gate. Automatic thumbnails and the hover layer are temporarily
disabled while they are redesigned off the synchronous startup/Metal layer path.

## Implemented architecture

### Portable C++20

- Canonical Pencil samples with real, coalesced, predicted, and estimated flags
- Estimated-sample correction by UIKit update index
- Pressure activation, saturation, and gamma mapping
- Canvas transforms and signed negative-coordinate tile addressing
- Multi-page documents with ordered raster/vector layers
- Sparse 256-by-256 premultiplied RGBA tiles
- Line, rectangle, ellipse, and circle geometry
- Deterministic versioned document serialization
- Explicit Android `VEC0`/`VEC1` vector-shape codec
- Platform-neutral round, pencil, and marker dab generation
- Quartic brush coverage and prediction-reset signaling

### iPad platform

- Programmatic UIKit application/scene lifecycle
- `MTKView` canvas with high-refresh presentation
- Batched coalesced and predicted Apple Pencil input
- Pressure, altitude, azimuth, barrel roll, and estimated-value updates
- Pencil double-tap and squeeze event capture
- Persistent Pencil activation threshold with lift-off hysteresis
- Brush/Eraser selection, retained stroke styles, Undo/Redo, and autosave
- Document/view transform with two-finger pan, pinch, rotation, and Reset View
- Dynamic retained pages/layers with visibility, opacity, and archive v2
- Brush color/hardness, technical outline tools, grid, thumbnails, and archive v3
- `.drafttable` Open/Save Copy plus PNG/PDF export
- Pencil hover preview, double-tap, and squeeze tool switching
- Thin Objective-C++ ownership bridge
- Diagnostics overlay
- XcodeGen project generation

### Metal foundations

- Visible immediate stroke renderer for the interactive milestone
- Sparse 258-by-258 color/coverage tile backend
- Premultiplied Porter-Duff OVER blending
- R8 MAX coverage accumulation
- Oriented elliptical dab instances
- Neighbor-derived one-pixel aprons
- Quartic soft-edge parity with the Android dab shader

The sparse tile backend is not yet connected to the visible canvas. The
immediate renderer is deliberately retained until the ordered render-command
and prediction surfaces can be connected without sacrificing latency.

## Build and release

Windows validates the portable modules. The iPad application itself is built
on a GitHub-hosted macOS runner using XcodeGen and Xcode.

```text
Windows edit -> git push -> macOS Actions -> unsigned IPA -> GitHub Release
```

Workflows:

- `.github/workflows/core-tests.yml`
- `.github/workflows/ipad-build.yml`

Scripts:

- `scripts/ios/build_ipa.sh`
- `scripts/ios/package_ipa.sh`
- `scripts/ios/generate_altstore_source.py`

Latest release:

- <https://github.com/Code-Andy/drafting_table/releases/latest>

## Validation performed

- Portable core tests on Windows/MSVC and GitHub Actions
- Document/persistence tests including malformed/trailing data
- Brush geometry and predicted-reset tests
- Metal/C++ instance-layout tests
- Xcode 16.4 device build with the iOS 18.5 SDK
- IPA structure validation (`Payload/DraftingTable.app`, arm64 executable,
  processed Info.plist, and compiled Metal library)

On-device validation remains mandatory for Pencil latency, prediction
correction, hover, gestures, memory pressure, and visual fidelity.

## Remaining product work

1. Connect ordered stroke commands to persistent raster tiles without
   rebuilding the stroke or page on every input event.
2. Implement document packages in Files, lazy tile persistence, recovery, and
   Android document migration fixtures.
3. Port brush, eraser, shade, fill, and uniform-alpha composition completely.
4. Port vector SDF rendering, snapping, selections, transforms, and rasterize.
5. Replace retained outline tools with editable vector layers, snapping,
   selections, transforms, rasterize, and merge.
6. Complete hover/squeeze palette behavior, haptics, and Pencil preference
   mappings after device feedback.
7. Add system image import and page-size-aware export.
8. Add deterministic Metal undo/redo fidelity and on-device performance tests.

## Licensing constraint

The upstream repository has no license file. The GitHub repository is a public
fork because GitHub public-fork networks cannot be private. Do not treat the
fork or its IPA assets as permission to redistribute upstream code; obtain an
explicit upstream license or permission before broader distribution.
