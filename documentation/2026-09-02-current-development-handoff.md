# 2026-09-02 — current development handoff

This is the exact resume point as of 2026-09-02 in Toronto.

## Repository state

- Local checkout: `D:\Vibe Code\Drafting Table Fork`
- Branch: `ipad-native-port`
- Source candidate: `5341b3c` — `Keep layer context menu delegate conformance`
- Tracking: `origin/ipad-native-port` includes the source candidate
- Fork: <https://github.com/Code-Andy/drafting_table>
- Upstream: <https://github.com/bgkatz/drafting_table>
- Upstream push URL: disabled as `no_push`
- Project version in `project.yml`: `0.6.0` build `7`
- Latest released version: `v0.5.0`
- Documentation baseline: `ad0c5f8`

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

## Exact continuation sequence

1. Push this documentation update and require both workflows to pass on the
   final documentation/source commit.
2. Write release notes that say "retained pages/layers" and do not claim sparse
   raster tiles, thumbnails, reorder, or Files document packages.
3. Tag and push `v0.6.0`.
4. Verify the tagged workflow, release asset, SHA-256, and direct IPA URL.
5. Collect real-iPad feedback before beginning the sparse raster milestone.

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
