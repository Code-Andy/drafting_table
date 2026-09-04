---
name: drafting-table-ipad-preview
description: Continue, refactor, or build the Drafting Table iPad fork for a reviewable v0.1 foundation and personal-sideload IPA. Use only for this fork's renderer, document, Pencil, package, bridge, CI, or IPA work; do not activate for generic iOS tasks.
---

# Drafting Table iPad preview workflow

Use this skill when the task targets `Code-Andy/drafting_table`, the Drafting
Table iPad fork checkout, or its v0.1 foundation. Read
`documentation/v0.1-refactor-workflow.md` before changing source; it is the
authoritative checklist and assumption log.

## Required operating rules

- Inspect remotes, branch, and `git status` first. Never overwrite, reset,
  clean, or switch away from a dirty checkout.
- Treat the original repo as design/reference material and Android as a
  behavior reference, not an oracle. Record intentional semantic differences.
- Keep document mutations serial. UI sends POD commands; Metal exclusively
  writes resident raster pixels; I/O reads immutable completed generations.
- Every tile tracks content and persisted generations, residency, and payload
  references. Never publish a generation before its GPU command buffer
  completes. Undo is the renderer transaction's atomic before/after tile
  record, not an unrelated command-history entry.
- Apply layer opacity once per group. Avoid full-page per-layer targets.
- Keep DTAR as a one-way importer only; never dual-write it or retain it as a
  live fallback after the tile path is accepted.
- Never add synchronous Pencil-path readback. Use ordered GPU checkpoints and
  asynchronous persistence.
- Use Luna at max reasoning for bounded work with exclusive file ownership.
  Use Sol sparingly for difficult bridge/renderer/transaction contracts.
  Review every major step and do not merge a worker's report without checking
  its diff and tests.
- If the shared index is dirty, commit owned files with `git commit --only`.
  Do not reset or include other agents' changes.
- Run portable Windows tests, then push and use macOS GitHub Actions for
  Swift/Objective-C++/Metal validation. A launch-only simulator smoke is not
  enough: submit a synthetic stroke through the public bridge and assert its
  persisted tile contains nonzero alpha. Deliver one verified unsigned arm64
  IPA for SideStore/AltStore. Do not prepare App Store/TestFlight distribution
  unless explicitly requested.

## v0.1 acceptance boundary

The first useful preview is one package-backed document, one page, two raster
layers, Pencil brush, true eraser, grouped opacity, renderer-transaction
undo/redo, close/reopen recovery, exact tile tests, tolerant visual goldens,
and a physical-iPad smoke test. Defer vectors, selections, snapping,
multi-page scale, and broad UI parity until the foundation gate passes.

## Completion report

End each task with the reviewed commit hash, files owned, tests and CI links,
IPA path/checksum if built, remaining gaps, and an explicit list of assumptions
(device/Pencil, bucket semantics, package container, Android behaviors not
copied, and signing/distribution limits).
