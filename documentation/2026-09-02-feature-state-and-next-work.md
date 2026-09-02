# 2026-09-02 — feature state and next work

## Honest state summary

The iPad port is now a useful retained-stroke sketching prototype with Pencil
input, smoothing, settings, autosave, view gestures, and an unreleased retained
page/layer candidate. It is not yet feature-parity Drafting Table. The Android
README describes the target product; it must not be read as a list of already
ported iPad features.

## Feature matrix

| Area | Current iPad state | Required next state |
| --- | --- | --- |
| Canvas | Visible paper canvas; immediate retained-stroke Metal replay | Ordered live/predicted/committed sparse tile compositor |
| Pencil | Coalesced/predicted samples, pressure, estimated updates, activation threshold | Hover preview, mappings, squeeze palette, haptics, measured latency |
| Curves | Catmull-Rom subdivision and improved joins/caps | Device tuning and tile-renderer parity |
| Tools | Brush and paper-colored replay eraser | Destination-out eraser, hardness, uniform alpha, shade, bucket fill |
| History | Per-active-layer stroke Undo/Redo | Deterministic raster/vector command history with memory limits |
| View | Two-finger pan/pinch/rotation, reset, persistence | Fit-to-page polish and extensive interruption/device tests |
| Pages | Retained add/select/rename/delete candidate | Thumbnails, reorder, sizes, package persistence |
| Layers | Retained visibility/opacity and active ownership candidate | Raster/vector types, reorder, merge, rasterize |
| Vectors | Portable geometry/codecs exist as foundations | Visible Metal SDF tools, edit/transform, snapping |
| Selection | Not connected on iPad | Raster/lasso and vector selection, copy/cut/paste/transforms |
| Documents | One autosaved application session | Files-compatible packages and multi-document browser |
| Import/export | Not connected on iPad | System image import, page PNG, multi-page PDF, share sheet |
| Diagnostics | Basic overlay/foundations | Latency, queue, tile, memory, prediction, exportable logs |
| Release | v0.6.0 public IPA built from green tag and inspected | Device acceptance, then next tagged raster milestone |

## Dependency-ordered next work

### Immediate — close v0.6

`v0.6.0` is released. Test page/layer selection, persistence, visibility,
opacity, deletion guards, gestures, and Pencil strokes on the iPad, then record
the results before changing the renderer architecture.

### Next — sparse raster command path

Define one ordered renderer command boundary for live, predicted, committed,
undo, clear, visibility, opacity, and page/layer changes. Connect
`BrushEmitter` batches to the existing sparse Metal tile foundation. Preserve
prediction replacement and do not rebuild the entire page per input update.

Acceptance should include:

- no visible seams at tile boundaries;
- no commit-time flash;
- true destination-out erasing;
- correct premultiplied alpha and layer opacity;
- deterministic undo/redo fixture results;
- bounded memory and reload behavior.

### Then — full raster tools

Port hardness, uniform-alpha MAX coverage, shade closed-path nonzero fill and
bridge behavior, and bucket fill with bleed. Match Android fixtures before UI
polish.

### Then — document packages and thumbnails

Add Files-compatible `.drafttable` packages, lazy tile persistence, atomic
recovery, page size metadata, thumbnails, page/layer reorder, raster/vector
types, and multi-document new/open/rename/delete.

### Then — vectors, snapping, and selections

Connect line/rectangle/ellipse/circle SDF rendering, grid overlays, vector and
angle snapping, raster/vector selection, transforms, copy/cut/paste, and
rasterize/merge behavior. These depend on stable document coordinates and the
page/layer/document model.

### Then — import/export and product gates

Add image import, PNG/PDF export, share sheet, hover and Pencil Pro affordances,
diagnostics, performance tests, package migration fixtures, and install/update/
reopen/data-retention device testing.

## Definition of complete

"All features" means the milestone gates in `FEATURE_ROADMAP.md` have passed,
not merely that controls are visible. Each feature needs its engine behavior,
persistence, rendering, UI, tests, macOS build, and real-device acceptance.

## External risk

The upstream project currently has no license file. Continue local development
and personal sideloading, but obtain permission or a license before treating
public IPA distribution as authorized redistribution.
