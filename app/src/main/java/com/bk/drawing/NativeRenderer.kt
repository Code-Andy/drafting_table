package com.bk.drawing

object NativeRenderer {
    init { System.loadLibrary("drawing") }

    /**
     * Configure where on disk the document is persisted. Tiles are read from
     * and written to `<dir>/tile_<tx>_<ty>.bin`. Call before any draw work;
     * loading happens lazily on the first GL operation.
     */
    external fun setDocumentDir(path: String)

    /** Reset emitter state and start a new in-progress stroke. */
    external fun beginStroke()

    /**
     * Append a sample to the current stroke and emit any new dabs needed to
     * reach (x, y), additively, into the bound (front-buffered) layer.
     */
    external fun extendStroke(
        width: Int, height: Int,
        transform: FloatArray,
        x: Float, y: Float, pressure: Float
    )

    /**
     * Bake the in-progress stroke into the tiles its bbox touches, then drop
     * the stroke samples. The tiles ARE the document state from now on.
     */
    external fun commitStroke()

    /**
     * Clear the bound (multi-buffered) layer to white and composite every
     * allocated tile onto it.
     */
    external fun renderDocument(
        width: Int, height: Int,
        transform: FloatArray
    )

    /**
     * Append a new (empty) layer above the current top, and switch the
     * active layer to it. Safe to call from any thread; the action is
     * applied on the GL thread at the start of the next operation.
     */
    external fun addLayer()

    /**
     * Move the active-layer pointer to the next layer, wrapping. Safe to
     * call from any thread.
     */
    external fun cycleActiveLayer()

    /**
     * Delete every tile in the active layer (GL textures + on-disk files).
     * For a vector layer, drops every shape and rewrites the empty marker.
     * Safe to call from any thread.
     */
    external fun clearActiveLayer()

    /**
     * Append a new (empty) vector layer above the current top, switch the
     * active layer to it. Vector layers hold parametric shapes (lines for
     * now; circles/rects later) instead of a tile grid.
     */
    external fun addVectorLayer()

    /**
     * Append a line shape to the active layer (only effective if the
     * active layer is a vector layer). Color and width follow the current
     * brush color and a fixed line width. Safe to call from any thread.
     */
    external fun addLine(x0: Float, y0: Float, x1: Float, y1: Float)

    /**
     * Live preview for the line tool — renders a single line into the
     * currently-bound framebuffer (intended to be the front-buffered
     * layer, called from inside onDrawFrontBufferedLayer). Clears the
     * buffer first so successive previews replace rather than accumulate.
     */
    external fun renderLinePreview(
        width: Int, height: Int,
        transform: FloatArray,
        x0: Float, y0: Float, x1: Float, y1: Float
    )

    /**
     * Set the active drawing tool: 0 = brush, 1 = eraser. The next stroke
     * (i.e. the next beginStroke) snapshots this value, so toggling
     * mid-stroke doesn't split a stroke. Safe to call from any thread.
     */
    external fun setTool(tool: Int)

    /**
     * Set the brush RGB color (alpha is fixed). `rgb` is 0xRRGGBB; any
     * upper bits are ignored. Snapshotted at the next beginStroke. Safe
     * to call from any thread.
     */
    external fun setBrushColor(rgb: Int)

    /**
     * Page-background grid controls. Read at multi-buffer composite time;
     * call forceRedraw() afterward to make a change appear immediately.
     */
    external fun setGridEnabled(enabled: Boolean)
    external fun setGridStyle(style: Int)   // 1 = lines, 2 = dots

    /**
     * Layer-state read accessors for UI display. Values may lag queued
     * addLayer/cycleActiveLayer calls by up to one stroke/render; that's
     * fine for status text.
     */
    external fun getLayerCount(): Int
    external fun getActiveLayer(): Int
}
