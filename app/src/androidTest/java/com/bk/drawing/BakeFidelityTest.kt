package com.bk.drawing

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Verifies that the raster-stroke bake produces identical pixels
 * across an undo/redo cycle. This is the spec the upcoming undo
 * refactor (re-bake from samples instead of restoring after-state
 * bytes) must satisfy.
 *
 * Each test:
 *   1. Draws a stroke through the production JNI path.
 *   2. Captures the layer's pixels.
 *   3. Undoes the stroke, then redoes it.
 *   4. Captures pixels again.
 *   5. Asserts the two snapshots are bit-identical.
 *
 * Currently the redo path memcpy's stored AFTER bytes back, so this
 * passes trivially. After the refactor, redo will re-run the bake;
 * this test will fail if the bake is not perfectly deterministic.
 */
@RunWith(AndroidJUnit4::class)
class BakeFidelityTest : RendererTestBase() {

    /** Width/height passed to extendStrokeBatch. The renderer uses
     *  it for the live front-buffer overlay (we ignore that path in
     *  tests) and to size the preview pre-pass. 1024 covers the
     *  modest sample ranges these tests draw within. */
    private val bufW = 1024
    private val bufH = 1024

    /** Apply standard brush settings for tests. Opaque red, default
     *  size, hard brush, predictions off. Call inside a gl{} block. */
    private fun standardBrush() {
        NativeRenderer.setTool(0)
        NativeRenderer.setBrushColor(0xFF0000)
        NativeRenderer.setBrushAlpha(1.0f)
        NativeRenderer.setBrushSize(1.0f)
        NativeRenderer.setBrushHardness(1.0f)
        NativeRenderer.setPredictionEnabled(false)
    }

    /** Run a single stroke through begin/extend/commit and drain the
     *  resulting actions. */
    private fun runStroke(xyp: FloatArray) {
        NativeRenderer.beginStroke()
        NativeRenderer.extendStrokeBatch(bufW, bufH, identity4x4,
                                         xyp, xyp.size / 3)
        NativeRenderer.commitStroke()
        NativeRenderer.flushPendingActions()
    }

    @Test
    fun shortStrokeAtOrigin_undoRedoMatches() {
        gl {
            standardBrush()

            // Short diagonal stroke within a single 256-px tile.
            val xyp = floatArrayOf(
                100f, 100f, 0.7f,
                120f, 110f, 0.7f,
                140f, 120f, 0.7f,
                160f, 130f, 0.7f,
            )
            runStroke(xyp)

            val baked = captureLayer(0)
            check(baked.tiles.isNotEmpty()) { "no tiles painted" }

            NativeRenderer.undo()
            NativeRenderer.flushPendingActions()
            NativeRenderer.redo()
            NativeRenderer.flushPendingActions()

            val rebaked = captureLayer(0)
            baked.assertEquals(rebaked, "shortStrokeAtOrigin")
        }
    }

    @Test
    fun longStrokeSpanningTiles_undoRedoMatches() {
        gl {
            standardBrush()

            // Diagonal stroke crossing the tile boundary at x=256 and
            // y=256 — exercises multi-tile bbox plus apron-stale flag
            // handling on neighbors.
            val xyp = floatArrayOf(
                100f, 100f, 0.6f,
                200f, 200f, 0.7f,
                300f, 300f, 0.8f,
                400f, 400f, 0.7f,
                500f, 500f, 0.6f,
            )
            runStroke(xyp)

            val baked = captureLayer(0)
            check(baked.tiles.size >= 4) {
                "expected stroke to span ≥4 tiles, got ${baked.tiles.size}"
            }

            NativeRenderer.undo()
            NativeRenderer.flushPendingActions()
            NativeRenderer.redo()
            NativeRenderer.flushPendingActions()

            captureLayer(0).also {
                baked.assertEquals(it, "longStrokeSpanningTiles")
            }
        }
    }

