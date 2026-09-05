# Compact workspace design specification

Date: 2026-09-05. Design owner: Astra / orchestrator. Scope: panels, controls,
flows, and visual review before native implementation. This document records
proposals, not completed renderer features.

## Review of the existing layout

Reviewed the upstream app screenshot and current fork files at `d0158a1`:
`DraftingTableViewController.swift`, `DraftingTheme.swift`,
`PageLayerRailViews.swift` (component placement via its callers),
`DrawingSettingsViewController.swift`, `AppMenuWindowView.swift`, and gallery /
color picker entry points. Source review is not a physical-iPad screenshot audit.

| Finding | Consequence | Proposed change |
| --- | --- | --- |
| 56 pt tool rail + 84 pt pages + 180 pt inspector can occupy 320 pt before the canvas | Pages consume drawing space even when staying on one page | 48 pt rail and one 244 pt inspector; pages are a tab, inspector can collapse |
| Tool state, brush controls, settings sheet, and legacy toolbar builders coexist in the controller | Ownership of visible settings is difficult to follow; future drift is likely | One binding per setting, rendered in the context strip and optional full Tool panel |
| Rail captions use 8 pt, several option labels use 9 pt | Shrinking all fonts further would undermine the user's readability requirement | 12–13 pt controls, 11 pt secondary text, small icons with generous hit targets |
| Multiple secondary controls are near the canvas, with separate floating toolbar positioning | Changing panels changes available anchors and spacing | Stable top context strip; one inspector anchor and one canvas navigation corner |
| Fixed menu geometry and long action titles require shrinking or truncation | Risk of wrapping/clipping in smaller windows | Content-sized dialogs, short verb labels, adaptive columns, system pickers at file boundaries |
| Main menu contains several disabled commands | Users see buttons without a useful completion path | Design the full intended flow now; native implementation must gate unavailable features honestly |
| Long monospace text dominates some control rows | More width required for ordinary labels | System sans for controls; monospaced figures for numeric values |

The permanent width changes from 320 to 292 pt with the inspector open, a
28 pt saving. The large gain comes from closing the inspector: 48 pt remains,
recovering 272 pt relative to the fully open old layout. These figures compare
horizontal chrome only; the new header and context strip also consume height.
Do not present this as a measured percentage increase in total canvas area.

## Design principles and standards

Preserve the original's paper / ink / sienna character. Use flat opaque
surfaces, subtle dividers, and restrained corners. Avoid translucent controls
over artwork, large pill collections, oversized icons, or toolbar animations
that move drawing targets during a stroke.

Frequent actions belong in visible controls. Apple recommends selecting toolbar
items deliberately, prioritizing primary tasks and grouping commands by
function: [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars).
Our choice is an always-visible rail with every existing tool, a contextual
property strip, and four inspector tabs. No nested tool family menu or
long-press-only tool is required.

