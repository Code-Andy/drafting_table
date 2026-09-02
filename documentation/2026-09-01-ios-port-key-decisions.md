# 2026-09-01 — iPad port key decisions

Each decision records the choice, why it was made, and what it implies for
future work.

## D001 — Native iPad shell, portable C++ engine, Metal renderer

Status: accepted.

UIKit owns lifecycle, interface, gesture arbitration, and Apple Pencil event
capture. Objective-C++ provides a narrow ownership/API bridge. Portable C++20
owns canonical samples and document behavior. Metal owns iPad rendering.

This retains high-value engine logic across platforms while allowing iPadOS
input and rendering to be implemented in the APIs designed for them. It avoids
trying to compile the Android Kotlin/JNI/OpenGL ES application directly for
iOS.

Consequence: platform-neutral behavior must be tested without UIKit/Metal, and
the thin bridge must be treated as a compiler-sensitive boundary.

## D002 — Windows edits and tests; GitHub macOS builds the IPA

Status: accepted.

Xcode, the iOS SDK, and Metal compiler are unavailable on Windows. GitHub
Actions on `macos-15` with Xcode 16.4 therefore performs the authoritative
device build. Windows runs C++ tests and repository checks before pushing.

Consequence: Apple-only compiler feedback arrives after a push. CI failures are
normal integration feedback, but a release tag is prohibited until both the
portable and macOS workflows pass on the exact commit.

## D003 — Unsigned IPA, signed by the sideloading tool

Status: accepted.

The build uses `CODE_SIGNING_ALLOWED=NO` and packages
`Payload/DraftingTable.app` as `DraftingTable.ipa`. No Apple development team,
certificate, provisioning profile, CocoaPods, or Fastlane is required in CI.
SideStore or another sideloading tool applies the user's signature later.

Consequence: CI proves build/package integrity, not install entitlement or
certificate longevity. SideStore device testing remains a separate gate.

## D004 — Device-testable vertical slices before parity

Status: accepted.

The blank first scaffold showed that archive success alone was insufficient.
Subsequent versions each needed a visible, testable improvement: canvas/icon,
stroke quality, settings/persistence, gestures, then page/layer behavior.

Consequence: foundations that are present but not connected must be described
as foundations. User-visible acceptance and internal completeness are tracked
separately.

## D005 — Immediate retained-stroke renderer remains temporary

Status: accepted, replacement pending.

The current visible renderer replays retained stroke geometry because it made
Pencil feedback available quickly. A sparse 258×258 Metal tile backend exists
but is not yet wired through ordered live/predicted/committed commands.

Consequence: the current eraser is paper-colored replay; large documents will
not have the memory/performance behavior of the final sparse raster engine.
Do not expand this path into a second production compositor. The next raster
work should connect the tile backend deliberately.

## D006 — Document coordinates are canonical

Status: accepted.

UIKit samples are converted from view points into document coordinates before
entering C++. Metal applies the matching document-to-view transform.

Consequence: stored strokes are independent of pan/zoom/rotation. Snapping,
selection, vectors, export, and persistence must continue to use document
coordinates. Gesture logic must preserve the document point under its centroid.

## D007 — Pencil "height" is a software activation threshold

Status: accepted.

iPadOS does not expose control over Apple Pencil's physical hover/detection
height. The app therefore treats low normalized force as not yet down and uses
a lower release threshold to avoid chatter around the boundary.

The activation range is 0–20%; release is 55% of activation. The setting is
persistent and intentionally housed in Settings because it is device/screen
protector calibration, not a frequent drawing control.

Consequence: UI copy must not promise hardware lift-off or hover adjustment.
Real device validation should cover light strokes and premature lift breaks.

## D008 — Archive evolution is versioned and transactional

Status: accepted.

`DTAR` archives are bounded, little-endian, rejected on malformed/trailing
input, and loaded transactionally so a failed decode does not destroy the
current session. Autosave uses atomic replacement. Version 2 adds pages and
layers; version 1 migrates into a single `Page 1 / Ink` structure.

Consequence: every schema change requires a new version or explicit compatible
extension, migration fixtures, round-trip tests, size/count bounds, and a
failure test that confirms existing state survives bad input.

## D009 — Page/layer deletion preserves minimum valid structure

Status: accepted.

A document always has at least one page, and a page always has at least one
layer. The engine rejects deletion of the final item; the interface also
disables the corresponding menu action.

Consequence: engine invariants do not depend on UI correctness. Selection
indices must be repaired after deletion, load, and future reorder operations.

## D010 — Release assets are not committed binaries

Status: accepted.

IPAs are attached to GitHub Releases. The repository stores build scripts and
a release manifest, not versioned binary blobs or a `release/` pile in Git.

Consequence: the stable user link is the tagged release asset. A local
`DraftingTable-latest.ipa` may be kept as a convenience output, but it is not
the public source of truth.

## D011 — Upstream remains fetch-only

Status: accepted.

`origin` is `Code-Andy/drafting_table`; `upstream` is
`bgkatz/drafting_table` with push URL disabled (`no_push`). Work is performed on
`ipad-native-port`.

Consequence: accidental pushes to the original project are prevented. Upstream
changes must be fetched and integrated explicitly.

## D012 — Public distribution has a licensing gate

Status: unresolved external constraint.

The upstream repository has no license file. GitHub labels the repository as a
fork through its fork network, but that does not grant redistribution rights.

Consequence: local development and personal sideloading can proceed, while
broader redistribution should wait for explicit upstream permission or a
license. Release visibility must not be represented as legal permission.
