# 2026-09-01 — iPad port development history

## Original goal and constraints

The requested end state is a native iPad version of Drafting Table that can be
developed from Windows, built by GitHub-hosted macOS runners, downloaded as an
unsigned IPA, and signed/sideloaded by the user. Work is local to the fork
until pushed to `Code-Andy/drafting_table`; `bgkatz/drafting_table` remains the
read-only upstream reference.

The user wanted rapid, device-testable increments instead of waiting for full
Android parity. The root agent acts as integrator and release owner while
bounded implementation work may be delegated. Every increment is expected to
produce a real IPA when it passes CI.

## Device feedback that changed the work

1. The first installed scaffold opened to a blank/black app and had a blank
   icon. This established that a successful archive is not a useful product
   milestone by itself. The next gate became a visible paper canvas, real app
   icon, obvious chrome, and live Pencil drawing.
2. Pencil drawing then worked and felt responsive, but curved strokes looked
   spotty. Stroke interpolation and thick join/cap generation were prioritized.
3. "Pen height" was clarified to mean the pressure/contact point at which a
   stroke begins and the point at which it is treated as lifted, especially
   with different screen protectors. UIKit cannot change Apple Pencil hardware
   hover or physical detection height, so the app implements a software
   activation threshold with release hysteresis.
4. The user asked to hide pressure tuning. The activation control therefore
   lives in Settings rather than occupying the primary drawing rail.
5. After Brush/Eraser, Undo/Redo, persistence, and gestures became useful, the
   user asked to continue toward the complete feature set. Work was reorganized
   into dependency-ordered milestones rather than isolated visual placeholders.

## Change ledger

### Foundation — commits `c0c8bb9` through `5fd83a4`

- Added a programmatic UIKit application and scene lifecycle.
- Added an `MTKView` canvas, Apple Pencil sample capture, Objective-C++ bridge,
  portable C++20 modules, and Metal foundations.
- Added XcodeGen project generation and GitHub Actions packaging of an unsigned
  device IPA.
- Fixed bridge signatures using real Xcode compiler feedback.
- Added portable Windows tests for coordinate, persistence, brush, and Metal
  layout invariants.

This was an architectural scaffold: the platform boundaries and build route
existed, but the app did not yet provide a useful visible drawing experience.

### v0.2.0 / v0.2.1 — visible device loop

Key commits: `fbdebd9`, `993c1f3`, `e925a83`.

- Replaced the black/blank presentation with a paper-colored canvas and visible
  page, layer, and tool chrome.
- Added a real asset-catalog app icon and launch background.
- Added immediate pressure-aware Pencil/finger stroke rendering, Undo, and
  Clear sufficient for device feedback.
- Corrected tag-release publishing and preserved release version metadata.

The v0.2 line intentionally favored a visible immediate renderer over claiming
that the unconnected sparse tile backend was already production drawing.

### v0.3.0 — smoother curves and activation tuning

Key commits: `72dd632`, `538881c`.

- Added curve subdivision and improved thick joins/caps to reduce spotty curved
  lines.
- Preserved coalesced and predicted Pencil input behavior.
- Added a persistent 0–20% activation-pressure threshold and a lower release
  threshold at 55% of the selected activation value.
- Documented that this is software contact/lift-off filtering, not control over
  Apple Pencil hardware hover height.

### v0.4.0 — retained drawing session

Key commits: `b0848f2`, `96ff11e`.

- Added Brush and Eraser tools with per-stroke size and opacity snapshots.
- Added per-session Undo and Redo.
- Added bounded versioned little-endian stroke archives, atomic autosave in
  Application Support, and launch restore.
- Moved activation tuning into a Settings sheet alongside size and opacity.
- Fixed an Apple SDK type collision found by the macOS build.

The eraser still replays paper-colored geometry in retained order. It is not a
true destination-out tile eraser and will need replacement in the raster parity
milestone.

### v0.5.0 — document/view transform and gestures

Key commits: `5f4ed6f`, `9382c8d`, `e571612`.

- Established document coordinates as the C++ input/storage coordinate system.
- Applied the matching atomic document-to-view transform in Metal.
- Added simultaneous two-finger pan, pinch, and rotation while preserving the
  document point under the gesture centroid.
- Added Reset View and persisted the transform in UserDefaults.
- Cancelled direct-finger drawing when a two-finger gesture takes ownership and
  prevented transform mutation during an active Pencil stroke.

Release: <https://github.com/Code-Andy/drafting_table/releases/tag/v0.5.0>

Direct IPA: <https://github.com/Code-Andy/drafting_table/releases/download/v0.5.0/DraftingTable.ipa>

Recorded SHA-256:
`479AE65F0EE38C4FF4F3D2AA04350B7F767396821063C2351ADC4FCD4E4D3D37`.

### v0.6.0 candidate — retained pages and layers

Key commits: `310928c`, `6d11522`.

- Replaced placeholder page/layer rails with metadata-driven controls.
- Added selection, add, rename, guarded delete, layer visibility, and opacity.
- Added active page/active layer ownership in the retained engine.
- Made Undo, Redo, and Clear operate on the active layer.
- Flattened visible layers on the active page from bottom to top for rendering.
- Added `DTAR` archive v2 with names, active indices, layer visibility/opacity,
  styles, and samples.
- Added migration of v1 flat-stroke archives into `Page 1 / Ink` and added real
  v1 fixture, v2 round-trip, and malformed archive tests.

This candidate is not yet tagged as of this record. The initial macOS build was
blocked by inherited UIKit context-menu declarations. Commits `4828724` and
`5341b3c` applied the class-specific fix: `UIButton` uses its inherited override
while the plain `UIView` layer row explicitly conforms to the delegate. Both
portable and macOS build workflows then passed and the branch IPA was inspected.

## Release history

| Version | Status | User-visible purpose |
| --- | --- | --- |
| v0.2.0 | pre-release | First visible canvas iteration |
| v0.2.1 | released | Correct version metadata and usable artifact |
| v0.3.0 | released | Curved-line smoothing and Pencil activation tuning |
| v0.4.0 | released | Retained tools, settings, Undo/Redo, autosave |
| v0.5.0 | latest released | Two-finger canvas transform and coordinate boundary |
| v0.6.0 | release-ready candidate | Retained pages/layers and archive v2 |

The release list is maintained at
<https://github.com/Code-Andy/drafting_table/releases>.
