# Drawing App

Custom technical-notebook / sketching app for the Wacom MovinkPad 11. See `NOTES.md` for design notes and architecture.

## Current state

**Spike 1** — a colored dot follows the pen, scaled by pressure. Validates the input → render path through `GLFrontBufferedRenderer` and the Kotlin↔NDK bridge.

## Build & run (first time)

1. Open this directory in Android Studio (File → Open → select `drawing_app`).
2. Android Studio will prompt to sync Gradle and download the wrapper jar (the wrapper jar is intentionally not in this repo). Let it run.
3. If prompted, install the requested SDK / NDK / CMake versions via the SDK Manager.
4. Connect the MovinkPad over USB (or via wireless ADB — see `NOTES.md`).
5. Hit **Run** (Shift+F10). The app will install and launch.
6. Touch the screen with finger or pen — dots should appear under the contact point, scaled by pressure.

If `adb devices` doesn't show the tablet from inside Android Studio, accept the host-key prompt on the tablet.

## Build & run (CLI)

```powershell
.\gradlew.bat installDebug
adb shell am start -n com.bk.drawing/.MainActivity
```

## Project layout

```
drawing_app/
├── settings.gradle.kts
├── build.gradle.kts                  # Root: AGP + Kotlin plugin versions
├── gradle.properties
├── gradle/wrapper/                   # Wrapper config (jar fetched on import)
├── app/
│   ├── build.gradle.kts              # App module: SDKs, NDK, deps
│   ├── proguard-rules.pro
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── java/com/bk/drawing/
│       │   ├── MainActivity.kt       # Activity, fullscreen + 90 Hz opt-in
│       │   ├── DrawingSurfaceView.kt # SurfaceView + GLFrontBufferedRenderer
│       │   └── NativeRenderer.kt     # JNI surface
│       ├── cpp/
│       │   ├── CMakeLists.txt
│       │   └── renderer.cpp          # GL ES 3 dot-drawing program
│       └── res/values/
│           ├── strings.xml
│           └── themes.xml
└── NOTES.md                          # Design + architecture notes
```

## What's wired up

- **Min SDK 33, target 34, NDK arm64-v8a only** — keeps build fast and uses the modern low-latency APIs.
- **`GLFrontBufferedRenderer`** (from `androidx.graphics:graphics-core`) drives rendering. Front buffer for the live stroke, multi-buffer for committed strokes.
- **JNI bridge** — `NativeRenderer.drawFrontDot` / `drawAllDots` call into `renderer.cpp`. All GL work happens in C++.
- **90 Hz opt-in** via `preferredDisplayModeId` on the activity window.
- **Stylus + finger input** — both `TOOL_TYPE_STYLUS` and `TOOL_TYPE_FINGER` are accepted so you can test without the pen.
- **Historical sample walking** — every input sample between vsyncs renders a dab, not just the most recent.

## Known caveats / things to fix on first build

- `androidx.graphics:graphics-core` is at `1.0.0-alpha05` here. If Android Studio offers a newer version, signatures in `DrawingSurfaceView.kt` may need minor tweaks (e.g. `onDrawMultiBufferedLayer` parameters). The fix is mechanical — let the IDE suggest the correct override signatures.
- The graphics-core artifact is alpha; expect occasional API churn until 1.0 stable.
- If `gradlew.bat` is missing, run `gradle wrapper --gradle-version 8.7` from a Gradle install once (or just open in Android Studio, which generates it).

## Next: Spike 2

Once dots feel responsive (track close to the pen tip when drawing along a straightedge), Spike 2 replaces them with proper textured brush dabs along a smoothed input path. See the build order in `NOTES.md`.