    @Test
    fun variablePressure_undoRedoMatches() {
        gl {
            standardBrush()

            // Pressure ramp across the stroke — exercises radiusOf
            // for the full input range including the kMinRadius=0
            // floor at the tail.
            val xyp = floatArrayOf(
                100f, 100f, 0.05f,
                150f, 120f, 0.30f,
                200f, 140f, 0.60f,
                250f, 160f, 0.90f,
                300f, 180f, 0.50f,
                350f, 200f, 0.10f,
            )
            runStroke(xyp)

            val baked = captureLayer(0)
            NativeRenderer.undo()
            NativeRenderer.flushPendingActions()
            NativeRenderer.redo()
            NativeRenderer.flushPendingActions()
            baked.assertEquals(captureLayer(0), "variablePressure")
        }
    }

    @Test
    fun eraserStroke_undoRedoMatches() {
        gl {
            // Lay down some ink first so the eraser has something
            // to erase.
            standardBrush()
            runStroke(floatArrayOf(
                100f, 100f, 0.9f,
                200f, 200f, 0.9f,
                300f, 300f, 0.9f,
            ))

            // Switch to eraser and drag across the ink.
            NativeRenderer.setTool(1)            // 1 = eraser
            runStroke(floatArrayOf(
                150f, 150f, 0.8f,
                250f, 250f, 0.8f,
            ))

            val afterErase = captureLayer(0)
            NativeRenderer.undo()                // undo erase
            NativeRenderer.flushPendingActions()
            NativeRenderer.redo()                // redo erase
            NativeRenderer.flushPendingActions()
            afterErase.assertEquals(captureLayer(0), "eraserStroke")
        }
    }

    @Test
    fun strokeCreatingNewTile_undoRedoMatches() {
        gl {
            standardBrush()

            // Two strokes in different tile regions. Strokes #1 is at
            // tile (0,0); stroke #2 forces creation of tile (4,4).
            // Tests that undo of stroke #2 deletes the new tile and
            // redo re-creates it with identical content.
            runStroke(floatArrayOf(50f, 50f, 0.8f, 100f, 100f, 0.8f))
            runStroke(floatArrayOf(
                1024f, 1024f, 0.8f,
                1080f, 1080f, 0.8f,
            ))

            val afterBoth = captureLayer(0)
            val tileCountAfterBoth = afterBoth.tiles.size

            // Undo the new-tile stroke and confirm a tile actually
            // got removed — the redo path's tile recreation is the
            // case we want to validate.
            NativeRenderer.undo()
            NativeRenderer.flushPendingActions()
            val afterUndo = captureLayer(0)
            check(afterUndo.tiles.size < tileCountAfterBoth) {
                "undo should have removed at least one tile"
            }

            NativeRenderer.redo()
            NativeRenderer.flushPendingActions()
            afterBoth.assertEquals(captureLayer(0), "strokeCreatingNewTile")
        }
    }

    @Test
    fun sequentialStrokes_undoBothRedoBoth_matches() {
        gl {
            standardBrush()

            runStroke(floatArrayOf(80f, 80f, 0.7f, 180f, 80f, 0.7f))
            runStroke(floatArrayOf(80f, 180f, 0.7f, 180f, 180f, 0.7f))

            val afterBoth = captureLayer(0)

            // Wind back to blank, then replay forward — the
            // refactor's main correctness risk is that the SECOND
            // redo's re-bake starts from the correct pre-state (the
            // first redo just restored it), not from blank.
            NativeRenderer.undo()
            NativeRenderer.flushPendingActions()
            NativeRenderer.undo()
            NativeRenderer.flushPendingActions()
            NativeRenderer.redo()
            NativeRenderer.flushPendingActions()
            NativeRenderer.redo()
            NativeRenderer.flushPendingActions()

            afterBoth.assertEquals(captureLayer(0), "sequentialStrokes")
        }
    }
}
