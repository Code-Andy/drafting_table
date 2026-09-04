# iPad port development record

This directory is the durable handoff record for the Drafting Table iPad
port. It captures product intent, implementation history, architectural
decisions, build/release mechanics, agent coordination, and known incomplete
work. It is intended to let a future developer or agent resume without access
to the original chat.

## Naming convention

Development records use:

```text
YYYY-MM-DD-key-change.md
```

The date is the local development date in `America/Toronto`. The remainder is
the principal change or decision documented by the file. Existing root-level
documents remain useful technical references, but new dated decisions and
handoffs belong here.

## Read this first

1. [2026-09-04-v0.9.9-release-notes.md](2026-09-04-v0.9.9-release-notes.md)
   — Stroke input limit fix, layer drag-to-reorder, vector badges, and 32-cell palette with custom slots.
2. [2026-09-04-v0.9.8-release-notes.md](2026-09-04-v0.9.8-release-notes.md)
   — Compact page previews/fonts, dynamic subtool menus to right of pages rail, popover color selector, and built-in non-scrolling app menu window.
3. [2026-09-03-v0.9.7-release-notes.md](2026-09-03-v0.9.7-release-notes.md)
   — Gap-closing bucket fill with margin/bleed controls, paper space maximization, and Apple Pencil Pro circular radial wheel menu.
3. [2026-09-03-current-development-handoff.md](2026-09-03-current-development-handoff.md)
   — exact branch, release, CI, and blocker state as of v0.9.8.
4. [2026-09-03-v0.9.2-pencil-pro-and-feature-set.md](2026-09-03-v0.9.2-pencil-pro-and-feature-set.md)
   — Apple Pencil Pro (hover preview, squeeze, roll/tilt, haptics) & Drafting Table feature set (Shade, Selection, 15° snap, pixel grid, doc rename).
5. [2026-09-03-v0.9.1-prerelease.md](2026-09-03-v0.9.1-prerelease.md)
   — visible color tool, smooth six-slice joins, live grid snap for shapes.
6. [2026-09-03-v0.9.0-prerelease.md](2026-09-03-v0.9.0-prerelease.md)
   — stroke de-dotting, HSV color picker, background page thumbnails.
7. [2026-09-03-ui-parity-with-original.md](2026-09-03-ui-parity-with-original.md)
   — original DRAW / SHAPE / SELECT tool rail, bottom status chips, Circle tool.
8. [2026-09-03-v0.7.2-launch-watchdog-fix.md](2026-09-03-v0.7.2-launch-watchdog-fix.md)
   — proven ODR namespace fix, on-demand rendering, vertex budget, breadcrumbs.
9. [2026-09-02-v0.7.1-launch-crash-hotfix.md](2026-09-02-v0.7.1-launch-crash-hotfix.md)
   — beige-screen crash reproduction, renderer/memory hardening, and verified IPA.
10. [2026-09-02-v0.7-major-feature-batch.md](2026-09-02-v0.7-major-feature-batch.md)
    — broad drawing, document, Pencil, Files, and export implementation jump.
11. [2026-09-02-v0.6-pages-layers-release.md](2026-09-02-v0.6-pages-layers-release.md)
    — tagged feature notes, CI evidence, IPA checksum, and download links.
12. [2026-09-02-feature-state-and-next-work.md](2026-09-02-feature-state-and-next-work.md)
    — honest feature matrix and dependency-ordered next work.
13. [2026-09-02-build-test-release-runbook.md](2026-09-02-build-test-release-runbook.md)
    — reproducible Windows, GitHub, IPA, and release procedure.
14. [2026-09-02-agentic-development-workflow.md](2026-09-02-agentic-development-workflow.md)
    — how delegated work is scoped, reviewed, and retired.
15. [2026-09-01-ios-port-development-history.md](2026-09-01-ios-port-development-history.md)
    — product request, device feedback, and the v0.1–v0.6 development ledger.
16. [2026-09-01-ios-port-key-decisions.md](2026-09-01-ios-port-key-decisions.md)
    — architecture and product decisions with reasons and consequences.
17. Early release notes:
    - [2026-09-01-v0.5.0-release-notes.md](2026-09-01-v0.5.0-release-notes.md) (coordinate space & gestures)
    - [2026-09-01-v0.4.0-release-notes.md](2026-09-01-v0.4.0-release-notes.md) (retained session & autosave)
    - [2026-09-01-v0.3.0-release-notes.md](2026-09-01-v0.3.0-release-notes.md) (Pencil curve quality & activation filter)
    - [2026-09-01-v0.2.0-release-notes.md](2026-09-01-v0.2.0-release-notes.md) (first interactive canvas)


## Other source-of-truth documents

- [`../CLAUDE.md`](../CLAUDE.md): original Android architecture and invariants.
- [`../IOS_PORT.md`](../IOS_PORT.md): consolidated iPad implementation status.
- [`../FEATURE_ROADMAP.md`](../FEATURE_ROADMAP.md): milestone dependency graph.
- [`../PORTING.md`](../PORTING.md): portable extraction plan and tool summary.
- [`../AGENTIC_SETUP.md`](../AGENTIC_SETUP.md): short-form orchestration notes.
- [`../releases/README.md`](../releases/README.md): stable IPA release pointers.

## Update rule

When a meaningful change lands, add or update a dated file containing:

- the user-visible change;
- the technical change and affected boundaries;
- the reason for the decision;
- validation actually performed;
- known limitations or deferred work;
- commit, CI run, release tag, and IPA link when applicable.

Do not call a foundation "complete" if it is not connected to the visible app.
Do not call a version released until its exact tagged macOS workflow succeeds
and its IPA asset has been inspected.
