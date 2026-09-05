# Canvas-first workspace · study 03

The current design prioritizes drawing space: one thin header, direct tool
access, anchored left tool windows, a partially exposed corner color wheel,
and compact Layers/Pages on the right. The second toolbar and bottom status
strip are removed.

Open [workspace-preview.html](workspace-preview.html) in a browser.
The editable source is [workspace-preview.fragment.html](workspace-preview.fragment.html).
Read [design-spec.md](design-spec.md), [tokens.json](tokens.json), and
[review-notes.md](review-notes.md) for the current contract and review evidence.
The supplied visual reference is preserved as
[palette-wheel-reference.png](palette-wheel-reference.png).

## Try the changes

1. Click a tool's small bottom-right arrow. Its settings window opens beside
   the rail. Tapping the active tool again opens/closes the same window.
2. Pin the tool window to keep it following tool changes; close it when you
   want the page unobstructed.
3. Rotate the bottom-left color arc by dragging, scrolling, or using its
   arrows. Choose a base or lighter shade.
4. Press the wheel center to switch to **My colors**. Pick a slot, adjust the
   hue ring / saturation square or enter hex, then **Replace slot**. Press the
   center again to return to RGB/Marker.
5. Use Layers/Pages on the right, or collapse that panel. The wheel also
   collapses to its center button.

## Preview scope

Panel navigation, settings, palette selection and editing, wheel rotation,
layer visibility/opacity, structural page/layer edits, and modal flows are
interactive. Drawing, native Pencil behavior, real document content,
persistence, and exports remain simulated. Reload resets local preview state.

The original warm-paper design is retained with tighter geometry.
**Marker** means a small marker-inspired palette, not calibrated COPIC color
matches. The prior study's design and review are preserved as
[study-02-design-spec.md](study-02-design-spec.md) and
[study-02-review-notes.md](study-02-review-notes.md).

## Updating

Edit the fragment and regenerate the standalone copy using the installed
visualize skill's `scripts/render.py`. Keep all design files in this folder.
Review browser interactions and responsive layouts before native wiring.
The orchestrator owns visual work; Luna is reserved for later bounded coding
tasks that can be reviewed.
