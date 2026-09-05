# Study 02 review record

Reviewed 2026-09-05 by the orchestrator. No Luna design delegation. No native
source edits, new automated tests, CI build, or IPA were needed for this study.

## Checks performed

- Compared the existing layout constants and controls with the original UI
  screenshot and retained the original source material in the parent folder.
- Opened the standalone preview in the browser at 1024, 736, and 360 px
  viewport widths. Checked the docked inspector, narrow-window overlay,
  context reflow, title row, and canvas controls. At 360 px the preview root
  measured 328 px with a matching 328 px scroll width (outer renderer padding
  accounts for the difference); no horizontal page overflow was present.
- Visually checked dark appearance and left-handed mirroring at narrow width.
- Opened the Brush, Eraser, Bucket, Shade, Line, Rectangle, Circle, Ellipse,
  Select, Lasso, and Eyedropper option panels. Confirmed context/panel changes.
- Added a page and used Undo; the page list returned from four to three.
- Opened Pencil settings, Pages, and Color. Checked the 32-color palette's
  bounded scrolling and stable inspector tabs.
- Opened PNG/PDF export, gallery, and the single-form New document flow.
  Selected custom page size, saw width/height fields, and cancelled.
- Opened Preferences / Files and simulated save failure. Verified that
  Retry and Save a copy were present.
- Checked embedded JavaScript syntax and parsed the proposed JSON tokens.
- Browser error log was empty during the inspected interactions.

## Corrections made during review

- Fixed page action buttons claiming the same flexible width as page names.
- Kept long inspector content inside the panel rather than stretching the
  full work area; tabs stay visible while the inspector scrolls.
- Gave document titles their own row at very narrow widths.
- Matched the handedness field's visible label and accessible name.
- Removed interior fill controls from Line; added the explicit vector-layer
  creation action to shape options on a raster layer.
- Preserved the original illustration binding when a layer is renamed.
- Added draft rollback for page-setup cancellation, consistent numeric select
  values, an aspect-link option for transform fields, and correct Escape /
  keyboard focus behavior.
- Kept modal validation notices above the overlay and marked simulated export
  and recovery actions explicitly.

## Limits of this review

This verifies a design aid, not app feature correctness. Renderer operations,
individual document contents, per-tool setting memory, Files/iCloud behavior,
physical Pencil actions, and Dynamic Type still require native implementation
and review. The minimum-width browser view is a fallback, not the intended
full-time iPad workspace. Physical iPad review remains the deciding evidence
for text size, target spacing, Pencil occlusion, and comfortable reach.
