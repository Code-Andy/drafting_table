# Drafting Table design guides

This directory is the single home for the iPad port's visual references.
The upstream Android **Concept A v4** material is preserved below. The latest
owner direction (2026-09-05) also permits improving layout and density before
native implementation, while preserving the iPad renderer and Pencil work.

## Current design proposal

[`compact-workspace/README.md`](compact-workspace/README.md) indexes the new
interactive workspace study, complete panel inventory, design specification,
and proposed tokens. It intentionally changes the old geometry and menu
organization and is marked **for review**, not a completed native release.

## Original parity reference order

For the original Android parity baseline, use this order. The new compact
proposal has its own versioned specification and does not overwrite it:

1. [`canonical-ui-reference.png`](canonical-ui-reference.png) — the upstream
   app preview and primary visual target.
2. [`ui-tokens.json`](ui-tokens.json) — machine-readable colors, typography,
   dimensions, palette, and component measurements extracted from upstream.
3. [`original-ui-design-system.md`](original-ui-design-system.md) — written
   implementation contract and source citations.
4. [`concept-a-v4-component-sheet.svg`](concept-a-v4-component-sheet.svg) —
   importable Figma/component reference for landscape, portrait, and controls.
5. [`drafting-table-ui-reference.html`](drafting-table-ui-reference.html) —
   standalone interactive visual reference for quick browser review.
6. [`ui-parity-history.md`](ui-parity-history.md) — historical parity record;
   useful context, but not authoritative over the current files above.

The inspected upstream source is
[`bgkatz/drafting_table` at `9a668cde`](https://github.com/bgkatz/drafting_table/tree/9a668cde44f5194db51df64a355a15af55f126a6).

## Original parity maintenance rules

- Match upstream geometry, hierarchy, icon shapes, labels, colors, and density
  before introducing iPad-specific visual changes.
- Treat screenshot values as a captured runtime state and source dimensions as
  the reusable layout contract.
- Use the actual upstream 32-color palette; the old "16-cell" comment is stale.
- Keep renderer architecture, Apple Pencil integration, and persistence choices
  out of the visual contract unless they change visible interaction feedback.
- Record intentional deviations in the implementation/release notes instead of
  silently changing these references.
- Update the source commit in both this index and `ui-tokens.json` whenever the
  upstream visual baseline changes.

`tools/drafting_table.png` remains as a compatibility copy because the root
README embeds it. The canonical design-guide copy is the file in this folder.
