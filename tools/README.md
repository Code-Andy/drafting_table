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
