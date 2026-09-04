# iPad release-pipeline hardening

This document records the release contract for the unsigned iPad v0.1
preview. It is deliberately separate from the renderer/product refactor: a
build that cannot be traced to one source commit, inspected as a device app,
and re-signed by SideStore is not a releasable preview.

## Release invariants

- The IPA is built from one immutable commit SHA. A manual workflow dispatch
  may select a branch or commit, but the release job checks out and publishes
  the SHA emitted by the build job, never the runner's moving default branch.
- The artifact includes `DraftingTable.ipa` and `build-metadata.txt`. The
  metadata binds the source SHA, bundle identifier, marketing version, build
  number, minimum OS, and IPA SHA-256. Release publication verifies all of
  those bindings before touching a GitHub Release.
- The app is an iOS device build containing an arm64 Mach-O executable. A
  simulator-only or malformed executable is rejected.
- `Info.plist` must contain `CFBundleIdentifier`,
  `CFBundleShortVersionString`, `CFBundleVersion`, and `MinimumOSVersion`.
  `build_ipa.sh` obtains the expected values from Xcode's generated build
  settings (which are sourced from `project.yml`) and passes them to the
  packaging validator.
- `default.metallib` must be present and non-empty in the app bundle. This is
  the compiled Metal library loaded by the renderer at runtime.
- The app and nested payloads are unsigned: no `_CodeSignature`,
  `embedded.mobileprovision`, or signature resources, and `codesign -dvv`
  must report that the code object is not signed. Signing remains the job of
  SideStore, AltStore, or another user-authorized signer.
- The package has exactly one `Payload/*.app`, contains its executable,
  `Info.plist`, and Metal library, and passes `unzip -t` integrity checking.

## Workflow provenance

`.github/workflows/ipad-build.yml` exposes the build SHA as a job output. The
build job first packages and validates the app, writes provenance metadata,
and uploads both files under an artifact name containing that SHA. The release
job then:

1. checks out `needs.build.outputs.built_sha` with a detached, shallow checkout;
2. downloads the artifact with the same SHA in its name;
3. compares metadata, checkout SHA, and the computed IPA SHA-256;
4. resolves an existing remote tag and refuses to publish if it points at a
   different commit; and
5. creates a new release with `gh release create --target <built-sha>` or
   uploads to an existing release already attached to that SHA.

This protects the manual-release path from a branch advance, a stale artifact,
or a tag that was created from another commit. Existing releases are never
silently overwritten with an IPA from a different source revision.

## SideStore and AltStore

The IPA intentionally remains unsigned. A user can download the workflow
artifact or GitHub Release asset and import it into SideStore, which applies a
personal signing identity and provisioning profile. The workflow does not
request a team, certificate, profile, or entitlement and does not change this
unsigned contract.

`generate_altstore_source.py` requires the final public HTTPS IPA URL and icon
URL. Bundle ID, marketing version, build number, and minimum OS now default to
the values read from the IPA's `Payload/*.app/Info.plist`; optional command-line
values are accepted only when they match. The feed records the IPA byte size
and SHA-256, so a stale feed cannot accidentally describe a different build.
The generator does not sign, upload, or read credentials.

Example (run after a public release exists):

```bash
python3 scripts/ios/generate_altstore_source.py \
  --ipa-path dist/ios/DraftingTable.ipa \
  --ipa-url https://github.com/Code-Andy/drafting_table/releases/download/v0.1.0/DraftingTable.ipa \
  --icon-url https://example.invalid/drafting-table-icon.png \
  --output dist/ios/altstore-source.json
```

The icon URL is intentionally still explicit: the repository may not have a
stable public icon host, while app identity and version data are authoritative
inside the IPA itself.

## Validation by environment

Windows can run static checks without pretending to build iOS artifacts:

```powershell
python -m py_compile scripts/ios/generate_altstore_source.py
git diff --check
```

The actual build/package checks are macOS-only and require Xcode, XcodeGen,
`xcodebuild`, `PlistBuddy`, `lipo`, `codesign`, `ditto`, `zip`, and `unzip`:

```bash
xcodegen generate --spec project.yml
bash scripts/ios/build_ipa.sh
```

A successful run prints the IPA path and writes
`dist/ios/build-metadata.txt`. Before a device preview, inspect the generated
metadata and SHA-256, then install the unsigned IPA through SideStore on an
iPad. The simulator smoke test remains a useful launch check but cannot prove
device architecture, Metal-library loading, or post-signing behavior.

## Design decisions and bounded trade-offs

- `project.yml` remains the single project-definition input; these scripts do
  not duplicate or rewrite its bundle/version/deployment settings.
- The logical release protocol is artifact-plus-provenance, but no assumption
  is made that a future distribution service stores one file per tile or one
  file per build. GitHub Release assets are immutable by SHA at publication;
  storage layout for document data is a separate renderer concern.
- The validator requires macOS inspection tools rather than silently skipping
  checks on a non-macOS host. This makes Windows validation intentionally
  static and prevents a false “device IPA” success.
