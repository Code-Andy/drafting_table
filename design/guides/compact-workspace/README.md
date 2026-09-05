# Compact workspace · study 02

Status: **design proposal for review, 2026-09-05**. This is a UI framework and
interactive visual aid, not an implemented iPad release. It responds to the
owner's request to design all panels before changing the native app.

Open [`workspace-preview.html`](workspace-preview.html) in a browser. Its
editable source is [`workspace-preview.fragment.html`](workspace-preview.fragment.html).
The preview runs locally; edits disappear when the page reloads. The same
sample illustration represents every document. No Pencil, file, or renderer
operation is claimed to work here.

Read [`design-spec.md`](design-spec.md) for the layout decisions, complete
panel and option inventory, interaction contracts, and implementation order.
[`tokens.json`](tokens.json) defines the proposed sizes and surface colors.

## Explore

1. Choose any drawing tool on the rail. Its frequent options appear across the
   top. Open **Options** for the full tool panel.
2. Switch **Layers / Pages / Color** in the inspector. Add or duplicate a
   layer/page, toggle visibility, and use Undo/Redo for those structural edits.
3. Use the Pencil button for mappings and **Try quick palette**. Open **View**
   for grid/snapping; the share button opens all export formats directly.
4. Open Preferences for light/dark appearance, mirrored left-handed layout,
   text/icon sizing, and roomier controls. Files includes simulated save and
   recovery states. These are design controls, not connected device settings.
5. Collapse the inspector for a larger canvas. At narrower window widths the
   inspector overlays the drawing instead of shrinking it.

## Relationship to upstream

The original screenshot, exact Android tokens, and previous parity guide in
the parent folder remain historical source references. This proposal
intentionally changes geometry, inspector placement, typography, and menu
organization under the owner's latest direction. It retains warm paper,
sienna selection, restrained rules, drafting tools, and document hierarchy.
It does not silently replace the original reference with a new baseline.

## Preview boundaries

Live: panel switching, context controls, tool selection, theme/handedness,
layer visibility/opacity, structural page/layer edits and undo, selection
outline, zoom/rotation/grid, color choice, and modal flows.

Simulated: drawing/erasing/filling, actual selection geometry, transforms,
merging pixels, image placement, individual document contents, persistent
storage, hardware detection, Pencil squeeze/hover/haptics, export, and recovery.
The preview labels these actions explicitly. Pixel-grid and hardware switches
show configuration state; they are not renderer or hardware implementations.

Not introduced: accounts, cloud collaboration, subscriptions, AI drawing
tools, a new brush marketplace, or extra shape families beyond the app's scope.

## Updating this study

Edit the fragment, then regenerate the standalone copy with the installed
visualize skill's `scripts/render.py`. Keep both here. Check interactions and
responsive layouts in a browser; native tests and a new IPA are not necessary
for a design-only update. Review changes before treating this proposal as the
native implementation specification.

The orchestrator owns visual judgment and review. Do not delegate visual aids
to Luna. Future repetitive native coding can be assigned to Luna with bounded
file ownership and review; Sol may handle independent complex implementation.
