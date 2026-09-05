# Drafting Table design guides

This directory is the single home for the iPad port's visual references. The
goal is direct UI parity with the upstream Android **Concept A v4** design while
keeping the iPad-native renderer and Apple Pencil behavior independent of the
visual shell.

## Authority order

When references disagree, use this order:

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

## Working rules

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
