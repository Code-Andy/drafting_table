# 2026-09-02 — agentic development workflow

## Operating model

The root Codex agent is the orchestrator and integrator. It owns architecture,
scope, review, conflict resolution, validation, commits, pushes, CI diagnosis,
release tags, artifact inspection, and the user-facing handoff.

Implementation agents are used only for concrete bounded work. They may produce
crude inventory, scaffolding, boilerplate, isolated algorithms, or a component
with explicit file ownership. Their report is input to review; it is never
evidence by itself that the app builds or that a feature is complete.

## Completed delegated tracks

The following tracks were used during the 2026-09-01 port session:

| Track | Agent label | Contribution |
| --- | --- | --- |
| visible UI | Godel | Paper canvas, visible chrome, icon/device loop |
| smooth strokes | Fermat | Curved-stroke interpolation and join work |
| pen activation UI | Raman | Software activation/lift-off tuning |
| retained stroke engine | Lagrange | Tool styles, Undo/Redo, archive/autosave slice |
| transform renderer | Leibniz | Metal document-to-view transform |
| canvas gestures | McClintock | Two-finger pan/pinch/rotation integration |
| dynamic rails | Rawls | Page/layer UIKit controls |
| page/layer engine | Helmholtz | Retained structure and archive migration |
| sparse Metal tiles | Hooke | Tile renderer foundation, not yet connected |

These tracks should be treated as completed/retired after their final reports.
Future work should create fresh, narrowly scoped tasks rather than assuming a
previous agent is still active or owns the subsystem.

## Delegation contract

Every delegated task must state:

- the exact objective and non-goals;
- files or subsystem it exclusively owns;
- interfaces it may call but not change;
- required tests or verification;
- platform limitations, especially inability to run Xcode on Windows;
- an explicit requirement to report incomplete behavior and risky assumptions.

Avoid concurrent writes to the same file. Cross-cutting architecture, archive
format changes, public bridge APIs, versioning, and release work stay with the
orchestrator unless a dedicated review step is planned.

## Integration checklist

For every returned change, the orchestrator checks:

1. Does the diff match the bounded task and avoid unrelated churn?
2. Does it preserve the Android intent described by `CLAUDE.md` without
   pretending Android-specific APIs are portable?
3. Are document/view coordinates, input ownership, prediction replacement,
   premultiplied alpha, negative tile addressing, and archive bounds preserved?
4. Are comments truthful about connected versus foundational behavior?
5. Are Swift/Objective-C++ names and types likely to import correctly?
6. Do Windows tests pass?
7. Does macOS/Xcode CI pass after push?
8. Does the exact IPA contain the expected version and resources?

## Validation and release loop

```text
scope bounded work
    -> delegate isolated implementation if useful
    -> inspect and integrate the diff
    -> run portable tests
    -> commit and push
    -> inspect Windows and macOS CI
    -> fix Apple-only compiler issues
    -> inspect branch IPA
    -> tag release
    -> inspect tagged IPA and checksum
    -> obtain real-device feedback
```

## Documentation responsibility

The orchestrator updates this `documentation/` directory whenever a key
decision, release, migration, build failure, or device-feedback change affects
the next developer's choices. Agent names and chat mechanics are operational
context; the source, tests, commits, CI, and device observations remain the
evidence of product state.
