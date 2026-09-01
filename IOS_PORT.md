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
5. Implement pages/layers UI behavior, thumbnails, reorder, visibility, and
   opacity.
6. Add two-finger pan/pinch/rotation, hover previews, squeeze palette, haptics,
   and Pencil preference mappings.
7. Add PNG/PDF export and system image import.
8. Add deterministic Metal undo/redo fidelity and on-device performance tests.

## Licensing constraint

The upstream repository has no license file. The GitHub repository is a public
fork because GitHub public-fork networks cannot be private. Do not treat the
fork or its IPA assets as permission to redistribute upstream code; obtain an
explicit upstream license or permission before broader distribution.
