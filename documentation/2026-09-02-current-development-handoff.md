# 2026-09-02 — current development handoff

This is the exact resume point as of 2026-09-02 in Toronto.

## Repository state

- Local checkout: `D:\Vibe Code\Drafting Table Fork`
- Branch: `ipad-native-port`
- Source candidate: `4bcbaaf` — `Fix Swift input and document picker control flow`
- Tracking: `origin/ipad-native-port` includes the source candidate
- Fork: <https://github.com/Code-Andy/drafting_table>
- Upstream: <https://github.com/bgkatz/drafting_table>
- Upstream push URL: disabled as `no_push`
- Project version in `project.yml`: `0.7.0` build `8`
- Latest released version: `v0.7.0`
- Documentation baseline: `ad0c5f8`

## What HEAD contains

The v0.7 candidate adds a broad feature batch on top of the v0.6 retained
document model: color/hardness, Line/Rectangle/Ellipse tools, grid, page/layer
duplicate and reorder, thumbnails, Pencil hover/actions, `.drafttable` Open and
Save Copy, PNG/PDF export, and archive v3 with v1/v2 migration.

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

## Validation result and resolved compiler issue

The first source candidate at `6d11522` passed portable tests but failed Swift
compilation. UIKit's class hierarchy required different declarations:

- `PageCardButton: UIButton` inherits `UIContextMenuInteractionDelegate` and
  overrides the context-menu configuration callback;
- `LayerRowView: UIView` explicitly conforms and implements the callback.

Commits `4828724` and `5341b3c` applied and refined that fix using successive
Xcode compiler feedback.

Portable core workflow passed on source candidate `5341b3c`:

- Run: <https://github.com/Code-Andy/drafting_table/actions/runs/33599071991>
- Conclusion: success
- Covered: portable core, document, brush, Metal layout, and iPad retained
  engine tests.

The iPad workflow also passed on `5341b3c`:

- Run: <https://github.com/Code-Andy/drafting_table/actions/runs/33599071908>
- Conclusion: success
- Environment: Xcode 16.4 / iPhoneOS 18.5

The downloaded branch artifact was inspected with these results:

- version `0.6.0`, build `7`;
- bundle `com.local.draftingtable.ipad`;
- arm64 Mach-O executable (`CPU_TYPE_ARM64`);
- compiled `Assets.car` and `default.metallib` present;
- SHA-256
  `F49B1BED7F10778F236D940F734C1247B1CD26A6625EE2F8182A8D02CB2EC321`.

## Release result

`57b11c5` was tagged as `v0.6.0`. The tagged build and publish workflow passed:
<https://github.com/Code-Andy/drafting_table/actions/runs/33599450183>.

The release IPA reports version `0.6.0` build `7`, is arm64, and contains its
compiled assets and Metal library. Its SHA-256 is
`82F55DE895B293F5967A3A61775ED46C85E0C69B1821B8BFE205EABD5CF57311`.

- Release: <https://github.com/Code-Andy/drafting_table/releases/tag/v0.6.0>
- IPA: <https://github.com/Code-Andy/drafting_table/releases/download/v0.6.0/DraftingTable.ipa>

## v0.7 candidate validation

Source candidate `4bcbaaf` passed both workflows:

- Portable core: <https://github.com/Code-Andy/drafting_table/actions/runs/33601182562>
- Xcode/IPA: <https://github.com/Code-Andy/drafting_table/actions/runs/33601182536>

The branch artifact reports `0.7.0` build `8`, contains an arm64 executable,
compiled assets and Metal library, and registers the `.drafttable` UTI. Its
pre-tag SHA-256 is
`A1B78B4AC6B550048D0EDC97F16A5D9833F6D8AB59D5EBA8FB79DA46C3D2DAC0`.

## Exact continuation sequence

1. Install `v0.7.0` build `8`.
2. Test color/hardness, all five tools, grid transform, duplicate/reorder,
   thumbnails, hover/double-tap/squeeze, `.drafttable` Open/Save Copy, PNG/PDF,
   autosave, migration, Pencil curves, and two-finger gestures.
3. Record device feedback as a new dated key-change file.
4. Begin the sparse raster command path and true eraser after obvious v0.7
   regressions are addressed.

## v0.7 release result

`8eed6ba` was tagged as `v0.7.0`. The tagged build and release workflow passed:
<https://github.com/Code-Andy/drafting_table/actions/runs/33601680372>.

- Release: <https://github.com/Code-Andy/drafting_table/releases/tag/v0.7.0>
- IPA: <https://github.com/Code-Andy/drafting_table/releases/download/v0.7.0/DraftingTable.ipa>
- SHA-256:
  `5A957E175198B6C34D5612CBC095720C075F768D4326CC3CF59C33646CBC31B0`

## Known boundaries of the candidate

- Layers are retained stroke lists, not final raster/vector layer types.
- The visible renderer is not the sparse tile renderer.
- Eraser is not destination-out.
- `.drafttable` is a flat archive rather than a lazy tile package, and there is
  no multi-document browser or Android tile-folder migration.
- PNG/PDF export exists; image import and page-size presets do not.
- Shape tools persist and export but are not editable/snappable vectors.
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