Use a 12 pt compact control style, 13 pt ordinary dialog copy, 11 pt secondary
metadata, and 16 pt dialog titles. Apple's iPad typography guidance lists 17 pt
as the default and 11 pt as the minimum; this compact professional workspace
deliberately uses the smaller end of that range and must be judged on the
physical iPad: [Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
Do not claim that 12 pt is Apple's default. Do not shrink existing 8–9 pt text.

Visible icons are 17 pt by default (16–20 pt adjustable in the study). Primary
touch targets are 44 × 44 pt, without overlapping neighboring targets.
Roomier mode uses 48 pt controls and larger type. The native version must
support Dynamic Type and increased contrast, and should reflow into scrolling
panels when large text exceeds the compact layout. See Apple's
[Accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility).
The study's 12–16 px slider is not a substitute for native Dynamic Type.

## Layout contract

| Region | Compact proposal | Rule |
| --- | --- | --- |
| Document header | 48 pt minimum | Documents + title left; undo/redo; view, Pencil, export, preferences, inspector |
| Tool property strip | 50 pt minimum | Selected tool, primary parameters, color, full options; reflow at narrow sizes |
| Tool rail | 48 pt | 17 pt icons, 44 pt targets, separators between raster / vector / selection |
| Inspector | 244 pt, adjustable 232–280 | Tool, Layers, Pages, Color; one panel at a time |
| Status line | 28 pt, expands if needed | Tool/layer, page specification, grid/snap state; no tiny tappable chips |
| Canvas navigation | 44 pt targets | Zoom out, percentage/fit, zoom in, focus toggle |
| Dividers | 1 pt | Consistent alignment; no doubled borders at panel joins |
| Dialogs | Up to 560 pt; gallery up to 740 pt | Fit window safe area, scroll long forms, no nested cascading menus |

At window widths greater than 820 CSS px in this preview, the inspector is
docked. At 820 and below it overlays the canvas; it never squeezes the drawing
into a sliver. This is an illustrative breakpoint: native code must calculate
from available safe-area width, text size, and the minimum usable canvas.
The compact-phone-sized browser check is a robustness check, not a new iPhone
product commitment. At 320–500 px, header actions and context controls wrap.

Default study shows Layers open to make the design inspectable. Production
should remember the user's last inspector state, selected tab, and side.
Right-handed drawing defaults to tools left / inspector right; left-handed
mirrors both. Keyboard and narrow windows preserve access to every tool.
Safe-area/home-indicator clearance belongs outside these content measurements.
The preview uses a 624 px work area for comparison, not a fixed native canvas.

## Tool and option inventory

| Tool | One-tap access / immediate controls | Full Tool panel | Native behavior contract |
| --- | --- | --- | --- |
| Brush | Rail; size, opacity, uniform alpha, color | Hardness, pressure response, stabilization, prediction, reset | Remember brush parameters independently; pressure changes width according to response |
| Eraser | Rail; size, opacity | Hardness, pressure response, uniform alpha, stabilization, prediction, reset | True alpha eraser; reveals lower layers; independent of brush size |
| Bucket | Rail; close-gap, bleed, boundary source, color | Tolerance, opacity, same gap/bleed/source values, reset | Default active raster layer; visible-layers boundary mode is an explicit extension |
| Shade | Rail; size, opacity, color | Hardness, pressure, uniform alpha, closure, stabilization, prediction, reset | Fill the closed path on lift; straight chord is the default closure |
| Line | Rail; stroke width, snap, color | Width, opacity, snap, angle constraint/step | Editable vector; no interior fill for a line |
| Rectangle | Rail; width, interior fill, snap, color | Width, fill, opacity, constraints | Editable vector; no hidden shape-family menu |
| Circle | Rail; width, fill, snap, color | Width, fill, opacity, constraints | Exact circular geometry |
| Ellipse | Rail; width, fill, snap, color | Width, fill, opacity, constraints | Independent axes |
| Select | Rail; combine mode, select/deselect, transform, copy, paste | Feather, replace/add/subtract/intersect, invert, cut/copy/paste/delete | Active-layer selection; disable geometry edits until a selection exists |
| Lasso | Rail; same selection controls | Same edit actions and feather | Freehand region, close to start |
| Eyedropper | Rail or Color panel | Active/visible sampling | Preview loupe; return to previous tool after picking; hover never paints |

Per-tool settings are a native contract. The study shares some parameter
values to demonstrate bindings and does not model every tool's saved preset.
It uses representative size/percentage ranges; engine ranges and document
units must be mapped during native wiring, not copied blindly from CSS pixels.

The grid and page background never count as bucket boundaries. For visible
layers, use the visible drawing composite as read-only input and write only
to the active raster layer. Mark this as a proposed feature until available;
it is not a claim about Android parity. Shape tools encountering a raster
layer must offer a visible “Create vector layer” transition, with Cancel,
rather than silently converting or mutating the existing layer.

## Panel and flow inventory

| Surface | Options / actions | State and dismissal contract |
| --- | --- | --- |
| Layers | Add raster/vector, select, visibility, opacity, lock, duplicate | Selected marker plus tint; retain layer names; opacity visibly affects one group |
| Layer actions | Rename, move up/down, duplicate, lock/unlock, rasterize, merge down, delete | Inapplicable actions disabled; explicit destructive confirmation; undoable commits |
| Pages | Thumbnail/name, selection, add, setup | One page list, no permanent second sidebar; stable selected page ID |
| Page actions | Rename, duplicate, move earlier/later, delete | First/last reorder bounds; cannot delete final page; undo after deletion |
| Page setup | A4/A3/Letter/Square/custom, orientation, resolution, units, dimensions, paper color | Validate positive dimensions and limits; Apply/Cancel transaction |
| Color | Foreground/previous swap, native color chooser, hex, 32 colors, recents, eyedropper | Hex/RGB validation, current-color ring; 4-column inspector palette preserves touch targets |
| Custom colors | RGB/hex values, custom slots, save current color | Slot storage local to app; preview only demonstrates four slots / first-slot save |
| Selection transform | X/Y, width/height, linked aspect, rotation, flip horizontal/vertical | Real app adds live geometry and handles; Apply/Cancel; positive-size validation |
| Documents | Gallery, open, new, rename, delete | Native Recently Deleted / recovery policy must exist before advertising recoverability |
| New document | Name and page setup in one form | No separate preset action sheet followed by another naming alert |
| Document actions | Rename, all documents, page setup, import, export, save copy, clear | No deep submenu; clear entire document requires explicit confirmation |
| Import / open | Files, Photos, editable document import, legacy one-way import | Native system picker, cancel, invalid/unsupported-file feedback |
| Image placement | Floating selection, fit, transform, place/cancel | Do not commit an imported image until Place; use new raster layer |
| Export | PNG/PDF/editable document, page scope, background, PNG scale | One form, then native share sheet; all-pages PNG means a named file set / ZIP |
| Save copy / backup | Editable document copy, all pages/layers | This study scopes backup to current document; bulk-library backup is deferred |
| Canvas view | Grid, pixel grid, snap, angle constraint/step, spacing, rotation, fit, 100%, reset rotation | No diagnostics over drawing by default; values reflect document/view scope |
| Apple Pencil | Hover, haptics, double-tap, squeeze, barrel roll | Gate unsupported hardware; preserve direct rail alternatives |
| Squeeze palette | Brush, eraser, bucket, lasso, color, undo, line, redo | One-level palette near Pencil; clamp to screen; no dwell menu navigation |
| Preferences / Workspace | Handedness, appearance, text/icon size, roomier controls | Immediate local preferences; mirror anchors, not drawing coordinates |
| Preferences / Input | Pencil-only drawing, prediction, activation threshold, stabilization, gestures | System/Pencil tuning belongs here; normal brush edits remain in tool controls |
| Preferences / Files | Default location, autosave information, Files open, backup | Saving, save failure, retry, save-copy escape route, recovery, missing-image states |
| Preferences / About | Version, shortcuts, diagnostics entry | Technical data kept outside ordinary drawing flow |
| Keyboard reference | Tool letters, undo/redo, close, focus | Never hijack typing in fields or ordinary Tab focus navigation |
| Diagnostics | Input/frame timing, GPU memory/tiles, Pencil sample rates | Real measured values only; preview displays unavailable dashes |

Raster selection transform is still a renderer transaction requirement; this
design does not weaken tile-generation, grouped-opacity, package-manifest,
serial ownership, or one-way DTAR import contracts.

## Interaction and error rules

- Tool switch: one tap. Common property adjustment: direct slider or field.
  Full properties: one tap on Options. A preset does not require another menu.
- Inspector tab changes are direct. Selecting a tool updates the strip and
  Tool panel without forcibly stealing the Layers tab.
- Page/layer titles stay on one line and truncate at the trailing edge. Full
  names remain available in rename/actions and accessibility labels.
- Essential tool names remain accessible through labels, Pencil hover help,
  and keyboard reference. Add a labeled-tools accessibility layout for users
  who cannot identify icons reliably; do not depend on hover for all naming.
- Dialog forms that have Apply/Cancel use draft state. Preferences apply
  immediately. Escape closes the current modal before closing an inspector.
- Avoid invisible tap regions extending into neighbors. Color dots can be
  20 pt inside a 44 pt square; an 8-column panel at 244 pt cannot satisfy that,
  so it becomes four columns. Native wider color sheets can use eight columns.
- Locked layers show the lock and stop mutations with a concise explanation.
  Hidden active layers offer Show; vector/raster mismatch offers a new layer.
- Save failure preserves current work and exposes Retry / Save a copy.
  Recovery identifies last saved versus recovered version without implying
  either is complete until package validation finishes.
- Export has preparing, cancellation, failure/retry, and share completion
  states. The preview shows configuration and handoff, not actual file work.
- Confirmation is reserved for lossy/destructive document actions, not tool
  switches, panel toggles, or normal parameter edits.

## Remaining design details before production wiring

The major surfaces are represented. The following fine-grained contracts are
specified here but intentionally not fully simulated: pressure response curve
editing, color-space conversion, floating-image content, vector node handles,
linked aspect ratio, long-list drag reordering, per-tool preset memory, Files
provider conflict selection, large-document export cancellation, and actual
Pencil radial positioning. They need native interaction review during wiring.

Do not add a button for a future backend option without its complete state
contract. The preview can expose proposed controls, but a test IPA must either
support them or identify them as unavailable.

## Implementation sequence after design review

1. Central tokens and reusable toolbar, field, row, swatch, inspector, dialog
   components. One settings model and stable document IDs. Remove duplicate
   live UI builders only after their replacements are connected.
2. Responsive shell and direct tool/context bindings; preserve current Pencil
   and renderer integration. Review landscape, portrait, split window, and
   Pencil/finger routing before broad feature wiring.
3. Layer/page/color inspectors and transactional forms. Wire existing actions
   first and review before adding missing capabilities.
4. Document/import/export flows and Pencil preferences; system pickers and
   failure/recovery surfaces. Enforce backend capability gating.
5. Selection/vector/fill options as their rendering contracts become ready.
   Review each major step, produce a sideload test release, and provide a
   concise physical-device checklist. No new test suite is requested here.

No native sources or IPA changed in this study. This sequence is not a claim
that all currently exposed options already have a functioning backend.

## Assumptions and review points

- Latest direction permits improving the original layout rather than requiring
  pixel-for-pixel Android geometry; original references remain preserved.
- All design guides stay beneath `design/guides`. Visual decisions stay with
  the orchestrator; Luna is for subsequent bounded coding tasks only.
- Warm light appearance is the default; dark chrome and left-handed mirroring
  are alternatives available in Preferences.
- Small visible icons should not mean small touch targets. The user's goal is
  a compact, usable workspace, not minimum possible text size.
- iPad Pro landscape is the primary review size; portrait and split windows
  must work. Exact physical device and preferred type size remain device-review
  choices, not blockers to making this preview.
- 11 existing drawing/selection tools stay directly accessible. No new brush
  marketplace, account system, collaboration feature, or shape catalogue.
- Side inspector tabs are preferred to permanently reserving a pages column.
  If frequent page switching proves central, a user-pinned page strip is a
  later option, not another permanent default panel.
- Active-layer bucket boundaries remain default. Visible-layer fill is an
  explicit proposed extension and needs implementation/capability treatment.
- This delivery is a design preview. Sideload IPA packaging resumes with native
  implementation; personal distribution scope remains unchanged.
