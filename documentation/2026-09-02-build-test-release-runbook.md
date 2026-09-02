# 2026-09-02 — build, test, and release runbook

## Tool summary

### Windows development machine

Required:

- Git and GitHub CLI (`gh`)
- Visual Studio C++ Build Tools or LLVM/clang
- CMake 3.20+ for the canonical configure/build/test path
- Python 3 only for the optional AltStore/SideStore source generator

Already observed on this machine: Git, authenticated `gh`, and Visual Studio
2019 C++ Build Tools. CMake was not initially on `PATH`; direct MSVC compilation
was used locally while GitHub ran canonical CMake/CTest.

Do not attempt to install Xcode, Apple SDKs, Metal tools, CocoaPods, or Fastlane
on Windows. This repository currently has no CocoaPods dependencies and the
unsigned build does not require Fastlane.

### GitHub macOS build host

- `macos-15`
- Xcode 16.4 or newer with iOS 18 SDK
- XcodeGen; the workflow installs it when absent
- Bash, `zip`, and standard Xcode command-line tools

No signing certificate, provisioning profile, or development team is used.

### Sideloading

SideStore or another compatible signer installs the unsigned IPA. Signing,
pairing, LocalDevVPN behavior, refresh intervals, and free-account limits are
outside the application build itself.

## Portable tests on Windows

Canonical path:

```powershell
cmake -S . -B build/core -DBUILD_TESTING=ON
cmake --build build/core --config Release --parallel
ctest --test-dir build/core -C Release --output-on-failure
```

The suite currently covers:

- canonical Pencil samples, pressure, transforms, and signed tile coordinates;
- document/vector persistence and malformed input;
- brush emission and coverage math;
- C++/Metal instance layout compatibility;
- retained iPad engine styles, Undo/Redo, pages/layers, archive v1 migration,
  archive v2 round trip, and transactional failure behavior.

If CMake is unavailable, initialize the Visual Studio environment with
`VsDevCmd.bat` and directly compile the relevant test plus its source files.
This is a local fallback, not a substitute for the GitHub CMake workflow.

## Unsigned IPA build

On macOS:

```bash
brew install xcodegen
xcodegen generate --spec project.yml
bash scripts/ios/build_ipa.sh
```

Expected output:

```text
dist/ios/DraftingTable.ipa
```

The script performs a device build with signing disabled and packages the
`.app` under the required `Payload/` directory.

## GitHub workflows

- Portable tests:
  <https://github.com/Code-Andy/drafting_table/actions/workflows/core-tests.yml>
- iPad build:
  <https://github.com/Code-Andy/drafting_table/actions/workflows/ipad-build.yml>

Every branch push runs both workflows. A tag matching `v*` also causes the iPad
workflow to publish `DraftingTable.ipa` to the matching GitHub Release.

## Release gate

Before creating a version tag:

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. Ensure `git status --short` is empty.
3. Ensure both workflows passed on the exact commit to be tagged.
4. Download and inspect the branch artifact.
5. Confirm the packaged `Info.plist` version/build match `project.yml`.
6. Confirm the archive contains:
   - `Payload/DraftingTable.app`;
   - an arm64 executable;
   - processed `Info.plist`;
   - compiled app icons/assets;
   - `default.metallib`.
7. Write release notes distinguishing user-visible behavior from foundations.
8. Create and push an annotated or lightweight `vX.Y.Z` tag.
9. Wait for the tag workflow and release job to finish.
10. Download the release asset, calculate SHA-256, and verify it again.

Useful commands:

```powershell
git tag v0.6.0
git push origin v0.6.0
gh run list --repo Code-Andy/drafting_table --limit 10
gh release view v0.6.0 --repo Code-Andy/drafting_table
Get-FileHash -Algorithm SHA256 .\DraftingTable.ipa
```

Do not tag `v0.6.0` until the failure recorded in
`2026-09-02-current-development-handoff.md` is fixed.

## Public artifact locations

- Latest release: <https://github.com/Code-Andy/drafting_table/releases/latest>
- All releases: <https://github.com/Code-Andy/drafting_table/releases>
- v0.5.0 IPA:
  <https://github.com/Code-Andy/drafting_table/releases/download/v0.5.0/DraftingTable.ipa>

## Failure handling

When the macOS workflow fails:

1. Read the first real compiler error, not only the final exit code.
2. Patch the source boundary named by Xcode.
3. Run available Windows tests and syntax/format checks.
4. Commit and push a focused fix.
5. Let the new run supersede the old failure; do not retag an unverified commit.

When an archive decode or autosave change is involved, add failure/migration
tests before releasing. When rendering/input changes are involved, a passing CI
build still requires real-iPad Pencil and gesture validation.
