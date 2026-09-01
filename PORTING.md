# iPad port status

The `ipad-native-port` branch is a local development fork of Drafting Table.
It currently provides a buildable vertical architecture, not feature parity
with the Android application.

## What exists now

- A portable C++20 core with canonical Pencil samples, estimated-property IDs,
  replaceable prediction tails, pressure mapping, canvas transforms, and
  signed sparse-tile addressing.
- Dependency-free Windows tests for the portable core.
- A UIKit/Metal iPad application shell generated with XcodeGen.
- Batched real, coalesced, and predicted Apple Pencil input through a thin
  Objective-C++ bridge into the portable core.
- Pressure, altitude, azimuth, barrel roll, estimated-value correction,
  double-tap, and squeeze event capture.
- A minimal premultiplied-alpha Metal line renderer and diagnostics overlay.
- An unsigned device build and IPA packaging workflow. Version tags can publish
  `DraftingTable.ipa` to a GitHub Release when this work is eventually pushed.
- An optional AltStore/SideStore source JSON generator.

## What is not ported yet

The production Android engine remains in `app/src/main/cpp/renderer.cpp`. Its
document/page/layer model, sparse GPU tiles, binary persistence, undo/redo,
brush coverage, shade fill, vector tools, selection system, snapping, imports,
exports, and GLES compositor still need to be separated from JNI/OpenGL and
connected to a Metal backend. The current iPad renderer draws only a diagnostic
polyline; it is not yet the Drafting Table renderer.

Recommended extraction order:

1. Version and extract the document, page, layer, vector, and persistence
   codecs without changing existing Android files on disk.
2. Extract brush emission, pressure response, snapping, transforms, selection
   geometry, and undo commands into platform-neutral modules.
3. Define a renderer-backend boundary and retain GLES as the Android backend.
4. Implement sparse 258-by-258 apron textures, coverage masks, premultiplied
   compositing, vector SDFs, shade stencil passes, and selection overlays in
   Metal.
5. Port the surrounding document UI, Files document packages, PNG/PDF export,
   image import, Pencil hover/palette/haptics, and on-device diagnostics.
6. Run latency and deterministic undo/redo fidelity tests on real iPad hardware.

## Tools

### Windows development machine

Required:

- Git
- Visual Studio Build Tools with the C++ workload, or LLVM/clang
- CMake 3.20 or newer for the normal `cmake`/`ctest` commands

This machine already has Git and Visual Studio 2019 C++ Build Tools. CMake is
not currently on `PATH`; the core tests can still be compiled directly with
MSVC, which is how this branch was validated locally. Ninja is optional.

Do not try to install Xcode, Swift's Apple SDK, Metal tools, CocoaPods, or
Fastlane on Windows. This project has no CocoaPods dependencies and does not
need Fastlane.

### IPA build host

Required on a macOS build host:

- Xcode 16 or newer with the iOS 18 SDK
- XcodeGen (`brew install xcodegen`); the workflow installs it automatically
- Bash, `zip`, and standard Xcode command-line tools

No Apple certificate, provisioning profile, development team, CocoaPods, or
Fastlane is required to produce the unsigned IPA. The build uses
`CODE_SIGNING_ALLOWED=NO`; the sideloading tool signs it later.

### iPad sideloading

For free-account SideStore installation and refreshes, plan on an Apple
Account, the SideStore Windows prerequisites, the pairing setup, and
LocalDevVPN when installing/updating/refreshing. Free signing is still subject
to Apple's short certificate lifetime; SideStore automates refresh rather than
turning it into a permanent signature.

## Build commands

Portable core on a configured Windows toolchain:

```powershell
cmake -S . -B build/core -DBUILD_TESTING=ON
cmake --build build/core --config Release
ctest --test-dir build/core -C Release --output-on-failure
```

Unsigned IPA on macOS:

```bash
brew install xcodegen
xcodegen generate --spec project.yml
scripts/ios/build_ipa.sh
```

Output:

```text
dist/ios/DraftingTable.ipa
```

## Licensing gate

The upstream repository currently contains no `LICENSE`, `COPYING`, or
`NOTICE` file. Local investigation and private development can continue, but
do not assume permission to redistribute the upstream code or publish an IPA.
Obtain explicit permission or an upstream license before public distribution.
