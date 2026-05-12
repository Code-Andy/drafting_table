# tools/

Development helpers — none of this is shipped in the APK.

## perfetto trace capture

For investigating the commit-time flash on fast handwriting.

1. Connect the MovinkPad via USB, ensure adb sees it (`adb devices`).
2. Launch the app to the canvas.
3. From the repo root:
   ```powershell
   .\tools\capture-trace.ps1
   ```
4. The script gives you a 10-second window — write a few short letters
   like `t` / `i` / `l` to trigger the flash during the capture.
5. The `.perfetto-trace` lands in the current directory. Open at
   [ui.perfetto.dev](https://ui.perfetto.dev) (drag the file into the
   browser).

### What to look for in the trace

Find the `com.bk.drawing` process row. The custom slices to scan for:

- `DrawingApp.onDrawFrontBufferedLayer` — front-buffer dispatch
- `DrawingApp.extendStrokeBatch` — native dab + preview pass
- `DrawingApp.onDrawMultiBufferedLayer` — commit-time callback
- `DrawingApp.commitStroke` — bake + persist (inside the above)
- `DrawingApp.renderDocument` — multi-buffer re-composite

Correlate with system rows above:

- `SurfaceFlinger` row — when each transaction is applied and which
  buffer is composited.
- Vsync events on the `gfx` row — frame boundaries.

The flash investigation question: **after `commitStroke` returns, when
does the next vsync present a multi-buffer with the new content, and
where is the front buffer during that interval?** The trace will show
the gap if there is one.

### Tracking flashes through the framework (buffer-level)

When ATRACE markers say our work fits in vsync but the user still sees
a flash, the cause is downstream of the GL thread. Three perfetto data
sources cover the rest of the pipeline:

- `android.surfaceflinger.frame` — adds a **Frame Timeline** row per
  process. Click into the layer for `com.bk.drawing` and you'll see
  one entry per displayed frame: `expected present`, `actual present`,
  jank type. If the "actual present" for the commit-frame is on a
  *later* vsync than where the new MB buffer arrived, that's the flash.
- `android.surfaceflinger.layers` — adds **Layer** rows under
  SurfaceFlinger. Look for our layer names; on each composition cycle
  the trace shows which buffer slot is being read. A flash is visible
  as one composition where the FB layer is invisible AND the MB layer
  is still pointing at the *previous* buffer.
- `android.surfaceflinger.transactions` — every `Transaction.apply()`
  becomes a slice. The GLFrontBufferedRenderer wraps FB-hide + MB-set
  into a single transaction in theory; this track lets us verify they
  arrive as one atomic transaction rather than two separate ones.

To find a specific flash: locate a `commitStroke` slice whose timeline
neighborhood looks normal (commit + renderDocument fit in vsync), then
walk down to the SurfaceFlinger / Frame Timeline rows on the same
horizontal range. The composition that *should* show the new stroke is
the one whose "expected present" lines up just after our
`onDrawMultiBufferedLayer` returns. If that composition's buffer slot
or jank info indicates an old MB buffer was used, that's the smoking
gun for buffer-queue / fence ordering.
