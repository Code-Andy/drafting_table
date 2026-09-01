# Local agentic development setup

This file records how the current Codex conversation is coordinating the iPad
port. It is operational context for future agent sessions, not a claim that the
listed milestones are complete product features.

## Repository state

- Local checkout: `D:\Vibe Code\Drafting Table Fork`
- Working branch: `ipad-native-port`
- Fork remote: `origin` -> `Code-Andy/drafting_table`
- Read-only source remote: `upstream` -> `bgkatz/drafting_table`
- GitHub default branch: `ipad-native-port`
- Upstream pushes are intentionally disabled locally.

## Agent roles

### Root orchestrator

The root Codex agent owns architecture, integration, review, tests, commits,
GitHub Actions, release creation, and the final user-facing status. It must not
accept a delegated implementation merely because it is large or plausible; it
reviews invariants against `CLAUDE.md`, compiles everything available on
Windows, and uses macOS CI to resolve Apple-only compiler errors.

### Luna implementation agents

Luna agents receive bounded mechanical tasks with disjoint file ownership.
They are used for source inventory, scaffolding, boilerplate, geometry/codecs,
and isolated platform components. They do not merge, release, or declare the
port complete.

Completed delegated tracks:

- upstream Android/JNI/GLES architecture audit;
- portable Pencil/core foundation;
- iPad UIKit/Metal scaffold;
- unsigned IPA workflow and packaging scripts;
- portable document and VEC0/VEC1 persistence foundation;
- platform-neutral brush/coverage geometry;
- sparse Metal tile backend;
- current visible-UI and immediate-stroke iteration.
- curved-stroke join smoothing and software Pencil activation/lift-off tuning.
- retained Brush/Eraser styles, Undo/Redo, versioned archives, and autosave.

## Delegation rules

1. Give every agent explicit file ownership.
2. Avoid concurrent edits to the same file.
3. Require agents to report compile limitations and unimplemented behavior.
4. Stop and mark completed agents after their final report.
5. Review every delegated diff for Android fidelity, threading, persistence,
   premultiplied alpha, prediction, and negative-tile invariants.
6. Correct misleading comments and remove fake-completeness claims.
7. Commit only after local checks pass.

## Validation loop

```text
delegate isolated work
        -> review/integrate
        -> MSVC portable tests
        -> YAML/JSON/Python validation
        -> commit and push
        -> GitHub Windows tests
        -> GitHub macOS/Xcode IPA build
        -> inspect failed Apple compiler logs
        -> patch and repeat
        -> tag release
        -> verify IPA contents and SHA-256
```

Windows does not have CMake on `PATH`, but Visual Studio 2019 C++ Build Tools
are installed. Portable test executables can be compiled directly through
`VsDevCmd.bat`. GitHub Actions runs the canonical CMake/CTest workflow.

## Release policy

IPA binaries are GitHub Release assets, not Git-tracked files. The repository
contains `releases/README.md` as a stable manifest pointing to the latest
release. Version tags matching `v*` trigger the macOS workflow, package an
unsigned IPA, and create or update the corresponding GitHub Release.

Before tagging:

- both CI workflows must pass on the exact commit;
- the iPad version/build settings must be updated;
- `git status` must be clean;
- the release notes must distinguish implemented behavior from foundations;
- the downloaded IPA must contain `Payload/DraftingTable.app`, an arm64
  executable, `Info.plist`, the app icon assets, and `default.metallib`.

## Current next steps

- validate the version 0.4 retained-session and tools iteration;
- publish the next tagged GitHub Release;
- collect iPad screenshots and threshold/curve behavior notes;
- then connect the sparse tile renderer through an ordered command path rather
  than expanding the diagnostic renderer into a second production engine.
