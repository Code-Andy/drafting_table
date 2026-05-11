package com.bk.drawing

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Before
import java.io.File

/**
 * Base class for renderer fidelity tests. Each test runs against a
 * fresh, empty document dir under the app's cache dir, with one
 * blank raster layer ready to draw into. Subclasses call [gl] to
 * dispatch onto the offscreen GL thread.
 */
abstract class RendererTestBase {
    protected lateinit var docDir: File

    @Before
    fun rendererBaseSetup() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        docDir = File(ctx.cacheDir, "test-doc-${System.nanoTime()}")
        docDir.deleteRecursively()
        docDir.mkdirs()
        gl {
            // loadDocument (rather than setDocumentDir) routes
            // through the action drain, which calls
            // closeCurrentDocument first — that releases the
            // previous test's GL objects (FBOs, textures) and clears
            // g_pages / undo / pending shapes. Without this reset,
            // state leaks between tests.
            NativeRenderer.loadDocument(docDir.absolutePath)
            // Default page bounds large enough for any reasonable
            // test stroke. Strokes outside this clip get dropped.
            NativeRenderer.setPageBounds(0f, 0f, 2048f, 2048f)
            // View scale of 1.0 keeps snap radii and ViewPx-derived
            // brush sizes in their natural doc-px units.
            NativeRenderer.setViewScale(1.0f)
            // Drain the load action so the fresh doc is in effect
            // before tests start dispatching strokes.
            NativeRenderer.flushPendingActions()
        }
    }

    @After
    fun rendererBaseTeardown() {
        if (::docDir.isInitialized) {
            docDir.deleteRecursively()
        }
    }

    /** Dispatch a block onto the shared GL thread. Exceptions propagate. */
    protected fun <T> gl(block: () -> T): T = GLTestContext.shared().run(block)

    // ---- Helpers -------------------------------------------------------

    /** Identity 4×4 matrix in column-major order — the no-op transform
     *  for tests that work in doc-pixel coordinates and don't need a
     *  view→buffer mapping. */
    protected val identity4x4: FloatArray = floatArrayOf(
        1f, 0f, 0f, 0f,
        0f, 1f, 0f, 0f,
        0f, 0f, 1f, 0f,
        0f, 0f, 0f, 1f
    )

    /** A "snapshot" of a single layer — every existing tile's
     *  (tx, ty) and its kTileBytes interior bytes. Comparing two
     *  snapshots tests whether two render paths produce identical
     *  pixels. */
    data class LayerSnapshot(val tiles: Map<Pair<Int, Int>, ByteArray>) {
        fun assertEquals(other: LayerSnapshot, msg: String = "") {
            check(tiles.size == other.tiles.size) {
                "$msg tile count: ${tiles.size} vs ${other.tiles.size}"
            }
            for ((coord, bytes) in tiles) {
                val otherBytes = other.tiles[coord]
                    ?: error("$msg tile $coord missing in other snapshot")
                check(bytes.contentEquals(otherBytes)) {
                    "$msg tile $coord pixels differ"
                }
            }
        }
    }

    /** Capture every existing tile in [layerIdx]. Must be called from
     *  within a [gl] block. */
    protected fun captureLayer(layerIdx: Int): LayerSnapshot {
        val coords = NativeRenderer.getLayerTileCoords(layerIdx)
        val map = mutableMapOf<Pair<Int, Int>, ByteArray>()
        var i = 0
        while (i < coords.size) {
            val tx = coords[i]
            val ty = coords[i + 1]
            val bytes = NativeRenderer.readTileBytes(layerIdx, tx, ty)
                ?: error("readTileBytes returned null for ($tx,$ty)")
            map[tx to ty] = bytes
            i += 2
        }
        return LayerSnapshot(map)
    }
}
