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

1. [2026-09-02-current-development-handoff.md](2026-09-02-current-development-handoff.md)
   — exact branch, release, CI, and blocker state.
2. [2026-09-01-ios-port-development-history.md](2026-09-01-ios-port-development-history.md)
   — product request, device feedback, and the v0.1–v0.6 development ledger.
3. [2026-09-01-ios-port-key-decisions.md](2026-09-01-ios-port-key-decisions.md)
   — architecture and product decisions with reasons and consequences.
4. [2026-09-02-build-test-release-runbook.md](2026-09-02-build-test-release-runbook.md)
   — reproducible Windows, GitHub, IPA, and release procedure.
5. [2026-09-02-agentic-development-workflow.md](2026-09-02-agentic-development-workflow.md)
   — how delegated work is scoped, reviewed, and retired.
6. [2026-09-02-feature-state-and-next-work.md](2026-09-02-feature-state-and-next-work.md)
   — honest feature matrix and dependency-ordered next work.
7. [2026-09-02-v0.6-pages-layers-release.md](2026-09-02-v0.6-pages-layers-release.md)
   — tagged feature notes, CI evidence, IPA checksum, and download links.
8. [2026-09-02-v0.7-major-feature-batch.md](2026-09-02-v0.7-major-feature-batch.md)
   — broad drawing, document, Pencil, Files, and export implementation jump.

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
