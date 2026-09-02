# 2026-09-02 — current development handoff

This is the exact resume point as of 2026-09-02 in Toronto.

## Repository state

- Local checkout: `D:\Vibe Code\Drafting Table Fork`
- Branch: `ipad-native-port`
- HEAD: `6d11522` — `Add retained pages layers and archive migration`
- Tracking: `origin/ipad-native-port` at the same commit
- Fork: <https://github.com/Code-Andy/drafting_table>
- Upstream: <https://github.com/bgkatz/drafting_table>
- Upstream push URL: disabled as `no_push`
- Project version in `project.yml`: `0.6.0` build `7`
- Latest released version: `v0.5.0`
- Working tree at documentation start: clean

## What HEAD contains

`310928c` adds dynamic UIKit page and layer rails. `6d11522` adds retained
page/layer ownership, bridge APIs, archive v2, v1 migration, and tests.

The active page owns an ordered layer list and active-layer index. Drawing,
Undo, Redo, and Clear target the active layer. Rendering snapshots flatten the
active page's visible layers bottom-up and multiply stroke opacity by layer
opacity. At least one page and one layer are always retained.

The UI supports:

- select and add pages/layers;
- long-press context menus for rename/delete;
- guarded deletion of the final page/layer;
- layer visibility and continuous opacity preview;
- autosave after committed mutations.

## Validation result

Portable core workflow passed on the exact HEAD:

- Run: <https://github.com/Code-Andy/drafting_table/actions/runs/33578439507>
- Conclusion: success
- Covered: portable core, document, brush, Metal layout, and iPad retained
  engine tests.

The iPad workflow failed on the exact HEAD:

- Run: <https://github.com/Code-Andy/drafting_table/actions/runs/33578439462>
- Conclusion: failure
- Stage: Swift compilation under Xcode 16.4 / iPhoneOS 18.5

The first reported errors are in
`platforms/ipad/PageLayerRailViews.swift`:

```text
line 91: redundant conformance of PageCardButton to
         UIContextMenuInteractionDelegate
line 125: overriding declaration requires an override keyword
```

UIKit's `UIButton`/`UIControl` already conforms to the context-menu delegate
and exposes the configuration callback as an overridable method. The expected
repair is to remove the explicit conformance from `PageCardButton` and mark its
callback `override`. `LayerRowView` should be checked for the same inherited
`UIView` conformance and callback behavior before the next push.

## Exact continuation sequence

1. Patch both context-menu view classes for inherited UIKit conformance.
2. Review the resulting Swift declarations rather than suppressing the error.
3. Commit and push to `ipad-native-port`.
4. Require both portable core and iPad unsigned IPA workflows to pass.
5. Download the branch IPA artifact and inspect:
   `Payload/DraftingTable.app`, arm64 executable, processed `Info.plist`, app
   icon assets, and `default.metallib`.
6. Confirm marketing version `0.6.0` and build `7` inside the packaged app.
7. Write release notes that say "retained pages/layers" and do not claim sparse
   raster tiles, thumbnails, reorder, or Files document packages.
8. Tag and push `v0.6.0` only after the branch build passes.
9. Verify the tagged workflow, release asset, SHA-256, and direct IPA URL.
10. Collect real-iPad feedback before beginning the sparse raster milestone.

## Known boundaries of the candidate

- Page cards do not yet contain rendered thumbnails.
- Page/layer reordering is not implemented.
- Layers are retained stroke lists, not final raster/vector layer types.
- The visible renderer is not the sparse tile renderer.
- Eraser is not destination-out.
- No Files document packages, multi-document browser, PNG/PDF export, or image
  import exists in the iPad port yet.
- Pencil and gesture behavior still require device validation in this version.

## Do not lose these invariants

- C++ receives document coordinates, never transformed view coordinates.
- Pencil strokes own drawing; two-finger touches own navigation.
- Active Pencil strokes block transform changes.
- A failed archive load leaves the existing session intact.
- Page/layer mutations cancel an in-progress stroke before changing ownership.
- Archive counts, names, samples, and byte length remain bounded.
- Layer opacity is applied once during snapshot/composition.
- Autosave happens after a committed UI mutation, not continuously for every
  slider tick.
